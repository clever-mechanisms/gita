// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Gita",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Gita", targets: ["GitaApp"]),
        .executable(name: "gita-agent", targets: ["GitaAgentHelper"]),
    ],
    dependencies: [
        // Ungated in-app updates (GitaUI / GitaApp only): https://getgita.app/appcast.xml.
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.10.1")
    ],
    targets: [
        // Git, provider and agent services. Foundation only.
        .target(name: "GitaCore"),
        // AppKit windows, views and controllers.
        .target(
            name: "GitaUI",
            dependencies: [
                "GitaCore",
                .product(name: "Sparkle", package: "Sparkle"),
            ]
        ),
        // Entry points.
        .executableTarget(
            name: "GitaApp",
            dependencies: ["GitaUI"],
            linkerSettings: [
                // Sparkle.framework ships in Contents/Frameworks.
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])
            ]
        ),
        .executableTarget(name: "GitaAgentHelper", dependencies: ["GitaCore"]),
        .testTarget(name: "GitaCoreTests", dependencies: ["GitaCore"]),
        .testTarget(name: "GitaUITests", dependencies: ["GitaUI", "GitaCore"]),
    ]
)
