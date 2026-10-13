// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Euclid",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/sindresorhus/KeyboardShortcuts", from: "1.10.0"),
        .package(url: "https://github.com/groue/GRDB.swift", from: "7.11.0"),
    ],
    targets: [
        // Pure, UI-free logic (search, clipboard history/store; later calculator/AI). Fast to test.
        .target(
            name: "EuclidCore",
            dependencies: [.product(name: "GRDB", package: "GRDB.swift")],
            path: "Sources/EuclidCore"
        ),
        .executableTarget(
            name: "Euclid",
            dependencies: ["EuclidCore", "KeyboardShortcuts"],
            path: "Sources/Euclid"
        ),
        .testTarget(name: "EuclidCoreTests", dependencies: ["EuclidCore"], path: "Tests/EuclidCoreTests"),
    ]
)
