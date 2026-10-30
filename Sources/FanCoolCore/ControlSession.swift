import Foundation

public struct FanControlIntent: Codable, Identifiable, Sendable {
    public let id: Int
    public let rpm: Double?
    public let confirmed: Bool
    public let smart: Bool
    public init(id: Int, rpm: Double?, confirmed: Bool, smart: Bool = false) {
        self.id = id; self.rpm = rpm; self.confirmed = confirmed; self.smart = smart
    }
}

public struct ControlState: Codable, Sendable {
    public var fans: [FanControlIntent] = []
    public var restoring = false
    public var notice: String?
    public var smartEnabled = false
    public var smartPercentage: Double?
    public var filteredTemperature: Double?
    public var smartReason: String?
    public var smartProfile: SmartProfile?
    public init() {}
}

/// Serial helper-owned session. Intent is distinct from hardware acknowledgement.
public final class ControlSession {
    public static let temperatureLimit = 90.0
    public static let heartbeatTimeout = 6.0
    private let hardware: FanHardware
    private let ownershipChanged: ((Set<Int>) throws -> Void)?
    public private(set) var controlledFans: Set<Int> = []
    public private(set) var lastHeartbeat: Date
    public private(set) var notice: String?
    private var restoring = false
    private var targets: [Int: Double] = [:]
    private var confirmed: Set<Int> = []
    private var corrections: [Int: Int] = [:]
    private var unconfirmedSince: [Int: Date] = [:]
    private var stableSamples: [Int: Int] = [:]
    private var pendingTakeovers: Set<Int> = []
    private var restorationFailureNotice = false
    private var restorationReason: String?
    private var smartPolicy: SmartFanPolicy?
    private var smartFans: Set<Int> = []
    private var smartDecision: SmartDecision?
    private var lastSmartWrite: Date?
    private var appliedSmartPercentage: Double?
    public static let convergenceTimeout = 20.0
    public var state: ControlState {
        var state = ControlState()
        state.fans = controlledFans.sorted().map { .init(id: $0, rpm: targets[$0], confirmed: confirmed.contains($0), smart: smartFans.contains($0)) }
        state.restoring = restoring
        state.notice = !restoring && !pendingTakeovers.isEmpty
            ? "正在等待固件交接（风扇 \(pendingTakeovers.sorted().map { String($0 + 1) }.joined(separator: "、"))），最多 20 秒；可随时切回系统。"
            : notice
        state.smartEnabled = smartPolicy != nil
        state.smartPercentage = appliedSmartPercentage
        state.filteredTemperature = smartDecision?.filteredTemperature
        state.smartReason = smartDecision?.reason
        state.smartProfile = smartPolicy?.profile
        return state
    }
    public init(hardware: FanHardware, now: Date = ControlClock.now, ownershipChanged: ((Set<Int>) throws -> Void)? = nil) {
        self.hardware = hardware; lastHeartbeat = now; self.ownershipChanged = ownershipChanged
    }
    public func heartbeat(now: Date = ControlClock.now) { lastHeartbeat = now }
    public func apply(fan: Int, rpm: Double, now: Date = ControlClock.now, thermalPressure: ThermalPressure = .nominal) throws {
        try applyRequests([(fan, rpm)], now: now, thermalPressure: thermalPressure)
    }
    public func applyPercentage(fan: Int, percent: Double, now: Date = ControlClock.now, thermalPressure: ThermalPressure = .nominal) throws {
        let readings = try hardware.fans().filter { fan == -1 || $0.id == fan }
        guard !readings.isEmpty, fan >= -1 else { throw FanCoolError.unavailable }
        let requests = try readings.map { ($0.id, try FanSpeed.rpm(percent: percent, fan: $0)) }
        try applyRequests(requests, now: now, thermalPressure: thermalPressure)
    }
    public func startSmart(now: Date = ControlClock.now, thermalPressure: ThermalPressure = .nominal,
                           profile: SmartProfile = .defaultProfile) throws {
        guard !thermalPressure.requiresSystemControl else { throw FanCoolError.hardware("系统热压力较高或未知，请保留 macOS 控制。") }
        let readings = try hardware.fans()
        guard !readings.isEmpty, readings.allSatisfy(\.controllable) else { throw FanCoolError.unavailable }
        guard let temperature = hardware.temperature() else { throw FanCoolError.temperatureUnavailable }
        var policy = SmartFanPolicy(profile: profile)
        let floor = readings.compactMap { fan in FanSpeed.percent(rpm: max(fan.actual, fan.mode == 1 ? (fan.target ?? 0) : 0), maximum: fan.maximum) }.max()
        let decision = try policy.evaluate(temperature: temperature, minimumPercentage: FanSpeed.minimumPercent(for: readings), now: now,
            preventDecrease: thermalPressure.preventsDecrease, minimumOutput: thermalPressure.preventsDecrease ? floor : nil)
        let requests = try readings.map { ($0.id, try FanSpeed.rpm(percent: decision.percentage, fan: $0)) }
        try applyRequests(requests, now: now, smartStart: true, thermalPressure: thermalPressure, reason: "智能温控启动（\(profile.title)）：\(decision.reason)")
        smartPolicy = policy; smartDecision = decision
        smartFans = Set(readings.map(\.id))
        appliedSmartPercentage = decision.percentage; lastSmartWrite = now
    }
    public func updateSmartProfile(_ profile: SmartProfile, now: Date = ControlClock.now) {
        // Do not reacquire manual/system fans when changing a running policy.
        smartPolicy?.setProfile(profile, now: now)
    }
    private func clearSmart() {
        smartPolicy = nil; smartDecision = nil; lastSmartWrite = nil; appliedSmartPercentage = nil
        smartFans.removeAll()
    }
    private func applyRequests(_ requests: [(Int, Double)], now: Date, smartStart: Bool = false,
                               thermalPressure: ThermalPressure = .nominal, reason: String = "用户固定手动目标") throws {
        let commandBegan = ControlClock.now
        guard !restoring else { throw FanCoolError.restoreFailed }
        let availability = hardware.controlAvailability()
        guard availability.allowed else { throw FanCoolError.hardware(availability.reason) }
        guard !thermalPressure.requiresSystemControl else { throw FanCoolError.hardware("系统热压力较高或未知，请使用系统自动。") }
        if let conflict = hardware.conflictingController() {
            throw FanCoolError.hardware("检测到 \(conflict) 正在运行。请将它切回自动并退出，再使用 FanCool 调速。")
        }
        let readings = try hardware.fans()
        for (id, rpm) in requests {
            guard let reading = readings.first(where: { $0.id == id }), reading.controllable else { throw FanCoolError.unavailable }
            guard rpm.isFinite, rpm >= reading.minimum!, rpm <= reading.maximum! else { throw FanCoolError.invalidSpeed }
            if thermalPressure.preventsDecrease && !smartStart {
                let floor = max(reading.actual, targets[id] ?? (reading.mode == 1 ? (reading.target ?? 0) : 0))
                guard rpm >= floor else { throw FanCoolError.hardware("系统热压力升高，暂不接受降低转速的手动目标。") }
            }
        }
        guard let temperature = hardware.temperature(), temperature.isFinite else { throw FanCoolError.temperatureUnavailable }
        guard temperature < Self.temperatureLimit || smartStart else { throw FanCoolError.tooHot }
        if smartStart && temperature >= Self.temperatureLimit {
            guard requests.allSatisfy({ id, rpm in readings.first(where: { $0.id == id })?.maximum.map { abs($0 - rpm) <= 1 } == true }) else {
                throw FanCoolError.tooHot
            }
        }
        // Preflight cannot mutate hardware; reject foreign global ownership
        // before adopting fans or entering the rollback path.
        try hardware.prepareControl(ownedFans: controlledFans.union(requests.map { $0.0 }))
        if smartPolicy != nil {
            smartFans.subtract(requests.map { $0.0 })
            if smartStart || smartFans.isEmpty { clearSmart() }
        }
        for (id, rpm) in requests {
            controlledFans.insert(id); targets[id] = rpm; confirmed.remove(id); corrections[id] = 0
            unconfirmedSince[id] = now; stableSamples[id] = 0
        }
        do {
            // Persist before the first write so a helper restart can release dirty fans.
            try ownershipChanged?(controlledFans)
            for (id, rpm) in requests { _ = try writeTarget(fan: id, rpm: rpm, now: now, reason: reason) }
            if temperature >= Self.temperatureLimit && !pendingTakeovers.isEmpty {
                throw FanCoolError.hardware("温度已达 90°C 且固件尚未完成交接，正在恢复系统控制。")
            }
        } catch {
            let original = error
            try restoreAll(reason: "控制写入失败，回滚至系统控制：\(original.localizedDescription)")
            throw original
        }
        // Do not count a bounded compatibility setup as a missing client heartbeat.
        let setupDuration = max(0, ControlClock.now.timeIntervalSince(commandBegan))
        notice = nil; heartbeat(now: now.addingTimeInterval(setupDuration))
    }
    public func requestAutomatic(fan: Int = -1) throws {
        if let conflict = hardware.conflictingController() {
            throw FanCoolError.hardware("\(conflict) 仍在运行，请先退出它，避免自动设置被再次覆盖。")
        }
        let ids = Set(try hardware.fans().filter { fan == -1 || $0.id == fan }.map(\.id))
        guard !ids.isEmpty, fan >= -1 else { throw FanCoolError.unavailable }
        smartFans.subtract(ids)
        if smartFans.isEmpty { clearSmart() }
        controlledFans.formUnion(ids)
        for id in ids { targets.removeValue(forKey: id); confirmed.remove(id) }
        try? ownershipChanged?(controlledFans)
        notice = nil
        try release(ids, reason: "用户恢复系统自动")
    }
    public func recover(_ ids: Set<Int>) {
        // Never erase dirty ownership just because the first read after restart fails.
        controlledFans = Set(ids.union(hardware.recoveryFans).filter { (0..<10).contains($0) })
        let hadOwnership = !controlledFans.isEmpty
        if hadOwnership { notice = "检测到上次未完成的控制会话，正在恢复自动。" }
        do { try hardware.prepareRecovery() }
        catch { notice = "兼容控制状态恢复未确认：\(error.localizedDescription)" }
        try? restoreAll(reason: "后台启动，恢复上次未完成的会话")
        if controlledFans.isEmpty && hadOwnership { notice = "上次未完成的会话已恢复系统自动。" }
    }
    public func restoreAll(reason: String? = nil) throws {
        clearSmart()
        targets.removeAll(); confirmed.removeAll()
        try release(controlledFans, reason: reason ?? notice ?? "释放控制会话")
    }
    private func release(_ ids: Set<Int>, reason: String) throws {
        if !restorationFailureNotice { restorationReason = notice }
        restoring = true
        var failures: [String] = []
        // Ftst can keep mode registers locked even when they already read zero.
        // For a full release, leave the global state BEFORE per-fan restoration.
        // A scoped release must preserve the other active fan's global lease.
        if ids.isSuperset(of: controlledFans) {
            do { try hardware.prepareRecovery() }
            catch {
                notice = "兼容控制释放尚未确认：\(error.localizedDescription)"
                restorationFailureNotice = true
                try? ownershipChanged?(controlledFans)
                throw error
            }
        }
        for fan in ids.sorted() {
            do {
                try hardware.restoreAutomatic(fan: fan, reason: reason); controlledFans.remove(fan)
                smartFans.remove(fan)
                targets.removeValue(forKey: fan); confirmed.remove(fan); unconfirmedSince.removeValue(forKey: fan)
                corrections.removeValue(forKey: fan); stableSamples.removeValue(forKey: fan)
                pendingTakeovers.remove(fan)
            }
            catch { failures.append("风扇 \(fan + 1)：\(error.localizedDescription)") }
        }
        do { try hardware.finishControl(remainingFans: controlledFans) }
        catch {
            // Keep recovery ownership until the GLOBAL lease is released too.
            controlledFans.formUnion(ids.isEmpty ? hardware.recoveryFans : ids)
            failures.append("兼容控制释放：\(error.localizedDescription)")
        }
        try? ownershipChanged?(controlledFans)
        guard failures.isEmpty else {
            restorationFailureNotice = true
            notice = failures.joined(separator: "；")
            throw FanCoolError.hardware(notice ?? FanCoolError.restoreFailed.localizedDescription)
        }
        restoring = false
        if restorationFailureNotice {
            notice = restorationReason.map { "\($0)；已恢复 macOS 系统控制。" } ?? "已恢复 macOS 系统控制。"
            restorationFailureNotice = false
        }
        restorationReason = nil
        if smartFans.isEmpty { clearSmart() }
    }
    @discardableResult
    private func writeTarget(fan: Int, rpm: Double, now: Date, reason: String) throws -> Bool {
        do {
            try hardware.setManual(fan: fan, rpm: rpm, reason: reason)
            if pendingTakeovers.remove(fan) != nil {
                unconfirmedSince[fan] = now; corrections[fan] = 0; stableSamples[fan] = 0
            }
            return true
        } catch FanCoolError.takeoverPending {
            pendingTakeovers.insert(fan)
            confirmed.remove(fan)
            return false
        }
    }
    public func check(now: Date = ControlClock.now, thermalPressure: ThermalPressure = .nominal) {
        guard !controlledFans.isEmpty else { return }
        let temperature = hardware.temperature()
        let conflict = hardware.conflictingController()
        if restoring || conflict != nil || thermalPressure.requiresSystemControl || temperature == nil || !(temperature?.isFinite ?? false)
            || ((temperature ?? 0) >= Self.temperatureLimit && smartPolicy == nil) || now.timeIntervalSince(lastHeartbeat) > Self.heartbeatTimeout {
            if !restoring {
                if let conflict { notice = "检测到 \(conflict)，已停止手动目标并请求恢复自动。" }
                else if thermalPressure.requiresSystemControl { notice = "macOS 热压力过高或未知，已请求恢复自动。" }
                else if (temperature ?? 0) >= Self.temperatureLimit { notice = "手动模式达到 90°C 保护阈值，已请求恢复系统控制。" }
                else if temperature == nil { notice = FanCoolError.temperatureUnavailable.localizedDescription }
                else { notice = "连接已中断，已请求恢复 macOS 自动散热。" }
            }
            try? restoreAll(); return
        }
        do {
            if temperature! >= Self.temperatureLimit && !pendingTakeovers.isEmpty {
                notice = "固件交接尚未完成且温度达到 90°C，已请求恢复系统控制。"
                try restoreAll(); return
            }
            let readings = try hardware.fans()
            if temperature! >= Self.temperatureLimit {
                let fixedFans = controlledFans.subtracting(smartFans)
                if !fixedFans.isEmpty {
                    try release(fixedFans, reason: "固定手动风扇达到 90°C，交回系统；其他风扇继续智能温控")
                }
            }
            var writtenThisTick = Set<Int>()
            if var policy = smartPolicy {
                let decision = try policy.evaluate(temperature: temperature!, minimumPercentage: FanSpeed.minimumPercent(for: readings), now: now,
                    preventDecrease: thermalPressure.preventsDecrease, minimumOutput: appliedSmartPercentage)
                smartPolicy = policy; smartDecision = decision
                if decision.releaseToSystem { notice = decision.reason; try restoreAll(); return }
                let mayWrite = decision.emergency || now.timeIntervalSince(lastSmartWrite ?? .distantPast) >= 2
                var changed = false
                if mayWrite {
                    for fan in readings where smartFans.contains(fan.id) {
                        let rpm = try FanSpeed.rpm(percent: decision.percentage, fan: fan)
                        let deadband = max(100, (fan.maximum! - fan.minimum!) * 0.02)
                        let delta = abs((targets[fan.id] ?? -1000) - rpm)
                        let emergencyWrite = decision.emergency && delta > 0.01
                        if emergencyWrite || delta >= deadband {
                            try writeTarget(fan: fan.id, rpm: rpm, now: now, reason: "智能·\(policy.profile.title)：\(decision.reason)")
                            if confirmed.contains(fan.id) { unconfirmedSince[fan.id] = now }
                            targets[fan.id] = rpm; confirmed.remove(fan.id); changed = true
                            writtenThisTick.insert(fan.id)
                        }
                    }
                    if changed { lastSmartWrite = now; appliedSmartPercentage = decision.percentage }
                }
            }
            for (id, target) in targets.sorted(by: { $0.key < $1.key }) {
                if writtenThisTick.contains(id) { continue }
                if pendingTakeovers.contains(id) {
                    try writeTarget(fan: id, rpm: target, now: now, reason: "等待固件交接后的目标应用")
                    continue
                }
                guard let reading = readings.first(where: { $0.id == id }) else { throw FanCoolError.unavailable }
                let registerTolerance = smartFans.contains(id) && smartDecision?.emergency == true ? 0.5 : 80.0
                let targetMatches = reading.mode == 1 && abs((reading.target ?? -1000) - target) <= registerTolerance
                if targetMatches {
                    stableSamples[id, default: 0] += 1
                    if stableSamples[id, default: 0] >= 5 { corrections[id] = 0 }
                    if abs(reading.actual - target) <= max(150, target * 0.08) {
                        confirmed.insert(id); unconfirmedSince.removeValue(forKey: id)
                    } else {
                        confirmed.remove(id)
                        if unconfirmedSince[id] == nil { unconfirmedSince[id] = now }
                    }
                } else {
                    stableSamples[id] = 0
                    confirmed.remove(id)
                    let attempts = (corrections[id] ?? 0) + 1
                    corrections[id] = attempts
                    guard attempts <= 3 else {
                        throw FanCoolError.hardware("风扇 \(id + 1) 的目标持续被覆盖，已停止竞争并请求恢复自动。")
                    }
                    try writeTarget(fan: id, rpm: target, now: now, reason: "目标读回不符，第 \(attempts) 次有限重试")
                }
                if pendingTakeovers.contains(id) { continue }
                if let since = unconfirmedSince[id], now.timeIntervalSince(since) >= Self.convergenceTimeout {
                    throw FanCoolError.hardware("风扇 \(id + 1) 的实际转速 20 秒未跟随目标，已请求恢复系统控制。")
                }
            }
        } catch { notice = error.localizedDescription; try? restoreAll() }
    }
}
