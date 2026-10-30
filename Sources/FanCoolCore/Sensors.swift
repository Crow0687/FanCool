import Foundation
import SMCBridge

public enum SensorKind: String, Codable, CaseIterable, Sendable {
    case temperature = "温度", power = "功率", voltage = "电压", current = "电流"
    public var unit: String {
        switch self { case .temperature: return "°C"; case .power: return "W"; case .voltage: return "V"; case .current: return "A" }
    }
    public func accepts(_ value: Double) -> Bool {
        guard value.isFinite else { return false }
        switch self {
        case .temperature: return value > 0 && value < 130
        case .power: return value >= 0 && value < 2000
        case .voltage: return value >= 0 && value < 100
        case .current: return abs(value) < 1000
        }
    }
}

public struct SensorReading: Identifiable, Codable, Sendable {
    public let key: String
    public let name: String
    public let group: String
    public let kind: SensorKind
    public let value: Double
    public let controlEligible: Bool
    public var id: String { key }
    public var isChip: Bool { kind == .temperature && controlEligible }
    public init(key: String, name: String, group: String, kind: SensorKind, value: Double, controlEligible: Bool = false) {
        self.key = key; self.name = name; self.group = group; self.kind = kind; self.value = value
        self.controlEligible = controlEligible
    }
}

public enum SensorCatalog {
    public static func controlKeys(chip: String) -> Set<String> {
        if ControlAvailability.appleSiliconGeneration(chip: chip) == 2 {
            return Set(["TCMb", "TCMz", "Tp1h", "Tp1t", "Tp1p", "Tp1l", "Tp01", "Tp05", "Tp09", "Tp0D", "Tp0X", "Tp0b", "Tp0f", "Tp0j", "Tg0f", "Tg0j"])
        }
        if ControlAvailability.appleSiliconGeneration(chip: chip) == 1 {
            return Set(["TCMb", "TCMz", "Tp09", "Tp0T", "Tp01", "Tp05", "Tp0D", "Tp0H", "Tp0L", "Tp0P", "Tp0X", "Tp0b", "Tg05", "Tg0D", "Tg0L", "Tg0T"])
        }
        if chip.hasPrefix("Apple") { return ["TCMb", "TCMz"] }
        return ["TC0D", "TC0F", "TC0P", "TCAD", "TG0D", "TG0P", "TCGC"]
    }
    public static func kind(for key: String) -> SensorKind? {
        switch key.first { case "T": return .temperature; case "P": return .power; case "V": return .voltage; case "I": return .current; default: return nil }
    }
    public static func describe(_ key: String, chip: String) -> (name: String, group: String) {
        if key == "TCMz" { return ("CPU 固件最高温", "CPU") }
        if key == "TCMb" { return ("CPU 固件汇总温度", "CPU") }
        if ControlAvailability.appleSiliconGeneration(chip: chip) == 2 {
            let efficiency = ["Tp1h", "Tp1t", "Tp1p", "Tp1l"]
            let performance = ["Tp01", "Tp05", "Tp09", "Tp0D", "Tp0X", "Tp0b", "Tp0f", "Tp0j"]
            if let index = efficiency.firstIndex(of: key) { return ("能效核心 \(index + 1)", "CPU") }
            if let index = performance.firstIndex(of: key) { return ("性能核心 \(index + 1)", "CPU") }
            if let index = ["Tg0f", "Tg0j"].firstIndex(of: key) { return ("GPU 温度 \(index + 1)", "GPU") }
        }
        if controlKeys(chip: chip).contains(key) {
            return key.hasPrefix("Tg") || key.hasPrefix("TG") || key == "TCGC" ? ("已映射 GPU 温度", "GPU") : ("已映射 CPU 温度", "CPU")
        }
        if key.hasPrefix("TB") || key.hasPrefix("Tb") { return ("电池温度传感器", "电池") }
        if key.hasPrefix("TH") { return ("存储温度传感器", "存储") }
        if key.hasPrefix("Tm") { return ("内存/主板温度", "系统") }
        if key.hasPrefix("TA") { return ("环境温度传感器", "系统") }
        if key == "PSTR" { return ("整机输入功率", "系统") }
        if key == "PCPC" { return ("CPU 功率", "CPU") }
        if key == "PG0C" { return ("GPU 功率", "GPU") }
        return ("\(kind(for: key)?.rawValue ?? "SMC")传感器", "其他")
    }
}

public enum FanSpeed {
    public static func percent(rpm: Double, maximum: Double?) -> Double? {
        guard rpm.isFinite, rpm >= 0, let maximum, maximum.isFinite, maximum > 0 else { return nil }
        return min(100, max(0, rpm / maximum * 100))
    }
    public static func minimumPercent(for fans: [FanReading]) -> Double {
        fans.filter(\.controllable).compactMap { fan in
            fan.minimum.flatMap { percent(rpm: $0, maximum: fan.maximum) }
        }.max().map { ceil($0) } ?? 26
    }
    public static func rpm(percent: Double, fan: FanReading) throws -> Double {
        guard fan.controllable, percent.isFinite, percent >= 0, percent <= 100 else { throw FanCoolError.invalidSpeed }
        let requested = (fan.maximum! * percent / 100).rounded()
        guard requested >= fan.minimum! - 1 else { throw FanCoolError.invalidSpeed }
        return min(fan.maximum!, max(fan.minimum!, requested))
    }
}

public enum ControllerConflict {
    public static func current() -> String? {
        var buffer = [CChar](repeating: 0, count: 128)
        return mf_conflicting_controller(&buffer, buffer.count) != 0 ? String(cString: buffer) : nil
    }
}
