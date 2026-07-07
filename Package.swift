// swift-tools-version:5.9
import PackageDescription

let package = Package(
  name: "NyaruDB2",
  platforms: [.iOS(.v15), .macOS(.v13)],
  products: [
    .library(name: "NyaruDB2", targets: ["NyaruDB2"])
  ],
  dependencies: [
    .package(url: "https://github.com/galileostd/swift-msgpack", from: "1.3.0"),
    .package(url: "https://github.com/apple/swift-crypto", from: "4.5.0"),
    .package(url: "https://github.com/apple/swift-log", from: "1.14.0"),
  ],
  targets: [
    .target(
      name: "NyaruDB2",
      dependencies: [
        .product(name: "SwiftMsgpack", package: "swift-msgpack"),
        .product(name: "Crypto", package: "swift-crypto"),
        .product(name: "Logging", package: "swift-log"),
      ],
      path: "Sources/NyaruDB2",
      linkerSettings: [
        .linkedLibrary("z"),
        .linkedLibrary("compression", .when(platforms: [.macOS])),
      ]
    ),
    .testTarget(
      name: "NyaruDB2Tests",
      dependencies: ["NyaruDB2"],
      path: "Tests/NyaruDB2Tests"
    ),
    .executableTarget(
      name: "NyaruDB2Benchmark",
      dependencies: ["NyaruDB2"],
      path: "Sources/Benchmark",
      linkerSettings: [
        .linkedLibrary("z"),
        .linkedLibrary("compression", .when(platforms: [.macOS])),
      ]
    ),
  ]
)
