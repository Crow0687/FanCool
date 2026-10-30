import Foundation

public struct FirmwareControlLease: Codable, Equatable {
    public let version: Int
    public let fans: [Int]
    public init(fans: [Int]) {
        version = 1; self.fans = fans.sorted()
    }
    public var isValid: Bool {
        version == 1 && !fans.isEmpty && fans.count <= 10 && fans == Array(0..<fans.count)
    }
}

public protocol FanRegisterAccess: AnyObject {
    func number(_ key: String) throws -> Double
    func isByteRegister(_ key: String) -> Bool
    func fans() throws -> [FanReading]
    func fanCount() throws -> Int
    func writeFanRegister(_ key: String, value: Double, fan: Int, restoring: Bool, targetRPM: Double?, reason: String) throws
}

/// Serialized by the helper's control queue. A global compatibility lease is
/// journaled BEFORE Ftst changes, and retained until automatic modes are verified.
public final class FirmwareFanControl {
    private unowned let registers: FanRegisterAccess
    private let persist: (FirmwareControlLease?) throws -> Void
    private let wait: (TimeInterval) -> Void
    private let clock: () -> Date
    public static let takeoverTimeout: TimeInterval = 20
    private var pendingSince: [Int: Date] = [:]
    private var unlockRequestedAt: Date?
    private var resetRequestedAt: Date?
    public private(set) var lease: FirmwareControlLease?
    private var recovering: Bool
    private var ownedFans: Set<Int> = []
    public var recoveryFans: Set<Int> { Set(lease?.fans ?? []) }

    public init(registers: FanRegisterAccess, lease: FirmwareControlLease? = nil,
                persist: @escaping (FirmwareControlLease?) throws -> Void,
                wait: @escaping (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) },
                clock: @escaping () -> Date = { ControlClock.now }) {
        self.registers = registers; self.lease = lease; self.persist = persist; self.wait = wait; self.clock = clock
        recovering = lease != nil
    }
    public func prepareControl(ownedFans: Set<Int>) throws {
        guard !recovering else { throw FanCoolError.restoreFailed }
        if lease == nil, registers.isByteRegister("Ftst") {
            let state = try registers.number("Ftst")
            guard state == 0 else {
                throw FanCoolError.hardware("检测到未由 FanCool 持有或未知的兼容控制状态，请先退出其他调速工具。")
            }
        }
        self.ownedFans = ownedFans
    }
    public func enterManual(fan: Int, key: String, rpm: Double, reason: String) throws {
        guard ownedFans.contains(fan), !recovering else { throw FanCoolError.restoreFailed }
        if try registers.number(key) == 1 {
            pendingSince.removeValue(forKey: fan)
            if pendingSince.isEmpty { unlockRequestedAt = nil }
            return
        }
        if lease != nil {
            try advanceCompatibility(fan: fan, key: key, rpm: rpm, reason: reason)
            return
        }
        do { try transition(fan: fan, key: key, rpm: rpm, reason: reason, compatibility: false); return }
        catch {
            guard case FanCoolError.firmwareWriteRejected(let failedKey, let status) = error,
                  failedKey == key, status == 0x10000082 else { throw error }
        }
        try acquireCompatibility(fan: fan, rpm: rpm, reason: reason)
        throw FanCoolError.takeoverPending
    }
    private func advanceCompatibility(fan: Int, key: String, rpm: Double, reason: String) throws {
        let now = clock()
        let began = pendingSince[fan] ?? now
        pendingSince[fan] = began
        guard now.timeIntervalSince(began) < Self.takeoverTimeout else {
            throw FanCoolError.hardware("风扇 \(fan + 1) 在 20 秒交接窗口内仍被固件拒绝，正在恢复系统控制。")
        }
        let unlock = try registers.number("Ftst")
        if unlock == 0, unlockRequestedAt == nil {
            try acquireCompatibility(fan: fan, rpm: rpm, reason: reason)
            throw FanCoolError.takeoverPending
        }
        guard unlock == 0 || unlock == 1 else { throw FanCoolError.hardware("兼容接管状态未知，正在恢复系统控制。") }
        guard unlock == 1, unlockRequestedAt.map({ now.timeIntervalSince($0) >= 3 }) ?? true else {
            throw FanCoolError.takeoverPending
        }
        do {
            // One attempt per watchdog tick. Heartbeats and release commands can
            // run between attempts instead of blocking the control queue.
            try registers.writeFanRegister(key, value: 1, fan: fan, restoring: false, targetRPM: rpm,
                reason: "\(reason)；兼容交接分步尝试，已等待 \(Int(now.timeIntervalSince(began))) 秒")
            pendingSince.removeValue(forKey: fan)
            if pendingSince.isEmpty { unlockRequestedAt = nil }
        } catch {
            guard case FanCoolError.firmwareWriteRejected(let failedKey, let status) = error,
                  failedKey == key, status == 0x10000082 else { throw error }
            throw FanCoolError.takeoverPending
        }
    }
    private func transition(fan: Int, key: String, rpm: Double, reason: String, compatibility: Bool) throws {
        try FanModeTransition.enterManual(key: key, readMode: { try self.registers.number(key) }, writeMode: { attempt in
            try self.registers.writeFanRegister(key, value: 1, fan: fan, restoring: false, targetRPM: rpm,
                reason: "\(reason)；\(compatibility ? "兼容" : "直接")接管 \(attempt)/\(FanModeTransition.maximumAttempts)")
        }, wait: wait)
    }
    private func acquireCompatibility(fan: Int, rpm: Double, reason: String) throws {
        guard registers.isByteRegister("Ftst") else {
            throw FanCoolError.hardware("固件持续拒绝直接接管，且没有已识别的 Ftst 兼容接口；已请求恢复系统控制。")
        }
        let value = try registers.number("Ftst")
        guard value == 0 || value == 1 else { throw FanCoolError.hardware("Ftst 状态未知，未执行兼容接管。") }
        if lease == nil {
            // Never adopt another app's global override or its manually owned fan.
            guard value == 0 else { throw FanCoolError.hardware("检测到未由 FanCool 持有的兼容控制状态，请先退出其他调速工具。") }
            let readings = try registers.fans().sorted { $0.id < $1.id }
            let declaredCount = try registers.fanCount()
            let candidate = FirmwareControlLease(fans: readings.map(\.id))
            guard candidate.isValid, declaredCount == readings.count,
                  readings.allSatisfy({ $0.mode == 0 || $0.mode == 3 || (ownedFans.contains($0.id) && $0.mode == 1) }) else {
                throw FanCoolError.hardware("风扇状态不完整或其他风扇已有手动控制，未执行全局兼容接管。")
            }
            try persist(candidate)
            lease = candidate
        }
        if value != 1 {
            try writeUnlock(1, fan: fan, rpm: rpm, reason: "\(reason)；建立已记录的兼容接管", restoring: false)
            let now = clock()
            unlockRequestedAt = now
            for id in ownedFans { pendingSince[id] = pendingSince[id] ?? now }
        }
    }
    private func writeUnlock(_ value: Double, fan: Int, rpm: Double?, reason: String, restoring: Bool) throws {
        for attempt in 1...3 {
            do {
                try registers.writeFanRegister("Ftst", value: value, fan: fan, restoring: restoring, targetRPM: rpm,
                    reason: "\(reason)；\(attempt)/3")
                return
            } catch {
                guard case FanCoolError.firmwareWriteRejected(let key, let status) = error,
                      key == "Ftst", status == 0x10000082, attempt < 3 else { throw error }
                wait(0.1)
            }
        }
    }
    public func prepareRecovery() throws {
        guard lease != nil else { return }
        recovering = true
        try resetUnlock(reason: "恢复系统前，先交回兼容控制权")
    }
    private func resetUnlock(reason: String) throws {
        guard let lease, lease.isValid, registers.isByteRegister("Ftst") else { throw FanCoolError.restoreFailed }
        if try registers.number("Ftst") != 0, resetRequestedAt.map({ clock().timeIntervalSince($0) >= 5 }) ?? true {
            try writeUnlock(0, fan: lease.fans[0], rpm: nil, reason: reason, restoring: true)
            resetRequestedAt = clock()
        }
        for attempt in 0..<4 {
            if (try? registers.number("Ftst")) == 0 { resetRequestedAt = nil; return }
            if attempt < 3 { wait(0.1) }
        }
        throw FanCoolError.recoveryPending
    }
    public func finishControl(remainingFans: Set<Int>) throws {
        ownedFans = remainingFans
        pendingSince = pendingSince.filter { remainingFans.contains($0.key) }
        guard remainingFans.isEmpty, let lease else { return }
        try resetUnlock(reason: "最后一只风扇释放，清除兼容接管")
        let readings = try registers.fans()
        guard lease.fans.allSatisfy({ id in readings.contains { $0.id == id && ($0.mode == 0 || $0.mode == 3) } }) else {
            throw FanCoolError.restoreFailed
        }
        try persist(nil)
        self.lease = nil; recovering = false; unlockRequestedAt = nil; resetRequestedAt = nil; pendingSince.removeAll()
    }
}
