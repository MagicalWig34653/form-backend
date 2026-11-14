// swift-tools-version: 6.0
// SPDX-License-Identifier: AGPL-3.0-only
import PackageDescription

// FormCrypto and its tests are unchanged from P3-A. The P4-A targets use Swift 5 language mode
// because Vapor 4 / Fluent 4 are not strict-concurrency clean.
let v5: [SwiftSetting] = [.swiftLanguageMode(.v5)]

let package = Package(
    name: "FormBackend",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "FormCrypto", targets: ["FormCrypto"]),
        .executable(name: "App", targets: ["App"]),
    ],
    dependencies: [
        .package(url: "https://github.com/vapor/vapor.git", exact: "4.122.3"),
        .package(url: "https://github.com/vapor/fluent.git", exact: "4.13.0"),
        // Patched copies of fluent-mysql-driver 4.8.0, mysql-kit 4.10.2 and mysql-nio 1.9.2 (TLS required, no payload/SQL
        // logging, handshake timeout). fluent-mysql-driver -> mysql-kit -> mysql-nio are all local path packages (siblings), so every identity has exactly one source.
        // Patches: backend/Vendor/README.md.
        .package(path: "Vendor/fluent-mysql-driver"),
        .package(url: "https://github.com/apple/swift-crypto.git", exact: "3.15.1"),
        // SSH transport for SFTP (ADR 0011); Apache-2.0.
        .package(url: "https://github.com/apple/swift-nio-ssh.git", exact: "0.15.1"),
        // Argon2 reference implementation (PHC winner), CC0-1.0 OR Apache-2.0; pinned by commit.
        .package(url: "https://github.com/P-H-C/phc-winner-argon2.git", revision: "f57e61e19229e23c4445b85494dbf7c07de721cb"),  // master at 2024-08-06; the 20190702 tag has no Package.swift and is not semver
    ],
    targets: [
        // Uses swift-crypto (API-compatible with CryptoKit, builds on Linux); P3-A originally used CryptoKit.
        .target(name: "FormCrypto", dependencies: [.product(name: "Crypto", package: "swift-crypto")]),
        .testTarget(name: "FormCryptoTests", dependencies: ["FormCrypto", .product(name: "Crypto", package: "swift-crypto")], resources: [.copy("Fixtures")]),

        // Configuration, error envelope, PII-free logging helpers. No Vapor/DB dependency.
        .target(name: "FormCore", swiftSettings: v5),
        // Fluent/MySQL wiring, SQL statement splitter, migration runner.
        .target(
            name: "FormPersistence",
            dependencies: [
                "FormCore",
                .product(name: "Fluent", package: "fluent"),
                .product(name: "FluentMySQLDriver", package: "fluent-mysql-driver"),
                .product(name: "Crypto", package: "swift-crypto"),
            ],
            swiftSettings: v5),
        // Routes (/health, /ready), error middleware.
        .target(
            name: "FormHTTP",
            dependencies: [
                "FormCore", "FormPersistence",
                .product(name: "Vapor", package: "vapor"),
            ],
            swiftSettings: v5),
        // v2 ingest endpoint (P5-A): signature check, idempotency, sealed package into stored_objects.
        .target(
            name: "FormIngest",
            dependencies: [
                "FormCore", "FormCrypto", "FormPersistence", "FormMail", "FormWebhooks", "FormStorage", "FormFlow", "FormAuth",
                .product(name: "Fluent", package: "fluent"),
                .product(name: "FluentMySQLDriver", package: "fluent-mysql-driver"),
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "Vapor", package: "vapor"),
            ],
            swiftSettings: v5),
        // Admin authentication core (P5-B1): passkey verification (copy of poc-passkey), sessions, rights.
        .target(
            name: "FormAuth",
            dependencies: [
                "FormCore", "FormPersistence",
                .product(name: "Fluent", package: "fluent"),
                .product(name: "FluentMySQLDriver", package: "fluent-mysql-driver"),
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "_CryptoExtras", package: "swift-crypto"),
                .product(name: "argon2", package: "phc-winner-argon2"),
                .product(name: "Vapor", package: "vapor"),
            ],
            swiftSettings: v5),
        // Outgoing mail: message building, templates, SMTP (NIO) and the legacy mail-proxy transport.
        .target(
            name: "FormMail",
            dependencies: [
                "FormCore", "FormPersistence",
                .product(name: "Fluent", package: "fluent"),
                .product(name: "FluentMySQLDriver", package: "fluent-mysql-driver"),
                .product(name: "Vapor", package: "vapor"),
            ],
            swiftSettings: v5),
        .target(name: "FormFlow", dependencies: ["FormCore", "FormCrypto", "FormPersistence", "FormMail", .product(name: "Fluent", package: "fluent"), .product(name: "FluentMySQLDriver", package: "fluent-mysql-driver"), .product(name: "Crypto", package: "swift-crypto"), .product(name: "Vapor", package: "vapor")], swiftSettings: v5),
        .testTarget(name: "FormFlowTests", dependencies: ["FormFlow", "FormCore", "FormCrypto", "FormPersistence", .product(name: "Crypto", package: "swift-crypto"), .product(name: "Vapor", package: "vapor")], swiftSettings: v5),
        .target(name: "FormWebhooks", dependencies: ["FormCore", "FormPersistence", "FormAuth", "FormMail",
            .product(name: "Crypto", package: "swift-crypto"), .product(name: "Fluent", package: "fluent"),
            .product(name: "Vapor", package: "vapor")], swiftSettings: v5),
        // SDK self-update over FTP/FTPS (ADR 0011).
        .target(
            name: "FormDeploy",
            dependencies: [
                "FormCore", "FormPersistence", "FormMail",
                .product(name: "NIOSSH", package: "swift-nio-ssh"),
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "Fluent", package: "fluent"),
                .product(name: "FluentMySQLDriver", package: "fluent-mysql-driver"),
                .product(name: "Vapor", package: "vapor"),
            ],
            swiftSettings: v5),
        .testTarget(
            name: "FormDeployTests",
            dependencies: ["FormDeploy", "FormCore", "FormMail", "TestSupport", .product(name: "Vapor", package: "vapor")],
            swiftSettings: v5),
        .target(name: "FormStorage", dependencies: ["FormAuth", "FormCore", "FormPersistence", "FormMail", "FormDeploy", .product(name: "Crypto", package: "swift-crypto"), .product(name: "Vapor", package: "vapor")], swiftSettings: v5),
        .testTarget(name: "FormStorageTests", dependencies: ["FormStorage", "FormAuth", "FormCore", "FormPersistence", "TestSupport", .product(name: "XCTVapor", package: "vapor")], swiftSettings: v5),
        // Admin API: forms, drafts, releases (P5-B2). Authenticates through FormAuth, authorizes with PermissionService.
        .target(
            name: "FormAdmin",
            dependencies: [
                "FormCore", "FormPersistence", "FormAuth", "FormCrypto", "FormMail", "FormDeploy", "FormWebhooks", "FormStorage", "FormFlow", "FormMigration",
                .product(name: "Fluent", package: "fluent"),
                .product(name: "FluentMySQLDriver", package: "fluent-mysql-driver"),
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "Vapor", package: "vapor"),
            ],
            swiftSettings: v5),
        .executableTarget(
            name: "App",
            dependencies: ["FormCore", "FormPersistence", "FormHTTP", "FormAuth", "FormAdmin", "FormIngest", "FormMail", "FormDeploy", "FormWebhooks", "FormStorage", "FormMigration", "FormFlow", .product(name: "Vapor", package: "vapor")],
            swiftSettings: v5),

        .target(name: "FormMigration", dependencies: ["FormCore", "FormAuth", "FormCrypto", "FormPersistence", .product(name: "Fluent", package: "fluent"), .product(name: "FluentMySQLDriver", package: "fluent-mysql-driver"), .product(name: "Vapor", package: "vapor"), .product(name: "Crypto", package: "swift-crypto")], swiftSettings: v5),
        .testTarget(name: "FormMigrationTests", dependencies: ["FormAdmin", "FormMail", "FormMigration", "FormCore", "FormAuth", "FormCrypto", "FormPersistence", .product(name: "Crypto", package: "swift-crypto"), .product(name: "Vapor", package: "vapor")], resources: [.copy("Fixtures")], swiftSettings: v5),
        .testTarget(name: "FormCoreTests", dependencies: ["FormCore"], swiftSettings: v5),
        .testTarget(name: "FormPersistenceTests", dependencies: ["FormPersistence", "FormCore", .product(name: "Vapor", package: "vapor")], swiftSettings: v5),
        .testTarget(
            name: "FormIngestTests",
            dependencies: ["FormIngest", "FormAuth", "FormHTTP", "FormCrypto", "FormPersistence", .product(name: "XCTVapor", package: "vapor")],
            swiftSettings: v5),
        .testTarget(
            name: "FormAuthTests",
            dependencies: ["FormAuth", "FormHTTP", "FormPersistence", .product(name: "_CryptoExtras", package: "swift-crypto"), .product(name: "XCTVapor", package: "vapor")],
            resources: [.copy("Fixtures")],
            swiftSettings: v5),
        .testTarget(
            name: "FormAdminTests",
            dependencies: ["FormAdmin", "FormAuth", "FormCore", "FormCrypto", "FormDeploy", "FormHTTP", "FormIngest", "FormMail", "FormPersistence", "FormWebhooks", "FormStorage", "FormFlow", "TestSupport", .product(name: "Crypto", package: "swift-crypto"), .product(name: "XCTVapor", package: "vapor")],
            swiftSettings: v5),
        // Shared test helpers (scriptable fake SMTP server with synthetic TLS material).
        .target(
            name: "TestSupport",
            dependencies: [.product(name: "Vapor", package: "vapor"), .product(name: "NIOSSH", package: "swift-nio-ssh"), .product(name: "Crypto", package: "swift-crypto")],
            path: "Tests/TestSupport",
            exclude: ["Fixtures"],
            swiftSettings: v5),
        .testTarget(
            name: "FormMailTests",
            dependencies: ["FormMail", "FormCore", "FormPersistence", "TestSupport", .product(name: "Vapor", package: "vapor")],
            swiftSettings: v5),
        .testTarget(
            name: "FormHTTPTests",
            dependencies: ["FormHTTP", "FormPersistence", .product(name: "XCTVapor", package: "vapor")],
            swiftSettings: v5),
    ]
)
