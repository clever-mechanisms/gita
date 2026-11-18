// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Gita",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Gita", targets: ["GitaApp"]),
        .executable(name: "gita-agent", targets: ["GitaAgentHelper"]),
    ],
    targets: [
        // Git, provider and agent services. Foundation only.
        .target(name: "GitaCore"),
        // AppKit windows, views and controllers.
        .target(name: "GitaUI", dependencies: ["GitaCore"]),
        // Entry points.
        .executableTarget(name: "GitaApp", dependencies: ["GitaUI"]),
        .executableTarget(name: "GitaAgentHelper", dependencies: ["GitaCore"]),
        .testTarget(name: "GitaCoreTests", dependencies: ["GitaCore"]),
        .testTarget(name: "GitaUITests", dependencies: ["GitaUI", "GitaCore"]),
    ]
)
