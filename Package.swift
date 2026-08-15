// swift-tools-version:5.9
//
// remote-shortcuts — Apple-native webhook server for macOS.
//
// SUPPLY-CHAIN POLICY: this package has ZERO third-party dependencies and must
// stay that way. The `dependencies:` array below is intentionally empty, and CI
// (`make audit`) fails the build if it ever stops being empty or if a
// Package.resolved with external pins appears. Everything we link against ships
// signed inside the macOS SDK.

import PackageDescription

let package = Package(
    name: "remote-shortcuts",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "remote-shortcuts", targets: ["remote-shortcuts"]),
        .library(name: "RemoteShortcutsCore", targets: ["RemoteShortcutsCore"]),
    ],
    dependencies: [
        // INTENTIONALLY EMPTY. See SECURITY.md ("Supply-chain posture").
    ],
    targets: [
        // No custom swiftSettings on purpose: an installer that fails on a
        // benign compiler warning is worse than the warning.
        .target(
            name: "RemoteShortcutsCore",
            path: "Sources/RemoteShortcutsCore"
        ),
        .executableTarget(
            name: "remote-shortcuts",
            dependencies: ["RemoteShortcutsCore"],
            path: "Sources/remote-shortcuts"
        ),
        .testTarget(
            name: "RemoteShortcutsCoreTests",
            dependencies: ["RemoteShortcutsCore"],
            path: "Tests/RemoteShortcutsCoreTests"
        ),
    ]
)
