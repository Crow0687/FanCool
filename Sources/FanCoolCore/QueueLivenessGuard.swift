import Foundation
import Darwin

public enum ControlClock {
    /// Monotonic, including time asleep. Encoded as Date only so injected test
    /// clocks and policy arithmetic can share one type; this is not a wall date.
    public static var now: Date {
        Date(timeIntervalSince1970: Double(clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)) / 1_000_000_000)
    }
}

/// Runs away from the SMC queue. It never attempts concurrent SMC access: on a
/// stuck queue the helper exits abnormally and launchd restarts journal recovery.
public final class QueueLivenessGuard {
    public enum Action { case none, probe, stalled }
    private let lock = NSLock()
    private var pendingSince: TimeInterval?
    private let timeout: TimeInterval
    private var timer: DispatchSourceTimer?
    public init(timeout: TimeInterval = 10) { self.timeout = timeout }
    public func step(at now: TimeInterval) -> Action {
        lock.lock(); defer { lock.unlock() }
        if let since = pendingSince { return now - since >= timeout ? .stalled : .none }
        pendingSince = now; return .probe
    }
    public func completed() { lock.lock(); pendingSince = nil; lock.unlock() }
    public func start(controlQueue: DispatchQueue, interval: Double = 1, onStall: @escaping () -> Void) {
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "local.fancool.helper.liveness"))
        timer.schedule(deadline: .now() + interval, repeating: interval)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            // Awake monotonic time avoids wall-clock changes and sleep false positives.
            let now = Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW)) / 1_000_000_000
            switch self.step(at: now) {
            case .none: break
            case .probe: controlQueue.async { [weak self] in self?.completed() }
            case .stalled: onStall()
            }
        }
        timer.resume(); self.timer = timer
    }
    deinit { timer?.cancel() }
}
