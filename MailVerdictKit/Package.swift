// swift-tools-version: 6.2
import PackageDescription

// Nearly all of the app lives here rather than in the Xcode project.
//
// A Package.swift is plainly reviewable where a project file is not, it builds and tests on any
// macOS runner without an Apple credential, and it keeps the app target thin — the app holds
// views and wiring, and everything worth testing without an app host lives here.
//
// No target exclusions yet: nothing in this package touches an Apple-only framework. Keep it that
// way — guard anything that does with `#if canImport(…)`, the way `Debug/DebugBridge.swift`
// already guards `Network`, rather than letting an unguarded import drag the whole suite onto a
// metered runner.

let package = Package(
    name: "MailVerdictKit",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [
        .library(name: "MailVerdictKit", targets: ["MailVerdictKit"])
    ],
    targets: [
        .target(name: "MailVerdictKit"),
        .testTarget(name: "MailVerdictKitTests", dependencies: ["MailVerdictKit"]),
    ]
)
