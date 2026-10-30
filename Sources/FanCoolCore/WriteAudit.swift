import Foundation
import Darwin

public struct SMCWriteEvent: Codable {
    public let id: UUID
    public let timestamp: Date
    public let phase: String
    public let fan: Int
    public let action: String
    public let key: String
    public let value: Double
    public let targetRPM: Double?
    public let reason: String
    public let error: String?
    public let context: String?
}

/// A bounded, private JSONL log. The production helper supplies its fixed root-owned
/// directory; tests use a private temporary directory owned by the test user.
public final class WriteAudit {
    private let url: URL
    private let owner: uid_t
    private let maximumBytes: Int
    private let lock = NSLock()
    public init(url: URL, owner: uid_t = getuid(), maximumBytes: Int = 2 * 1024 * 1024) throws {
        self.url = url; self.owner = owner; self.maximumBytes = maximumBytes
        var info = stat()
        guard maximumBytes >= 4096, lstat(url.deletingLastPathComponent().path, &info) == 0,
              info.st_uid == owner, info.st_mode & S_IFMT == S_IFDIR, info.st_mode & 0o022 == 0 else {
            throw FanCoolError.hardware("调速日志目录权限不安全。")
        }
    }
    private func openLog() throws -> Int32 {
        let fd = open(url.path, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK, 0o600)
        guard fd >= 0 else { throw posixError() }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == owner, info.st_mode & S_IFMT == S_IFREG,
              info.st_mode & 0o077 == 0, info.st_nlink == 1 else {
            close(fd); throw FanCoolError.hardware("调速日志文件权限不安全。")
        }
        if info.st_size >= maximumBytes {
            close(fd)
            guard rename(url.path, url.path + ".previous") == 0 else { throw posixError() }
            return try openLog()
        }
        return fd
    }
    private func posixError() -> NSError { NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
    private func append(_ event: SMCWriteEvent) throws {
        lock.lock(); defer { lock.unlock() }
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        var data = try encoder.encode(event); data.append(0x0a)
        let fd = try openLog(); defer { close(fd) }
        try data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let count = Darwin.write(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw posixError() }
                offset += count
            }
        }
    }
    public func perform(fan: Int, restoring: Bool, key: String, value: Double, targetRPM: Double?, reason: String,
                        context: (() -> String?)? = nil, operation: () throws -> Void) throws {
        let id = UUID()
        func record(phase: String, error: String? = nil) throws {
            try append(.init(id: id, timestamp: Date(), phase: phase, fan: fan,
                action: restoring ? "restore-system" : "set-manual", key: key, value: value,
                targetRPM: targetRPM, reason: String(reason.prefix(512)), error: error,
                context: context?().map { String($0.prefix(1024)) }))
        }
        do { try record(phase: "intent") }
        catch {
            // Loss of diagnostics must block new overrides, never block releasing them.
            if !restoring { throw FanCoolError.hardware("无法记录调速日志，未执行新的控制写入：\(error.localizedDescription)") }
            NSLog("FanCool restore audit unavailable: %@", error.localizedDescription)
        }
        do { try operation() }
        catch {
            try? record(phase: "failed", error: error.localizedDescription)
            throw error
        }
        do { try record(phase: "completed") }
        catch {
            if !restoring { throw FanCoolError.hardware("写入已执行，但结果日志失败，正在请求恢复系统控制。") }
            NSLog("FanCool restore result audit unavailable: %@", error.localizedDescription)
        }
    }
    public func recentText(limit: Int = 128 * 1024) throws -> String {
        lock.lock(); defer { lock.unlock() }
        let fd = open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { if errno == ENOENT { return "" }; throw posixError() }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == owner, info.st_mode & S_IFMT == S_IFREG,
              info.st_mode & 0o077 == 0, info.st_nlink == 1 else { throw FanCoolError.hardware("日志权限不安全，未读取。") }
        let size = min(max(0, limit), 128 * 1024)
        let offset = max(0, info.st_size - off_t(size))
        guard lseek(fd, offset, SEEK_SET) >= 0 else { throw posixError() }
        var data = Data(count: size)
        let count = data.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, size) }
        guard count >= 0 else { throw posixError() }
        data.count = count
        if offset > 0, let newline = data.firstIndex(of: 0x0a) { data.removeSubrange(...newline) }
        return String(decoding: data, as: UTF8.self)
    }
}
