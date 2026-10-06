// swift-tools-version: 6.0
// BPM and musical key. Key: vendored libkeyfinder (https://github.com/mixxxdj/libkeyfinder, GPL-3),
// its FFTW calls swapped for vDSP. Tempo: Beat This! (https://github.com/CPJKU/beat_this, MIT),
// weights downloaded on first use into App Support, never bundled.
import PackageDescription

let package = Package(
  name: "AnalysisKit",
  platforms: [.macOS("14.4")],
  products: [
    .library(name: "AnalysisKit", targets: ["AnalysisKit"]),
    .executable(name: "analysis-eval", targets: ["analysis-eval"]),
  ],
  targets: [
    .target(
      name: "CKeyFinder",
      linkerSettings: [.linkedFramework("Accelerate")]),
    .target(name: "AnalysisKit", dependencies: ["CKeyFinder"]),
    .executableTarget(name: "analysis-eval", dependencies: ["AnalysisKit"]),
    .testTarget(name: "AnalysisKitTests", dependencies: ["AnalysisKit"]),
  ],
  swiftLanguageModes: [.v6],
  cxxLanguageStandard: .cxx17
)
