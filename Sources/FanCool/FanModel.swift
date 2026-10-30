import AppKit
import FanCoolCore
import SwiftUI

enum FanMode: String, CaseIterable {
    case system = "系统", smart = "智能", manual = "手动"
}

enum FanPreset: String, CaseIterable {
    case automatic = "系统自动", smart = "智能温控", low = "低速", balanced = "均衡", high = "高速", full = "全速", custom = "自定义"
    static let manualOptions: [Self] = [.low, .balanced, .high, .full, .custom]
    var percent: Double? {
        switch self { case .automatic, .smart, .custom: return nil; case .low: return 35; case .balanced: return 55; case .high: return 75; case .full: return 100 }
    }
}

@MainActor
final class FanModel: ObservableObject {
    @Published var snapshot = HardwareSnapshot()
    @Published var scope = -1
    @Published var selectedMode: FanMode = .system
    @Published var selectedPreset: FanPreset?
    @Published var customPercent = 55.0
    @Published var control = ControlState()
    @Published var busy = false
    @Published var authorized = false
    @Published var message: String?
    @Published var alert: String?
    @Published var refreshed = false
    @Published var showSensors = false
    @Published var showSettings = false
    @Published private(set) var preferredProfile: SmartProfile = .defaultProfile
    @Published var draftProfile: SmartProfile = .defaultProfile { didSet { settingsNotice = nil } }
    @Published var settingsNotice: String?
    @Published var sensorKindFilter = "温度"
    @Published var sensorSearch = ""
    let demo: Bool
    let chip: String
    private let hardware = HardwareMonitor()
    private let helper = HelperClient()
    private var polling: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []
    private var afterAuthorization: (() -> Void)?
    private var startupSmartPending = true
    private let preferences: UserDefaults?

    var targetFans: [FanReading] { snapshot.fans.filter { scope == -1 || $0.id == scope } }
    var minimumPercent: Double { FanSpeed.minimumPercent(for: targetFans) }
    var percentageRange: ClosedRange<Double> { min(99, minimumPercent)...100 }
    var canAdjust: Bool { !busy && snapshot.controlAvailability.allowed && snapshot.conflictingController == nil && !targetFans.isEmpty && targetFans.allSatisfy(\.controllable) }
    var isCustom: Bool { selectedMode == .manual && selectedPreset == .custom }
    var canApplyCustom: Bool { isCustom && canAdjust }
    var canStartSmart: Bool { canAdjust && snapshot.temperature != nil && snapshot.fans.allSatisfy(\.controllable) }
    var displayedProfile: SmartProfile { control.smartProfile ?? preferredProfile }
    var canSaveProfile: Bool {
        !busy && (draftProfile != preferredProfile || (control.smartEnabled && control.smartProfile != draftProfile))
    }
    var canRemoveHelper: Bool { !busy && (demo ? authorized : InstalledAuthorization.load() != nil) }
    var authorizationTitle: String {
        if demo { return authorized ? "已授权" : "授权" }
        return authorized ? "已授权" : (InstalledAuthorization.load() == nil ? "授权" : "更新授权")
    }
    var averagePercent: Double? {
        let values = targetFans.compactMap(\.percentage)
        return values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
    }
    var filteredSensors: [SensorReading] {
        snapshot.sensors.filter { sensor in
            (sensorKindFilter == "全部" || sensor.kind.rawValue == sensorKindFilter) &&
            (sensorSearch.isEmpty || "\(sensor.name) \(sensor.key) \(sensor.group)".localizedCaseInsensitiveContains(sensorSearch))
        }.sorted { ($0.group, $0.key) < ($1.group, $1.key) }
    }
    var status: String {
        if let message { return message }
        if let error = snapshot.error { return error }
        if let conflict = snapshot.conflictingController { return "请先退出 \(conflict)，避免多个调速程序互相覆盖" }
        if let notice = control.notice { return notice }
        if refreshed && !snapshot.controlAvailability.allowed { return snapshot.controlAvailability.reason }
        if startupSmartPending && refreshed && !authorized && !demo {
            return "默认智能温控待启用：请在设置中完成\(authorizationTitle)"
        }
        if control.restoring { return "正在恢复自动，等待硬件确认…" }
        if control.smartEnabled {
            let names = control.fans.filter(\.smart).map { "风扇 \($0.id + 1)" }.joined(separator: "、")
            return "智能温控（\(names)）：\(control.smartReason ?? "随温度调节")"
        }
        if !control.fans.isEmpty {
            return control.fans.allSatisfy(\.confirmed) ? "已确认 \(control.fans.count) 只风扇的目标转速" : "正在调整 \(control.fans.count) 只风扇，等待硬件稳定…"
        }
        guard !snapshot.fans.isEmpty else { return refreshed ? "未检测到可读取的风扇" : "正在连接 Mac 硬件…" }
        if snapshot.fans.allSatisfy({ $0.mode == 0 || $0.mode == 3 }) { return "系统自动：由 macOS 调节，FanCool 不主动提速" }
        return "检测到已有手动模式，FanCool 尚未接管"
    }
    var currentModeDescription: String {
        guard !snapshot.fans.isEmpty else { return "正在读取" }
        return snapshot.fans.map { "风扇 \($0.id + 1) · \(modeTitle(for: $0))" }.joined(separator: "　")
    }
    var customStateDescription: String {
        guard isCustom else { return "" }
        let matches = targetFans.allSatisfy { fan in
            guard let intent = intent(for: fan.id), !intent.smart, let rpm = intent.rpm, let target = targetRPM(for: fan) else { return false }
            return abs(rpm - target) < 1
        }
        if matches && !targetFans.isEmpty {
            return targetFans.allSatisfy { intent(for: $0.id)?.confirmed == true } ? "已应用 · 实际转速已确认" : "目标已应用 · 等待实际转速稳定"
        }
        return "待应用 · 调整设置不会立即改变转速"
    }
    func intent(for id: Int) -> FanControlIntent? { control.fans.first { $0.id == id } }
    func modeTitle(for fan: FanReading) -> String {
        if let intent = intent(for: fan.id) {
            if control.restoring { return "恢复中" }
            if intent.smart { return "智能" }
            return intent.confirmed ? "手动" : "调整中"
        }
        if fan.mode == 0 || fan.mode == 3 { return "系统" }
        return fan.mode == 1 ? "已有手动" : "未知"
    }
    func targetRPM(for fan: FanReading) -> Double? { try? FanSpeed.rpm(percent: customPercent, fan: fan) }
    func isTargetAdjusting(for fan: FanReading) -> Bool {
        guard !control.restoring, let intent = intent(for: fan.id) else { return false }
        return !intent.confirmed
    }

    init(demo: Bool = false, preferences: UserDefaults? = nil) {
        self.demo = demo; chip = demo ? "Apple M2 Pro" : Machine.chip
        self.preferences = preferences ?? (demo ? nil : .standard)
        if let store = self.preferences {
            preferredProfile = FanPreferences.profile(in: store); draftProfile = preferredProfile
        }
        if demo { snapshot = .demo; refreshed = true }
    }
    func openSettings() {
        if !showSettings { draftProfile = preferredProfile; settingsNotice = nil }
        showSettings = true
    }
    func closeSettings() {
        guard !busy else { return }
        afterAuthorization = nil; showSettings = false
    }
    func settingsDismissed() { afterAuthorization = nil }
    private func requestAuthorization(then action: @escaping () -> Void) {
        openSettings()
        afterAuthorization = action
        settingsNotice = "请在下方完成后台授权，随后继续刚才的操作。"
    }
    func saveProfile() {
        guard !busy else { return }
        let profile = draftProfile
        if demo || !control.smartEnabled {
            persistProfile(profile)
            if demo && control.smartEnabled { control.smartProfile = profile }
            settingsNotice = control.smartEnabled ? "策略已保存，智能风扇将平滑调整。" : "已保存；下次启用智能模式时使用\(profile.title)策略。"
            return
        }
        guard authorized else { settingsNotice = "请先完成后台授权，再调整正在运行的智能策略。"; return }
        busy = true
        Task {
            defer { busy = false }
            do {
                try await helper.updateSmartProfile(profile)
                persistProfile(profile)
                if let state = try? await helper.state() { control = state }
                settingsNotice = control.smartEnabled ? "已保存\(profile.title)策略；只调整智能风扇，降速会先等待再平缓过渡。" : "已保存；下次启用智能模式时使用\(profile.title)策略。"
            } catch { settingsNotice = "未保存：\(error.localizedDescription)" }
        }
    }
    private func persistProfile(_ profile: SmartProfile) {
        if let preferences { FanPreferences.save(profile, in: preferences) }
        preferredProfile = profile
    }
    private func presentError(_ error: Error) {
        if showSettings { settingsNotice = error.localizedDescription }
        else { alert = error.localizedDescription }
    }
    func start() {
        guard polling == nil else { return }
        if !demo {
            let center = NSWorkspace.shared.notificationCenter
            observers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in await self?.releaseForSleep() }
            })
            observers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in await self?.refreshAfterWake() }
            })
        }
        polling = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refresh()
                do { try await Task.sleep(nanoseconds: 2_000_000_000) } catch { return }
            }
        }
    }
    func refresh() async {
        if demo { applyStartupDefaultIfReady(); return }
        snapshot = await hardware.sample(); refreshed = true
        if scope != -1 && !snapshot.fans.contains(where: { $0.id == scope }) { scope = -1 }
        customPercent = min(100, max(minimumPercent, customPercent))
        if helper.isInstalled {
            do {
                _ = try await helper.heartbeat()
                if !busy { control = try await helper.state() }
                authorized = true
                if !busy { message = nil }
            } catch { authorized = false; message = error.localizedDescription }
        } else { authorized = false; control = ControlState() }
        updatePresetSelection()
        applyStartupDefaultIfReady()
    }
    /// One startup attempt, after reads and authorization are ready. Never retries a released session.
    func applyStartupDefaultIfReady() {
        guard startupSmartPending, refreshed, !busy, snapshot.error == nil else { return }
        guard authorized || demo else { return }
        startupSmartPending = false
        guard control.fans.isEmpty, !control.restoring, canStartSmart,
              !snapshot.thermalPressure.requiresSystemControl,
              snapshot.fans.allSatisfy({ $0.mode == 0 || $0.mode == 3 }) else { return }
        startSmart(automatically: true)
    }
    private func updatePresetSelection() {
        // Polling must never dismiss a user's pending manual settings.
        guard selectedMode != .manual, !busy else { return }
        if control.smartEnabled && control.fans.allSatisfy(\.smart) { selectedMode = .smart }
        else if !snapshot.fans.isEmpty && snapshot.fans.allSatisfy({ $0.mode == 0 || $0.mode == 3 }) && control.fans.isEmpty { selectedMode = .system }
    }
    func scopeChanged() {
        customPercent = min(100, max(minimumPercent, customPercent))
    }
    func selectMode(_ mode: FanMode) {
        guard !busy else { return }
        startupSmartPending = false
        switch mode {
        case .manual:
            if selectedMode != .manual { selectedPreset = nil; scope = -1 }
            selectedMode = .manual
        case .system: restore()
        case .smart:
            if control.smartEnabled && control.fans.allSatisfy(\.smart) { selectedMode = .smart; scope = -1 }
            else { startSmart() }
        }
    }
    func authorize() {
        if demo { authorized = true; settingsNotice = "演示授权完成"; applyStartupDefaultIfReady(); return }
        guard !busy else { return }
        busy = true; message = "正在等待系统管理员授权…"
        Task {
            var success = false
            defer {
                busy = false
                let next = afterAuthorization; afterAuthorization = nil
                if success {
                    if let next { next() }
                    else { applyStartupDefaultIfReady() }
                }
            }
            do {
                try await helper.authorize()
                authorized = true; message = nil
                control = try await helper.state()
                success = true
                settingsNotice = "后台授权已完成。"
            } catch is CancellationError { message = nil; settingsNotice = "已取消授权，继续只读监测。" }
            catch { message = nil; settingsNotice = error.localizedDescription }
        }
    }
    func select(_ preset: FanPreset) {
        guard !busy else { return }
        startupSmartPending = false
        if preset == .automatic { selectMode(.system); return }
        if preset == .smart { selectMode(.smart); return }
        selectedMode = .manual
        if preset == .custom {
            if selectedPreset != .custom { scope = -1 }
            selectedPreset = .custom
            scopeChanged()
            return
        }
        guard let percent = preset.percent else { return }
        let minimum = FanSpeed.minimumPercent(for: snapshot.fans)
        apply(percent: max(minimum, percent), preset: preset, fan: -1)
    }
    func applyCustom() {
        guard canApplyCustom else { return }
        apply(percent: customPercent, preset: .custom, fan: scope)
    }
    private func apply(percent: Double, preset: FanPreset, fan target: Int) {
        let fans = snapshot.fans.filter { target == -1 || $0.id == target }
        guard !busy, snapshot.controlAvailability.allowed, snapshot.conflictingController == nil,
              !fans.isEmpty, fans.allSatisfy(\.controllable) else { return }
        if demo {
            let ids = Set(fans.map(\.id))
            snapshot.fans = snapshot.fans.map { fan in
                guard ids.contains(fan.id), let rpm = try? FanSpeed.rpm(percent: percent, fan: fan) else { return fan }
                return FanReading(id: fan.id, actual: rpm, target: rpm, minimum: fan.minimum, maximum: fan.maximum, mode: 1)
            }
            control.fans.removeAll { ids.contains($0.id) }
            control.fans += snapshot.fans.filter { ids.contains($0.id) }.map { .init(id: $0.id, rpm: $0.target, confirmed: true) }
            control.smartEnabled = control.fans.contains(where: \.smart)
            if !control.smartEnabled { control.smartPercentage = nil; control.filteredTemperature = nil; control.smartReason = nil; control.smartProfile = nil }
            selectedMode = .manual; selectedPreset = preset
            if preset != .custom { scope = -1; customPercent = percent }
            return
        }
        guard authorized else {
            requestAuthorization { [weak self] in self?.apply(percent: percent, preset: preset, fan: target) }
            return
        }
        busy = true
        Task {
            defer { busy = false }
            do {
                try await helper.set(percentage: percent, fan: target)
                control = try await helper.state()
                selectedMode = .manual; selectedPreset = preset
                if preset != .custom { scope = -1; customPercent = percent }
                message = nil
                await refresh()
            } catch { presentError(error); control = (try? await helper.state()) ?? control }
        }
    }
    func startSmart(automatically: Bool = false) {
        guard canStartSmart else { return }
        startupSmartPending = false
        scope = -1
        if demo {
            let temperature = snapshot.temperature ?? 57.7
            let percentage = SmartFanPolicy.curvePercentage(at: temperature, profile: preferredProfile)
            apply(percent: percentage, preset: .smart, fan: -1)
            control.fans = control.fans.map { .init(id: $0.id, rpm: $0.rpm, confirmed: $0.confirmed, smart: true) }
            selectedMode = .smart; selectedPreset = nil
            control.smartEnabled = true; control.smartPercentage = percentage
            control.smartProfile = preferredProfile
            control.filteredTemperature = temperature; control.smartReason = "按平滑温度曲线调节"
            return
        }
        guard authorized else {
            requestAuthorization { [weak self] in self?.startSmart() }
            return
        }
        busy = true
        Task {
            defer { busy = false }
            do {
                try await helper.startSmart(profile: preferredProfile); control = try await helper.state()
                selectedMode = .smart; selectedPreset = nil; message = nil
                await refresh()
            } catch {
                if automatically { message = "未能自动启用智能温控：\(error.localizedDescription)" }
                else { presentError(error) }
            }
        }
    }
    func restore() {
        guard !busy else { return }
        startupSmartPending = false
        scope = -1
        if let conflict = snapshot.conflictingController { presentError(FanCoolError.hardware("请先在 \(conflict) 中切回自动并退出，再使用 FanCool。")); return }
        if demo {
            if control.smartEnabled { scope = -1; control = ControlState() }
            let ids = Set(targetFans.map(\.id))
            let automatic = HardwareSnapshot.demo
            snapshot.fans = snapshot.fans.map { fan in ids.contains(fan.id) ? automatic.fans.first(where: { $0.id == fan.id })! : fan }
            control.fans.removeAll { ids.contains($0.id) }; selectedMode = .system; selectedPreset = nil; return
        }
        if !authorized && snapshot.fans.allSatisfy({ $0.mode == 0 || $0.mode == 3 }) { selectedMode = .system; selectedPreset = nil; return }
        guard authorized else {
            requestAuthorization { [weak self] in self?.restore() }
            return
        }
        busy = true
        Task {
            defer { busy = false }
            do {
                try await helper.restore(fan: scope); message = nil
                control = try await helper.state(); await refresh()
                selectedMode = .system; selectedPreset = nil
            } catch { presentError(error); control = (try? await helper.state()) ?? control }
        }
    }
    func uninstallHelper() {
        guard !busy else { return }
        startupSmartPending = false
        if demo { authorized = false; return }
        busy = true
        Task {
            defer { busy = false }
            do { try await helper.uninstall(); authorized = false; control = ControlState(); message = "后台服务已移除，继续只读监测"; settingsNotice = message }
            catch is CancellationError { }
            catch { settingsNotice = error.localizedDescription }
        }
    }
    func exportWriteLog() {
        guard !busy else { return }
        guard authorized else { openSettings(); settingsNotice = "请先更新后台授权，再导出调速日志。"; return }
        busy = true
        Task {
            defer { busy = false }
            do {
                let text = try await helper.recentWriteLog()
                let panel = NSSavePanel()
                panel.title = "导出最近调速日志"
                panel.nameFieldStringValue = "FanCool-smc-writes.jsonl"
                guard await panel.begin() == .OK, let url = panel.url else { return }
                try Data(text.utf8).write(to: url, options: .atomic)
            } catch { presentError(error) }
        }
    }
    private func releaseForSleep() async {
        startupSmartPending = false
        guard authorized else { return }
        do { try await helper.release(reason: "系统即将睡眠"); control = try await helper.state() }
        catch { message = error.localizedDescription }
    }
    private func refreshAfterWake() async {
        if helper.isInstalled { try? await helper.release(reason: "唤醒后重新确认硬件") }
        await hardware.reset()
        control = ControlState()
        await refresh()
    }
    func prepareToQuit() async {
        startupSmartPending = false
        polling?.cancel()
        if !demo && authorized { try? await helper.release(reason: "主程序正常退出") }
        helper.disconnect()
    }
}
