import Foundation
import CryptoKit
import FanCoolCore

enum AdministratorInstaller {
    static var bundledHelper: URL { Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/FanCoolHelper") }
    static func run(uninstall: Bool = false) async throws {
        let source = bundledHelper
        guard let clientHash = HelperIdentity.currentCodeHash(), let helperHash = HelperIdentity.codeHash(at: source) else {
            throw FanCoolError.hardware("app 或后台服务的本地签名无效，请重新构建。")
        }
        let digest = SHA256.hash(data: try Data(contentsOf: source)).map { String(format: "%02x", $0) }.joined()
        let command = try AdministratorCommand.make(helperSource: source.path, fileSHA256: digest,
            clientHash: clientHash, helperHash: helperHash, userID: getuid(), uninstall: uninstall)
        // The OS owns the password prompt; no password is collected or stored by FanCool.
        let script = "do shell script " + ShellEscaping.appleScriptString(command) + " with administrator privileges"
        try await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", script]
            let pipe = Pipe()
            process.standardOutput = pipe; process.standardError = pipe
            try process.run()
            let output = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let details = String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            if process.terminationStatus != 0 {
                if details.contains("(-128)") { throw CancellationError() }
                throw FanCoolError.hardware("管理员授权或后台服务安装未完成。\n\(details)")
            }
        }.value
    }
}
