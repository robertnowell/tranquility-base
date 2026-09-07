// swift-tools-version:5.9
import PackageDescription

// A one-target wrapper around Sentry's static XCFramework.
//
// The upstream package declares seven binary targets (static, dynamic,
// arm64e variants, Objective-C variants), and SwiftPM fetches every binary
// artifact a package declares whether or not a product uses it: measured
// 6 Sep 2026, a first resolve pulled about 3 GB and stalled for twenty
// minutes on this Mac. The app links exactly one of them. So this package
// names that one (the same URL and checksum the upstream manifest names for
// 9.27.0) and nothing else, and a resolve costs 72 MB.
//
// `SentryCppHelper` mirrors upstream: an empty Swift target whose only job
// is a linker setting, because a static framework with C++ inside needs
// libc++ on the link line and a binary target cannot ask for it.
//
// To upgrade: bump the version in the URL and paste the new checksum from
// upstream's Package.swift for that tag. Both are in one place.
let package = Package(
    name: "SentryStatic",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "SentryStatic", targets: ["Sentry", "SentryCppHelper"]),
    ],
    targets: [
        .binaryTarget(
            name: "Sentry",
            url: "https://github.com/getsentry/sentry-cocoa/releases/download/9.27.0/Sentry.xcframework.zip",
            checksum: "7bc6d6666db31423a18e44b9e612ac600f919928f0e7f72ac5f5804882a82ab5"
        ),
        .target(
            name: "SentryCppHelper",
            path: "Sources/SentryCppHelper",
            linkerSettings: [.linkedLibrary("c++")]
        ),
    ]
)
