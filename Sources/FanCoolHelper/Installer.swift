import Foundation
import FanCoolCore
import Darwin

enum Installer {
    static func install(clientHash: String, expectedHelperHash: String, userID: UInt32) throws {
        guard geteuid() == 0, HelperIdentity.currentCodeHash() == expectedHelperHash else {
            throw FanCoolError.hardware("后台服务身份校验失败，未安装。")
        }
        let authorization = try InstalledAuthorization(clientCodeHash: clientHash, helperCodeHash: expectedHelperHash, userID: userID)
        for path in ["/Library/PrivilegedHelperTools", "/Library/LaunchDaemons", HelperIdentity.configurationDirectory] {
            try createProtectedDirectory(path)
        }
        try stopExistingService()
        try recoverPendingControl()
        let files = FileManager.default
        let temporary = "/Library/PrivilegedHelperTools/.fancool-\(UUID().uuidString)"
        defer { try? files.removeItem(atPath: temporary) }
        try files.copyItem(atPath: CommandLine.arguments[0], toPath: temporary)
        try files.setAttributes([.posixPermissions: 0o755, .ownerAccountID: 0, .groupOwnerAccountID: 0], ofItemAtPath: temporary)
        guard HelperIdentity.codeHash(at: URL(fileURLWithPath: temporary)) == expectedHelperHash else {
            throw FanCoolError.hardware("复制后的后台服务签名不一致，未启用。")
        }
        guard rename(temporary, HelperIdentity.executablePath) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        try JSONEncoder().encode(authorization).write(to: URL(fileURLWithPath: HelperIdentity.configurationPath), options: .atomic)
        try files.setAttributes([.posixPermissions: 0o644, .ownerAccountID: 0, .groupOwnerAccountID: 0], ofItemAtPath: HelperIdentity.configurationPath)
        let plist: [String: Any] = [
            "Label": HelperIdentity.service,
            "ProgramArguments": [HelperIdentity.executablePath, "--daemon"],
            "MachServices": [HelperIdentity.service: true],
            "UserName": "root", "ProcessType": "Adaptive", "ExitTimeOut": 20,
            "KeepAlive": ["SuccessfulExit": false], "ThrottleInterval": 3
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: URL(fileURLWithPath: HelperIdentity.launchPlistPath), options: .atomic)
        try files.setAttributes([.posixPermissions: 0o644, .ownerAccountID: 0, .groupOwnerAccountID: 0], ofItemAtPath: HelperIdentity.launchPlistPath)
        try launchctl(["bootstrap", "system", HelperIdentity.launchPlistPath])
        print("FanCool 后台服务已安装并绑定当前 app。")
    }
    static func uninstall() throws {
        guard geteuid() == 0 else { throw FanCoolError.hardware("移除后台服务需要管理员授权。") }
        try stopExistingService()
        try recoverPendingControl()
        for path in [HelperIdentity.launchPlistPath, HelperIdentity.executablePath, HelperIdentity.configurationPath, HelperIdentity.journalPath,
                     HelperIdentity.compatibilityLeasePath, HelperIdentity.auditPath, HelperIdentity.auditPath + ".previous"] {
            if FileManager.default.fileExists(atPath: path) { try FileManager.default.removeItem(atPath: path) }
        }
        _ = rmdir(HelperIdentity.configurationDirectory)
        print("FanCool 后台服务已移除。")
    }
    private static func createProtectedDirectory(_ path: String) throws {
        if !FileManager.default.fileExists(atPath: path) {
            try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o755, .ownerAccountID: 0, .groupOwnerAccountID: 0])
        }
        guard HelperIdentity.isProtectedPath(path, directory: true) else {
            throw FanCoolError.hardware("安装目录权限不安全：\(path)。未继续安装。")
        }
    }
    private static func stopExistingService() throws {
        let status = try launchctl(["print", "system/" + HelperIdentity.service], allowFailure: true)
        if status == 0 { try launchctl(["bootout", "system/" + HelperIdentity.service]) }
    }
    private static func recoverPendingControl() throws {
        let lease = try FirmwareLeaseJournal.load()
        let ids = ControlJournal.load()
        guard lease != nil || !ids.isEmpty else { return }
        let audit = try WriteAudit(url: URL(fileURLWithPath: HelperIdentity.auditPath), owner: 0)
        let hardware = try SMCHardware(audit: audit, compatibilityLease: lease, saveCompatibilityLease: FirmwareLeaseJournal.save)
        let session = ControlSession(hardware: hardware, ownershipChanged: ControlJournal.save)
        session.recover(ids)
        // The global reset can acknowledge asynchronously. Keep the old recovery
        // record and allow it to settle before installing/removing a daemon.
        for _ in 0..<12 where !session.controlledFans.isEmpty || !hardware.recoveryFans.isEmpty {
            usleep(250_000)
            session.check()
        }
        guard session.controlledFans.isEmpty, hardware.recoveryFans.isEmpty else {
            throw FanCoolError.hardware("旧控制会话尚未恢复系统，已保留恢复记录，未继续替换或移除后台。")
        }
    }
    @discardableResult
    private static func launchctl(_ arguments: [String], allowFailure: Bool = false) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = output
        try process.run()
        let errorData = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        if process.terminationStatus != 0 && !allowFailure {
            throw FanCoolError.hardware("后台服务启停失败：\(String(decoding: errorData, as: UTF8.self))")
        }
        return process.terminationStatus
    }
}
