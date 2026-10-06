import Foundation
import Testing

@testable import ApolloBridge

// MARK: - Protocol parsing

@Suite struct ApolloEventParsing {
  @Test func parsesEveryEventKind() {
    #expect(ApolloEvent.parse(#"{"event":"status","message":"Loading model"}"#) == .status("Loading model"))
    #expect(ApolloEvent.parse(#"{"event":"progress","fraction":0.42}"#) == .progress(0.42))
    #expect(ApolloEvent.parse(#"{"event":"progress","fraction":1}"#) == .progress(1))
    #expect(ApolloEvent.parse(#"{"event":"done","output":"/tmp/x.wav"}"#) == .done("/tmp/x.wav"))
    #expect(ApolloEvent.parse(#"{"event": "error", "message": "boom"}"#) == .error("boom"))
  }

  @Test func toleratesWhitespaceAndExtraFields() {
    #expect(ApolloEvent.parse("  {\"event\":\"progress\",\"fraction\":0.5,\"extra\":true}\r") == .progress(0.5))
  }

  @Test func clampsProgress() {
    #expect(ApolloEvent.parse(#"{"event":"progress","fraction":1.7}"#) == .progress(1))
    #expect(ApolloEvent.parse(#"{"event":"progress","fraction":-3}"#) == .progress(0))
  }

  @Test func ignoresNoise() {
    for line in ["", "   ", "Loading weights...", "{", "[1,2]", #"{"event":"weird"}"#,
                 #"{"event":"progress"}"#, #"{"event":"done"}"#, #"{"message":"no event"}"#] {
      #expect(ApolloEvent.parse(line) == nil, "\(line)")
    }
  }

  @Test func errorWithoutMessageStillSurfaces() {
    #expect(ApolloEvent.parse(#"{"event":"error"}"#) == .error("Unknown error"))
  }
}

@Suite struct LineSplitting {
  @Test func joinsPartialReads() {
    var s = LineSplitter()
    #expect(s.append(Data("{\"a\":".utf8)) == [])
    #expect(s.append(Data("1}\n{\"b\"".utf8)) == ["{\"a\":1}"])
    #expect(s.append(Data(":2}\r\n\n".utf8)) == ["{\"b\":2}", ""])
    #expect(s.finish() == [])
  }

  @Test func flushesUnterminatedTail() {
    var s = LineSplitter()
    _ = s.append(Data("last line".utf8))
    #expect(s.finish() == ["last line"])
  }

  @Test func capsRunawayLines() {
    var s = LineSplitter()
    s.maxLineBytes = 8
    #expect(s.append(Data("0123456789".utf8)) == ["0123456789"])
  }

  @Test func survivesInvalidUTF8() {
    var s = LineSplitter()
    #expect(s.append(Data([0x61, 0xFF, 0x62, 0x0A])).count == 1)
  }
}

// MARK: - Subprocess plumbing with fake scripts

func makeTempDir() throws -> URL {
  let dir = FileManager.default.temporaryDirectory.appending(path: "ApolloBridgeTests-\(UUID().uuidString)")
  try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
  return dir
}

func writeScript(_ body: String, to url: URL) throws {
  try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
  try ("#!/bin/sh\n" + body).write(to: url, atomically: true, encoding: .utf8)
  try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
}

final class Collected: @unchecked Sendable {
  private let lock = NSLock()
  private var items: [String] = []
  func add(_ s: String) { lock.withLock { items.append(s) } }
  var all: [String] { lock.withLock { items } }
}

@Suite struct LineProcessTests {
  @Test func streamsSplitWritesAndStderr() async throws {
    let dir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let script = dir.appending(path: "fake.sh")
    try writeScript("""
      printf '{"event":"status","message":"Loading model"}\\n'
      printf '{"event":"prog'
      sleep 0.2
      printf 'ress","fraction":0.5}\\n'
      echo "a log line" >&2
      echo "not json on stdout"
      printf '{"event":"done","output":"/x.wav"}'
      exit 3
      """, to: script)
    let out = Collected(), err = Collected()
    let p = LineProcess(executable: script, arguments: [], environment: [:])
    let outcome = try await p.run(onStdoutLine: out.add, onStderrLine: err.add)
    #expect(outcome.exitStatus == 3)
    #expect(!outcome.terminatedByUs)
    #expect(outcome.stderrTail == "a log line")
    #expect(err.all == ["a log line"])
    let events = out.all.compactMap { ApolloEvent.parse($0) }
    #expect(events == [.status("Loading model"), .progress(0.5), .done("/x.wav")])
  }

  @Test func terminateStopsAStuckProcess() async throws {
    let dir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let script = dir.appending(path: "hang.sh")
    try writeScript("trap '' TERM\nwhile true; do sleep 0.1; done\n", to: script)  // ignores SIGTERM
    let p = LineProcess(executable: script, arguments: [], environment: [:])
    p.killGracePeriod = 0.5
    let start = Date()
    Task { try await Task.sleep(for: .milliseconds(200)); p.terminate() }
    let outcome = try await p.run(onStdoutLine: { _ in })
    #expect(outcome.terminatedByUs)
    #expect(outcome.wasSignalled)
    #expect(Date().timeIntervalSince(start) < 5)
  }

  @Test func stderrTailIsBounded() async throws {
    let dir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let script = dir.appending(path: "noisy.sh")
    try writeScript("i=0; while [ $i -lt 2000 ]; do echo \"line $i of noise\" >&2; i=$((i+1)); done; echo LAST >&2\n", to: script)
    let p = LineProcess(executable: script, arguments: [], environment: [:])
    let outcome = try await p.run(onStdoutLine: { _ in })
    #expect(outcome.stderrTail.utf8.count <= LineProcess.stderrTailLimit)
    #expect(outcome.stderrTail.hasSuffix("LAST"))
  }
}

// MARK: - ApolloRuntime against a fake installed venv

struct FakeInstall {
  let root: URL
  let runtime: ApolloRuntime

  init(script: String) async throws {
    root = try makeTempDir()
    let project = root.appending(path: "apollo")
    try FileManager.default.createDirectory(at: project.appending(path: "src/apollo_repair"), withIntermediateDirectories: true)
    try "[project]\nname = \"fake\"\n".write(to: project.appending(path: "pyproject.toml"), atomically: true, encoding: .utf8)
    try "version = 1\n".write(to: project.appending(path: "uv.lock"), atomically: true, encoding: .utf8)
    try "print('hi')\n".write(to: project.appending(path: "src/apollo_repair/cli.py"), atomically: true, encoding: .utf8)
    runtime = ApolloRuntime(projectDirectory: project, supportDirectory: root.appending(path: "support"))
    try writeScript(script, to: runtime.repairExecutable)
  }

  func cleanup() { try? FileManager.default.removeItem(at: root) }
}

@Suite struct ApolloRuntimeTests {
  static let happyScript = """
    out=""
    while [ $# -gt 0 ]; do case "$1" in --output) out="$2"; shift;; esac; shift; done
    echo '{"event":"status","message":"Loading model"}'
    for f in 0.0 0.25 0.5 0.75 1.0; do echo "{\\"event\\":\\"progress\\",\\"fraction\\":$f}"; done
    echo "warning: something chatty" >&2
    : > "$out"
    echo "{\\"event\\":\\"done\\",\\"output\\":\\"$out\\"}"
    """

  @Test func stateTracksMarkerAndProjectChanges() async throws {
    let fake = try await FakeInstall(script: Self.happyScript)
    defer { fake.cleanup() }
    #expect(await fake.runtime.state() == .notInstalled)
    try await fake.runtime.writeMarker()
    #expect(await fake.runtime.state() == .ready)
    try "print('changed')\n".write(
      to: fake.runtime.projectDirectory.appending(path: "src/apollo_repair/cli.py"), atomically: true, encoding: .utf8)
    #expect(await fake.runtime.state() == .notInstalled)
  }

  @Test func repairRefusesWhenNotInstalled() async throws {
    let fake = try await FakeInstall(script: Self.happyScript)
    defer { fake.cleanup() }
    await #expect(throws: ApolloError.notInstalled) {
      _ = try await fake.runtime.repair(input: fake.root, output: fake.root, progress: { _ in })
    }
  }

  @Test func repairReportsProgressAndReturnsOutput() async throws {
    let fake = try await FakeInstall(script: Self.happyScript)
    defer { fake.cleanup() }
    try await fake.runtime.writeMarker()
    let progress = Collected(), status = Collected()
    let out = fake.root.appending(path: "out.wav")
    let result = try await fake.runtime.repair(
      input: fake.root.appending(path: "in.mp3"), output: out,
      progress: { progress.add(String($0)) }, status: status.add)
    #expect(result.path == out.path)
    #expect(progress.all.first == "0.0")
    #expect(progress.all.last == "1.0")
    #expect(status.all == ["Loading model"])
  }

  @Test func repairSurfacesErrorEvent() async throws {
    let fake = try await FakeInstall(script: """
      echo '{"event":"status","message":"Decoding audio"}'
      echo 'Traceback: ValueError' >&2
      echo '{"event":"error","message":"No audio stream in in.mp3"}'
      exit 1
      """)
    defer { fake.cleanup() }
    try await fake.runtime.writeMarker()
    await #expect(throws: ApolloError.repairFailed("No audio stream in in.mp3")) {
      _ = try await fake.runtime.repair(input: fake.root, output: fake.root.appending(path: "o.wav"), progress: { _ in })
    }
  }

  @Test func repairFallsBackToStderrWhenProcessDies() async throws {
    let fake = try await FakeInstall(script: "echo 'Segmentation fault' >&2\nexit 139\n")
    defer { fake.cleanup() }
    try await fake.runtime.writeMarker()
    await #expect(throws: ApolloError.repairFailed("Segmentation fault")) {
      _ = try await fake.runtime.repair(input: fake.root, output: fake.root.appending(path: "o.wav"), progress: { _ in })
    }
  }

  @Test func cancelTerminatesRepair() async throws {
    let fake = try await FakeInstall(script: """
      echo '{"event":"progress","fraction":0.1}'
      exec sleep 30
      """)
    defer { fake.cleanup() }
    try await fake.runtime.writeMarker()
    let runtime = fake.runtime
    let start = Date()
    Task {
      try await Task.sleep(for: .milliseconds(300))
      await runtime.cancel()
    }
    await #expect(throws: CancellationError.self) {
      _ = try await runtime.repair(input: fake.root, output: fake.root.appending(path: "o.wav"), progress: { _ in })
    }
    #expect(Date().timeIntervalSince(start) < 10)
    // A cancelled job leaves the runtime usable.
    #expect(await runtime.state() == .ready)
  }
}
