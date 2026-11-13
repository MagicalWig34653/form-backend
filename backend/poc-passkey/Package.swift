// swift-tools-version: 6.0
// SPDX-License-Identifier: AGPL-3.0-only
// Standalone P3-C proof of concept. Deliberately NOT part of backend/Package.swift.
import PackageDescription

let package = Package(
    name: "PasskeyPoC",
    platforms: [.macOS(.v13)],
    products: [.library(name: "PasskeyPoC", targets: ["PasskeyPoC"])],
    dependencies: [
        // Apache-2.0. Same range that swift-server/webauthn-swift declares.
        .package(url: "https://github.com/apple/swift-crypto.git", "3.8.1" ..< "6.0.0")
    ],
    targets: [
        .target(
            name: "PasskeyPoC",
            dependencies: [
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "_CryptoExtras", package: "swift-crypto"),
            ]
        ),
        .testTarget(
            name: "PasskeyPoCTests",
            dependencies: ["PasskeyPoC"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
