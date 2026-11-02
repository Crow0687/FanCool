import Foundation
import FanCoolCore

/// Runs the production sleep/wake orchestration with injected, non-SMC clients.
@MainActor
func runWakeResumeChecks() async throws -> Int {
    var count = 0
    var stores: [ObjectIdentifier: UserDefaults] = [:]
    var suites: [String] = []
    defer { for suite in suites { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) } }
    func expect(_ value: Bool, _ label: String) throws {
        guard value else { throw FanCoolError.hardware("Wake check failed: \(label)") }
        count += 1
    }
    func fixture(_ intents: [FanControlIntent], profile: SmartProfile = .quiet) -> (FanModel, WakeCheckClient, WakeCheckMonitor) {
        let monitor = WakeCheckMonitor()
        let client = WakeCheckClient()
        client.current.fans = intents
        client.current.smartEnabled = intents.contains(where: \.smart)
        client.current.smartProfile = client.current.smartEnabled ? profile : nil
        let suite = "FanCool.WakeChecks." + UUID().uuidString
        suites.append(suite)
        let store = UserDefaults(suiteName: suite)!
        let model = FanModel(preferences: store, helper: client, hardware: monitor)
        stores[ObjectIdentifier(model)] = store
        model.selectMode(.manual) // Disable the unrelated cold-start default.
        model.snapshot = .demo; model.refreshed = true; model.authorized = true
        model.control = client.current
        model.selectedMode = intents.isEmpty ? .system : (intents.allSatisfy(\.smart) ? .smart : .manual)
        return (model, client, monitor)
    }
    let smart: [FanControlIntent] = [
        .init(id: 0, rpm: 3000, confirmed: true, smart: true),
        .init(id: 1, rpm: 3300, confirmed: true, smart: true)
    ]
    let manual: [FanControlIntent] = [
        .init(id: 0, rpm: 4012, confirmed: true), .init(id: 1, rpm: 4622, confirmed: true)
    ]
    let (model, client, monitor) = fixture(smart)
    await model.releaseForSleep()
    try expect(client.current.fans.isEmpty && client.commands == ["release:系统即将睡眠"], "sleep releases both fans before suspending")
    await model.refresh()
    try expect(monitor.samples == 0, "polling performs no hardware reads or reacquisition while sleeping")
    await model.releaseForSleep()
    await model.refreshAfterWake()
    try expect(model.selectedMode == .smart && client.profiles == [.quiet] && model.control.fans.allSatisfy(\.smart),
        "wake restores the applied smart strategy exactly once")
    try expect(monitor.resets == 1 && client.commands.prefix(2) == ["release:系统即将睡眠", "release:唤醒后重新确认硬件"],
        "wake resets cached hardware and confirms release before new control")
    await model.refreshAfterWake(); await model.refresh()
    try expect(client.profiles.count == 1 && monitor.resets == 1, "duplicate wake notifications and polling do not restart smart control")
    await model.releaseForSleep(); await model.refreshAfterWake()
    try expect(client.profiles.count == 2, "a second sleep cycle captures and restores the newly active session")

    let (system, systemClient, _) = fixture([])
    await system.releaseForSleep(); await system.refreshAfterWake(); await system.refresh()
    try expect(system.selectedMode == .system && systemClient.profiles.isEmpty && systemClient.targets.isEmpty,
        "explicit system mode remains system after wake instead of using cold-start smart")

    let (fixed, fixedClient, _) = fixture(manual)
    fixed.selectedPreset = .custom; fixed.scope = 1; fixed.customPercent = 99
    await fixed.releaseForSleep(); await fixed.refreshAfterWake()
    try expect(fixedClient.targets.map(\.0) == [0, 1] && fixedClient.targets.map(\.1) == [4012, 4622],
        "individual applied RPMs resume without applying the 99 percent slider draft")
    try expect(fixed.selectedMode == .manual && fixed.isCustom && fixed.scope == 1,
        "restoring manual control preserves its custom editor")
    let (single, singleClient, _) = fixture([manual[0]])
    await single.releaseForSleep(); await single.refreshAfterWake()
    try expect(singleClient.targets.count == 1 && singleClient.targets.first?.0 == 0 && singleClient.profiles.isEmpty,
        "single manual fan resumes while the other remains system controlled")
    let (mixed, mixedClient, _) = fixture([manual[0], smart[1]], profile: .balanced)
    await mixed.releaseForSleep(); await mixed.refreshAfterWake()
    try expect(mixedClient.profiles == [.balanced] && mixedClient.targets.count == 1 && mixed.control.fans.first(where: { $0.id == 0 })?.smart == false
        && mixed.control.fans.first(where: { $0.id == 1 })?.smart == true, "mixed smart/manual operation resumes with its original strategy and manual override")

    let (waiting, waitingClient, waitingMonitor) = fixture(smart)
    await waiting.releaseForSleep()
    waitingMonitor.reading.temperature = nil
    await waiting.refreshAfterWake()
    try expect(waitingClient.profiles.isEmpty && waiting.status.contains("准备恢复"), "wake waits for a fresh trusted temperature")
    waitingMonitor.reading.temperature = 70
    await waiting.refresh()
    try expect(waitingClient.profiles == [.quiet], "a transient sensor warmup recovers within the wake window")

    let (unauthorized, unauthorizedClient, _) = fixture(smart)
    await unauthorized.releaseForSleep(); unauthorizedClient.isInstalled = false
    await unauthorized.refreshAfterWake()
    try expect(unauthorizedClient.profiles.isEmpty && !unauthorized.showSettings && !unauthorized.busy,
        "wake never prompts for administrator authorization")
    unauthorizedClient.isInstalled = true
    await unauthorized.refresh()
    try expect(unauthorizedClient.profiles == [.quiet], "wake reconnects when the existing authorization becomes readable")

    let (releaseWait, releaseClient, _) = fixture(smart)
    await releaseWait.releaseForSleep(); releaseClient.releaseFailures = 1
    await releaseWait.refreshAfterWake()
    try expect(releaseClient.profiles.isEmpty && !releaseWait.canAdjust, "unconfirmed wake release blocks automatic and manual takeover")
    await releaseWait.refresh()
    try expect(releaseClient.profiles == [.quiet], "transient release failure is retried before restoring smart mode")

    let (stateWait, stateClient, _) = fixture(smart)
    await stateWait.releaseForSleep(); stateClient.stateFailures = 1
    await stateWait.refreshAfterWake()
    try expect(stateClient.profiles.isEmpty, "a successful heartbeat alone cannot authorize wake restoration")
    await stateWait.refresh()
    try expect(stateClient.profiles.count == 1, "a confirmed fresh helper state permits restoration")

    let (recovery, recoveryClient, _) = fixture(smart)
    await recovery.releaseForSleep()
    recoveryClient.returnRestoring = true
    await recovery.refreshAfterWake()
    try expect(recoveryClient.profiles.isEmpty, "helper recovery must finish before wake control can resume")
    recoveryClient.returnRestoring = false; await recovery.refresh()
    try expect(recoveryClient.profiles.count == 1, "completed helper recovery permits a single restoration")

    let (unknown, unknownClient, unknownMonitor) = fixture(smart)
    await unknown.releaseForSleep(); unknownMonitor.reading.thermalPressure = .unknown
    await unknown.refreshAfterWake()
    try expect(unknownClient.profiles.isEmpty, "unknown wake thermal state cannot acquire control")
    unknownMonitor.reading.thermalPressure = .nominal; await unknown.refresh()
    try expect(unknownClient.profiles.count == 1, "a fresh known thermal state can finish wake preflight")

    let (expired, expiredClient, expiredMonitor) = fixture(smart)
    await expired.releaseForSleep(); expiredMonitor.reading.error = "warming up"
    let wakeTime = ProcessInfo.processInfo.systemUptime
    await expired.refreshAfterWake(now: wakeTime)
    await expired.resumeAfterWakeIfReady(stateReady: true, now: wakeTime + 31)
    expiredMonitor.reading.error = nil; await expired.refresh()
    try expect(expiredClient.profiles.isEmpty && expired.status.contains("未能确认"), "wake attempts expire and never silently rearm on later samples")

    let (cancelled, cancelledClient, cancelMonitor) = fixture(smart)
    await cancelled.releaseForSleep(); cancelMonitor.reading.temperature = nil
    await cancelled.refreshAfterWake()
    cancelled.selectMode(.system)
    while cancelled.busy { await Task.yield() }
    cancelMonitor.reading.temperature = 65; await cancelled.refresh()
    try expect(cancelledClient.profiles.isEmpty && cancelled.selectedMode == .system, "an explicit user mode choice cancels the pending wake plan")

    for pressure in [ThermalPressure.serious, .critical] {
        let (unsafe, unsafeClient, unsafeMonitor) = fixture(smart)
        await unsafe.releaseForSleep(); unsafeMonitor.reading.thermalPressure = pressure
        await unsafe.refreshAfterWake()
        unsafeMonitor.reading.thermalPressure = .nominal; await unsafe.refresh()
        try expect(unsafeClient.profiles.isEmpty && unsafe.status.contains("热压力"), "unsafe thermal pressure cancels restoration permanently for this wake")
    }
    let (hot, hotClient, hotMonitor) = fixture(manual)
    await hot.releaseForSleep(); hotMonitor.reading.temperature = 90
    await hot.refreshAfterWake()
    hotMonitor.reading.temperature = 60; await hot.refresh()
    try expect(hotClient.targets.isEmpty, "old manual targets never resume after an overtemperature wake")

    let (conflict, conflictClient, conflictMonitor) = fixture(smart)
    await conflict.releaseForSleep(); conflictMonitor.reading.conflictingController = "Other controller"
    await conflict.refreshAfterWake()
    conflictMonitor.reading.conflictingController = nil; await conflict.refresh()
    try expect(conflictClient.profiles.isEmpty && conflict.status.contains("Other controller"), "another controller cancels wake takeover")
    let (changed, changedClient, changedMonitor) = fixture(manual)
    await changed.releaseForSleep(); changedMonitor.reading.fans.removeLast()
    await changed.refreshAfterWake()
    try expect(changedClient.targets.isEmpty && changed.status.contains("数量或转速范围"), "changed fan topology cannot receive stale targets")
    let (ranges, rangesClient, rangesMonitor) = fixture(manual)
    await ranges.releaseForSleep()
    rangesMonitor.reading.fans[0] = .init(id: 0, actual: 1350, target: 1350, minimum: 1350, maximum: 4000, mode: 0)
    await ranges.refreshAfterWake()
    try expect(rangesClient.targets.isEmpty, "changed hardware limits reject an old out of range target before any write")

    let (failed, failedClient, _) = fixture([manual[0], smart[1]])
    await failed.releaseForSleep(); failedClient.failTarget = 0
    await failed.refreshAfterWake(); await failed.refresh()
    try expect(failedClient.profiles.count == 1 && failed.control.fans.isEmpty && failed.status.contains("未恢复原模式")
        && failedClient.commands.last == "release:释放控制会话", "a partial mixed restoration failure releases earlier writes and is never automatically retried")

    let (interrupted, interruptedClient, _) = fixture([manual[0], smart[1]])
    await interrupted.releaseForSleep()
    interruptedClient.afterSmart = { await interrupted.releaseForSleep() }
    await interrupted.refreshAfterWake()
    try expect(interruptedClient.targets.isEmpty && interrupted.control.fans.isEmpty,
        "a new sleep during resume invalidates remaining writes and releases partial control")
    interruptedClient.afterSmart = nil
    await interrupted.refreshAfterWake()
    try expect(interruptedClient.profiles.count == 2 && interruptedClient.targets.count == 1,
        "the next wake restores the interrupted original plan instead of a partial session")

    let (restoring, restoringClient, _) = fixture(smart)
    restoring.control.restoring = true
    await restoring.releaseForSleep(); await restoring.refreshAfterWake()
    try expect(restoringClient.profiles.isEmpty, "an already failed or restoring session is never automatically reacquired")

    let (stale, staleClient, staleMonitor) = fixture(smart)
    staleMonitor.afterSample = { await stale.releaseForSleep() }
    await stale.refresh()
    try expect(stale.control.fans.isEmpty && staleClient.profiles.isEmpty,
        "a pre-sleep sample returning late cannot overwrite the released control state")
    staleMonitor.afterSample = nil; await stale.refreshAfterWake()
    try expect(staleClient.profiles.count == 1, "discarding a stale poll preserves the sleep plan for its real wake")

    // New model instances emulate a process restart, sharing only disk preferences.
    func relaunch(_ original: FanModel) async -> (FanModel, WakeCheckClient) {
        let client = WakeCheckClient()
        let fresh = FanModel(preferences: stores[ObjectIdentifier(original)]!, helper: client, hardware: WakeCheckMonitor())
        await fresh.refresh()
        await fresh.resumeAfterWakeIfReady(stateReady: true)
        return (fresh, client)
    }
    let (restartedSmart, restartedSmartClient) = await relaunch(model)
    try expect(restartedSmart.selectedMode == .smart && restartedSmartClient.profiles == [.quiet],
        "process restart restores the persisted smart strategy rather than the default strategy")
    let (restartedManual, restartedManualClient) = await relaunch(fixed)
    try expect(restartedManual.selectedMode == .manual && restartedManualClient.targets.map(\.1) == [4012, 4622],
        "process restart restores independent applied manual targets without the slider draft")
    let (restartedMixed, restartedMixedClient) = await relaunch(mixed)
    try expect(restartedMixedClient.profiles == [.balanced] && restartedMixed.control.fans.first(where: { $0.id == 0 })?.smart == false
        && restartedMixed.control.fans.first(where: { $0.id == 1 })?.smart == true, "process restart restores mixed smart and manual operation")
    // Explicit system selection must be persisted even without an installed helper.
    let systemStore = stores[ObjectIdentifier(system)]!
    let systemChoice = FanModel(demo: true, preferences: systemStore)
    systemChoice.selectMode(.system)
    let (restartedSystem, restartedSystemClient) = await relaunch(system)
    try expect(restartedSystem.selectedMode == .system && restartedSystemClient.profiles.isEmpty && restartedSystemClient.targets.isEmpty,
        "persisted system mode suppresses the first-install smart default")
    let corruptStore = stores[ObjectIdentifier(stale)]!
    corruptStore.set(Data("invalid".utf8), forKey: "FanCool.appliedSession.v1")
    let (corrupt, corruptClient) = await relaunch(stale)
    try expect(corruptClient.profiles.isEmpty && corrupt.status.contains("无法读取"), "corrupt saved state fails closed instead of enabling default smart")
    let pendingStore = stores[ObjectIdentifier(fixed)]!
    let pending = FanModel(preferences: pendingStore, helper: WakeCheckClient(), hardware: WakeCheckMonitor())
    pending.selectMode(.manual); pending.select(.custom); pending.customPercent = 100
    let (afterDraft, afterDraftClient) = await relaunch(fixed)
    try expect(afterDraftClient.targets.map(\.1) == [4012,4622] && afterDraft.selectedMode == .manual,
        "an unapplied editor change never overwrites the persisted running configuration")
    let orphanClient = WakeCheckClient()
    orphanClient.current.fans = smart; orphanClient.current.smartEnabled = true
    let orphan = FanModel(preferences: pendingStore, helper: orphanClient, hardware: WakeCheckMonitor())
    await orphan.refresh(); await orphan.resumeAfterWakeIfReady(stateReady: true)
    try expect(orphanClient.commands.first?.hasPrefix("release:") == true && orphanClient.targets.map(\.1) == [4012,4622],
        "relaunch releases a surviving helper session before heartbeats can keep it alive")
    let authClient = WakeCheckClient(); authClient.isInstalled = false
    let auth = FanModel(preferences: pendingStore, helper: authClient, hardware: WakeCheckMonitor())
    await auth.refresh()
    try expect(authClient.targets.isEmpty && !auth.showSettings && auth.status.contains("上次运行模式待启用"),
        "saved manual startup waits for authorization without prompting or silently selecting smart")
    authClient.isInstalled = true; await auth.refresh(); await auth.resumeAfterWakeIfReady(stateReady: true)
    try expect(authClient.targets.map(\.1) == [4012,4622], "saved startup resumes after authorization becomes available")
    return count
}

private final class WakeCheckMonitor: FanSampling {
    var reading = HardwareSnapshot.demo
    var samples = 0
    var resets = 0
    var afterSample: (() async -> Void)?
    func sample() async -> HardwareSnapshot { samples += 1; await afterSample?(); return reading }
    func reset() async { resets += 1 }
}

@MainActor
private final class WakeCheckClient: FanControlClient {
    var isInstalled = true
    var current = ControlState()
    var commands: [String] = []
    var profiles: [SmartProfile] = []
    var targets: [(Int, Double)] = []
    var releaseFailures = 0
    var stateFailures = 0
    var failTarget: Int?
    var returnRestoring = false
    var afterSmart: (() async -> Void)?
    func authorize() async throws { throw FanCoolError.hardware("Checks must not authorize") }
    func uninstall() async throws { throw FanCoolError.hardware("Checks must not uninstall") }
    func heartbeat() async throws -> String? { nil }
    func set(fan: Int, rpm: Double) async throws {
        if failTarget == fan { throw FanCoolError.hardware("Simulated firmware rejection") }
        targets.append((fan, rpm)); commands.append("manual:\(fan)")
        current.fans.removeAll { $0.id == fan }
        current.fans.append(.init(id: fan, rpm: rpm, confirmed: true))
        current.smartEnabled = current.fans.contains(where: \.smart)
    }
    func set(percentage: Double, fan: Int) async throws { throw FanCoolError.hardware("Wake must restore applied RPMs") }
    func restore(fan: Int) async throws { current = ControlState() }
    func startSmart(profile: SmartProfile) async throws {
        profiles.append(profile); commands.append("smart")
        current.fans = [.init(id: 0, rpm: 3000, confirmed: false, smart: true), .init(id: 1, rpm: 3300, confirmed: false, smart: true)]
        current.smartEnabled = true; current.smartProfile = profile
        await afterSmart?()
    }
    func updateSmartProfile(_ profile: SmartProfile) async throws { current.smartProfile = profile }
    func state() async throws -> ControlState {
        if stateFailures > 0 { stateFailures -= 1; throw FanCoolError.unavailable }
        var state = current; state.restoring = returnRestoring
        return state
    }
    func recentWriteLog() async throws -> String { "" }
    func release(reason: String) async throws {
        commands.append("release:\(reason)")
        if releaseFailures > 0 { releaseFailures -= 1; throw FanCoolError.restoreFailed }
        current = ControlState()
    }
    func disconnect() {}
}
