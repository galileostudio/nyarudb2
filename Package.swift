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
    dependencies: [
        .package(url: "https://github.com/a2/MessagePack.swift.git", from: "4.0.0")
    ],
    targets: [
        .target(
            name: "NyaruDB2",
            dependencies: [
                .product(name: "MessagePack", package: "MessagePack.swift")
            ],
            path: "Sources/NyaruDB2",
            swiftSettings: [
                .unsafeFlags(["-warnings-as-errors"]),
                .define("IOS15_8_OR_LATER")
            ],
            linkerSettings: [
                .linkedLibrary("z"),
                .linkedFramework("Compression", .when(platforms: [.iOS]))
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
