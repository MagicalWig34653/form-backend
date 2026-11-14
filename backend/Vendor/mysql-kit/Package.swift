// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "mysql-kit",
    platforms: [
        .macOS(.v10_15),
        .iOS(.v13),
        .watchOS(.v6),
        .tvOS(.v13),
    ],
    products: [
        .library(name: "MySQLKit", targets: ["MySQLKit"]),
    ],
    dependencies: [
        .package(url: "https://github.com/vapor/async-kit.git", from: "1.20.0"),
        // LOCAL PATCH (form-backend): vendored sibling instead of the remote package (one identity, no SwiftPM conflict).
        .package(path: "../mysql-nio"),
        .package(url: "https://github.com/vapor/sql-kit.git", from: "3.33.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", "2.0.0" ..< "6.0.0"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.82.0"),
        .package(url: "https://github.com/apple/swift-nio-ssl.git", from: "2.30.0"),
    ],
    targets: [
        .target(
            name: "MySQLKit",
            dependencies: [
                .product(name: "AsyncKit", package: "async-kit"),
                .product(name: "MySQLNIO", package: "mysql-nio"),
                .product(name: "SQLKit", package: "sql-kit"),
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "NIOFoundationCompat", package: "swift-nio"),
                .product(name: "NIOSSL", package: "swift-nio-ssl"),
            ],
            swiftSettings: swiftSettings
        ),
        // LOCAL PATCH (form-backend): test target removed, Tests/ are not vendored.
    ]
)

var swiftSettings: [SwiftSetting] { [
    .enableUpcomingFeature("ExistentialAny"),
    .enableUpcomingFeature("ConciseMagicFile"),
    .enableUpcomingFeature("ForwardTrailingClosures"),
    .enableUpcomingFeature("DisableOutwardActorInference"),
    .enableUpcomingFeature("MemberImportVisibility"),
    .enableExperimentalFeature("StrictConcurrency=complete"),
] }
