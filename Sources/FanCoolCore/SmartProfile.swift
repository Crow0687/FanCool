import Foundation

public enum SmartProfile: String, Codable, CaseIterable, Sendable {
    case balanced, cool, quiet
    public static let defaultProfile: Self = .cool
    public var title: String {
        switch self { case .balanced: return "均衡"; case .cool: return "凉爽"; case .quiet: return "静音" }
    }
    public var symbol: String {
        switch self { case .balanced: return "scale.3d"; case .cool: return "snowflake"; case .quiet: return "speaker.wave.1" }
    }
    public var summary: String {
        switch self {
        case .balanced: return "在日常转速与散热响应之间折中。"
        case .cool: return "更早提高转速，优先增加散热。"
        case .quiet: return "日常保持较低转速，高温时仍主动升速。"
        }
    }
    public var curve: [(temperature: Double, percentage: Double)] {
        switch self {
        case .cool: return [(45,26),(55,40),(65,55),(70,65),(75,75),(80,85),(85,95),(90,100)]
        case .balanced: return [(45,26),(55,30),(65,42),(70,52),(75,65),(80,78),(85,92),(90,100)]
        case .quiet: return [(45,26),(55,26),(65,32),(70,40),(75,52),(80,68),(85,88),(90,100)]
        }
    }
    public var curveSummary: String {
        [70.0, 75, 80, 90].map { "\(Int($0))°C → \(Int(SmartFanPolicy.curvePercentage(at: $0, profile: self)))%" }.joined(separator: "　")
    }
}

public enum FanPreferences {
    public static let profileKey = "FanCool.smartProfile"
    public static func profile(in defaults: UserDefaults) -> SmartProfile {
        defaults.string(forKey: profileKey).flatMap(SmartProfile.init(rawValue:)) ?? .defaultProfile
    }
    public static func save(_ profile: SmartProfile, in defaults: UserDefaults) {
        defaults.set(profile.rawValue, forKey: profileKey)
    }
}
