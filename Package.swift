// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Prism",
    platforms: [.macOS("26.0")],
    targets: [
        // Pure algorithms — no UI, no WebKit — so they can be tested on their
        // own and reused by any player pipeline.
        .target(name: "AutoMixCore"),
        .executableTarget(
            name: "Prism",
            dependencies: ["AutoMixCore"],
            path: "Sources/Prism",
            swiftSettings: [.unsafeFlags(["-parse-as-library"])]
        ),
        // A plain executable rather than a .testTarget: `swift test` on macOS
        // needs Xcode's XCTest runner, and this machine's Xcode licence is
        // unaccepted. Run with `swift run AutoMixTests`; exits non-zero on
        // failure, so it drops straight into CI.
        .executableTarget(name: "AutoMixTests", dependencies: ["AutoMixCore"])
    ]
)
