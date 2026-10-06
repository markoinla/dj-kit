// swift-tools-version: 6.0
// Native MLX port of Apollo (https://github.com/JusperLee/Apollo, CC BY-SA 4.0).
// Building requires a Swift 6.3+ toolchain (Xcode 27): mlx-swift 0.32 declares tools 6.3.
// Build with xcodebuild, not `swift build` — MLX's Metal shaders are compiled by Xcode's build system.
import PackageDescription

let package = Package(
  name: "ApolloMLX",
  platforms: [.macOS("14.4")],
  products: [
    .library(name: "ApolloMLX", targets: ["ApolloMLX"]),
    .executable(name: "apollo-mlx", targets: ["apollo-mlx"]),
  ],
  dependencies: [
    // Same pin as demucs-mlx-swift (via StemsKit) so the app links one mlx-swift.
    .package(url: "https://github.com/ml-explore/mlx-swift", .upToNextMinor(from: "0.32.3"))
  ],
  targets: [
    .target(
      name: "ApolloMLX",
      dependencies: [.product(name: "MLX", package: "mlx-swift")]),
    .executableTarget(name: "apollo-mlx", dependencies: ["ApolloMLX"]),
    .testTarget(name: "ApolloMLXTests", dependencies: ["ApolloMLX"]),
  ],
  swiftLanguageModes: [.v6]
)
