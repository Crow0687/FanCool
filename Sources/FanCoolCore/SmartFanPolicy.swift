import Foundation

public struct SmartDecision: Sendable {
    public let percentage: Double
    public let filteredTemperature: Double
    public let reason: String
    public let emergency: Bool
    public let releaseToSystem: Bool
}

/// Experimental comfort policy; percentages are shares of each fan's maximum RPM.
/// This policy does not replace firmware thermal protection.
public struct SmartFanPolicy {
    public static var curve: [(temperature: Double, percentage: Double)] { SmartProfile.cool.curve }
    public private(set) var profile: SmartProfile
    private var profileChangedAt: Date?
    private var filtered: Double?
    private var lastSample: Date?
    private var lastOutput: Double?
    private var descentSince: Date?
    private var descentReference: Double?
    private var veryHotSince: Date?
    private var history: [(Date, Double)] = []
    private var rapidRiseSamples = 0
    public init(profile: SmartProfile = .defaultProfile) { self.profile = profile }
    public mutating func setProfile(_ profile: SmartProfile, now: Date) {
        guard self.profile != profile else { return }
        self.profile = profile; profileChangedAt = now; descentSince = nil
        // Preserve EMA, last output, rate history and the sustained-hot timer.
    }

    public static func curvePercentage(at temperature: Double, profile: SmartProfile = .defaultProfile) -> Double {
        let curve = profile.curve
        guard temperature.isFinite else { return 100 }
        if temperature <= curve[0].temperature { return curve[0].percentage }
        for index in 1..<curve.count {
            let lower = curve[index - 1], upper = curve[index]
            if temperature <= upper.temperature {
                let position = (temperature - lower.temperature) / (upper.temperature - lower.temperature)
                return lower.percentage + position * (upper.percentage - lower.percentage)
            }
        }
        return 100
    }
    public mutating func evaluate(temperature: Double, minimumPercentage: Double, now: Date,
                                 preventDecrease: Bool = false, minimumOutput: Double? = nil) throws -> SmartDecision {
        guard temperature.isFinite, temperature > 0, temperature < 130,
              minimumPercentage.isFinite, (0...100).contains(minimumPercentage) else { throw FanCoolError.temperatureUnavailable }
        let elapsed = lastSample.map { now.timeIntervalSince($0) } ?? 0
        // A stale sample or a clock discontinuity must not produce a new control target.
        guard lastSample == nil || (elapsed > 0 && elapsed <= 5) else {
            throw FanCoolError.hardware("智能温控采样时间异常，已请求恢复系统控制。")
        }
        let previous = filtered ?? temperature
        let alpha = lastSample == nil ? 1 : 1 - pow(0.8, elapsed)
        filtered = previous + alpha * (temperature - previous)
        lastSample = now
        let smooth = filtered!
        history.append((now, smooth))
        history.removeAll { now.timeIntervalSince($0.0) > 5 }
        if let first = history.first, now.timeIntervalSince(first.0) >= 2 {
            let rate = (smooth - first.1) / now.timeIntervalSince(first.0)
            rapidRiseSamples = rate > 1.5 ? rapidRiseSamples + 1 : 0
        }
        if temperature >= 95 { if veryHotSince == nil { veryHotSince = now } }
        else { veryHotSince = nil }
        if let veryHotSince, now.timeIntervalSince(veryHotSince) >= 15 {
            return .init(percentage: 100, filteredTemperature: smooth,
                reason: "持续高温，已请求交回 macOS 散热管理", emergency: true, releaseToSystem: true)
        }
        // Emergency decisions use the raw trusted temperature, never the delayed EMA.
        if temperature >= 90 {
            profileChangedAt = nil
            lastOutput = 100; descentSince = nil; descentReference = max(smooth, temperature)
            return .init(percentage: 100, filteredTemperature: smooth,
                reason: "原始控制温度达到 90°C，临时全速散热", emergency: true, releaseToSystem: false)
        }
        let boost = rapidRiseSamples >= 2 ? 10.0 : 0.0
        let desired = min(100, max(minimumPercentage, Self.curvePercentage(at: smooth, profile: profile) + boost))
        let old = lastOutput ?? desired
        var output = desired
        var reason = boost > 0 ? "温升较快，临时提前升速" : "按平滑温度曲线调节"
        if desired < old {
            if descentReference == nil { descentReference = previous }
            if let changedAt = profileChangedAt {
                if descentSince == nil { descentSince = changedAt }
            } else if smooth <= descentReference! - 3 {
                if descentSince == nil { descentSince = now }
            } else { descentSince = nil }
            if let descentSince, now.timeIntervalSince(descentSince) >= 15 {
                output = max(desired, old - 3 * elapsed)
                reason = "温度稳定回落，缓慢降速"
            } else { output = old; reason = profileChangedAt == nil ? "等待降温稳定 15 秒，暂不降速" : "策略已更新，等待 15 秒后平缓降速" }
        } else {
            profileChangedAt = nil
            descentSince = nil; descentReference = smooth
            output = min(desired, old + 10 * elapsed)
            if lastOutput == nil { output = desired }
        }
        output = min(100, max(minimumPercentage, output))
        if preventDecrease {
            output = min(100, max(output, old, minimumOutput ?? old))
            descentSince = nil
            if profileChangedAt != nil { profileChangedAt = now }
            if output > desired { reason = "系统热压力升高，暂停降速" }
        }
        if output <= desired { profileChangedAt = nil }
        lastOutput = output
        return .init(percentage: output, filteredTemperature: smooth, reason: reason,
            emergency: false, releaseToSystem: false)
    }
}
