import Foundation
import FanCoolCore

@MainActor
final class HelperClient {
    private var connection: NSXPCConnection?
    var isConnected = false
    private let clientHash = HelperIdentity.currentCodeHash()
    private let helperHash = HelperIdentity.codeHash(at: AdministratorInstaller.bundledHelper)
    var supportsControl: Bool { clientHash != nil && helperHash != nil }
    var isInstalled: Bool {
        guard let installed = InstalledAuthorization.load() else { return false }
        return installed.clientCodeHash == clientHash && installed.helperCodeHash == helperHash && installed.userID == getuid()
    }

    func authorize() async throws {
        guard supportsControl else { throw FanCoolError.hardware("app 的本地签名无效，请重新构建后再授权。") }
        if isInstalled {
            do { _ = try await heartbeat(); return }
            catch { disconnect() }
        }
        try await AdministratorInstaller.run()
        disconnect()
        connect()
        _ = try await heartbeat()
    }
    func uninstall() async throws {
        if isInstalled { try await release(reason: "卸载后台服务前释放控制") }
        disconnect()
        try await AdministratorInstaller.run(uninstall: true)
    }
    func connect() {
        guard connection == nil, isInstalled, let helperHash,
              let requirement = HelperIdentity.requirement(codeHash: helperHash) else { return }
        let connection = NSXPCConnection(machServiceName: HelperIdentity.service, options: .privileged)
        connection.setCodeSigningRequirement(requirement)
        connection.remoteObjectInterface = NSXPCInterface(with: FanCoolHelperProtocol.self)
        connection.interruptionHandler = { [weak self, weak connection] in
            Task { @MainActor in if self?.connection === connection { self?.disconnect() } }
        }
        connection.invalidationHandler = { [weak self, weak connection] in
            Task { @MainActor in
                if self?.connection === connection { self?.connection = nil; self?.isConnected = false }
            }
        }
        self.connection = connection
        connection.resume()
    }
    private func request(timeoutSeconds: Double = 5, _ body: @escaping (FanCoolHelperProtocol, @escaping (String?) -> Void) -> Void) async throws -> String? {
        connect()
        guard let connection else { throw FanCoolError.hardware("请先授权 FanCool 后台服务。") }
        // XPC can otherwise wait indefinitely when a launch daemon cannot start.
        return try await withCheckedThrowingContinuation { continuation in
            let reply = OneShotReply(continuation)
            let timeout = DispatchWorkItem {
                reply.fail(FanCoolError.hardware("后台服务响应超时，正在等待控制状态；请检查连接并导出调速日志。"))
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + timeoutSeconds, execute: timeout)
            guard let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
                timeout.cancel(); reply.fail(error)
            }) as? FanCoolHelperProtocol else {
                timeout.cancel(); reply.fail(FanCoolError.unavailable); return
            }
            body(proxy) { message in timeout.cancel(); reply.succeed(message) }
        }
    }
    func heartbeat() async throws -> String? {
        let message = try await request(timeoutSeconds: 12) { $0.heartbeat(reply: $1) }
        isConnected = true
        return message
    }
    func set(fan: Int, rpm: Double) async throws {
        let message = try await request(timeoutSeconds: 12) { $0.setSpeed(fan: fan, rpm: rpm, reply: $1) }
        if let message { throw FanCoolError.hardware(message) }
        isConnected = true
    }
    func restore(fan: Int = -1) async throws {
        let message = try await request { $0.restoreAutomatic(fan: fan, reply: $1) }
        if let message { throw FanCoolError.hardware(message) }
    }
    func set(percentage: Double, fan: Int) async throws {
        let message = try await request(timeoutSeconds: 12) { $0.setPercentage(fan: fan, percent: percentage, reply: $1) }
        if let message { throw FanCoolError.hardware(message) }
        isConnected = true
    }
    func startSmart(profile: SmartProfile) async throws {
        let message = try await request(timeoutSeconds: 12) { $0.startSmart(profile: profile.rawValue, reply: $1) }
        if let message { throw FanCoolError.hardware(message) }
        isConnected = true
    }
    func updateSmartProfile(_ profile: SmartProfile) async throws {
        let message = try await request { $0.updateSmartProfile(profile: profile.rawValue, reply: $1) }
        if let message { throw FanCoolError.hardware(message) }
    }
    func state() async throws -> ControlState {
        guard let json = try await request({ $0.controlState(reply: $1) }), let data = json.data(using: .utf8) else {
            throw FanCoolError.hardware("后台控制状态暂不可用。")
        }
        return try JSONDecoder().decode(ControlState.self, from: data)
    }
    func recentWriteLog() async throws -> String {
        guard let text = try await request({ $0.recentWriteLog(reply: $1) }) else {
            throw FanCoolError.hardware("暂时无法读取调速日志。")
        }
        return text
    }
    func release(reason: String = "释放控制会话") async throws {
        let message = try await request { $0.releaseControl(reason: reason, reply: $1) }
        if let message { throw FanCoolError.hardware(message) }
    }
    func disconnect() {
        let old = connection
        connection = nil; isConnected = false
        old?.invalidationHandler = nil
        old?.interruptionHandler = nil
        old?.invalidate()
    }
}

private final class OneShotReply: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<String?, Error>?
    init(_ continuation: CheckedContinuation<String?, Error>) { self.continuation = continuation }
    func succeed(_ value: String?) { complete(.success(value)) }
    func fail(_ error: Error) { complete(.failure(error)) }
    private func complete(_ result: Result<String?, Error>) {
        lock.lock(); let current = continuation; continuation = nil; lock.unlock()
        current?.resume(with: result)
    }
}
