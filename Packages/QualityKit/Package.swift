// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "QualityKit",
    platforms: [.macOS("14.4")],
    products: [
        .library(name: "QualityKit", targets: ["QualityKit"]),
        .executable(name: "qualitycheck", targets: ["qualitycheck"]),
    ],
    targets: [
        .target(name: "QualityKit"),
        .executableTarget(name: "qualitycheck", dependencies: ["QualityKit"]),
        .testTarget(name: "QualityKitTests", dependencies: ["QualityKit"]),
    ],
    swiftLanguageModes: [.v6]
)
