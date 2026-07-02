// swift-tools-version:5.9
import PackageDescription

let package = Package(
  name: "NyaruDB2",
  platforms: [.iOS(.v15), .macOS(.v12)],
  products: [
    .library(name: "NyaruDB2", targets: ["NyaruDB2"])
  ],
  dependencies: [
          .package(url: "https://github.com/nnabeyang/swift-msgpack", from: "1.2.0")
  ],
  targets: [
    .target(
      name: "NyaruDB2",
      dependencies: [
          .product(name: "SwiftMsgpack", package: "swift-msgpack")
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
  ]
)
