// swift-tools-version: 6.0
import PackageDescription

// Developer tool for scripts/quality.sh; not part of the app. Kept in its own package so the app has no dependencies.
let package = Package(
    name: "QualityMetrics",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "quality-metrics", targets: ["QualityMetrics"])],
    dependencies: [.package(url: "https://github.com/swiftlang/swift-syntax.git", from: "602.0.0")],
    targets: [
        .target(
            name: "QualityMetricsCore",
            dependencies: [
                .product(name: "SwiftSyntax", package: "swift-syntax"),
                .product(name: "SwiftParser", package: "swift-syntax"),
                .product(name: "SwiftOperators", package: "swift-syntax"),
            ]
        ),
        .executableTarget(name: "QualityMetrics", dependencies: ["QualityMetricsCore"]),
        .testTarget(name: "QualityMetricsCoreTests", dependencies: ["QualityMetricsCore"]),
    ]
)
