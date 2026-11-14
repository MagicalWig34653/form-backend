// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "fluent-mysql-driver",
    platforms: [
        .macOS(.v10_15),
        .iOS(.v13),
        .watchOS(.v6),
        .tvOS(.v13),
    ],
    products: [
        .library(name: "FluentMySQLDriver", targets: ["FluentMySQLDriver"]),
    ],
    dependencies: [
        .package(url: "https://github.com/vapor/fluent-kit.git", from: "1.52.2"),
        // LOCAL PATCH (form-backend): vendored sibling instead of the remote package (one identity, no SwiftPM conflict).
        .package(path: "../mysql-kit"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.6.4"),
        .package(url: "https://github.com/vapor/async-kit.git", from: "1.21.0"),
    ],
    targets: [
        .target(
            name: "FluentMySQLDriver",
            dependencies: [
                .product(name: "FluentKit", package: "fluent-kit"),
                .product(name: "FluentSQL", package: "fluent-kit"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "MySQLKit", package: "mysql-kit"),
                .product(name: "AsyncKit", package: "async-kit"),
            ],
            swiftSettings: swiftSettings
        ),
        // LOCAL PATCH (form-backend): test target removed, Tests/ are not vendored.
    ]
)

var swiftSettings: [SwiftSetting] { [
    .enableUpcomingFeature("ExistentialAny"),
    .enableUpcomingFeature("MemberImportVisibility"),
    .enableUpcomingFeature("ConciseMagicFile"),
    .enableUpcomingFeature("ForwardTrailingClosures"),
    .enableUpcomingFeature("DisableOutwardActorInference"),
    .enableExperimentalFeature("StrictConcurrency=complete"),
] }
