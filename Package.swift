// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "euclid-bar",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "euclid-bar", targets: ["euclid-bar"]),
        // The search engine on its own: no dependencies, embeddable in any Swift app or CLI.
        .library(name: "EuclidSearch", targets: ["EuclidSearch"]),
    ],
    dependencies: [
        .package(url: "https://github.com/sindresorhus/KeyboardShortcuts", from: "1.10.0"),
        .package(url: "https://github.com/groue/GRDB.swift", from: "7.11.0"),
        .package(url: "https://github.com/dduan/TOMLDecoder", from: "0.4.5"),
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.10.0"),
    ],
    targets: [
        // Fuzzy matching and ranking. Depends on nothing but Foundation; EuclidCore re-exports it.
        .target(name: "EuclidSearch", path: "Sources/EuclidSearch"),
        // Pure, UI-free logic (search, clipboard history/store; later calculator/AI). Fast to test.
        .target(
            name: "EuclidCore",
            dependencies: [
                "EuclidSearch",
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "TOMLDecoder", package: "TOMLDecoder"),
            ],
            path: "Sources/EuclidCore"
        ),
        .executableTarget(
            name: "euclid-bar",
            dependencies: ["EuclidCore", "KeyboardShortcuts", .product(name: "Sparkle", package: "Sparkle")],
            path: "Sources/EuclidBar"
        ),
        .testTarget(name: "EuclidSearchTests", dependencies: ["EuclidSearch"], path: "Tests/EuclidSearchTests"),
        .testTarget(name: "EuclidCoreTests", dependencies: ["EuclidCore"], path: "Tests/EuclidCoreTests"),
    ]
)
