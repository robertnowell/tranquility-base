// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "VoiceDispatch",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "VoiceDispatchCore", targets: ["VoiceDispatchCore"]),
        .executable(name: "vdctl", targets: ["vdctl"]),
        .executable(name: "dispatch-test-target", targets: ["dispatch-test-target"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
    ],
    targets: [
        .target(
            name: "VoiceDispatchCore",
            dependencies: [.product(name: "GRDB", package: "GRDB.swift")]
        ),
        .executableTarget(
            name: "vdctl",
            dependencies: ["VoiceDispatchCore"]
        ),
        .executableTarget(name: "dispatch-test-target"),
        // ObjC because Swift cannot catch NSExceptions, and AVFoundation throws
        // them. See the header for the incident this exists to prevent.
        .target(name: "ObjCExceptionFirewall"),
        .executableTarget(
            name: "VoiceDispatchApp",
            dependencies: ["VoiceDispatchCore", "ObjCExceptionFirewall"]
        ),
        .testTarget(
            name: "VoiceDispatchCoreTests",
            dependencies: ["VoiceDispatchCore"]
        ),
    ]
)
