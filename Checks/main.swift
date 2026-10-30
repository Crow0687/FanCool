import Foundation
import FanCoolCore
import Security
import Darwin

// Fault injection exists only in the uninstalled check executable, never in the root service.
if CommandLine.arguments.contains("--stalled-queue-child") {
    let blocked = DispatchQueue(label: "fancool.check.blocked")
    blocked.async { Thread.sleep(forTimeInterval: 10) }
    let guardrail = QueueLivenessGuard(timeout: 0.25)
    guardrail.start(controlQueue: blocked, interval: 0.03) { _exit(75) }
    withExtendedLifetime(guardrail) { RunLoop.main.run(until: Date().addingTimeInterval(2)) }
    exit(99)
}

var checks = 0
func expect(_ condition: @autoclosure () -> Bool, _ name: String) {
    guard condition() else { fputs("FAIL: \(name)\n", stderr); exit(1) }
    checks += 1
}
func rejects(_ name: String, _ body: () throws -> Void) {
    do { try body(); expect(false, name) }
    catch { checks += 1 }
}

final class FakeHardware: FanHardware {
    var heat: Double? = 50
    var manual: [Int: Double] = [:]
    var failTarget = false
    var failRestore = false
    var failRead = false
    var admission = true
    func controlAvailability() -> ControlAvailability { .init(allowed: admission, reason: "Injected admission") }
    var writes = 0
    var maxima = [4900.0, 4900.0]
    var minima = [1000.0, 1000.0]
    var failFan: Int?
    var conflict: String?
    var forcedReadback: Double?
    var actualOverride: Double?
    func fans() throws -> [FanReading] {
        if failRead { throw FanCoolError.unavailable }
        return (0..<2).map { .init(id: $0, actual: actualOverride ?? manual[$0] ?? 1000, target: manual[$0] == nil ? nil : (forcedReadback ?? manual[$0]), minimum: minima[$0], maximum: maxima[$0], mode: manual[$0] == nil ? 0 : 1) }
    }
    func temperature() -> Double? { heat }
    func setManual(fan: Int, rpm: Double) throws {
        writes += 1; manual[fan] = rpm
        if failTarget || fan == failFan { throw FanCoolError.hardware("Injected target failure after mode write") }
    }
    func conflictingController() -> String? { conflict }
    func restoreAutomatic(fan: Int) throws {
        if failRead { throw FanCoolError.unavailable }
        if failRestore { throw FanCoolError.restoreFailed }
        manual.removeValue(forKey: fan)
    }
}

expect(SMCCodec.fourCC("F0Ac") == 0x46304163, "fourCC ordering")
expect(SMCCodec.name(0x46532120) == "FS! ", "fourCC spaces")
expect(SMCCodec.decode(type: "fpe2", bytes: [0x2b, 0xc0]) == 2800, "Intel RPM decoding")
expect(SMCCodec.decode(type: "sp78", bytes: [0xff, 0x80]) == -0.5, "signed fractional temperature")
expect(SMCCodec.decode(type: "sp78", bytes: [0x39, 0xb3]).map { abs($0 - 57.699) < 0.01 } == true, "temperature precision")
expect(SMCCodec.decode(type: "ui32", bytes: [0, 0, 0x10, 0]) == 4096, "key count endian")
for rpm in [1000.0, 1800, 2800, 3800, 4900] {
    for type in ["flt ", "fpe2"] {
        let encoded = SMCCodec.encode(rpm, type: type)!
        expect(SMCCodec.decode(type: type, bytes: encoded) == rpm, "RPM round-trip \(type) \(rpm)")
    }
}
expect(SMCCodec.encode(.nan, type: "flt ") == nil, "NaN rejected")
expect(SMCCodec.encode(.infinity, type: "flt ") == nil, "infinite target rejected")
expect(SMCCodec.decode(type: "flt ", bytes: [0, 0, 0x80, 0x7f]) == nil, "infinite sensor rejected")
expect(SMCCodec.decode(type: "sp78", bytes: [1]) == nil, "truncated payload rejected")
expect(SMCCodec.encode(20_000, type: "fpe2") == nil, "fixed-point overflow rejected")
expect(SMCCodec.decode(type: "fp88", bytes: [0x0c, 0x80]) == 12.5, "voltage fixed-point decoding")
expect(SMCCodec.decode(type: "sp87", bytes: [0xff, 0xc0]) == -0.5, "signed current fixed-point decoding")
expect(FanSpeed.percent(rpm: 0, maximum: 5349) == 0, "zero readback remains visible")
expect(FanSpeed.percent(rpm: 1000, maximum: nil) == nil, "unknown maximum never fabricates a percentage")

let start = Date(timeIntervalSince1970: 1000)
let hw = FakeHardware()
let session = ControlSession(hardware: hw, now: start)
rejects("below minimum rejected") { try session.apply(fan: 0, rpm: 999, now: start) }
rejects("above maximum rejected") { try session.apply(fan: 0, rpm: 4901, now: start) }
rejects("missing fan rejected") { try session.apply(fan: 9, rpm: 2800, now: start) }
rejects("NaN rejected before write") { try session.apply(fan: 0, rpm: .nan, now: start) }
expect(hw.writes == 0, "invalid requests never touch hardware")
hw.heat = nil
rejects("no temperature prevents takeover") { try session.apply(fan: 0, rpm: 2800, now: start) }
hw.heat = 90
rejects("hot hardware prevents takeover") { try session.apply(fan: 0, rpm: 2800, now: start) }
hw.heat = 50
try session.apply(fan: 0, rpm: 2800, now: start)
try session.apply(fan: 1, rpm: 3800, now: start)
expect(hw.manual.count == 2, "independent multi-fan commands")
session.heartbeat(now: start.addingTimeInterval(6))
session.check(now: start.addingTimeInterval(10))
expect(hw.manual.count == 2, "heartbeat keeps live session")
session.check(now: start.addingTimeInterval(15))
expect(hw.manual.isEmpty && session.controlledFans.isEmpty, "lost heartbeat restores every controlled fan")

for trigger in ["heat", "sensor", "pressure"] {
    hw.heat = 50
    try session.apply(fan: 0, rpm: 1800, now: start)
    if trigger == "heat" { hw.heat = 90 }
    if trigger == "sensor" { hw.heat = nil }
    session.check(now: start.addingTimeInterval(1), thermalPressure: trigger == "pressure" ? .serious : .nominal)
    expect(hw.manual.isEmpty, "\(trigger) safety release")
}
hw.heat = 50; hw.failTarget = true
rejects("target-write failure reported") { try session.apply(fan: 0, rpm: 2800, now: start) }
expect(hw.manual.isEmpty, "partial takeover rolls back")
hw.failTarget = false
try session.apply(fan: 0, rpm: 2800, now: start)
hw.failRestore = true
rejects("restore failure reported") { try session.restoreAll() }
expect(session.controlledFans.contains(0), "failed restoration remains tracked")
rejects("new takeover blocked during restoration") { try session.apply(fan: 1, rpm: 2800, now: start) }
hw.failRestore = false
session.check(now: start.addingTimeInterval(1))
expect(hw.manual.isEmpty && session.controlledFans.isEmpty, "watchdog retries failed restoration")

let dual = FakeHardware()
dual.maxima = [5349, 5777]; dual.minima = [1350, 1458]
let dualSession = ControlSession(hardware: dual, now: start)
let dualReadings = try dual.fans()
expect(FanSpeed.minimumPercent(for: dualReadings) == 26, "shared percentage respects both hardware minima")
try dualSession.applyPercentage(fan: -1, percent: 50, now: start)
expect(dual.manual[0] == 2675 && dual.manual[1] == 2889, "same percentage maps to asymmetric fan RPM limits")
expect(dualSession.state.fans.count == 2 && dualSession.state.fans.allSatisfy { !$0.confirmed }, "write acknowledgement is not reported as stable RPM")
dualSession.check(now: start.addingTimeInterval(1))
expect(dualSession.state.fans.allSatisfy(\.confirmed), "both actual RPM readings confirm independently")
try dualSession.requestAutomatic(fan: 0)
expect(dual.manual[0] == nil && dual.manual[1] == 2889, "scoped automatic preserves the other controlled fan")
try dualSession.restoreAll()
try dualSession.applyPercentage(fan: 1, percent: 75, now: start)
expect(dual.manual[0] == nil && dual.manual[1] == 4333, "selected fan control leaves the other fan alone")
try dualSession.restoreAll()
let writeCount = dual.writes
rejects("zero percent below firmware minimum rejected") { try dualSession.applyPercentage(fan: -1, percent: 0, now: start) }
rejects("infinite percentage rejected") { try dualSession.applyPercentage(fan: -1, percent: .infinity, now: start) }
expect(dual.writes == writeCount, "invalid percentage never starts a partial batch")
dual.failFan = 1
rejects("second fan failure reported") { try dualSession.applyPercentage(fan: -1, percent: 55, now: start) }
expect(dual.manual.isEmpty && dualSession.controlledFans.isEmpty, "second fan failure releases the entire batch")
dual.failFan = nil
dual.conflict = "Macs Fan Control"
let conflictWrites = dual.writes
rejects("concurrent controller blocks takeover") { try dualSession.applyPercentage(fan: -1, percent: 55, now: start) }
expect(dual.writes == conflictWrites, "conflict detection never fights another controller")
dual.conflict = nil
try dualSession.applyPercentage(fan: -1, percent: 55, now: start)
dual.conflict = "Macs Fan Control"
dualSession.check(now: start.addingTimeInterval(1))
expect(dual.manual.isEmpty, "another controller appearing causes safe release")
dual.conflict = nil
try dualSession.applyPercentage(fan: 0, percent: 55, now: start)
dual.forcedReadback = 1500
for tick in 1...4 { dualSession.check(now: start.addingTimeInterval(Double(tick))) }
expect(dual.manual.isEmpty && dualSession.controlledFans.isEmpty, "persistent overwritten target stops after bounded retries")
expect(dualSession.notice?.contains("被覆盖") == true, "overridden target reports its actual reason")
dual.forcedReadback = nil
dual.manual[0] = 3000; dual.manual[1] = 3300
try dualSession.requestAutomatic()
expect(dual.manual.isEmpty, "explicit automatic clears inherited manual modes on both fans")
var persisted = Set<Int>()
let journalHardware = FakeHardware()
let journalSession = ControlSession(hardware: journalHardware, now: start) { ids in
    if !ids.isEmpty { expect(journalHardware.writes == 0, "ownership journal is written before hardware mutation") }
    persisted = ids
}
try journalSession.applyPercentage(fan: -1, percent: 55, now: start)
expect(persisted == [0, 1], "both dirty fans are journaled")
let recovered = ControlSession(hardware: journalHardware, now: start)
recovered.recover(persisted)
expect(journalHardware.manual.isEmpty, "helper restart releases journaled fans")
expect(SensorCatalog.describe("Tp1h", chip: "Apple M2 Pro").name == "能效核心 1", "M2 sensor naming uses its generation map")
expect(SensorCatalog.describe("ZZZZ", chip: "Apple M2 Pro").group == "其他", "unknown sensor location is not invented")
expect(!SensorKind.temperature.accepts(.nan) && !SensorKind.temperature.accepts(200), "invalid temperatures never enter the sensor list")

let sampleHash = String(repeating: "a", count: 40)
expect(HelperIdentity.validCodeHash(sampleHash), "local ad-hoc CDHash accepted")
expect(!HelperIdentity.validCodeHash(sampleHash + ";id"), "requirement injection rejected")
expect(!HelperIdentity.validCodeHash(String(repeating: "a", count: 39)), "truncated hash rejected")
expect(HelperIdentity.requirement(codeHash: "identifier fake") == nil, "free-form requirements rejected")
rejects("invalid identity cannot be installed") {
    _ = try InstalledAuthorization(clientCodeHash: "bad", helperCodeHash: sampleHash, userID: 501)
}
rejects("root GUI identity cannot be installed") {
    _ = try InstalledAuthorization(clientCodeHash: sampleHash, helperCodeHash: sampleHash, userID: 0)
}
let identity = try InstalledAuthorization(clientCodeHash: sampleHash, helperCodeHash: sampleHash, userID: 501)
let decodedIdentity = try JSONDecoder().decode(InstalledAuthorization.self, from: JSONEncoder().encode(identity))
expect(decodedIdentity == identity, "authorization policy round-trip")

func shellOutput(_ command: String, executable: String = "/bin/sh", option: String = "-c") throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = option == "-n" ? ["-n", "-c", command] : [option, command]
    let output = Pipe(); process.standardOutput = output; process.standardError = output
    try process.run()
    let data = output.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
    guard process.terminationStatus == 0 else { throw FanCoolError.hardware(String(decoding: data, as: UTF8.self)) }
    return String(decoding: data, as: UTF8.self)
}
for value in ["path with spaces", "quote'\"", "$(printf injected)`printf injected`$HOME", "line1\nline2"] {
    let output = try shellOutput("/usr/bin/printf '%s' " + ShellEscaping.quote(value))
    expect(output == value, "installer path remains literal: \(value)")
}
let installCommand = try AdministratorCommand.make(helperSource: "/tmp/helper' \"$(printf bad)",
    fileSHA256: String(repeating: "b", count: 64), clientHash: sampleHash, helperHash: sampleHash, userID: 501)
_ = try shellOutput(installCommand, option: "-n")
checks += 1 // Parse the actual install command without executing any of it.
let scriptResult = try shellOutput("return " + ShellEscaping.appleScriptString(installCommand), executable: "/usr/bin/osascript", option: "-e")
expect(scriptResult == installCommand + "\n", "AppleScript preserves the complete installer command without executing it")
rejects("digest injection rejected") {
    _ = try AdministratorCommand.make(helperSource: "/tmp/helper", fileSHA256: "'; id", clientHash: sampleHash, helperHash: sampleHash, userID: 501)
}

if let ownHash = HelperIdentity.currentCodeHash(), let requirementText = HelperIdentity.requirement(codeHash: ownHash) {
    var requirement: SecRequirement?
    expect(SecRequirementCreateWithString(requirementText as CFString, [], &requirement) == errSecSuccess, "exact code-hash requirement compiles")
    var ownCode: SecCode?; var staticCode: SecStaticCode?
    expect(SecCodeCopySelf([], &ownCode) == errSecSuccess, "read running local identity")
    expect(SecCodeCopyStaticCode(ownCode!, [], &staticCode) == errSecSuccess, "read running signed code")
    expect(SecStaticCodeCheckValidity(staticCode!, [], requirement) == errSecSuccess, "ad-hoc signed peer matches its exact pin")
    var wrongRequirement: SecRequirement?
    _ = SecRequirementCreateWithString(HelperIdentity.requirement(codeHash: String(repeating: "0", count: 40))! as CFString, [], &wrongRequirement)
    expect(SecStaticCodeCheckValidity(staticCode!, [], wrongRequirement) != errSecSuccess, "different binary identity is rejected")
} else { expect(false, "running binary has readable local code signature") }

for (temperature, expected) in [(20.0, 26.0), (55, 40), (65, 55), (70, 65), (73.4, 71.8), (75, 75), (80, 85), (90, 100), (110, 100)] {
    expect(abs(SmartFanPolicy.curvePercentage(at: temperature) - expected) < 0.0001, "smart curve interpolates \(temperature)°C")
}
var smoothing = SmartFanPolicy()
let firstDecision = try smoothing.evaluate(temperature: 73.4, minimumPercentage: 26, now: start)
expect(firstDecision.filteredTemperature == 73.4 && abs(firstDecision.percentage - 71.8) < 0.001, "smart first sample does not start from zero degrees")
let emergency = try smoothing.evaluate(temperature: 95, minimumPercentage: 26, now: start.addingTimeInterval(1))
expect(emergency.filteredTemperature < 90 && emergency.percentage == 100 && emergency.emergency, "raw high temperature bypasses EMA delay and ramp limit")
var falling = SmartFanPolicy()
_ = try falling.evaluate(temperature: 80, minimumPercentage: 26, now: start)
var fall = firstDecision
for tick in 1...15 { fall = try falling.evaluate(temperature: 60, minimumPercentage: 26, now: start.addingTimeInterval(Double(tick))) }
expect(fall.percentage == 85, "cooling must remain stable before reducing fan speed")
fall = try falling.evaluate(temperature: 60, minimumPercentage: 26, now: start.addingTimeInterval(16))
expect(fall.percentage == 82, "downward slew is limited to three percentage points per second")
var wobble = SmartFanPolicy()
_ = try wobble.evaluate(temperature: 70, minimumPercentage: 26, now: start)
for tick in 1...30 {
    let value = try wobble.evaluate(temperature: tick % 2 == 0 ? 69.5 : 70, minimumPercentage: 26, now: start.addingTimeInterval(Double(tick)))
    expect(value.percentage >= 65, "small temperature jitter does not reduce and raise fan repeatedly")
}
var rising = SmartFanPolicy()
_ = try rising.evaluate(temperature: 50, minimumPercentage: 26, now: start)
_ = try rising.evaluate(temperature: 70, minimumPercentage: 26, now: start.addingTimeInterval(1))
_ = try rising.evaluate(temperature: 80, minimumPercentage: 26, now: start.addingTimeInterval(2))
let prediction = try rising.evaluate(temperature: 85, minimumPercentage: 26, now: start.addingTimeInterval(3))
expect(prediction.reason.contains("提前升速"), "sustained temperature rise adds a bounded early boost")
var invalidPolicy = SmartFanPolicy()
rejects("smart rejects invalid control temperature") { _ = try invalidPolicy.evaluate(temperature: .nan, minimumPercentage: 26, now: start) }
_ = try invalidPolicy.evaluate(temperature: 70, minimumPercentage: 26, now: start)
rejects("smart rejects stale control cadence") { _ = try invalidPolicy.evaluate(temperature: 70, minimumPercentage: 26, now: start.addingTimeInterval(10)) }

let smartHardware = FakeHardware()
smartHardware.maxima = [5349, 5777]; smartHardware.minima = [1350, 1458]; smartHardware.heat = 70
let smartSession = ControlSession(hardware: smartHardware, now: start)
try smartSession.startSmart(now: start)
expect(smartSession.state.smartEnabled && smartHardware.manual[0] == 3477 && smartHardware.manual[1] == 3755, "70 degree smart control raises both fans above idle with individual maxima")
smartSession.heartbeat(now: start.addingTimeInterval(1)); smartSession.check(now: start.addingTimeInterval(1))
expect(smartSession.state.fans.allSatisfy(\.confirmed), "smart target actual speeds are confirmed")
let beforeSmartRamp = smartHardware.writes
smartHardware.heat = 80
for tick in 2...5 {
    let before = smartHardware.writes
    smartSession.heartbeat(now: start.addingTimeInterval(Double(tick)))
    smartSession.check(now: start.addingTimeInterval(Double(tick)))
    if tick % 2 == 1 { expect(smartHardware.writes == before, "normal smart updates are coalesced at two-second intervals") }
}
expect(smartHardware.writes > beforeSmartRamp, "smart responds to increasing temperature")
smartHardware.heat = 90
smartSession.heartbeat(now: start.addingTimeInterval(6)); smartSession.check(now: start.addingTimeInterval(6))
expect(smartHardware.manual[0] == 5349 && smartHardware.manual[1] == 5777, "smart high temperature requests full cooling instead of dropping to minimum")
smartSession.check(now: start.addingTimeInterval(7), thermalPressure: .serious)
expect(!smartSession.state.smartEnabled && smartHardware.manual.isEmpty, "system serious thermal pressure reclaims smart control")
smartHardware.heat = 70
try smartSession.startSmart(now: start)
smartHardware.heat = nil
smartSession.check(now: start.addingTimeInterval(1))
expect(smartHardware.manual.isEmpty && !smartSession.state.smartEnabled, "missing trusted temperature exits smart mode")
smartHardware.heat = 70
try smartSession.startSmart(now: start)
try smartSession.applyPercentage(fan: 0, percent: 55, now: start.addingTimeInterval(1))
expect(smartSession.state.smartEnabled && smartHardware.manual[1] == 3755, "single manual override preserves the other smart fan")
expect(smartSession.state.fans.first(where: { $0.id == 0 })?.smart == false && smartSession.state.fans.first(where: { $0.id == 1 })?.smart == true, "per-fan state distinguishes mixed manual and smart control")
smartHardware.heat = 80
smartSession.heartbeat(now: start.addingTimeInterval(2)); smartSession.check(now: start.addingTimeInterval(2))
expect(smartHardware.manual[0] == 2942 && smartHardware.manual[1]! > 3755, "smart updates cannot overwrite the manually selected fan")
smartHardware.heat = 90
smartSession.heartbeat(now: start.addingTimeInterval(3)); smartSession.check(now: start.addingTimeInterval(3))
expect(smartHardware.manual[0] == nil && smartHardware.manual[1] == 5777, "mixed high-temperature protection releases fixed control and keeps smart full cooling")
try smartSession.requestAutomatic()
expect(smartHardware.manual.isEmpty && !smartSession.state.smartEnabled, "global system mode releases every mixed control intent")
smartHardware.heat = 70
try smartSession.restoreAll()
try smartSession.startSmart(now: start)
smartSession.check(now: start.addingTimeInterval(9))
expect(smartHardware.manual.isEmpty && !smartSession.state.smartEnabled, "smart mode cannot survive a lost app heartbeat")
smartHardware.heat = 95
try smartSession.startSmart(now: start)
for tick in 1...15 {
    smartSession.heartbeat(now: start.addingTimeInterval(Double(tick)))
    smartSession.check(now: start.addingTimeInterval(Double(tick)))
}
expect(smartHardware.manual.isEmpty && smartSession.notice?.contains("持续高温") == true, "persistent high temperature releases to the OS after full cooling attempt")

let stalled = FakeHardware(); stalled.actualOverride = 0
let stalledSession = ControlSession(hardware: stalled, now: start)
try stalledSession.applyPercentage(fan: -1, percent: 75, now: start)
for tick in 1...20 {
    stalledSession.heartbeat(now: start.addingTimeInterval(Double(tick)))
    stalledSession.check(now: start.addingTimeInterval(Double(tick)))
}
expect(stalled.manual.isEmpty && stalledSession.notice?.contains("20 秒") == true, "valid target registers with stalled actual fans trigger convergence timeout")
expect(!SensorCatalog.controlKeys(chip: "Apple M2 Pro").contains("TCHP"), "an unknown TC prefix cannot become a control temperature")
expect(SensorCatalog.describe("TCXX", chip: "Apple M2 Pro").group == "其他", "unmapped TC sensor is display-only")
expect(SensorCatalog.controlKeys(chip: "Apple M2 Pro").contains("TCMz"), "explicit M2 aggregate map is available for control")
let untrusted = SensorReading(key: "TCXX", name: "unknown", group: "CPU", kind: .temperature, value: 120)
expect(!untrusted.isChip, "a display group alone never grants temperature control eligibility")


let scopedSmart = FakeHardware(); scopedSmart.heat = 70
let scopedSmartSession = ControlSession(hardware: scopedSmart, now: start)
try scopedSmartSession.startSmart(now: start)
try scopedSmartSession.requestAutomatic(fan: 0)
expect(scopedSmart.manual[0] == nil && scopedSmartSession.state.fans.first(where: { $0.id == 1 })?.smart == true, "scoped restore preserves the other fan's smart ownership")
scopedSmart.heat = 80
scopedSmartSession.heartbeat(now: start.addingTimeInterval(2)); scopedSmartSession.check(now: start.addingTimeInterval(2))
expect(scopedSmart.manual[0] == nil && scopedSmart.manual[1]! > 3185, "scoped system release is not silently reacquired by the smart loop")
try scopedSmartSession.applyPercentage(fan: -1, percent: 75, now: start.addingTimeInterval(3))
expect(!scopedSmartSession.state.smartEnabled && scopedSmartSession.state.fans.allSatisfy { !$0.smart }, "global manual preset exits smart for all fans")
scopedSmart.heat = 85
scopedSmartSession.heartbeat(now: start.addingTimeInterval(4)); scopedSmartSession.check(now: start.addingTimeInterval(4))
expect(scopedSmart.manual[0] == 3675 && scopedSmart.manual[1] == 3675, "fixed all-fan preset does not keep following the old smart curve")
try scopedSmartSession.restoreAll()


// Profile preferences alter ordinary targets, never emergency or ownership rules.
expect(SmartProfile(rawValue: "unknown") == nil, "unrecognized smart profiles are rejected")
expect(SmartProfile.defaultProfile == .cool, "upgrading preserves the previous cooling preference")
for profile in SmartProfile.allCases {
    let points = profile.curve
    expect(points.first!.percentage >= 26 && points.last!.percentage == 100, "profile endpoints stay within controllable cooling bounds")
    expect(zip(points, points.dropFirst()).allSatisfy { $0.0.temperature < $0.1.temperature && $0.0.percentage <= $0.1.percentage }, "every profile curve is monotonic")
    var policy = SmartFanPolicy(profile: profile)
    let first = try policy.evaluate(temperature: 70, minimumPercentage: 26, now: start)
    expect(first.filteredTemperature == 70 && first.percentage == SmartFanPolicy.curvePercentage(at: 70, profile: profile), "profile initializes from the actual trusted temperature")
    let hot = try policy.evaluate(temperature: 90, minimumPercentage: 26, now: start.addingTimeInterval(1))
    expect(hot.percentage == 100 && hot.emergency, "all profiles immediately request maximum at raw 90 degrees")
}
expect(SmartFanPolicy.curvePercentage(at: 70, profile: .quiet) == 40 && SmartFanPolicy.curvePercentage(at: 70, profile: .balanced) == 52 && SmartFanPolicy.curvePercentage(at: 70, profile: .cool) == 65, "70 degree profile targets are distinct")
expect(SmartFanPolicy.curvePercentage(at: 72.5, profile: .quiet) == 46, "quiet curve interpolates between nodes")
expect((45...90).allSatisfy { temperature in
    let value = Double(temperature)
    return SmartFanPolicy.curvePercentage(at: value, profile: .quiet) <= SmartFanPolicy.curvePercentage(at: value, profile: .balanced)
        && SmartFanPolicy.curvePercentage(at: value, profile: .balanced) <= SmartFanPolicy.curvePercentage(at: value, profile: .cool)
}, "quiet, balanced and cool maintain their intended ordering throughout the curve")
var strategySwitch = SmartFanPolicy()
_ = try strategySwitch.evaluate(temperature: 70, minimumPercentage: 26, now: start)
strategySwitch.setProfile(.quiet, now: start.addingTimeInterval(1))
var switchedDecision: SmartDecision?
for tick in 1...15 { switchedDecision = try strategySwitch.evaluate(temperature: 70, minimumPercentage: 26, now: start.addingTimeInterval(Double(tick))) }
expect(switchedDecision!.percentage == 65, "switching to quiet does not abruptly reduce an active target")
strategySwitch.setProfile(.quiet, now: start.addingTimeInterval(15))
let firstQuietDrop = try strategySwitch.evaluate(temperature: 70, minimumPercentage: 26, now: start.addingTimeInterval(16))
expect(firstQuietDrop.percentage == 62, "a quieter profile starts gradual reduction after 15 seconds even at steady temperature")
let secondQuietDrop = try strategySwitch.evaluate(temperature: 70, minimumPercentage: 26, now: start.addingTimeInterval(17))
expect(secondQuietDrop.percentage == 59, "profile changes retain the three-points-per-second downward limit")
var louderSwitch = SmartFanPolicy(profile: .quiet)
_ = try louderSwitch.evaluate(temperature: 70, minimumPercentage: 26, now: start)
louderSwitch.setProfile(.cool, now: start.addingTimeInterval(1))
let firstCoolRise = try louderSwitch.evaluate(temperature: 70, minimumPercentage: 26, now: start.addingTimeInterval(1))
expect(firstCoolRise.percentage == 50, "switching to cool retains the ordinary upward limit")
var pressureSwitch = SmartFanPolicy()
_ = try pressureSwitch.evaluate(temperature: 70, minimumPercentage: 26, now: start)
pressureSwitch.setProfile(.quiet, now: start.addingTimeInterval(1))
for tick in 1...30 { switchedDecision = try pressureSwitch.evaluate(temperature: 70, minimumPercentage: 26, now: start.addingTimeInterval(Double(tick)), preventDecrease: true, minimumOutput: 65) }
expect(switchedDecision!.percentage == 65, "fair pressure overrides a requested quieter profile")
for tick in 31...44 { switchedDecision = try pressureSwitch.evaluate(temperature: 70, minimumPercentage: 26, now: start.addingTimeInterval(Double(tick))) }
expect(switchedDecision!.percentage == 65, "time under fair pressure does not count toward the quiet transition delay")
let afterFairDrop = try pressureSwitch.evaluate(temperature: 70, minimumPercentage: 26, now: start.addingTimeInterval(45))
expect(afterFairDrop.percentage == 62, "profile transition resumes gradually after normal pressure is stable")
var hotSwitch = SmartFanPolicy()
_ = try hotSwitch.evaluate(temperature: 95, minimumPercentage: 26, now: start)
for tick in 1...14 { _ = try hotSwitch.evaluate(temperature: 95, minimumPercentage: 26, now: start.addingTimeInterval(Double(tick))) }
hotSwitch.setProfile(.quiet, now: start.addingTimeInterval(14))
let hotRelease = try hotSwitch.evaluate(temperature: 95, minimumPercentage: 26, now: start.addingTimeInterval(15))
expect(hotRelease.releaseToSystem, "changing profiles cannot reset the sustained-high-temperature safety timer")

let profileHW = FakeHardware(); profileHW.maxima = [5349,5777]; profileHW.minima = [1350,1458]; profileHW.heat = 70
let profileSession = ControlSession(hardware: profileHW, now: start)
profileSession.updateSmartProfile(.quiet, now: start)
expect(profileHW.writes == 0 && profileSession.controlledFans.isEmpty, "saving a profile never enables an inactive smart session")
try profileSession.startSmart(now: start, profile: .quiet)
expect(profileHW.manual[0] == 2140 && profileHW.manual[1] == 2311 && profileSession.state.smartProfile == .quiet, "helper starts the selected quiet curve for both asymmetric fans")
try profileSession.restoreAll()
try profileSession.startSmart(now: start, profile: .cool)
try profileSession.applyPercentage(fan: 0, percent: 55, now: start.addingTimeInterval(1))
let beforeProfileUpdate = profileHW.writes
profileSession.updateSmartProfile(.quiet, now: start.addingTimeInterval(1))
expect(profileHW.writes == beforeProfileUpdate && profileSession.state.smartProfile == .quiet, "profile changes are queued without an immediate override write")
for tick in 2...24 {
    let now = start.addingTimeInterval(Double(tick)); profileSession.heartbeat(now: now); profileSession.check(now: now)
}
expect(profileHW.manual[0] == 2942 && profileSession.state.fans.first(where: { $0.id == 0 })?.smart == false, "changing a mixed session's profile never alters its manual fan")
expect(profileHW.manual[1]! < 3755 && profileSession.state.fans.first(where: { $0.id == 1 })?.smart == true, "only the existing smart fan transitions to the quieter curve")
try profileSession.requestAutomatic()
expect(profileHW.manual.isEmpty, "system release still clears every fan after profile changes")

let preferenceSuite = "FanCool.CoreChecks." + UUID().uuidString
let preferenceStore = UserDefaults(suiteName: preferenceSuite)!
defer { preferenceStore.removePersistentDomain(forName: preferenceSuite) }
expect(FanPreferences.profile(in: preferenceStore) == .cool, "missing preferences preserve the previous default")
FanPreferences.save(.quiet, in: preferenceStore)
expect(FanPreferences.profile(in: preferenceStore) == .quiet, "profile preference round-trips")
preferenceStore.set("corrupted profile", forKey: FanPreferences.profileKey)
expect(FanPreferences.profile(in: preferenceStore) == .cool, "invalid stored preferences fall back to a supported profile")

// Near-maximum emergency targets must bypass both the deadband and the 2s cadence.
let nearMax = FakeHardware(); nearMax.maxima = [5349, 5777]; nearMax.minima = [1350, 1458]; nearMax.heat = 89.5
let nearSession = ControlSession(hardware: nearMax, now: start)
try nearSession.startSmart(now: start)
expect(nearMax.manual[0] == 5322 && nearMax.manual[1] == 5748, "near-maximum starting targets exercise a sub-100 RPM gap")
nearMax.heat = 90
nearSession.check(now: start.addingTimeInterval(0.25))
expect(nearMax.manual[0] == 5349 && nearMax.manual[1] == 5777, "emergency closes the last small RPM gap immediately")
let maxWrites = nearMax.writes
nearSession.check(now: start.addingTimeInterval(0.5))
expect(nearMax.writes == maxWrites, "already confirmed maximum does not cause a write storm")
let maxOverride = FakeHardware(); maxOverride.heat = 90
let maxOverrideSession = ControlSession(hardware: maxOverride, now: start)
try maxOverrideSession.startSmart(now: start)
maxOverride.forcedReadback = 4895
for tick in 1...4 { maxOverrideSession.check(now: start.addingTimeInterval(Double(tick))) }
expect(maxOverride.manual.isEmpty, "a near-maximum firmware override still has bounded correction attempts")

let pressureHW = FakeHardware(); pressureHW.heat = 80
let pressureSession = ControlSession(hardware: pressureHW, now: start)
try pressureSession.startSmart(now: start)
pressureHW.heat = 60
for tick in 1...30 {
    let now = start.addingTimeInterval(Double(tick)); pressureSession.heartbeat(now: now)
    pressureSession.check(now: now, thermalPressure: .fair)
}
expect(pressureHW.manual[0] == 4165 && pressureSession.state.smartEnabled, "fair pressure holds cooling despite sustained temperature drop")
for tick in 31...50 {
    let now = start.addingTimeInterval(Double(tick)); pressureSession.heartbeat(now: now)
    pressureSession.check(now: now)
}
expect(pressureHW.manual[0]! < 4165, "normal thermal pressure allows gradual cooling reduction again")
try pressureSession.restoreAll()
try pressureSession.applyPercentage(fan: -1, percent: 75, now: start)
let beforePressureReject = pressureHW.writes
rejects("fair pressure rejects a lower fixed manual target") {
    try pressureSession.applyPercentage(fan: -1, percent: 55, now: start, thermalPressure: .fair)
}
expect(pressureHW.writes == beforePressureReject && pressureHW.manual.count == 2, "fair manual rejection leaves both targets intact")
try pressureSession.applyPercentage(fan: -1, percent: 100, now: start, thermalPressure: .fair)
expect(pressureHW.manual[0] == 4900 && pressureHW.manual[1] == 4900, "fair pressure still permits increased cooling")
rejects("serious pressure blocks new manual takeover immediately") {
    try pressureSession.applyPercentage(fan: -1, percent: 100, now: start, thermalPressure: .serious)
}
pressureSession.check(now: start.addingTimeInterval(1), thermalPressure: .unknown)
expect(pressureHW.manual.isEmpty, "unrecognized thermal pressure fails open to the system")
rejects("unknown thermal pressure blocks smart start") { try pressureSession.startSmart(now: start, thermalPressure: .unknown) }
// A decision not yet written at an odd tick cannot permit a lower write on the next fair tick.
pressureHW.heat = 80; try pressureSession.startSmart(now: start); pressureHW.heat = 60
for tick in 1...19 {
    let now = start.addingTimeInterval(Double(tick)); pressureSession.heartbeat(now: now); pressureSession.check(now: now)
}
let floorBeforeFair = pressureHW.manual[0]!
pressureSession.heartbeat(now: start.addingTimeInterval(20))
pressureSession.check(now: start.addingTimeInterval(20), thermalPressure: .fair)
expect(pressureHW.manual[0]! >= floorBeforeFair, "fair floor uses the applied target rather than an unwritten policy output")
try pressureSession.restoreAll()
pressureHW.manual = [0: 4500, 1: 4500]; pressureHW.heat = 55
try pressureSession.startSmart(now: start, thermalPressure: .fair)
expect(pressureHW.manual[0]! >= 4500 && pressureHW.manual[1]! >= 4500, "smart start during fair pressure preserves existing cooling")
try pressureSession.restoreAll()

let admissionHW = FakeHardware(); admissionHW.admission = false
let denied = ControlSession(hardware: admissionHW, now: start)
rejects("unqualified hardware blocks manual writes") { try denied.applyPercentage(fan: -1, percent: 75, now: start) }
rejects("unqualified hardware blocks smart writes") { try denied.startSmart(now: start) }
expect(admissionHW.writes == 0, "admission failures never mutate SMC")
let admissionReadings = dualReadings.map {
    FanReading(id: $0.id, actual: $0.actual, target: 0, minimum: $0.minimum, maximum: $0.maximum, mode: 0)
}
for generation in 1...12 {
    for suffix in ["", " Pro", " Max", " Ultra"] {
        let chip = "Apple M\(generation)\(suffix)"
        expect(ControlAvailability.evaluate(model: "Mac99,1", chip: chip, fans: admissionReadings, formatsValid: true, reportedFanCount: 2).allowed,
            "M-series family is admitted by capabilities without model/generation whitelist: \(chip)")
    }
}
expect(ControlAvailability.evaluate(model: "Mac15,11", chip: "Apple M3 Max", fans: admissionReadings, formatsValid: true, reportedFanCount: 2).allowed,
    "the reported M3 Max model is no longer hard blocked")
for chip in ["Intel Core i9", "Apple A17", "Apple M", "Apple M0", "Apple Mbad"] {
    expect(!ControlAvailability.evaluate(model: "Mac99,1", chip: chip, fans: admissionReadings, formatsValid: true, reportedFanCount: 2).allowed,
        "non-M or malformed processor remains read-only")
}
expect(ControlAvailability.evaluate(model: "Mac99,1", chip: "Apple M4", fans: Array(admissionReadings.prefix(1)), formatsValid: true, reportedFanCount: 1).allowed,
    "a complete single-fan machine is supported")
expect(!ControlAvailability.evaluate(model: "Mac99,1", chip: "Apple M3 Max", fans: Array(admissionReadings.prefix(1)), formatsValid: true, reportedFanCount: 2).allowed,
    "a failed second fan read cannot be mistaken for a single-fan Mac")
for count in [3, 4, 10] {
    let fans = (0..<count).map { FanReading(id: $0, actual: 2000, target: 0, minimum: 1200, maximum: 6000, mode: 3) }
    expect(ControlAvailability.evaluate(model: "Mac99,1", chip: "Apple M4 Ultra", fans: fans, formatsValid: true, reportedFanCount: count).allowed,
        "complete multi-fan discovery is supported")
}
expect(!ControlAvailability.evaluate(model: "Mac99,1", chip: "Apple M4", fans: [], formatsValid: true, reportedFanCount: 0).allowed,
    "fanless devices stay sensor-only")
expect(!ControlAvailability.evaluate(model: "Mac99,1", chip: "Apple M4", fans: admissionReadings, formatsValid: true, reportedFanCount: 11).allowed,
    "unsupported fan address range is rejected")
expect(!ControlAvailability.evaluate(model: "Mac99,1", chip: "Apple M4", fans: [admissionReadings[0], admissionReadings[0]], formatsValid: true, reportedFanCount: 2).allowed,
    "duplicate fan IDs are rejected")
expect(!ControlAvailability.evaluate(model: "Mac99,1", chip: "Apple M4", fans: admissionReadings, formatsValid: false, reportedFanCount: 2).allowed,
    "unknown SMC formats remain read-only across all M chips")
for broken in [
    FanReading(id: 0, actual: .nan, target: 0, minimum: 1200, maximum: 6000, mode: 0),
    FanReading(id: 0, actual: 2000, target: nil, minimum: 1200, maximum: 6000, mode: 0),
    FanReading(id: 0, actual: 2000, target: 0, minimum: 6000, maximum: 1200, mode: 0),
    FanReading(id: 0, actual: 2000, target: 0, minimum: 1200, maximum: 6000, mode: 2)
] {
    expect(!ControlAvailability.evaluate(model: "Mac99,1", chip: "Apple M3", fans: [broken], formatsValid: true, reportedFanCount: 1).allowed,
        "invalid readings and mode block takeover")
}
expect(SMCCodec.supportsFanSpeed(type: "flt ", size: 4), "float RPM metadata is supported")
expect(SMCCodec.supportsFanSpeed(type: "fpe2", size: 2), "fixed-point RPM metadata is supported")
expect(!SMCCodec.supportsFanSpeed(type: "flt ", size: 2), "wrong float width is rejected")
expect(!SMCCodec.supportsFanSpeed(type: "ui16", size: 2), "unrecognized RPM encoding is rejected")
expect(ControlAvailability.appleSiliconGeneration(chip: "Apple M10 Max") == 10, "multi-digit future generations are parsed exactly")
expect(!SensorCatalog.controlKeys(chip: "Apple M10 Max").contains("Tp0T"), "M10 cannot accidentally select the M1 sensor map")

let pendingRecovery = FakeHardware(); pendingRecovery.manual = [0: 3500, 1: 3500]; pendingRecovery.failRead = true
var retainedDirty = Set<Int>()
let retryRecovery = ControlSession(hardware: pendingRecovery, now: start) { retainedDirty = $0 }
retryRecovery.recover([0, 1])
expect(retainedDirty == [0, 1] && retryRecovery.controlledFans == [0, 1], "initial SMC failure never erases dirty recovery ownership")
pendingRecovery.failRead = false
retryRecovery.check(now: start.addingTimeInterval(1))
expect(pendingRecovery.manual.isEmpty && retainedDirty.isEmpty, "recovery retries and clears the journal only after successful release")
let deadlineHW = FakeHardware(); let deadlineSession = ControlSession(hardware: deadlineHW, now: start)
try deadlineSession.applyPercentage(fan: -1, percent: 75, now: start)
deadlineSession.check(now: start.addingTimeInterval(6))
expect(deadlineHW.manual.count == 2, "heartbeat deadline does not fire before six seconds")
deadlineSession.check(now: start.addingTimeInterval(6.01))
expect(deadlineHW.manual.isEmpty, "heartbeat deadline releases after six seconds")

let probe = QueueLivenessGuard(timeout: 10)
expect(probe.step(at: 0) == .probe && probe.step(at: 9) == .none, "liveness checks enqueue only one probe")
expect(probe.step(at: 10) == .stalled, "a blocked control queue has an independent deadline")
probe.completed()
expect(probe.step(at: 20) == .probe, "a completed queue probe resets the deadline")
let faultChild = Process()
faultChild.executableURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
faultChild.arguments = ["--stalled-queue-child"]
try faultChild.run(); faultChild.waitUntilExit()
expect(faultChild.terminationStatus == 75, "independent liveness guard exits an actually blocked child process")

let auditDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("fancool-audit-check-" + UUID().uuidString)
try FileManager.default.createDirectory(at: auditDirectory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
defer { try? FileManager.default.removeItem(at: auditDirectory) }
let auditURL = auditDirectory.appendingPathComponent("writes.jsonl")
let audit = try WriteAudit(url: auditURL, maximumBytes: 4096)
var auditOperations = 0
try audit.perform(fan: 0, restoring: false, key: "F0Tg", value: 4000, targetRPM: 4000, reason: "smart increase") { auditOperations += 1 }
let auditText = try audit.recentText()
let auditRecords = try auditText.split(separator: "\n").map { try JSONDecoder().decode(AuditRecord.self, from: Data($0.utf8)) }
expect(auditOperations == 1 && auditRecords.map(\.phase) == ["intent", "completed"], "every raw write has intent and completion records")
expect(auditRecords[0].id == auditRecords[1].id && auditRecords[0].reason == "smart increase" && auditRecords[1].key == "F0Tg", "write audit correlates reason, raw key and result")
rejects("audit preserves firmware error") {
    try audit.perform(fan: 1, restoring: false, key: "F1Tg", value: 4300, targetRPM: 4300, reason: "test rejection") { throw FanCoolError.hardware("firmware test error") }
}
let failedAuditText = try audit.recentText()
expect(failedAuditText.contains("firmware test error"), "failed writes include their actual error")
for _ in 0..<10 {
    try audit.perform(fan: 1, restoring: false, key: "F1Tg", value: 4300, targetRPM: 4300, reason: String(repeating: "x", count: 500)) {}
}
expect(FileManager.default.fileExists(atPath: auditURL.path + ".previous"), "audit rotates instead of growing without a bound")
let auditSize = (try FileManager.default.attributesOfItem(atPath: auditURL.path)[.size] as! NSNumber).intValue
expect(auditSize < 6000, "bounded audit file allows at most one extra record")
let boundedTail = try audit.recentText(limit: 3000)
expect(boundedTail.utf8.count <= 3000 && boundedTail.split(separator: "\n").allSatisfy { (try? JSONSerialization.jsonObject(with: Data($0.utf8))) != nil }, "export returns bounded complete JSONL records")
let protectedTarget = auditDirectory.appendingPathComponent("must-not-touch")
try Data("sentinel".utf8).write(to: protectedTarget)
let symlinkURL = auditDirectory.appendingPathComponent("symlink.jsonl")
try FileManager.default.createSymbolicLink(at: symlinkURL, withDestinationURL: protectedTarget)
let brokenAudit = try WriteAudit(url: symlinkURL)
var blockedOperation = false
rejects("unsafe audit path prevents new override") {
    try brokenAudit.perform(fan: 0, restoring: false, key: "F0Tg", value: 4000, targetRPM: 4000, reason: "test") { blockedOperation = true }
}
expect(!blockedOperation, "audit failure blocks hardware mutation before it starts")
try brokenAudit.perform(fan: 0, restoring: true, key: "F0md", value: 0, targetRPM: nil, reason: "safety release") { blockedOperation = true }
expect(blockedOperation, "audit failure cannot prevent system-control restoration")
let sentinelText = try String(contentsOf: protectedTarget)
expect(sentinelText == "sentinel", "audit never follows symlinks or edits unrelated files")
rejects("unsafe audit file cannot be exported") { _ = try brokenAudit.recentText() }

let resultFailureURL = auditDirectory.appendingPathComponent("result-failure.jsonl")
let resultFailureAudit = try WriteAudit(url: resultFailureURL)
var resultOperationRan = false
rejects("failure to log a completed override is surfaced for rollback") {
    try resultFailureAudit.perform(fan: 0, restoring: false, key: "F0Tg", value: 4000, targetRPM: 4000, reason: "result failure") {
        resultOperationRan = true
        try FileManager.default.removeItem(at: resultFailureURL)
        try FileManager.default.createSymbolicLink(at: resultFailureURL, withDestinationURL: protectedTarget)
    }
}
expect(resultOperationRan, "completion-log error is distinguished from a pre-write rejection")
let blockedFIFO = auditDirectory.appendingPathComponent("fifo.jsonl")
expect(mkfifo(blockedFIFO.path, 0o600) == 0, "prepare non-regular audit path")
let fifoAudit = try WriteAudit(url: blockedFIFO)
rejects("FIFO audit paths are rejected without blocking") {
    try fifoAudit.perform(fan: 0, restoring: false, key: "F0Tg", value: 4000, targetRPM: 4000, reason: "FIFO safety") {}
}

struct AuditRecord: Decodable { let id: UUID; let phase: String; let reason: String; let key: String }

checks += try runFirmwareControlChecks()
print("PASS: \(checks) checks. No real SMC writes or system-service installation performed.")
