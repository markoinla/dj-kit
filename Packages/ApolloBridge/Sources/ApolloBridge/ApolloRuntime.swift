import CryptoKit
import Foundation

public enum ApolloSetupState: Sendable, Equatable {
  case notInstalled, installing(String), ready, failed(String)
}

/// Inference device passed to `apollo-repair --device`. `.auto` picks MPS when available.
public enum ApolloDevice: String, Sendable, CaseIterable { case auto, mps, cpu }

public enum ApolloError: LocalizedError, Sendable, Equatable {
  case notInstalled
  case busy
  case downloadFailed(String)
  case checksumMismatch(expected: String, actual: String)
  case installFailed(step: String, message: String)
  case repairFailed(String)

  public var errorDescription: String? {
    switch self {
    case .notInstalled: "Apollo isn't installed yet."
    case .busy: "Apollo is already running a job."
    case .downloadFailed(let m): "Download failed: \(m)"
    case .checksumMismatch(let e, let a): "Downloaded uv failed its checksum (expected \(e), got \(a))."
    case .installFailed(let step, let m): "\(step) failed: \(m)"
    case .repairFailed(let m): m
    }
  }
}

/// Owns the Python runtime behind Apollo repair: uv, a uv-managed CPython, the project's
/// venv and the Hugging Face weight cache, all under `supportDirectory/runtime/`. The
/// bundled `projectDirectory` (the `apollo/` uv project) is only ever read.
public actor ApolloRuntime {
  /// uv release fetched by `install()`; checksum from the release's `.sha256` asset.
  static let uvVersion = "0.12.23"
  static let uvArchiveSHA256 = "50487ae565ccd96e499056b4674d438f4c53170202617b4c759defe0c6a1b544"
  static var uvURL: URL {
    URL(string: "https://github.com/astral-sh/uv/releases/download/\(uvVersion)/uv-aarch64-apple-darwin.tar.gz")!
  }

  public nonisolated let projectDirectory: URL
  public nonisolated let supportDirectory: URL

  private var transient: ApolloSetupState?
  private var current: LineProcess?
  private var cancelRequested = false
  private var device: ApolloDevice = .auto

  public init(projectDirectory: URL, supportDirectory: URL) {
    self.projectDirectory = projectDirectory.standardizedFileURL
    self.supportDirectory = supportDirectory.standardizedFileURL
  }

  // MARK: Layout

  nonisolated var runtimeDirectory: URL { supportDirectory.appending(path: "runtime", directoryHint: .isDirectory) }
  nonisolated var uvExecutable: URL { runtimeDirectory.appending(path: "bin/uv") }
  nonisolated var venvDirectory: URL { runtimeDirectory.appending(path: "venv", directoryHint: .isDirectory) }
  nonisolated var repairExecutable: URL { venvDirectory.appending(path: "bin/apollo-repair") }
  nonisolated var markerFile: URL { runtimeDirectory.appending(path: "installed.json") }

  nonisolated var environment: [String: String] {
    let inherited = ProcessInfo.processInfo.environment
    var env: [String: String] = [
      "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
      "LANG": "en_US.UTF-8",
      "UV_CACHE_DIR": runtimeDirectory.appending(path: "uv-cache").path,
      "UV_PYTHON_INSTALL_DIR": runtimeDirectory.appending(path: "python").path,
      "UV_PYTHON_BIN_DIR": runtimeDirectory.appending(path: "python-bin").path,
      "UV_PROJECT_ENVIRONMENT": venvDirectory.path,
      "UV_PYTHON_PREFERENCE": "only-managed",
      "UV_NO_CONFIG": "1",
      "HF_HOME": runtimeDirectory.appending(path: "huggingface").path,
      "HF_HUB_DISABLE_TELEMETRY": "1",
      "PYTHONNOUSERSITE": "1",
      "PYTHONUNBUFFERED": "1",
      "PYTORCH_ENABLE_MPS_FALLBACK": "1",
    ]
    for key in ["HOME", "TMPDIR", "USER", "LOGNAME"] { env[key] = inherited[key] }
    return env
  }

  // MARK: State

  public func state() async -> ApolloSetupState {
    if let transient { return transient }
    return isInstalled() ? .ready : .notInstalled
  }

  public func setDevice(_ device: ApolloDevice) { self.device = device }

  /// Ready means the marker matches the current bundled project, so an app update that
  /// changes `apollo/` (deps or code) reports `.notInstalled` until `install()` re-syncs.
  func isInstalled() -> Bool {
    guard FileManager.default.isExecutableFile(atPath: repairExecutable.path),
      let data = try? Data(contentsOf: markerFile),
      let marker = try? JSONDecoder().decode(Marker.self, from: data)
    else { return false }
    return marker.fingerprint == (try? projectFingerprint())
  }

  struct Marker: Codable {
    var fingerprint: String
    var uvVersion: String
    var installedAt: Date
  }

  func writeMarker() throws {
    let marker = Marker(fingerprint: try projectFingerprint(), uvVersion: Self.uvVersion, installedAt: Date())
    try FileManager.default.createDirectory(at: runtimeDirectory, withIntermediateDirectories: true)
    try JSONEncoder().encode(marker).write(to: markerFile, options: .atomic)
  }

  /// SHA-256 over the project's lock, metadata and sources.
  nonisolated func projectFingerprint() throws -> String {
    let fm = FileManager.default
    var files = ["pyproject.toml", "uv.lock", ".python-version"]
    let src = projectDirectory.appending(path: "src")
    if let e = fm.enumerator(at: src, includingPropertiesForKeys: [.isRegularFileKey]) {
      for case let url as URL in e {
        let rel = String(url.standardizedFileURL.path.dropFirst(projectDirectory.path.count + 1))
        if rel.contains("__pycache__") || url.lastPathComponent == ".DS_Store" { continue }
        if (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true { files.append(rel) }
      }
    }
    var hasher = SHA256()
    for rel in files.sorted() {
      let url = projectDirectory.appending(path: rel)
      guard let data = try? Data(contentsOf: url) else {
        if rel == "pyproject.toml" || rel == "uv.lock" {
          throw ApolloError.installFailed(step: "Reading the Apollo project", message: "missing \(url.path)")
        }
        continue
      }
      hasher.update(data: Data(rel.utf8))
      hasher.update(data: Data([0]))
      hasher.update(data: data)
    }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
  }

  // MARK: Install

  /// Downloads uv, then `uv sync` installs a managed CPython and the locked deps into
  /// `runtime/venv`, then the model weights are fetched into `runtime/huggingface`.
  /// About 650 MB of downloads on a fresh Mac; safe to re-run.
  public func install(progress: @escaping @Sendable (String) -> Void) async throws {
    if case .installing = transient { throw ApolloError.busy }
    guard current == nil else { throw ApolloError.busy }
    cancelRequested = false
    let report: @Sendable (String) -> Void = progress
    func step(_ message: String) {
      transient = .installing(message)
      report(message)
    }
    do {
      try FileManager.default.createDirectory(
        at: runtimeDirectory.appending(path: "bin"), withIntermediateDirectories: true)

      if try await installedUVVersion() != Self.uvVersion {
        step("Downloading uv \(Self.uvVersion)")
        try await downloadUV()
      }
      try checkCancelled()

      step("Installing Python and dependencies")
      try await runInstallStep(
        "Installing Python and dependencies", executable: uvExecutable,
        arguments: ["sync", "--project", projectDirectory.path, "--locked", "--no-dev",
                    "--no-editable", "--no-progress"],
        onStderr: { line in
          let t = line.trimmingCharacters(in: .whitespaces)
          if !t.isEmpty { report("Installing: \(t)") }
        })
      try checkCancelled()

      step("Downloading model weights")
      try await runInstallStep(
        "Downloading model weights", executable: repairExecutable,
        arguments: ["--prefetch-weights"], onStderr: { _ in })
      try checkCancelled()

      try writeMarker()
      transient = nil
      report("Ready")
    } catch is CancellationError {
      transient = nil
      throw CancellationError()
    } catch {
      let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
      transient = .failed(message)
      throw error
    }
  }

  private func checkCancelled() throws {
    if cancelRequested || Task.isCancelled { throw CancellationError() }
  }

  private func installedUVVersion() async throws -> String? {
    guard FileManager.default.isExecutableFile(atPath: uvExecutable.path) else { return nil }
    let lines = LinesBox()
    let p = LineProcess(executable: uvExecutable, arguments: ["--version"], environment: environment)
    let outcome = try await p.run(onStdoutLine: { lines.append($0) })
    guard outcome.exitStatus == 0, let first = lines.all.first else { return nil }
    // "uv 0.12.23 (abcdef 2026-10-01)"
    let parts = first.split(separator: " ")
    return parts.count >= 2 ? String(parts[1]) : nil
  }

  private func downloadUV() async throws {
    let fm = FileManager.default
    let (tmp, response) = try await URLSession.shared.download(from: Self.uvURL)
    defer { try? fm.removeItem(at: tmp) }
    if let http = response as? HTTPURLResponse, http.statusCode != 200 {
      throw ApolloError.downloadFailed("uv: HTTP \(http.statusCode)")
    }
    let digest = SHA256.hash(data: try Data(contentsOf: tmp, options: .mappedIfSafe))
      .map { String(format: "%02x", $0) }.joined()
    guard digest == Self.uvArchiveSHA256 else {
      throw ApolloError.checksumMismatch(expected: Self.uvArchiveSHA256, actual: digest)
    }
    let extractDir = runtimeDirectory.appending(path: "uv-extract-\(UUID().uuidString)")
    try fm.createDirectory(at: extractDir, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: extractDir) }
    let tar = LineProcess(
      executable: URL(fileURLWithPath: "/usr/bin/tar"),
      arguments: ["-xzf", tmp.path, "-C", extractDir.path], environment: environment)
    let outcome = try await tar.run(onStdoutLine: { _ in })
    guard outcome.exitStatus == 0 else {
      throw ApolloError.installFailed(step: "Unpacking uv", message: outcome.stderrTail)
    }
    let extracted = extractDir.appending(path: "uv-aarch64-apple-darwin/uv")
    if fm.fileExists(atPath: uvExecutable.path) { try fm.removeItem(at: uvExecutable) }
    try fm.moveItem(at: extracted, to: uvExecutable)
    try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: uvExecutable.path)
  }

  private func runInstallStep(
    _ name: String, executable: URL, arguments: [String],
    onStderr: @escaping @Sendable (String) -> Void
  ) async throws {
    let errorMessage = LinesBox()
    let p = LineProcess(executable: executable, arguments: arguments, environment: environment,
                        currentDirectory: runtimeDirectory)
    current = p
    defer { current = nil }
    if cancelRequested { p.terminate() }
    let outcome = try await p.run(
      onStdoutLine: { line in
        if case .error(let m) = ApolloEvent.parse(line) { errorMessage.append(m) }
      },
      onStderrLine: onStderr)
    if outcome.terminatedByUs { throw CancellationError() }
    guard outcome.exitStatus == 0, !outcome.wasSignalled else {
      let detail = errorMessage.all.last ?? Self.lastLines(outcome.stderrTail, 6)
      throw ApolloError.installFailed(step: name, message: detail.isEmpty ? "exit status \(outcome.exitStatus)" : detail)
    }
  }

  // MARK: Repair

  public func repair(input: URL, output: URL,
                     progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
    try await repair(input: input, output: output, progress: progress, status: { _ in })
  }

  /// Same as `repair(input:output:progress:)`, plus human-readable status lines
  /// ("Decoding audio", "Loading model", "Repairing on MPS", ...).
  public func repair(input: URL, output: URL,
                     progress: @escaping @Sendable (Double) -> Void,
                     status: @escaping @Sendable (String) -> Void) async throws -> URL {
    if case .installing = transient { throw ApolloError.busy }
    guard isInstalled() else { throw ApolloError.notInstalled }
    guard current == nil else { throw ApolloError.busy }
    cancelRequested = false

    var env = environment
    env["HF_HUB_OFFLINE"] = "1"  // weights were fetched by install(); never block on network
    let p = LineProcess(
      executable: repairExecutable,
      arguments: ["--input", input.path, "--output", output.path, "--device", device.rawValue],
      environment: env, currentDirectory: runtimeDirectory)
    current = p
    defer { current = nil }

    let result = ResultBox()
    let outcome = try await p.run(onStdoutLine: { line in
      switch ApolloEvent.parse(line) {
      case .progress(let f): progress(f)
      case .status(let m): status(m)
      case .done(let path): result.setDone(path)
      case .error(let m): result.setError(m)
      case nil: break
      }
    })

    if outcome.terminatedByUs || cancelRequested { throw CancellationError() }
    let (done, error) = result.values
    if outcome.exitStatus == 0, !outcome.wasSignalled, let done {
      progress(1)
      return URL(fileURLWithPath: done)
    }
    let tail = Self.lastLines(outcome.stderrTail, 6)
    throw ApolloError.repairFailed(
      error ?? (tail.isEmpty ? "apollo-repair exited with status \(outcome.exitStatus)" : tail))
  }

  /// Stops the running repair or install step (SIGTERM, then SIGKILL after 5 s).
  public func cancel() async {
    cancelRequested = true
    current?.terminate()
  }

  static func lastLines(_ text: String, _ n: Int) -> String {
    text.split(separator: "\n", omittingEmptySubsequences: true).suffix(n).joined(separator: "\n")
  }
}

/// Thread-safe collectors for values produced in subprocess callbacks.
final class LinesBox: @unchecked Sendable {
  private let lock = NSLock()
  private var lines: [String] = []
  func append(_ s: String) { lock.withLock { lines.append(s) } }
  var all: [String] { lock.withLock { lines } }
}

final class ResultBox: @unchecked Sendable {
  private let lock = NSLock()
  private var done: String?
  private var error: String?
  func setDone(_ s: String) { lock.withLock { done = s } }
  func setError(_ s: String) { lock.withLock { error = s } }
  var values: (String?, String?) { lock.withLock { (done, error) } }
}
