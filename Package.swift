// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Euclid",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/sindresorhus/KeyboardShortcuts", from: "1.10.0"),
    ],
    targets: [
        // Pure, UI-free logic (search, later calculator/AI). Fast to test.
        .target(name: "EuclidCore", path: "Sources/EuclidCore"),
        .executableTarget(
            name: "Euclid",
            dependencies: ["EuclidCore", "KeyboardShortcuts"],
            path: "Sources/Euclid"
        ),
        .testTarget(name: "EuclidCoreTests", dependencies: ["EuclidCore"], path: "Tests/EuclidCoreTests"),
    ]
)
