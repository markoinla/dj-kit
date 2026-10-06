// swift-tools-version: 6.0
// Building requires a Swift 6.3+ toolchain (Xcode 27): demucs-mlx-swift declares tools 6.3.
// Build with xcodebuild, not `swift build` — MLX's Metal shaders are compiled by Xcode's build system.
import PackageDescription

let package = Package(
  name: "StemsKit",
  platforms: [.macOS("14.4")],
  products: [
    .library(name: "StemsKit", targets: ["StemsKit"]),
    .executable(name: "stemsplit", targets: ["stemsplit"]),
  ],
  dependencies: [
    .package(url: "https://github.com/ssmall256/demucs-mlx-swift", .upToNextMinor(from: "0.1.0")),
    .package(url: "https://github.com/ml-explore/mlx-swift", .upToNextMinor(from: "0.32.3")),
  ],
  targets: [
    .target(
      name: "StemsKit",
      dependencies: [
        .product(name: "DemucsMLX", package: "demucs-mlx-swift"),
        .product(name: "DemucsAudio", package: "demucs-mlx-swift"),
        .product(name: "MLX", package: "mlx-swift"),
      ]),
    .executableTarget(name: "stemsplit", dependencies: ["StemsKit"]),
    .testTarget(name: "StemsKitTests", dependencies: ["StemsKit"]),
  ],
  swiftLanguageModes: [.v6]
)
