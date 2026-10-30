import Foundation

public enum AdministratorCommand {
    /// Fixed installation entry points only. Paths are quoted, hashes are strictly hex.
    public static func make(helperSource: String, fileSHA256: String, clientHash: String,
                            helperHash: String, userID: UInt32, uninstall: Bool = false) throws -> String {
        guard fileSHA256.utf8.count == 64,
              fileSHA256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              HelperIdentity.validCodeHash(clientHash), HelperIdentity.validCodeHash(helperHash), userID > 0 else {
            throw FanCoolError.hardware("安装包身份校验失败。")
        }
        let operation = uninstall ? "--uninstall" : "--install --client-hash \(clientHash) --helper-hash \(helperHash) --client-uid \(userID)"
        return """
        set -eu
        fancool_stage=$(/usr/bin/mktemp -d /private/tmp/fancool-authorize.XXXXXX)
        trap '/bin/rm -rf -- "$fancool_stage"' EXIT
        /usr/bin/install -m 700 \(ShellEscaping.quote(helperSource)) "$fancool_stage/FanCoolHelper"
        fancool_digest=$(/usr/bin/shasum -a 256 "$fancool_stage/FanCoolHelper")
        if [ "${fancool_digest%% *}" != '\(fileSHA256)' ]; then
            /usr/bin/printf '%s\\n' 'FanCool 安装文件校验失败，未执行安装。' >&2
            exit 77
        fi
        "$fancool_stage/FanCoolHelper" \(operation)
        """
    }
}
