// swift-tools-version:5.9
//
// Sfere iOS SDK. The manifest sits at the repository root because Swift Package Manager only
// resolves packages whose Package.swift is at the root of the git repository; the sources live
// under ios/ so the Android SDK can share this repository.

import PackageDescription

let package = Package(
    name: "SfereAnalytics",
    platforms: [
        .iOS(.v15),
        // macOS is listed so `swift test` runs the unit tests on a Mac host.
        .macOS(.v12),
    ],
    products: [
        .library(name: "SfereAnalytics", targets: ["SfereAnalytics"]),
    ],
    dependencies: [
        .package(url: "https://github.com/segmentio/analytics-swift.git", .upToNextMinor(from: "1.10.1")),
    ],
    targets: [
        .target(
            name: "SfereAnalytics",
            dependencies: [
                .product(name: "Segment", package: "analytics-swift"),
            ],
            path: "ios/Sources/SfereAnalytics",
            resources: [
                .process("PrivacyInfo.xcprivacy"),
            ]
        ),
        .testTarget(
            name: "SfereAnalyticsTests",
            dependencies: ["SfereAnalytics"],
            path: "ios/Tests/SfereAnalyticsTests"
        ),
    ]
)
