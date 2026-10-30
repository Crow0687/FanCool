// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "FanCool",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "FanCool", targets: ["FanCool"]),
        .executable(name: "FanCoolHelper", targets: ["FanCoolHelper"]),
        .executable(name: "FanCoolChecks", targets: ["FanCoolChecks"])
    ],
    targets: [
        .target(name: "SMCBridge", linkerSettings: [.linkedFramework("IOKit"), .linkedLibrary("proc")]),
        .target(name: "FanCoolCore", dependencies: ["SMCBridge"], linkerSettings: [.linkedFramework("Security")]),
        .executableTarget(name: "FanCool", dependencies: ["FanCoolCore"], linkerSettings: [.linkedFramework("SwiftUI")]),
        .executableTarget(name: "FanCoolHelper", dependencies: ["FanCoolCore"]),
        .executableTarget(name: "FanCoolChecks", dependencies: ["FanCoolCore"], path: "Checks")
    ]
)
