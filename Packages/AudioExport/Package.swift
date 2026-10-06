// swift-tools-version: 6.0
// Converts a finished WAV (StemsKit's stems, Apollo's repair) to the file type the
// user picked: AIFF, WAV, FLAC (Core Audio) or MP3 (vendored LAME 3.100, LGPL).
import PackageDescription

let package = Package(
  name: "AudioExport",
  platforms: [.macOS("14.4")],
  products: [
    .library(name: "AudioExport", targets: ["AudioExport"]),
  ],
  targets: [
    // libmp3lame, encoder only. See Sources/CLAME/README.md.
    .target(
      name: "CLAME",
      exclude: ["COPYING", "LICENSE", "README.md"],
      cSettings: [
        .define("HAVE_CONFIG_H"),
        .headerSearchPath("."),
        .headerSearchPath("libmp3lame"),
      ]),
    .target(name: "AudioExport", dependencies: ["CLAME"]),
    .testTarget(name: "AudioExportTests", dependencies: ["AudioExport"]),
  ],
  swiftLanguageModes: [.v6]
)
