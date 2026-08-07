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
            dependencies: ["TranquilityCore", "ObjCExceptionFirewall"]
        ),
        .testTarget(
            name: "TranquilityCoreTests",
            dependencies: ["TranquilityCore"]
        ),
    ]
)
