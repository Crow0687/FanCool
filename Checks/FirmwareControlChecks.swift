import Foundation
import FanCoolCore

private final class RegisterFixture: FanRegisterAccess {
    var unlock = 0.0
    var hasUnlock = true
    var requiresUnlock = true
    var failModes = Set<Int>()
    var failUnlockRelease = false
    var permissionFailure = false
    var clock = Date(timeIntervalSince1970: 100)
    var modeReadyDelay: TimeInterval = 0
    var unlockReadDelay: TimeInterval = 0
    var activatedAt: Date?
    var scheduledUnlock: (Double, Date)?
    var rejectZeroModeWhileUnlocked = false
    var modes = [0: 0.0, 1: 0.0]
    var targets = [0: 0.0, 1: 0.0]
    var events: [(String, Double)] = []
    var beforeUnlock: (() throws -> Void)?
    var visibleFans: Set<Int> = [0, 1]
    func fanCount() throws -> Int { 2 }
    private func refreshUnlock() {
        if let (value, at) = scheduledUnlock, clock >= at {
            unlock = value; scheduledUnlock = nil
            if value == 1 { activatedAt = clock }
        }
    }
    func number(_ key: String) throws -> Double {
        refreshUnlock()
        if key == "Ftst", hasUnlock { return unlock }
        for id in 0..<2 {
            if key == "F\(id)Md" { return modes[id]! }
        }
        throw FanCoolError.unavailable
    }
    func isByteRegister(_ key: String) -> Bool { key == "Ftst" && hasUnlock }
    func fans() throws -> [FanReading] {
        refreshUnlock()
        return (0..<2).filter { visibleFans.contains($0) }.map { .init(id: $0, actual: targets[$0]!, target: targets[$0], minimum: 1000, maximum: 4900, mode: Int(modes[$0]!)) }
    }
    func writeFanRegister(_ key: String, value: Double, fan: Int, restoring: Bool, targetRPM: Double?, reason: String) throws {
        events.append((key, value))
        refreshUnlock()
        if permissionFailure { throw FanCoolError.firmwareWriteRejected(key: key, status: 0xe00002c1) }
        if key == "Ftst" {
            if value == 1 { try beforeUnlock?() }
            if value == 0 && failUnlockRelease { throw FanCoolError.firmwareWriteRejected(key: key, status: 0x10000082) }
            if unlockReadDelay > 0 { scheduledUnlock = (value, clock.addingTimeInterval(unlockReadDelay)) }
            else { unlock = value; if value == 1 { activatedAt = clock } }
        } else {
            let notReady = requiresUnlock && (unlock != 1 || activatedAt.map { clock.timeIntervalSince($0) < modeReadyDelay } == true)
            if (value == 1 && (notReady || failModes.contains(fan))) || (value == 0 && unlock == 1 && rejectZeroModeWhileUnlocked) {
                throw FanCoolError.firmwareWriteRejected(key: key, status: 0x10000082)
            }
            modes[fan] = value
        }
    }
}

private final class CompatibilityFixture: FanHardware {
    let registers = RegisterFixture()
    var stored: FirmwareControlLease?
    var failSave = false
    var failClear = false
    var failTarget = false
    var waits: [TimeInterval] = []
    var heat = 65.0
    var targetWrites: [Double] = []
    private let initialLease: FirmwareControlLease?
    lazy var controller = FirmwareFanControl(registers: registers, lease: initialLease, persist: { [unowned self] lease in
        if (lease == nil && self.failClear) || (lease != nil && self.failSave) { throw FanCoolError.hardware("Injected journal failure") }
        self.stored = lease
    }, wait: { [unowned self] delay in self.waits.append(delay); self.registers.clock = self.registers.clock.addingTimeInterval(delay) },
       clock: { [unowned self] in self.registers.clock })
    init(lease: FirmwareControlLease? = nil) { initialLease = lease; stored = lease }
    var recoveryFans: Set<Int> { controller.recoveryFans }
    func prepareControl(ownedFans: Set<Int>) throws { try controller.prepareControl(ownedFans: ownedFans) }
    func prepareRecovery() throws { try controller.prepareRecovery() }
    func finishControl(remainingFans: Set<Int>) throws { try controller.finishControl(remainingFans: remainingFans) }
    func controlAvailability() -> ControlAvailability { .init(allowed: true, reason: "fixture") }
    func fans() throws -> [FanReading] { try registers.fans() }
    func temperature() -> Double? { heat }
    func setManual(fan: Int, rpm: Double) throws {
        try controller.enterManual(fan: fan, key: "F\(fan)Md", rpm: rpm, reason: "fixture")
        if failTarget { throw FanCoolError.hardware("Injected target failure") }
        registers.targets[fan] = rpm
        targetWrites.append(rpm)
    }
    func restoreAutomatic(fan: Int) throws {
        try registers.writeFanRegister("F\(fan)Md", value: 0, fan: fan, restoring: true, targetRPM: nil, reason: "fixture")
        registers.targets[fan] = 0
    }
}

func runFirmwareControlChecks() throws -> Int {
    var count = 0
    func check(_ condition: Bool, _ name: String) throws {
        guard condition else { throw FanCoolError.hardware("Firmware check failed: \(name)") }
        count += 1
    }
    func fails(_ name: String, _ body: () throws -> Void) throws {
        do { try body() } catch { count += 1; return }
        throw FanCoolError.hardware("Firmware check did not fail: \(name)")
    }
    var attempts = 0
    var waits: [TimeInterval] = []
    var mode = 0.0
    try FanModeTransition.enterManual(key: "F0Md", readMode: { mode }, writeMode: { _ in
        attempts += 1
        if attempts < 3 { throw FanCoolError.firmwareWriteRejected(key: "F0Md", status: 0x10000082) }
        mode = 1
    }, wait: { waits.append($0) })
    try check(attempts == 3 && waits.count == 2 && mode == 1, "transient rejection recovers with bounded direct retries")
    try FanModeTransition.enterManual(key: "F0Md", readMode: { 1 }, writeMode: { _ in attempts += 1 }, wait: { _ in })
    try check(attempts == 3, "already-manual readback never repeats takeover")
    attempts = 0; waits = []
    try fails("persistent rejection") {
        try FanModeTransition.enterManual(key: "F0Md", readMode: { 0 }, writeMode: { _ in
            attempts += 1; throw FanCoolError.firmwareWriteRejected(key: "F0Md", status: 0x10000082)
        }, wait: { waits.append($0) })
    }
    try check(attempts == 6 && waits.count == 5, "direct rejection has a strict attempt and delay budget")
    for failure in [FanCoolError.hardware("audit failure"), .firmwareWriteRejected(key: "F0Md", status: 0xe00002c1), .firmwareWriteRejected(key: "F1Md", status: 0x10000082)] {
        attempts = 0; waits = []
        try fails("nonmatching failure is not retried") {
            try FanModeTransition.enterManual(key: "F0Md", readMode: { 0 }, writeMode: { _ in attempts += 1; throw failure }, wait: { waits.append($0) })
        }
        try check(attempts == 1 && waits.isEmpty, "permission, audit and other-register errors stop immediately")
    }
    mode = 0; attempts = 0
    try FanModeTransition.enterManual(key: "F0Md", readMode: { mode }, writeMode: { _ in
        attempts += 1; mode = 1; throw FanCoolError.firmwareWriteRejected(key: "F0Md", status: 0x10000082)
    }, wait: { _ in })
    try check(attempts == 1, "readback can confirm a transition despite a rejected reply")

    let now = Date(timeIntervalSince1970: 100)
    func ticks(_ hardware: CompatibilityFixture, _ session: ControlSession, count: Int) {
        for _ in 0..<count {
            hardware.registers.clock = hardware.registers.clock.addingTimeInterval(1)
            session.heartbeat(now: hardware.registers.clock)
            session.check(now: hardware.registers.clock)
        }
    }
    let direct = CompatibilityFixture(); direct.registers.requiresUnlock = false
    let directSession = ControlSession(hardware: direct, now: now)
    try directSession.applyPercentage(fan: -1, percent: 55, now: now)
    try check(direct.stored == nil && !direct.registers.events.contains { $0.0 == "Ftst" }, "working direct hardware never writes the compatibility register")
    try directSession.restoreAll()

    let hw = CompatibilityFixture()
    hw.registers.beforeUnlock = { try check(hw.stored?.isValid == true, "lease is persisted before the global write") }
    let session = ControlSession(hardware: hw, now: now)
    try session.startSmart(now: now)
    try check(hw.registers.unlock == 1 && hw.stored?.fans == [0, 1] && session.controlledFans == [0, 1], "fallback controls asymmetric sessions with a recorded global lease")
    try check(hw.waits.allSatisfy { $0 < 1 } && session.state.notice?.contains("等待固件") == true && hw.targetWrites.isEmpty,
        "yield is pending state with no blocking multi-second sleep or premature target writes")
    ticks(hw, session, count: 5)
    try check(session.state.fans.allSatisfy(\.confirmed) && session.state.notice == nil, "watchdog completes and confirms both pending targets")
    try session.requestAutomatic(fan: 0)
    try check(hw.registers.unlock == 1 && hw.stored != nil && session.controlledFans == [1], "single fan release preserves the other smart fan and lease")
    try session.restoreAll()
    try check(hw.registers.unlock == 0 && hw.stored == nil && session.controlledFans.isEmpty, "last fan release clears both ownership records and global state")

    let lost = CompatibilityFixture(); lost.registers.requiresUnlock = false
    let lostSession = ControlSession(hardware: lost, now: now)
    try lostSession.startSmart(now: now)
    lost.registers.requiresUnlock = true; lost.registers.modes[0] = 0; lost.registers.modes[1] = 0
    lostSession.heartbeat(now: now.addingTimeInterval(1)); lostSession.check(now: now.addingTimeInterval(1))
    ticks(lost, lostSession, count: 5)
    try check(lostSession.state.smartEnabled && lost.registers.unlock == 1 && lost.registers.modes.values.allSatisfy { $0 == 1 }, "lost direct control can transition to the recorded compatibility path")
    try lostSession.restoreAll()

    for fault in ["journal", "second-fan", "target"] {
        let broken = CompatibilityFixture()
        broken.failSave = fault == "journal"; broken.failTarget = fault == "target"
        if fault == "second-fan" { broken.registers.failModes = [1] }
        let brokenSession = ControlSession(hardware: broken, now: now)
        if fault == "journal" { try fails(fault) { try brokenSession.applyPercentage(fan: -1, percent: 55, now: now) } }
        else { try brokenSession.applyPercentage(fan: -1, percent: 55, now: now); ticks(broken, brokenSession, count: 23) }
        try check(broken.registers.unlock == 0 && broken.stored == nil && brokenSession.controlledFans.isEmpty && broken.registers.modes.values.allSatisfy { $0 == 0 }, "\(fault) failure rolls back every acquired fan and the global lease")
        if fault == "journal" { try check(!broken.registers.events.contains { $0.0 == "Ftst" }, "failed persistence prevents all global mutations") }
    }
    let foreign = CompatibilityFixture(); foreign.registers.unlock = 1
    let foreignSession = ControlSession(hardware: foreign, now: now)
    try fails("foreign lease") { try foreignSession.startSmart(now: now) }
    try check(foreign.registers.events.isEmpty && foreign.stored == nil, "foreign global state is rejected before any takeover or rollback writes")
    let otherFan = CompatibilityFixture(); otherFan.registers.modes[1] = 1; otherFan.registers.targets[1] = 3500
    let singleSession = ControlSession(hardware: otherFan, now: now)
    try fails("another manual fan outside the requested scope") { try singleSession.applyPercentage(fan: 0, percent: 55, now: now) }
    try check(otherFan.registers.modes[1] == 1 && otherFan.registers.targets[1] == 3500 && !otherFan.registers.events.contains { $0.0 == "Ftst" },
        "global fallback cannot adopt or reset an unrequested manual fan")
    let unsupported = CompatibilityFixture(); unsupported.registers.hasUnlock = false
    let unsupportedSession = ControlSession(hardware: unsupported, now: now)
    try fails("missing compatibility encoding") { try unsupportedSession.startSmart(now: now) }
    try check(!unsupported.registers.events.contains { $0.0 == "Ftst" }, "unknown compatibility metadata is never written")
    let incomplete = CompatibilityFixture(); incomplete.registers.visibleFans = [0]
    let incompleteSession = ControlSession(hardware: incomplete, now: now)
    try fails("incomplete fan reads") { try incompleteSession.applyPercentage(fan: 0, percent: 55, now: now) }
    try check(!incomplete.registers.events.contains { $0.0 == "Ftst" }, "a missing second fan cannot masquerade as a complete single-fan machine")

    let pending = CompatibilityFixture()
    var dirty = Set<Int>()
    let pendingSession = ControlSession(hardware: pending, now: now) { dirty = $0 }
    try pendingSession.startSmart(now: now)
    pending.registers.failUnlockRelease = true
    try fails("global release failure") { try pendingSession.restoreAll() }
    try check(!dirty.isEmpty && pending.stored != nil && pendingSession.state.restoring, "failed global release keeps ownership and blocks per-fan restoration until it is safe")
    pending.registers.failUnlockRelease = false
    ticks(pending, pendingSession, count: 1)
    try check(dirty.isEmpty && pending.stored == nil && !pendingSession.state.restoring, "watchdog retries unfinished global release")
    try pendingSession.startSmart(now: pending.registers.clock)
    pending.failClear = true
    try fails("journal removal failure") { try pendingSession.restoreAll() }
    try check(pending.registers.unlock == 0 && pending.stored != nil && !dirty.isEmpty, "journal cleanup failure cannot falsely report completed recovery")
    pending.failClear = false; ticks(pending, pendingSession, count: 1)
    try check(dirty.isEmpty && pending.stored == nil, "journal cleanup can be retried without reacquiring control")

    let restarted = CompatibilityFixture(lease: FirmwareControlLease(fans: [0, 1]))
    restarted.registers.unlock = 1; restarted.registers.modes = [0: 1, 1: 1]
    let restartedSession = ControlSession(hardware: restarted, now: now)
    restartedSession.recover([])
    try check(restarted.registers.events.first?.0 == "Ftst" && restarted.registers.events.first?.1 == 0, "restart clears global takeover before restoring individual modes")
    try check(restartedSession.controlledFans.isEmpty && restarted.stored == nil && restarted.registers.modes.values.allSatisfy { $0 == 0 }, "lease alone recovers every fan even without the old per-fan journal")
    try check(restartedSession.notice?.contains("已恢复系统") == true, "completed lease-only recovery reports completion")
    try check(!FirmwareControlLease(fans: []).isValid && !FirmwareControlLease(fans: [0, 2]).isValid && !FirmwareControlLease(fans: [0, 0]).isValid, "malformed recovery scopes are rejected")

    // Reproduce the supplied M3 Max log: Ftst is active, but mode writes remain
    // locked until the fan/controller has had about eight seconds to settle.
    let slow = CompatibilityFixture(); slow.registers.modeReadyDelay = 8
    let slowSession = ControlSession(hardware: slow, now: now)
    try slowSession.startSmart(now: now)
    ticks(slow, slowSession, count: 5)
    try check(slowSession.state.smartEnabled && slowSession.state.notice?.contains("等待固件") == true && slow.targetWrites.isEmpty,
        "slow M3 handoff remains pending while heartbeats are processed")
    ticks(slow, slowSession, count: 5)
    try check(slowSession.state.fans.allSatisfy(\.confirmed) && !slow.targetWrites.isEmpty,
        "eight-second handoff completes without a false timeout or heartbeat loss")
    slow.registers.rejectZeroModeWhileUnlocked = true
    let releaseStart = slow.registers.events.count
    try slowSession.restoreAll()
    try check(slow.registers.events[releaseStart].0 == "Ftst" && slow.registers.events[releaseStart].1 == 0 && slow.stored == nil,
        "full release clears global state before touching mode-zero registers that reject writes")

    let cancel = CompatibilityFixture(); cancel.registers.modeReadyDelay = 8
    let cancelSession = ControlSession(hardware: cancel, now: now)
    try cancelSession.startSmart(now: now)
    try cancelSession.requestAutomatic()
    ticks(cancel, cancelSession, count: 10)
    try check(cancelSession.controlledFans.isEmpty && cancel.stored == nil && cancel.targetWrites.isEmpty,
        "system selection cancels a pending handoff without later reacquisition")
    let dead = CompatibilityFixture(); dead.registers.modeReadyDelay = 8
    let deadSession = ControlSession(hardware: dead, now: now)
    try deadSession.startSmart(now: now)
    dead.registers.clock = dead.registers.clock.addingTimeInterval(7)
    deadSession.check(now: dead.registers.clock)
    try check(deadSession.controlledFans.isEmpty && dead.registers.unlock == 0 && dead.stored == nil,
        "lost heartbeat releases a pending handoff instead of waiting out its full deadline")
    let timeout = CompatibilityFixture(); timeout.registers.modeReadyDelay = 100
    let timeoutSession = ControlSession(hardware: timeout, now: now)
    try timeoutSession.startSmart(now: now)
    ticks(timeout, timeoutSession, count: 22)
    try check(timeoutSession.controlledFans.isEmpty && timeout.registers.unlock == 0 && timeout.stored == nil && timeoutSession.notice?.contains("20 秒") == true,
        "a controller that never becomes writable reaches its fixed deadline and fully releases")
    let emergency = CompatibilityFixture(); emergency.registers.modeReadyDelay = 8
    let emergencySession = ControlSession(hardware: emergency, now: now)
    try emergencySession.startSmart(now: now)
    emergency.heat = 90
    ticks(emergency, emergencySession, count: 10)
    try check(emergency.targetWrites.isEmpty && emergencySession.controlledFans.isEmpty && emergency.registers.unlock == 0,
        "high temperature aborts an unfinished handoff instead of holding a global override without cooling authority")
    try emergencySession.restoreAll()
    let delayed = CompatibilityFixture(); delayed.registers.unlockReadDelay = 2
    let delayedSession = ControlSession(hardware: delayed, now: now)
    try delayedSession.startSmart(now: now)
    ticks(delayed, delayedSession, count: 6)
    try check(delayedSession.state.fans.allSatisfy(\.confirmed), "delayed global readback is awaited without repeated unlock writes")
    try fails("delayed release acknowledgement remains pending") { try delayedSession.restoreAll() }
    ticks(delayed, delayedSession, count: 3)
    try check(delayedSession.controlledFans.isEmpty && delayed.stored == nil && delayed.registers.events.filter { $0.0 == "Ftst" && $0.1 == 0 }.count == 1,
        "delayed reset is not restarted every watchdog tick and eventually confirms release")
    try check(delayedSession.notice?.contains("已恢复") == true, "successful delayed release replaces its obsolete pending notice")
    return count
}
