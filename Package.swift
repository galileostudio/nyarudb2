// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "NyaruDB2",
    platforms: [.iOS(.v15), .macOS(.v12)],
    products: [
        .library(
            name: "NyaruDB2",
            targets: ["NyaruDB2"]),
        .executable(name: "QuickStartRunner", targets: ["QuickStartRunner"]),
    ],
    targets: [
        .target(
            name: "NyaruDB2",
            path: "Sources/NyaruDB2",
            linkerSettings: [
                .linkedLibrary("z"),
                .linkedLibrary("compression", .when(platforms: [.macOS]))
            ]
        ),
        .executableTarget(
            name: "Benchmark",
            dependencies: ["NyaruDB2"],
            path: "Sources/Benchmark"
        ),
        .executableTarget(
            name: "QuickStartRunner",
            dependencies: ["NyaruDB2"],
            path: "Sources/QuickStart"
        ),
        .testTarget(
            name: "NyaruDB2Tests",
            dependencies: ["NyaruDB2"],
            path: "Tests/NyaruDB2Tests"
        ),
    ]
)
