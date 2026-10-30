import Foundation
import Security
import Darwin

public enum HelperIdentity {
    // Compatibility identities are immutable: preserve installed authorization,
    // ownership recovery and logs when product / module names change.
    public static let appIdentifier = "local.minifan.app"
    public static let helperIdentifier = "local.minifan.helper"
    public static let service = "local.minifan.helper"
    public static let executablePath = "/Library/PrivilegedHelperTools/local.minifan.helper"
    public static let launchPlistPath = "/Library/LaunchDaemons/local.minifan.helper.plist"
    public static let configurationDirectory = "/Library/Application Support/MiniFan"
    public static let configurationPath = configurationDirectory + "/authorization.json"
    public static let journalPath = configurationDirectory + "/control-state.json"
    public static let compatibilityLeasePath = configurationDirectory + "/fan-control-lease.json"
    public static let auditPath = configurationDirectory + "/smc-writes.jsonl"

    public static func validCodeHash(_ hash: String) -> Bool {
        hash.utf8.count == 40 && hash.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
    public static func requirement(codeHash: String) -> String? {
        guard validCodeHash(codeHash) else { return nil }
        return "cdhash H\"\(codeHash)\""
    }
    public static func currentCodeHash() -> String? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        return codeHash(staticCode)
    }
    public static func codeHash(at url: URL) -> String? {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code,
              SecStaticCodeCheckValidity(code, [], nil) == errSecSuccess else { return nil }
        return codeHash(code)
    }
    private static func codeHash(_ code: SecStaticCode) -> String? {
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let info = information as? [String: Any], let unique = info[kSecCodeInfoUnique as String] as? Data else { return nil }
        let hash = unique.map { String(format: "%02x", $0) }.joined()
        return validCodeHash(hash) ? hash : nil
    }
    public static func isProtectedPath(_ path: String, directory: Bool) -> Bool {
        var info = stat()
        guard lstat(path, &info) == 0, info.st_uid == 0, (info.st_mode & 0o022) == 0 else { return false }
        return (info.st_mode & S_IFMT) == (directory ? S_IFDIR : S_IFREG)
    }
}

public struct InstalledAuthorization: Codable, Equatable {
    public let clientCodeHash: String
    public let helperCodeHash: String
    public let userID: UInt32
    public init(clientCodeHash: String, helperCodeHash: String, userID: UInt32) throws {
        guard HelperIdentity.validCodeHash(clientCodeHash), HelperIdentity.validCodeHash(helperCodeHash), userID > 0 else {
            throw FanCoolError.hardware("后台服务的签名哈希无效。")
        }
        self.clientCodeHash = clientCodeHash; self.helperCodeHash = helperCodeHash; self.userID = userID
    }
    public static func load() -> Self? {
        guard HelperIdentity.isProtectedPath(HelperIdentity.configurationDirectory, directory: true),
              HelperIdentity.isProtectedPath(HelperIdentity.configurationPath, directory: false),
              HelperIdentity.isProtectedPath(HelperIdentity.executablePath, directory: false),
              let data = try? Data(contentsOf: URL(fileURLWithPath: HelperIdentity.configurationPath)),
              let value = try? JSONDecoder().decode(Self.self, from: data),
              HelperIdentity.validCodeHash(value.clientCodeHash), HelperIdentity.validCodeHash(value.helperCodeHash), value.userID > 0 else { return nil }
        return value
    }
}

public enum ShellEscaping {
    public static func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    public static func appleScriptString(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\r", with: "\\r").replacingOccurrences(of: "\n", with: "\\n") + "\""
    }
}

@objc public protocol FanCoolHelperProtocol {
    func ping(reply: @escaping (String?) -> Void)
    func setSpeed(fan: Int, rpm: Double, reply: @escaping (String?) -> Void)
    func setPercentage(fan: Int, percent: Double, reply: @escaping (String?) -> Void)
    func startSmart(profile: String, reply: @escaping (String?) -> Void)
    func updateSmartProfile(profile: String, reply: @escaping (String?) -> Void)
    func controlState(reply: @escaping (String?) -> Void)
    func restoreAutomatic(fan: Int, reply: @escaping (String?) -> Void)
    func releaseControl(reason: String, reply: @escaping (String?) -> Void)
    func heartbeat(reply: @escaping (String?) -> Void)
    func recentWriteLog(reply: @escaping (String?) -> Void)
}
