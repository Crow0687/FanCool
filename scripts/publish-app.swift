import Foundation
import Darwin

// The old executable's vnode, signed pages and resources remain intact even
// when that generation is still running. Never copy over an existing bundle.
let incoming = URL(fileURLWithPath: CommandLine.arguments[1])
let destination = URL(fileURLWithPath: CommandLine.arguments[2])
let backup = URL(fileURLWithPath: CommandLine.arguments[3])
let files = FileManager.default
if files.fileExists(atPath: destination.path) {
    let status = incoming.path.withCString { source in
        destination.path.withCString { target in
            renameatx_np(AT_FDCWD, source, AT_FDCWD, target, UInt32(RENAME_SWAP))
        }
    }
    guard status == 0 else {
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSLocalizedDescriptionKey: "无法安全交换 app；现有 app 保持完整。"])
    }
    // After the atomic swap, incoming now holds the complete previous app.
    try files.moveItem(at: incoming, to: backup)
    print("Preserved previous build: \(backup.path)")
} else {
    try files.moveItem(at: incoming, to: destination)
}
