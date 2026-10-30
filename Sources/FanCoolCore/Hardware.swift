import Foundation
import SMCBridge

public struct FanReading: Identifiable, Sendable {
    public let id: Int
    public let actual: Double
    public let target: Double?
    public let minimum: Double?
    public let maximum: Double?
    public let mode: Int?
    public var percentage: Double? { FanSpeed.percent(rpm: actual, maximum: maximum) }
    public var controllable: Bool {
        guard let minimum, let maximum else { return false }
        return minimum.isFinite && maximum.isFinite && minimum >= 0 && maximum > minimum && maximum < 30_000
    }
    public init(id: Int, actual: Double, target: Double?, minimum: Double?, maximum: Double?, mode: Int?) {
        self.id = id; self.actual = actual; self.target = target
        self.minimum = minimum; self.maximum = maximum; self.mode = mode
    }
}

public struct HardwareSnapshot: Sendable {
    public var fans: [FanReading] = []
    public var reportedFanCount: Int?
    public var temperature: Double?
    public var cpu: Double?
    public var error: String?
    public var sensors: [SensorReading] = []
    public var conflictingController: String?
    public var controlAvailability = ControlAvailability(allowed: false, reason: "正在探测硬件能力。")
    public var thermalPressure = ThermalPressure.unknown
    public var hottestChipSensor: SensorReading? { sensors.filter(\.isChip).max { $0.value < $1.value } }
    public init() {}
    public static var demo: Self {
        var value = Self()
        value.controlAvailability = .init(allowed: true, reason: "演示硬件")
        value.thermalPressure = .nominal
        value.reportedFanCount = 2
        value.fans = [.init(id: 0, actual: 2675, target: 2675, minimum: 1350, maximum: 5349, mode: 0),
                      .init(id: 1, actual: 2889, target: 2889, minimum: 1458, maximum: 5777, mode: 0)]
        value.temperature = 57.7; value.cpu = 34.3
        value.sensors = [.init(key: "Tp01", name: "性能核心 1", group: "CPU", kind: .temperature, value: 57.7, controlEligible: true),
                         .init(key: "Tg0f", name: "GPU 温度 1", group: "GPU", kind: .temperature, value: 51.2, controlEligible: true),
                         .init(key: "TB1T", name: "电池温度", group: "电池", kind: .temperature, value: 32.1),
                         .init(key: "PSTR", name: "整机输入功率", group: "系统", kind: .power, value: 26.4)]
        return value
    }
}

public enum FanCoolError: LocalizedError {
    case hardware(String)
    case firmwareWriteRejected(key: String, status: UInt32)
    case takeoverPending
    case recoveryPending
    case unavailable
    case invalidSpeed
    case temperatureUnavailable
    case tooHot
    case restoreFailed
    public var errorDescription: String? {
        switch self {
        case .hardware(let message): return message
        case .firmwareWriteRejected(let key, let status): return "固件拒绝了 \(key) 写入（0x\(String(status, radix: 16))）。"
        case .takeoverPending: return "正在等待固件交接风扇控制权。"
        case .recoveryPending: return "正在等待固件确认恢复系统控制。"
        case .unavailable: return "这台 Mac 未提供可控制的风扇或完整转速范围。"
        case .invalidSpeed: return "转速必须在当前风扇的硬件范围内。"
        case .temperatureUnavailable: return "暂时无法读取芯片温度，已停止手动调速。"
        case .tooHot: return "当前温度已达手动调速保护阈值，请使用系统自动或智能温控。"
        case .restoreFailed: return "恢复自动模式未获硬件确认，后台服务将继续重试。"
        }
    }
}

public enum SMCCodec {
    public static func supportsFanSpeed(type: String, size: Int) -> Bool {
        switch type.trimmingCharacters(in: .whitespaces) {
        case "flt": return size == 4
        case "fpe2": return size == 2
        default: return false
        }
    }
    public static func fourCC(_ text: String) -> UInt32 {
        text.utf8.prefix(4).reduce(0) { ($0 << 8) | UInt32($1) }
    }
    public static func name(_ code: UInt32) -> String {
        String(bytes: [24, 16, 8, 0].map { UInt8((code >> $0) & 255) }, encoding: .ascii) ?? "????"
    }
    public static func decode(type: String, bytes: [UInt8]) -> Double? {
        switch type.trimmingCharacters(in: .whitespaces) {
        case "flt" where bytes.count >= 4:
            let bits = UInt32(bytes[0]) | UInt32(bytes[1]) << 8 | UInt32(bytes[2]) << 16 | UInt32(bytes[3]) << 24
            let value = Double(Float(bitPattern: bits))
            return value.isFinite ? value : nil
        case "fpe2" where bytes.count >= 2: return Double(UInt16(bytes[0]) << 8 | UInt16(bytes[1])) / 4
        case "sp78" where bytes.count >= 2: return Double(Int16(bitPattern: UInt16(bytes[0]) << 8 | UInt16(bytes[1]))) / 256
        case "ui8" where !bytes.isEmpty: return Double(bytes[0])
        case "ui16" where bytes.count >= 2: return Double(UInt16(bytes[0]) << 8 | UInt16(bytes[1]))
        case "ui32" where bytes.count >= 4:
            return Double(bytes.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) })
        default:
            let code = Array(type)
            guard code.count == 4, bytes.count >= 2, (type.hasPrefix("sp") || type.hasPrefix("fp")),
                  let fraction = Int(String(code[3]), radix: 16) else { return nil }
            let bits = UInt16(bytes[0]) << 8 | UInt16(bytes[1])
            return (type.hasPrefix("sp") ? Double(Int16(bitPattern: bits)) : Double(bits)) / pow(2, Double(fraction))
        }
    }
    public static func encode(_ number: Double, type: String) -> [UInt8]? {
        guard number.isFinite, number >= 0 else { return nil }
        switch type.trimmingCharacters(in: .whitespaces) {
        case "flt":
            guard number <= Double(Float.greatestFiniteMagnitude) else { return nil }
            let bits = Float(number).bitPattern
            return [0, 8, 16, 24].map { UInt8((bits >> $0) & 255) }
        case "fpe2":
            guard number <= 16383.75 else { return nil }
            let bits = UInt16((number * 4).rounded())
            return [UInt8(bits >> 8), UInt8(bits & 255)]
        case "ui8": return number <= 255 ? [UInt8(number)] : nil
        case "ui16":
            guard number <= 65535 else { return nil }
            let bits = UInt16(number)
            return [UInt8(bits >> 8), UInt8(bits & 255)]
        default: return nil
        }
    }
}

public protocol FanHardware: AnyObject {
    func fans() throws -> [FanReading]
    func temperature() -> Double?
    func setManual(fan: Int, rpm: Double) throws
    func restoreAutomatic(fan: Int) throws
    func conflictingController() -> String?
    func controlAvailability() -> ControlAvailability
    func setManual(fan: Int, rpm: Double, reason: String) throws
    func restoreAutomatic(fan: Int, reason: String) throws
    var recoveryFans: Set<Int> { get }
    func prepareControl(ownedFans: Set<Int>) throws
    func prepareRecovery() throws
    func finishControl(remainingFans: Set<Int>) throws
}

public extension FanHardware {
    var recoveryFans: Set<Int> { [] }
    func prepareControl(ownedFans: Set<Int>) throws {}
    func prepareRecovery() throws {}
    func finishControl(remainingFans: Set<Int>) throws {}
    func conflictingController() -> String? { nil }
    func controlAvailability() -> ControlAvailability { .init(allowed: false, reason: "硬件适配器尚未声明调速能力。") }
    func setManual(fan: Int, rpm: Double, reason: String) throws { try setManual(fan: fan, rpm: rpm) }
    func restoreAutomatic(fan: Int, reason: String) throws { try restoreAutomatic(fan: fan) }
}

public final class SMCHardware: FanHardware, FanRegisterAccess {
    private var connection: UInt32 = 0
    private var temperatureKeys: [String]?
    private var sensorKeys: [String]?
    private let chip = Machine.chip
    private let audit: WriteAudit?
    private let initialLease: FirmwareControlLease?
    private let saveLease: ((FirmwareControlLease?) throws -> Void)?
    private lazy var modeController = FirmwareFanControl(registers: self, lease: initialLease, persist: { [unowned self] lease in
        guard let saveLease = self.saveLease else { throw FanCoolError.hardware("缺少兼容恢复记录，未执行全局写入。") }
        try saveLease(lease)
    })
    public var recoveryFans: Set<Int> { modeController.recoveryFans }
    public func prepareControl(ownedFans: Set<Int>) throws { try modeController.prepareControl(ownedFans: ownedFans) }
    public func prepareRecovery() throws { try modeController.prepareRecovery() }
    public func finishControl(remainingFans: Set<Int>) throws { try modeController.finishControl(remainingFans: remainingFans) }
    public init(audit: WriteAudit? = nil, compatibilityLease: FirmwareControlLease? = nil,
                saveCompatibilityLease: ((FirmwareControlLease?) throws -> Void)? = nil) throws {
        self.audit = audit
        initialLease = compatibilityLease; saveLease = saveCompatibilityLease
        let status = mf_smc_open(&connection)
        guard status == 0 else { throw FanCoolError.hardware("无法连接 AppleSMC（0x\(String(status, radix: 16))）。") }
    }
    deinit { mf_smc_close(connection) }
    private func value(_ key: String) throws -> MFSMCValue {
        var value = MFSMCValue()
        let status = mf_smc_read(connection, SMCCodec.fourCC(key), &value)
        guard status == 0 else { throw FanCoolError.hardware("SMC \(key)：0x\(String(status, radix: 16))。") }
        return value
    }
    public func number(_ key: String) throws -> Double {
        var value = try value(key)
        let bytes = withUnsafeBytes(of: &value.bytes) { Array($0.prefix(Int(value.size))) }
        guard let number = SMCCodec.decode(type: SMCCodec.name(value.type), bytes: bytes) else {
            throw FanCoolError.hardware("SMC \(key) 使用了暂不支持的数据格式。")
        }
        return number
    }
    public func isByteRegister(_ key: String) -> Bool {
        guard let raw = try? value(key) else { return false }
        return raw.size == 1 && SMCCodec.name(raw.type).trimmingCharacters(in: .whitespaces) == "ui8"
    }
    public func writeFanRegister(_ key: String, value: Double, fan: Int, restoring: Bool, targetRPM: Double?, reason: String) throws {
        guard key == "Ftst" || key == "F\(fan)Md" || key == "F\(fan)md", value == 0 || value == 1 else {
            throw FanCoolError.hardware("无效的模式接管写入。")
        }
        try write(key, value, fan: fan, restoring: restoring, targetRPM: targetRPM, reason: reason)
    }
    private func write(_ key: String, _ number: Double, fan: Int, restoring: Bool, targetRPM: Double?, reason: String) throws {
        guard let audit else { throw FanCoolError.hardware("只读硬件连接不能执行写入。") }
        try audit.perform(fan: fan, restoring: restoring, key: key, value: number, targetRPM: targetRPM, reason: reason,
            context: { self.writeContext(fan: fan) }) {
        var value = try value(key)
        guard let encoded = SMCCodec.encode(number, type: SMCCodec.name(value.type)), encoded.count == Int(value.size) else {
            throw FanCoolError.hardware("SMC \(key) 不支持写入此数值。")
        }
        withUnsafeMutableBytes(of: &value.bytes) { $0.copyBytes(from: encoded) }
        let status = mf_smc_write(connection, SMCCodec.fourCC(key), &value)
        guard status == 0 else { throw FanCoolError.firmwareWriteRejected(key: key, status: status) }
        }
    }
    private func writeContext(fan: Int) -> String {
        func reading(_ key: String) -> String { (try? number(key)).map { String($0) } ?? "unavailable" }
        let mode = modeKey(fan) ?? "F\(fan)Md"
        return "chip=\(chip); modeKey=\(mode); mode=\(reading(mode)); target=\(reading("F\(fan)Tg")); actual=\(reading("F\(fan)Ac")); Ftst=\(reading("Ftst")); pressure=\(ProcessInfo.processInfo.thermalState.rawValue); conflict=\(ControllerConflict.current() ?? "none")"
    }
    private func modeKey(_ fan: Int) -> String? {
        ["F\(fan)md", "F\(fan)Md"].first { (try? number($0)) != nil }
    }
    public func fanCount() throws -> Int {
        let count = try number("FNum")
        guard count.isFinite, count >= 0, count <= 10, count.rounded(.towardZero) == count else { throw FanCoolError.unavailable }
        return Int(count)
    }
    public func fans() throws -> [FanReading] {
        let count = try fanCount()
        return (0..<count).compactMap { id in
            guard let actual = try? number("F\(id)Ac"), actual >= 0, actual < 30_000 else { return nil }
            let mode = modeKey(id).flatMap { try? number($0) }
                ?? (try? number("FS! ")).map { (Int($0) & (1 << id)) == 0 ? 0.0 : 1.0 }
            return FanReading(id: id, actual: actual, target: try? number("F\(id)Tg"),
                              minimum: try? number("F\(id)Mn"), maximum: try? number("F\(id)Mx"), mode: mode.map(Int.init))
        }
    }
    public func temperature() -> Double? {
        discoverSensors()
        return temperatureKeys?.compactMap { try? number($0) }.filter { $0 > 0 && $0 < 130 }.max()
    }
    private func discoverSensors() {
        guard sensorKeys == nil else { return }
        var keys = Set<String>()
        if let count = try? number("#KEY"), count > 0, count < 20_000 {
            for index in 0..<UInt32(count) {
                var key: UInt32 = 0
                if mf_smc_key_at_index(connection, index, &key) == 0 {
                    let name = SMCCodec.name(key)
                    if SensorCatalog.kind(for: name) != nil { keys.insert(name) }
                }
            }
        }
        sensorKeys = keys.filter { key in
            guard let kind = SensorCatalog.kind(for: key), let raw = try? value(key) else { return false }
            let type = SMCCodec.name(raw.type).trimmingCharacters(in: .whitespaces)
            guard type == "flt" || type.hasPrefix("sp") || type.hasPrefix("fp"), let number = try? number(key) else { return false }
            return kind.accepts(number)
        }.sorted()
        temperatureKeys = sensorKeys?.filter { key in
            SensorCatalog.controlKeys(chip: chip).contains(key)
        }
    }
    public func sensors() -> [SensorReading] {
        discoverSensors()
        return (sensorKeys ?? []).compactMap { key in
            guard let kind = SensorCatalog.kind(for: key), let value = try? number(key), kind.accepts(value) else { return nil }
            let description = SensorCatalog.describe(key, chip: chip)
            return SensorReading(key: key, name: description.name, group: description.group, kind: kind, value: value,
                controlEligible: SensorCatalog.controlKeys(chip: chip).contains(key))
        }
    }
    public func conflictingController() -> String? { ControllerConflict.current() }
    public func controlAvailability() -> ControlAvailability {
        guard let count = try? fanCount() else {
            return .init(allowed: false, reason: "无法可靠识别风扇数量，仅提供只读监测。")
        }
        let readings = (try? fans()) ?? []
        let formatsValid = readings.allSatisfy { fan in
            guard let mode = modeKey(fan.id), let rawMode = try? value(mode),
                  rawMode.size == 1, SMCCodec.name(rawMode.type).trimmingCharacters(in: .whitespaces) == "ui8",
                  let rawTarget = try? value("F\(fan.id)Tg"),
                  SMCCodec.supportsFanSpeed(type: SMCCodec.name(rawTarget.type), size: Int(rawTarget.size)),
                  let maximum = fan.maximum,
                  SMCCodec.encode(maximum, type: SMCCodec.name(rawTarget.type))?.count == Int(rawTarget.size) else { return false }
            return ["Ac", "Mn", "Mx"].allSatisfy { suffix in
                guard let raw = try? value("F\(fan.id)\(suffix)") else { return false }
                return SMCCodec.supportsFanSpeed(type: SMCCodec.name(raw.type), size: Int(raw.size))
            } && [0, 1, 3].contains(fan.mode ?? -1)
        }
        return .evaluate(model: Machine.model, chip: chip, fans: readings, formatsValid: formatsValid, reportedFanCount: count)
    }
    public func setManual(fan: Int, rpm: Double) throws {
        try setManual(fan: fan, rpm: rpm, reason: "固定手动目标")
    }
    public func setManual(fan: Int, rpm: Double, reason: String) throws {
        let availability = controlAvailability()
        guard availability.allowed else { throw FanCoolError.hardware(availability.reason) }
        guard let reading = try fans().first(where: { $0.id == fan }), reading.controllable,
              rpm.isFinite, rpm >= reading.minimum!, rpm <= reading.maximum!, let key = modeKey(fan) else { throw FanCoolError.invalidSpeed }
        try modeController.enterManual(fan: fan, key: key, rpm: rpm, reason: reason)
        // Compatibility acquisition yields for several seconds. Recheck safety
        // before writing a target that was calculated before that wait.
        guard !ThermalPressure.current.requiresSystemControl else { throw FanCoolError.hardware("接管期间系统热压力升高，正在恢复系统控制。") }
        guard let heat = temperature(), heat.isFinite else { throw FanCoolError.temperatureUnavailable }
        guard heat < ControlSession.temperatureLimit || rpm >= reading.maximum! - 1 else { throw FanCoolError.tooHot }
        try write("F\(fan)Tg", rpm, fan: fan, restoring: false, targetRPM: rpm, reason: reason)
        // SMC values can lag behind a successful write. The session verifies on later samples.
    }
    public func restoreAutomatic(fan: Int) throws {
        try restoreAutomatic(fan: fan, reason: "恢复系统自动")
    }
    public func restoreAutomatic(fan: Int, reason: String) throws {
        guard let current = try fans().first(where: { $0.id == fan }) else { throw FanCoolError.restoreFailed }
        if current.mode == 3 { return }
        if current.mode == 0 && (current.target ?? 0) == 0 { return }
        if let key = modeKey(fan) {
            // Mode 0 is already automatic, even if the firmware reports a native
            // minimum target. Rewriting a locked, already-zero mode can fail.
            if current.mode != 0 { try write(key, 0, fan: fan, restoring: true, targetRPM: nil, reason: reason) }
        } else {
            let mask = Int(try number("FS! ")) & ~(1 << fan)
            try write("FS! ", Double(mask), fan: fan, restoring: true, targetRPM: nil, reason: reason)
        }
        #if arch(arm64)
        // Apple Silicon's target is a forced minimum; clear the override on release.
        try write("F\(fan)Tg", 0, fan: fan, restoring: true, targetRPM: nil, reason: reason)
        #endif
        for _ in 0..<15 {
            usleep(80_000)
            if let reading = try fans().first(where: { $0.id == fan }), reading.mode == 0 || reading.mode == 3 { return }
        }
        throw FanCoolError.restoreFailed
    }
}

public actor HardwareMonitor {
    private var hardware: SMCHardware?
    public init() {}
    public func reset() { hardware = nil }
    public func sample() -> HardwareSnapshot {
        var snapshot = HardwareSnapshot()
        snapshot.thermalPressure = .current
        let cpu = mf_cpu_usage()
        snapshot.cpu = cpu >= 0 ? min(100, max(0, cpu)) : nil
        do {
            if hardware == nil { hardware = try SMCHardware() }
            snapshot.reportedFanCount = try hardware!.fanCount()
            snapshot.fans = try hardware!.fans()
            snapshot.controlAvailability = hardware!.controlAvailability()
            snapshot.sensors = hardware!.sensors()
            snapshot.temperature = snapshot.hottestChipSensor?.value
            snapshot.conflictingController = ControllerConflict.current()
        } catch {
            snapshot.error = error.localizedDescription
            hardware = nil
        }
        return snapshot
    }
}

public enum Machine {
    public static var model: String {
        var length = 0
        guard sysctlbyname("hw.model", nil, &length, nil, 0) == 0, length > 0 else { return "未知机型" }
        var buffer = [CChar](repeating: 0, count: length)
        guard sysctlbyname("hw.model", &buffer, &length, nil, 0) == 0 else { return "未知机型" }
        return String(cString: buffer)
    }
    public static var chip: String {
        var length = 0
        guard sysctlbyname("machdep.cpu.brand_string", nil, &length, nil, 0) == 0, length > 0 else { return "当前 Mac" }
        var buffer = [CChar](repeating: 0, count: length)
        guard sysctlbyname("machdep.cpu.brand_string", &buffer, &length, nil, 0) == 0 else { return "当前 Mac" }
        return String(cString: buffer)
    }
}
