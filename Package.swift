// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "M7Control",
    platforms: [.macOS(.v14)],
    targets: [
        // Pure logic with no AppKit: request building, reply parsing, key decoding.
        .target(name: "M7Core"),
        // Objective-C shim over Apple's private Night Shift client.
        .target(
            name: "NightShiftBridge",
            linkerSettings: [.linkedFramework("Foundation")]
        ),
        .executableTarget(
            name: "M7Control",
            dependencies: ["M7Core", "NightShiftBridge"]
        ),
        .testTarget(name: "M7CoreTests", dependencies: ["M7Core"]),
    ],
    swiftLanguageModes: [.v5]
)
