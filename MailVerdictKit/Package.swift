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
//
// SwiftSoup is a pure-Swift HTML parser (the reader's document builder needs one, and it targets
// Linux explicitly, which is why it was picked over anything that shells out to libxml2 or a
// system WebKit). swift-crypto is linked on Linux only: it is Apple's CryptoKit API rebuilt for
// platforms that lack it, so `PushEnvelope` uses CryptoKit on iOS and the same calls here.
//
// `PushEnvelope` is its own product because the notification service extension links it and
// nothing else — an extension runs under a small memory budget, and everything in
// `MailVerdictKit` would count against it.

let package = Package(
    name: "MailVerdictKit",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [
        .library(name: "MailVerdictKit", targets: ["MailVerdictKit"]),
        .library(name: "Push", targets: ["Push"]),
        .library(name: "PushEnvelope", targets: ["PushEnvelope"]),
    ],
    dependencies: [
        .package(url: "https://github.com/scinfu/SwiftSoup.git", from: "2.13.9"),
        .package(url: "https://github.com/apple/swift-crypto.git", from: "4.5.2"),
    ],
    targets: [
        .target(name: "MailVerdictKit", dependencies: ["SwiftSoup"]),
        .target(
            name: "PushEnvelope",
            dependencies: [
                .product(name: "Crypto", package: "swift-crypto", condition: .when(platforms: [.linux]))
            ]
        ),
        .target(name: "Push", dependencies: ["MailVerdictKit", "PushEnvelope"]),
        .testTarget(
            name: "PushTests",
            dependencies: ["Push", "PushEnvelope", "MailVerdictKit"],
            // Read off the source tree via `#filePath`, the same as ContractTests' snapshot.
            exclude: ["Fixtures"]
        ),
        .testTarget(
            name: "MailVerdictKitTests",
            dependencies: ["MailVerdictKit"],
            // ContractTests reads these straight off the checked-out source tree via `#filePath`
            // — there is no built product to bundle them into, so SwiftPM's own resource handling
            // would only warn about files it was never meant to copy anywhere.
            exclude: ["Fixtures/api-contract"]
        ),
    ]
)
