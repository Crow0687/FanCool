import Foundation

/// Some firmware temporarily rejects takeover while its controller changes state.
/// Retry only the observed SMC rejection, never permission, metadata or audit errors.
public enum FanModeTransition {
    public static let maximumAttempts = 6
    public static let retryDelay: TimeInterval = 0.15

    public static func enterManual(key: String, readMode: () throws -> Double,
                                   writeMode: (Int) throws -> Void,
                                   wait: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }) throws {
        for attempt in 1...maximumAttempts {
            if try readMode() == 1 { return }
            do {
                try writeMode(attempt)
                // Successful writes may have delayed readback. ControlSession
                // still verifies mode, target and actual speed on later samples.
                return
            } catch {
                guard case FanCoolError.firmwareWriteRejected(let failedKey, let status) = error,
                      failedKey == key, status == 0x10000082 else { throw error }
                // A reply may be rejected after the mode has already changed.
                if (try? readMode()) == 1 { return }
                guard attempt < maximumAttempts else { throw error }
                wait(retryDelay)
            }
        }
    }
}
