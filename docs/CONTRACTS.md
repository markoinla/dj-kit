# Module contracts

The app is a native SwiftUI macOS app plus three local Swift packages and one Python
project. Each piece is built by a separate worker; these are the seams between them.
Change a contract only by editing this file and saying so.

Common: macOS 14.4 minimum (matches Wax Studio), Swift 6 language mode, Apple Silicon
(arm64) only. Bundle ID `la.marko.djtools`, display name "DJ Tools" (placeholder).
App data lives in `~/Library/Application Support/DJTools/`. Default output folder
`~/Music/DJ Tools/`. No code signing yet (ad-hoc `-` / `CODE_SIGNING_ALLOWED=NO`).

## Packages/QualityKit — bad-file detector (pure Swift: AVFoundation + Accelerate)

```swift
public enum QualityVerdict: String, Sendable, Codable { case lossless, goodLossy, lowQuality, fakeLossless, unknown }
public struct QualityReport: Sendable, Codable, Equatable {
  public var url: URL
  public var container: String          // "mp3", "flac", "wav", "aiff", "m4a", ...
  public var isLosslessContainer: Bool
  public var declaredBitrateKbps: Int?  // from the file, when it has one
  public var sampleRate: Double
  public var channels: Int
  public var duration: TimeInterval
  public var cutoffHz: Double?          // estimated spectral cutoff (where the highs stop)
  public var verdict: QualityVerdict
  public var summary: String            // one line for the UI, e.g. "Cuts off at 16 kHz — likely a 128 kbps MP3"
}
public enum QualityAnalyzer {
  public static func analyze(_ url: URL) async throws -> QualityReport
}
```

## Packages/StemsKit — stem separation (wraps ssmall256/demucs-mlx-swift)

```swift
public enum StemModel: String, Sendable, CaseIterable { case htdemucs, htdemucsFT, htdemucs6s }
public struct StemResult: Sendable { public var stems: [String: URL] }   // "vocals","drums","bass","other"(,"guitar","piano")
public actor StemSeparator {
  public init(model: StemModel = .htdemucs)
  public func separate(input: URL, outputDirectory: URL,
                       progress: @escaping @Sendable (Double) -> Void) async throws -> StemResult
}
```
Writes `<outputDirectory>/<track name> (Stems)/<stem>.wav`. Model weights download on first
use into App Support (`DJTools/models/`), never into the bundle.

## apollo/ + Packages/ApolloBridge — Apollo repair, Python behind a Swift bridge

`apollo/` is a uv project (Python) wrapping https://github.com/JusperLee/Apollo inference,
weights from Hugging Face `JusperLee/Apollo`. Entry point:

```
uv run --project <apollo dir> apollo-repair --input IN --output OUT.wav [--device auto|mps|cpu]
```
stdout is JSON lines, one object per line, nothing else on stdout (logs go to stderr):
`{"event":"status","message":"Loading model"}`, `{"event":"progress","fraction":0.42}`,
`{"event":"done","output":"/path/OUT.wav"}`, `{"event":"error","message":"..."}`. Exit 0 on success.

The app bundles `apollo/` as a resource. `ApolloBridge` (pure Swift, no Python linkage):

```swift
public enum ApolloSetupState: Sendable, Equatable { case notInstalled, installing(String), ready, failed(String) }
public actor ApolloRuntime {
  public init(projectDirectory: URL, supportDirectory: URL)   // supportDirectory = App Support/DJTools
  public func state() async -> ApolloSetupState
  public func install(progress: @escaping @Sendable (String) -> Void) async throws   // uv + python + deps + weights
  public func repair(input: URL, output: URL,
                     progress: @escaping @Sendable (Double) -> Void) async throws -> URL
  public func cancel() async
}
```
`install` downloads `uv` into `supportDirectory/runtime/bin` with the official standalone
installer (no Homebrew, no sudo) and keeps uv's cache, Python and venv under
`supportDirectory/runtime/`.

## app/ — the SwiftUI shell (XcodeGen, `app/project.yml`)

Depends on the three packages by local path. Drop files or folders in; each track gets
actions Check Quality, Separate Stems, Repair (Apollo); a job queue shows progress;
results land in the output folder with Reveal in Finder. Design follows Wax Studio
(`Wax Studio`, see its `WaxMac/DesignSystem`).

## Packages/ApolloMLX — experimental native port of Apollo (MLX Swift)

Same job as the Python bridge, no Python. Built to compare speed and quality against it;
the app may later swap it in behind the same `ApolloRepairing` seam.

```swift
public actor ApolloMLXRepairer {
  public init(modelsDirectory: URL)            // default App Support/DJTools/models/apollo-mlx
  public func prepare(progress: @escaping @Sendable (String) -> Void) async throws   // fetch/convert weights
  public func repair(input: URL, output: URL,
                     progress: @escaping @Sendable (Double) -> Void) async throws -> URL
}
```
