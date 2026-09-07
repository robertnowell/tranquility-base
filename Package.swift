// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TranquilityBase",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "TranquilityCore", targets: ["TranquilityCore"]),
        .executable(name: "tbase", targets: ["tbase"]),
        .executable(name: "tbase-test-target", targets: ["tbase-test-target"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
        // Sparkle arrives as a prebuilt XCFramework binary target, so SwiftPM will
        // NOT embed it in the app bundle the way an Xcode "Embed Frameworks" phase
        // would. scripts/bundle.sh copies it into Contents/Frameworks and signs it.
        .package(url: "https://github.com/sparkle-project/Sparkle.git", from: "2.9.6"),
        // Sentry, for the app target only: Core stays network-free and
        // testable. Through a local wrapper that names just the static
        // XCFramework (see Vendor/SentryStatic/Package.swift for why the
        // upstream package is not used directly); it links into the binary,
        // nothing is copied into the bundle.
        .package(path: "Vendor/SentryStatic"),
        // PostHog, for product events (Track). Source-built; its own
        // automatic capture is switched off in Analytics.swift.
        .package(url: "https://github.com/PostHog/posthog-ios.git", from: "3.71.4"),
    ],
    targets: [
        .target(
            name: "TranquilityCore",
            dependencies: [.product(name: "GRDB", package: "GRDB.swift")]
        ),
        .executableTarget(
            name: "tbase",
            dependencies: ["TranquilityCore"]
        ),
        .executableTarget(name: "tbase-test-target"),
        // ObjC because Swift cannot catch NSExceptions, and AVFoundation throws
        // them. See the header for the incident this exists to prevent.
        .target(name: "ObjCExceptionFirewall"),
        .executableTarget(
            name: "TranquilityApp",
            dependencies: [
                "TranquilityCore",
                "ObjCExceptionFirewall",
                .product(name: "Sparkle", package: "Sparkle"),
                .product(name: "SentryStatic", package: "SentryStatic"),
                .product(name: "PostHog", package: "posthog-ios"),
            ]
        ),
        .testTarget(
            name: "TranquilityCoreTests",
            dependencies: ["TranquilityCore"]
        ),
    ]
)
