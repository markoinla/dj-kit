// swift-tools-version: 6.0
// BPM and musical key. Key: vendored libkeyfinder (https://github.com/mixxxdj/libkeyfinder, GPL-3),
// its FFTW calls swapped for vDSP. Tempo: Beat This! (https://github.com/CPJKU/beat_this, MIT),
// weights downloaded on first use into App Support, never bundled; the network runs on MLX, so
// build and test with xcodebuild (it compiles MLX's Metal shaders), not `swift build`.
import PackageDescription

let package = Package(
  name: "AnalysisKit",
  platforms: [.macOS("14.4")],
  products: [
    .library(name: "AnalysisKit", targets: ["AnalysisKit"]),
    .executable(name: "analysis-eval", targets: ["analysis-eval"]),
  ],
  dependencies: [
    // Same pin as ApolloMLX / StemsKit so the app links one mlx-swift.
    .package(url: "https://github.com/ml-explore/mlx-swift", .upToNextMinor(from: "0.32.3")),
    // analysis-eval only: folder mode reads the files' own BPM / key / genre tags.
    .package(path: "../AudioExport"),
  ],
  targets: [
    .target(
      name: "CKeyFinder",
      linkerSettings: [.linkedFramework("Accelerate")]),
    .target(
      name: "AnalysisKit",
      dependencies: ["CKeyFinder", .product(name: "MLX", package: "mlx-swift")]),
    .executableTarget(
      name: "analysis-eval",
      dependencies: ["AnalysisKit", .product(name: "AudioExport", package: "AudioExport")]),
    .testTarget(name: "AnalysisKitTests", dependencies: ["AnalysisKit"]),
  ],
  swiftLanguageModes: [.v6],
  cxxLanguageStandard: .cxx17
)
