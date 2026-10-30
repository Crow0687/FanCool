import Foundation
import FanCoolCore
import Darwin

final class Helper: NSObject, NSXPCListenerDelegate, FanCoolHelperProtocol {
    private let queue = DispatchQueue(label: "local.fancool.helper.control")
    private let session: ControlSession
    private var connection: NSXPCConnection?
    private var timer: DispatchSourceTimer?
    private var termination: DispatchSourceSignal?
    private var terminating = false
    private let authorizedUserID: uid_t
    private let audit: WriteAudit
    private let liveness = QueueLivenessGuard()

    init(hardware: FanHardware, authorizedUserID: uid_t, audit: WriteAudit) {
        session = ControlSession(hardware: hardware, ownershipChanged: ControlJournal.save)
        self.authorizedUserID = authorizedUserID; self.audit = audit; super.init()
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection peer: NSXPCConnection) -> Bool {
        // The listener pins the administrator-approved app's exact CDHash.
        guard connection == nil, peer.effectiveUserIdentifier == authorizedUserID else { return false }
        connection = peer
        peer.exportedInterface = NSXPCInterface(with: FanCoolHelperProtocol.self)
        peer.exportedObject = self
        peer.invalidationHandler = { [weak self, weak peer] in
            guard let self else { return }
            self.queue.async {
                try? self.session.restoreAll(reason: "主程序 XPC 连接已断开")
                DispatchQueue.main.async {
                    if self.connection === peer { self.connection = nil }
                }
            }
        }
        peer.resume()
        return true
    }
    func ping(reply: @escaping (String?) -> Void) { queue.async { reply(self.session.notice) } }
    func heartbeat(reply: @escaping (String?) -> Void) {
        queue.async { self.session.heartbeat(); reply(self.session.notice) }
    }
    func setSpeed(fan: Int, rpm: Double, reply: @escaping (String?) -> Void) {
        queue.async {
            do {
                try self.session.apply(fan: fan, rpm: rpm, thermalPressure: .current)
                reply(nil)
            } catch { reply(error.localizedDescription) }
        }
    }
    func restoreAutomatic(fan: Int, reply: @escaping (String?) -> Void) {
        queue.async {
            do { try self.session.requestAutomatic(fan: fan); reply(nil) }
            catch FanCoolError.recoveryPending { reply(nil) }
            catch { reply(error.localizedDescription) }
        }
    }
    func releaseControl(reason: String, reply: @escaping (String?) -> Void) {
        queue.async {
            let allowed = ["主程序正常退出", "系统即将睡眠", "唤醒后重新确认硬件", "卸载后台服务前释放控制", "释放控制会话"]
            let description = allowed.contains(reason) ? reason : "释放控制会话"
            do { try self.session.restoreAll(reason: description); reply(nil) }
            catch FanCoolError.recoveryPending { reply(nil) }
            catch { reply(error.localizedDescription) }
        }
    }
    func setPercentage(fan: Int, percent: Double, reply: @escaping (String?) -> Void) {
        queue.async {
            do { try self.session.applyPercentage(fan: fan, percent: percent, thermalPressure: .current); reply(nil) }
            catch { reply(error.localizedDescription) }
        }
    }
    func startSmart(profile: String, reply: @escaping (String?) -> Void) {
        queue.async {
            do {
                guard let selected = SmartProfile(rawValue: profile) else { throw FanCoolError.hardware("不支持的智能策略。") }
                try self.session.startSmart(thermalPressure: .current, profile: selected)
                reply(nil)
            } catch { reply(error.localizedDescription) }
        }
    }
    func updateSmartProfile(profile: String, reply: @escaping (String?) -> Void) {
        queue.async {
            guard let selected = SmartProfile(rawValue: profile) else { reply("不支持的智能策略。"); return }
            self.session.updateSmartProfile(selected)
            reply(nil)
        }
    }
    func controlState(reply: @escaping (String?) -> Void) {
        queue.async {
            do { reply(String(decoding: try JSONEncoder().encode(self.session.state), as: UTF8.self)) }
            catch { reply(nil) }
        }
    }
    func recentWriteLog(reply: @escaping (String?) -> Void) {
        queue.async { reply(try? self.audit.recentText()) }
    }
    func startWatchdog() {
        liveness.start(controlQueue: queue) {
            // A failed exit is intentional: KeepAlive restarts the helper. Do not
            // clear ownership or call SMC here while its original call may be stuck.
            _exit(75)
        }
        queue.async { self.session.recover(ControlJournal.load()) }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.session.check(thermalPressure: .current)
            if self.terminating && self.session.controlledFans.isEmpty { exit(0) }
        }
        timer.resume(); self.timer = timer
        signal(SIGTERM, SIG_IGN)
        let termination = DispatchSource.makeSignalSource(signal: SIGTERM, queue: queue)
        termination.setEventHandler { [weak self] in
            guard let self else { return }
            self.terminating = true
            try? self.session.restoreAll(reason: "后台服务收到终止请求")
            if self.session.controlledFans.isEmpty { exit(0) }
        }
        termination.resume(); self.termination = termination
    }
}

enum ControlJournal {
    static func load() -> Set<Int> {
        guard HelperIdentity.isProtectedPath(HelperIdentity.journalPath, directory: false),
              let data = try? Data(contentsOf: URL(fileURLWithPath: HelperIdentity.journalPath)),
              let ids = try? JSONDecoder().decode([Int].self, from: data) else { return [] }
        return Set(ids.filter { (0..<10).contains($0) })
    }
    static func save(_ ids: Set<Int>) throws {
        try JSONEncoder().encode(ids.sorted()).write(to: URL(fileURLWithPath: HelperIdentity.journalPath), options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: HelperIdentity.journalPath)
    }
}

enum FirmwareLeaseJournal {
    static func load() throws -> FirmwareControlLease? {
        var info = stat()
        if lstat(HelperIdentity.compatibilityLeasePath, &info) != 0 {
            if errno == ENOENT { return nil }
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        guard HelperIdentity.isProtectedPath(HelperIdentity.configurationDirectory, directory: true),
              HelperIdentity.isProtectedPath(HelperIdentity.compatibilityLeasePath, directory: false),
              info.st_mode & 0o077 == 0, info.st_nlink == 1 else {
            throw FanCoolError.hardware("兼容控制恢复记录权限不安全。")
        }
        let lease = try JSONDecoder().decode(FirmwareControlLease.self,
            from: Data(contentsOf: URL(fileURLWithPath: HelperIdentity.compatibilityLeasePath)))
        guard lease.isValid else { throw FanCoolError.hardware("兼容控制恢复记录无效，未清除。") }
        return lease
    }
    static func save(_ lease: FirmwareControlLease?) throws {
        guard HelperIdentity.isProtectedPath(HelperIdentity.configurationDirectory, directory: true) else {
            throw FanCoolError.hardware("兼容控制恢复目录权限不安全。")
        }
        _ = try load()
        if let lease {
            guard lease.isValid else { throw FanCoolError.restoreFailed }
            try JSONEncoder().encode(lease).write(to: URL(fileURLWithPath: HelperIdentity.compatibilityLeasePath), options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: HelperIdentity.compatibilityLeasePath)
            let fd = open(HelperIdentity.compatibilityLeasePath, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
            guard fd >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
            defer { close(fd) }
            guard fsync(fd) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        } else if unlink(HelperIdentity.compatibilityLeasePath) != 0 && errno != ENOENT {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        let directory = open(HelperIdentity.configurationDirectory, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard directory >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        defer { close(directory) }
        guard fsync(directory) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
    }
}

do {
    guard geteuid() == 0 else { throw FanCoolError.hardware("后台服务需要通过 FanCool 的管理员授权安装。") }
    if CommandLine.arguments.contains("--install") {
        func argument(_ name: String) throws -> String {
            guard let index = CommandLine.arguments.firstIndex(of: name), CommandLine.arguments.count > index + 1 else {
                throw FanCoolError.hardware("安装参数缺失。")
            }
            return CommandLine.arguments[index + 1]
        }
        guard let userID = UInt32(try argument("--client-uid")) else { throw FanCoolError.hardware("安装用户无效。") }
        try Installer.install(clientHash: argument("--client-hash"), expectedHelperHash: argument("--helper-hash"), userID: userID)
        exit(0)
    }
    if CommandLine.arguments.contains("--uninstall") { try Installer.uninstall(); exit(0) }
    guard CommandLine.arguments.contains("--daemon"), let authorization = InstalledAuthorization.load(),
          authorization.helperCodeHash == HelperIdentity.currentCodeHash(),
          let requirement = HelperIdentity.requirement(codeHash: authorization.clientCodeHash) else {
        throw FanCoolError.hardware("后台服务尚未授权，或 app 已更新，请在 FanCool 中重新授权。")
    }
    let audit = try WriteAudit(url: URL(fileURLWithPath: HelperIdentity.auditPath), owner: 0)
    let hardware = try SMCHardware(audit: audit, compatibilityLease: FirmwareLeaseJournal.load(), saveCompatibilityLease: FirmwareLeaseJournal.save)
    let helper = Helper(hardware: hardware, authorizedUserID: authorization.userID, audit: audit)
    let listener = NSXPCListener(machServiceName: HelperIdentity.service)
    listener.setConnectionCodeSigningRequirement(requirement)
    listener.delegate = helper
    helper.startWatchdog()
    listener.resume()
    withExtendedLifetime(helper) { RunLoop.main.run() }
} catch {
    fputs("\(error.localizedDescription)\n", stderr)
    exit(1)
}
