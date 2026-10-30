import Foundation

public enum ThermalPressure: String, Codable, Sendable {
    case nominal, fair, serious, critical, unknown
    public var requiresSystemControl: Bool { self == .serious || self == .critical || self == .unknown }
    public var preventsDecrease: Bool { self != .nominal }
    public var title: String {
        switch self {
        case .nominal: return "正常"
        case .fair: return "轻度升高"
        case .serious: return "较高"
        case .critical: return "严重"
        case .unknown: return "未知"
        }
    }
    public static var current: Self {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: return .nominal
        case .fair: return .fair
        case .serious: return .serious
        case .critical: return .critical
        @unknown default: return .unknown
        }
    }
}
