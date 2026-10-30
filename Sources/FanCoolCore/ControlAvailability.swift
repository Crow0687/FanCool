import Foundation

public struct ControlAvailability: Codable, Sendable {
    public let allowed: Bool
    public let reason: String
    public init(allowed: Bool, reason: String) { self.allowed = allowed; self.reason = reason }

    /// Identify the M-series family without a list of product/model generations.
    public static func appleSiliconGeneration(chip: String) -> Int? {
        let words = chip.split(separator: " ")
        guard words.count >= 2, words[0] == "Apple", words[1].first == "M" else { return nil }
        let digits = words[1].dropFirst()
        guard !digits.isEmpty, digits.utf8.allSatisfy({ (48...57).contains($0) }),
              let generation = Int(digits), generation > 0 else { return nil }
        return generation
    }

    /// Admission describes detected capabilities, not proof that firmware will accept writes.
    public static func evaluate(model: String, chip: String, fans: [FanReading], formatsValid: Bool,
                                reportedFanCount: Int) -> Self {
        guard appleSiliconGeneration(chip: chip) != nil else {
            return .init(allowed: false, reason: "当前处理器 \(chip) 不属于 Apple M 系列，仅提供只读监测。")
        }
        guard reportedFanCount > 0 else {
            return .init(allowed: false, reason: "未检测到可读取的风扇，仅提供传感器监测。")
        }
        guard reportedFanCount <= 10, fans.count == reportedFanCount,
              Set(fans.map(\.id)) == Set(0..<reportedFanCount) else {
            return .init(allowed: false, reason: "风扇识别不完整，暂不开放调速；已读取 \(fans.count) / \(reportedFanCount) 只。")
        }
        guard fans.allSatisfy({ fan in
            fan.controllable && fan.actual.isFinite && (0..<30_000).contains(fan.actual)
                && fan.target.map { $0.isFinite && (0..<30_000).contains($0) } == true
                && [0, 1, 3].contains(fan.mode ?? -1)
        }), formatsValid else {
            return .init(allowed: false, reason: "风扇边界、目标或 SMC 编码暂不受支持，仅提供只读监测。")
        }
        return .init(allowed: true, reason: "Apple M 系列能力检查通过（\(reportedFanCount) 只风扇）；写入仍需固件接受并通过读回确认。")
    }
}
