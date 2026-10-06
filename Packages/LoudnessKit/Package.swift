// swift-tools-version: 6.0
// ITU-R BS.1770-4 / EBU R128 loudness (integrated, LRA, sample and true peak)
// and a pure-gain normalization plan. Pure Swift: AVFoundation + Accelerate.
import PackageDescription

let package = Package(
    name: "LoudnessKit",
    platforms: [.macOS("14.4")],
    products: [
        .library(name: "LoudnessKit", targets: ["LoudnessKit"]),
        .executable(name: "loudness", targets: ["loudness"]),
    ],
    targets: [
        .target(name: "LoudnessKit"),
        .executableTarget(name: "loudness", dependencies: ["LoudnessKit"]),
        .testTarget(name: "LoudnessKitTests", dependencies: ["LoudnessKit"]),
    ],
    swiftLanguageModes: [.v6]
)
