// swift-tools-version: 6.0
// Pure Swift bridge to the bundled `apollo/` Python project. No Python linkage: it installs
// uv + Python + deps into App Support and drives `apollo-repair` as a subprocess.
import PackageDescription

let package = Package(
  name: "ApolloBridge",
  platforms: [.macOS("14.4")],
  products: [
    .library(name: "ApolloBridge", targets: ["ApolloBridge"]),
    .executable(name: "apollo-cli-test", targets: ["apollo-cli-test"]),
  ],
  targets: [
    .target(name: "ApolloBridge"),
    .executableTarget(name: "apollo-cli-test", dependencies: ["ApolloBridge"]),
    .testTarget(name: "ApolloBridgeTests", dependencies: ["ApolloBridge"]),
  ],
  swiftLanguageModes: [.v6]
)
