import Foundation
import AppKit
import FanCoolCore

/// Exercises the same model actions as the native UI, always with demo hardware.
@MainActor
func runUIWorkflowChecks() throws {
    var count = 0
    func expect(_ value: Bool, _ label: String) throws {
        guard value else { throw FanCoolError.hardware("UI check failed: \(label)") }
        count += 1
    }
    try expect(FanRotorAsset.image != nil && FanRotorAsset.image!.size.width == FanRotorAsset.image!.size.height,
        "the distributable app loads its square rotor asset from bundled resources")
    let rotor = FanRotationView(frame: NSRect(x: 0, y: 0, width: 32, height: 32), role: "test")
    rotor.setSpinning(true)
    try expect(rotor.hasRotorContents && rotor.rotationAnimation != nil, "native rotor has a bitmap and an installed compositor animation")
    let animationStart = rotor.rotationAnimation?.beginTime
    rotor.setSpinning(true)
    try expect(rotor.rotationAnimation?.beginTime == animationStart, "hardware refreshes do not restart the rotor animation")
    try expect(rotor.rotationAnimation?.repeatCount == .infinity && rotor.rotationAnimation?.duration == 3.2,
        "native rotation repeats continuously with a full-cycle duration")
    rotor.setSpinning(false)
    try expect(rotor.rotationAnimation == nil, "stopped or reduced-motion state removes native rotation")
    let menuRotor = FanRotationView(frame: NSRect(x: 0, y: 0, width: 18, height: 18), template: true, role: "test-menu")
    try expect(menuRotor.hasRotorContents && menuRotor.hitTest(.zero) == nil, "menu silhouette loads and does not intercept left/right clicks")
    let model = FanModel(demo: true)
    try expect(model.selectedMode == .system && !model.isCustom, "preflight stays system until startup checks complete")
    let initial = model.snapshot.fans.map(\.actual)
    model.selectMode(.manual)
    try expect(model.selectedPreset == nil && model.control.fans.isEmpty && model.snapshot.fans.map(\.actual) == initial,
        "entering manual does not apply a remembered target")
    model.select(.custom)
    try expect(model.isCustom && model.control.fans.isEmpty, "custom choice only opens the editor")
    model.scope = 0; model.customPercent = 75; model.scopeChanged()
    try expect(model.control.fans.isEmpty && model.customStateDescription.contains("待应用"), "draft scope and slider changes are pending")
    model.applyCustom()
    try expect(model.snapshot.fans[0].target == 4012 && model.snapshot.fans[1].mode == 0,
        "applying fan one leaves system fan two untouched")
    try expect(model.customStateDescription.contains("已应用"), "applied draft is labelled separately")
    model.select(.low)
    try expect(model.scope == -1 && model.snapshot.fans.map(\.target) == [1872, 2022], "preset always addresses both fans despite previous single scope")
    try expect(!model.isCustom, "fixed preset hides slider and scope")
    model.select(.custom)
    model.customPercent = 80; model.scope = 1; model.scopeChanged()
    try expect(model.snapshot.fans.map(\.target) == [1872, 2022] && model.customStateDescription.contains("待应用"), "editing a custom value does not alter an active preset")
    model.applyCustom()
    try expect(model.snapshot.fans.map(\.target) == [1872, 4622], "fan two custom application preserves fan one preset")
    model.selectMode(.system)
    try expect(model.scope == -1 && model.control.fans.isEmpty && model.snapshot.fans.allSatisfy { $0.mode == 0 }, "system selection is global")
    model.selectMode(.smart)
    let smartTargets = model.control.fans.map(\.rpm)
    try expect(model.selectedMode == .smart && model.control.fans.count == 2 && model.control.fans.allSatisfy(\.smart), "smart selection manages both fans")
    let adjusting = FanModel(demo: true)
    adjusting.selectMode(.smart)
    adjusting.control.fans = adjusting.control.fans.map { .init(id: $0.id, rpm: $0.rpm, confirmed: false, smart: true) }
    try expect(adjusting.snapshot.fans.allSatisfy { adjusting.modeTitle(for: $0) == "智能" && adjusting.isTargetAdjusting(for: $0) },
        "new smart targets keep their mode badge while separately reporting pending confirmation")
    adjusting.control.fans = adjusting.control.fans.map { .init(id: $0.id, rpm: $0.rpm, confirmed: true, smart: true) }
    try expect(adjusting.snapshot.fans.allSatisfy { adjusting.modeTitle(for: $0) == "智能" && !adjusting.isTargetAdjusting(for: $0) },
        "confirmed smart targets clear adjustment status without changing the mode badge")
    adjusting.control.restoring = true
    try expect(adjusting.snapshot.fans.allSatisfy { adjusting.modeTitle(for: $0) == "恢复中" && !adjusting.isTargetAdjusting(for: $0) },
        "system restoration remains visible and is not presented as ordinary target adjustment")
    model.selectMode(.manual)
    try expect(model.selectedPreset == nil && model.control.fans.map(\.rpm) == smartTargets && model.control.fans.allSatisfy(\.smart), "manual editing preserves active smart operation")
    model.select(.custom); model.scope = 0; model.customPercent = 55
    model.applyCustom()
    try expect(model.selectedMode == .manual && model.control.fans.first(where: { $0.id == 0 })?.smart == false
        && model.control.fans.first(where: { $0.id == 1 })?.smart == true, "single custom override keeps the other fan smart")
    try expect(model.currentModeDescription.contains("风扇 1 · 手动") && model.currentModeDescription.contains("风扇 2 · 智能"), "running-state labels describe mixed operation")
    model.selectMode(.system)
    model.selectMode(.manual)
    try expect(model.selectedPreset == nil && model.control.fans.isEmpty, "reentering manual never reapplies the last custom value")

    let suite = "FanCool.UIWorkflow." + UUID().uuidString
    let store = UserDefaults(suiteName: suite)!
    defer { store.removePersistentDomain(forName: suite) }
    let settingsModel = FanModel(demo: true, preferences: store)
    settingsModel.openSettings()
    try expect(settingsModel.showSettings && settingsModel.preferredProfile == .cool, "settings opens without changing the default strategy")
    settingsModel.draftProfile = .quiet
    try expect(settingsModel.preferredProfile == .cool && settingsModel.control.fans.isEmpty, "selecting a draft does not persist or acquire control")
    settingsModel.closeSettings(); settingsModel.openSettings()
    try expect(settingsModel.draftProfile == .cool, "closing without saving discards the draft")
    settingsModel.draftProfile = .quiet; settingsModel.saveProfile()
    try expect(settingsModel.preferredProfile == .quiet && FanPreferences.profile(in: store) == .quiet, "settings save persists the selected profile")
    try expect(settingsModel.selectedMode == .system && settingsModel.control.fans.isEmpty, "saving a strategy under system mode never starts smart control")
    let relaunched = FanModel(demo: true, preferences: store)
    try expect(relaunched.preferredProfile == .quiet && relaunched.selectedMode == .system, "relaunch loads saved strategy before startup checks")
    relaunched.snapshot.temperature = 70
    relaunched.applyStartupDefaultIfReady()
    try expect(relaunched.selectedMode == .smart && relaunched.control.smartProfile == .quiet && relaunched.snapshot.fans.map(\.target) == [2140,2311],
        "startup automatically enables both fans with the saved quiet strategy")
    relaunched.selectMode(.manual); relaunched.select(.custom); relaunched.scope = 0; relaunched.customPercent = 55; relaunched.applyCustom()
    let mixedBefore = relaunched.control.fans.map(\.rpm)
    relaunched.openSettings(); relaunched.draftProfile = .balanced; relaunched.saveProfile()
    try expect(relaunched.control.smartProfile == .balanced && relaunched.control.fans.map(\.rpm) == mixedBefore, "saving a mixed session strategy preserves existing targets until its gradual update")
    try expect(relaunched.control.fans.first(where: { $0.id == 0 })?.smart == false && relaunched.control.fans.first(where: { $0.id == 1 })?.smart == true, "strategy settings do not acquire the manual fan")
    let priorTargets = relaunched.control.fans.map(\.rpm)
    relaunched.closeSettings(); relaunched.openSettings()
    try expect(relaunched.control.fans.map(\.rpm) == priorTargets && relaunched.customPercent == 55 && relaunched.scope == 0,
        "auxiliary settings presentation preserves control and pending custom editor")
    let startup = FanModel(demo: true)
    startup.refreshed = false
    startup.applyStartupDefaultIfReady()
    try expect(startup.control.fans.isEmpty, "startup waits for the first hardware sample")
    startup.refreshed = true; startup.busy = true; startup.applyStartupDefaultIfReady()
    try expect(startup.control.fans.isEmpty, "startup waits while an operation is busy")
    startup.busy = false; startup.applyStartupDefaultIfReady()
    try expect(startup.control.smartEnabled && startup.control.fans.count == 2, "ready startup acquires both demo fans")
    startup.control = ControlState(); startup.snapshot = .demo; startup.selectedMode = .system
    startup.applyStartupDefaultIfReady()
    try expect(startup.control.fans.isEmpty, "startup never reacquires after a control session is released")

    for mode in [FanMode.system, .manual] {
        let choice = FanModel(demo: true)
        choice.selectMode(mode); choice.applyStartupDefaultIfReady()
        try expect(choice.control.fans.isEmpty && choice.selectedMode == mode, "explicit mode selection cancels pending startup")
    }
    for pressure in [ThermalPressure.serious, .critical, .unknown] {
        let unsafe = FanModel(demo: true)
        unsafe.snapshot.thermalPressure = pressure
        unsafe.applyStartupDefaultIfReady()
        try expect(unsafe.control.fans.isEmpty, "startup respects system thermal pressure")
        unsafe.snapshot.thermalPressure = .nominal; unsafe.applyStartupDefaultIfReady()
        try expect(unsafe.control.fans.isEmpty, "blocked startup never automatically retries later")
    }
    let conflict = FanModel(demo: true)
    conflict.snapshot.conflictingController = "Other fan controller"
    conflict.applyStartupDefaultIfReady()
    try expect(conflict.control.fans.isEmpty, "startup does not compete with another controller")
    let missingTemperature = FanModel(demo: true)
    missingTemperature.snapshot.temperature = nil; missingTemperature.applyStartupDefaultIfReady()
    try expect(missingTemperature.control.fans.isEmpty, "startup requires a trusted temperature")
    let unsupported = FanModel(demo: true)
    unsupported.snapshot.controlAvailability = .init(allowed: false, reason: "read only")
    unsupported.applyStartupDefaultIfReady()
    try expect(unsupported.control.fans.isEmpty, "startup respects runtime control admission")
    let existingManual = FanModel(demo: true)
    existingManual.snapshot.fans = existingManual.snapshot.fans.map {
        FanReading(id: $0.id, actual: $0.actual, target: $0.target, minimum: $0.minimum, maximum: $0.maximum, mode: 1)
    }
    existingManual.applyStartupDefaultIfReady()
    try expect(existingManual.control.fans.isEmpty, "startup does not overwrite existing manual hardware state")
    let initialError = FanModel(demo: true)
    initialError.snapshot.error = "initial read failed"; initialError.applyStartupDefaultIfReady()
    try expect(initialError.control.fans.isEmpty, "startup waits through an initial read failure")
    initialError.snapshot.error = nil; initialError.applyStartupDefaultIfReady()
    try expect(initialError.control.smartEnabled, "startup may proceed when initial reads recover")
    let fanless = FanModel(demo: true)
    fanless.snapshot.fans = []; fanless.snapshot.reportedFanCount = 0
    fanless.snapshot.controlAvailability = .init(allowed: false, reason: "No fan")
    fanless.applyStartupDefaultIfReady()
    try expect(!fanless.canAdjust && !fanless.canStartSmart && fanless.control.fans.isEmpty, "fanless Apple Silicon remains monitoring-only")
    let noAuthorization = FanModel(preferences: store)
    noAuthorization.snapshot = .demo; noAuthorization.refreshed = true
    noAuthorization.applyStartupDefaultIfReady()
    try expect(noAuthorization.control.fans.isEmpty && !noAuthorization.showSettings && !noAuthorization.busy
        && noAuthorization.status.contains("待启用"), "unauthorized startup stays system without prompting or opening settings")

    let authorizationGate = FanModel(preferences: store)
    authorizationGate.snapshot = .demo
    authorizationGate.startSmart()
    try expect(authorizationGate.showSettings && !authorizationGate.busy && authorizationGate.control.fans.isEmpty,
        "unauthorized smart action opens settings without an administrator prompt or hardware takeover")
    authorizationGate.closeSettings()
    try expect(!authorizationGate.showSettings, "pending authorization can be dismissed")

    print("PASS: \(count) UI workflow checks using demo hardware. No real SMC writes or authorization performed.")
}
