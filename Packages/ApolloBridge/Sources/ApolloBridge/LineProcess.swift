import Foundation
import os

/// Runs a subprocess and delivers its stdout and stderr line by line as they arrive.
/// Keeps the last few KB of stderr for error messages. `terminate()` sends SIGTERM, then
/// SIGKILL if the process is still alive after a grace period.
final class LineProcess: @unchecked Sendable {
  struct Outcome: Sendable {
    var exitStatus: Int32
    var wasSignalled: Bool
    var stderrTail: String
    var terminatedByUs: Bool
  }

  private struct State {
    var stdoutSplitter = LineSplitter()
    var stderrSplitter = LineSplitter()
    var stderrTail: [String] = []
    var stderrTailBytes = 0
    var terminated = false
    var signalled = false
    var stdoutClosed = false
    var stderrClosed = false
  }

  let executable: URL
  let arguments: [String]
  let environment: [String: String]
  let currentDirectory: URL?
  var killGracePeriod: TimeInterval = 5
  static let stderrTailLimit = 8 * 1024

  private let process = Process()
  private let state = OSAllocatedUnfairLock(initialState: State())

  init(executable: URL, arguments: [String], environment: [String: String],
       currentDirectory: URL? = nil) {
    self.executable = executable
    self.arguments = arguments
    self.environment = environment
    self.currentDirectory = currentDirectory
  }

  /// Runs to completion. Task cancellation terminates the process.
  func run(
    onStdoutLine: @escaping @Sendable (String) -> Void,
    onStderrLine: @escaping @Sendable (String) -> Void = { _ in }
  ) async throws -> Outcome {
    let out = Pipe(), err = Pipe()
    process.executableURL = executable
    process.arguments = arguments
    process.environment = environment
    if let currentDirectory { process.currentDirectoryURL = currentDirectory }
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = out
    process.standardError = err

    let group = DispatchGroup()
    group.enter(); group.enter(); group.enter()

    // Each stream leaves the group exactly once: at EOF, or when we stop waiting for it
    // because the process exited but a grandchild still holds the pipe open.
    let closeStdout: @Sendable () -> Void = { [state] in
      let lines: [String]? = state.withLock { s in
        guard !s.stdoutClosed else { return nil }
        s.stdoutClosed = true
        return s.stdoutSplitter.finish()
      }
      guard let lines else { return }
      out.fileHandleForReading.readabilityHandler = nil
      lines.forEach(onStdoutLine)
      group.leave()
    }
    let closeStderr: @Sendable () -> Void = { [state] in
      let lines: [String]? = state.withLock { s in
        guard !s.stderrClosed else { return nil }
        s.stderrClosed = true
        let lines = s.stderrSplitter.finish()
        Self.appendTail(lines, to: &s)
        return lines
      }
      guard let lines else { return }
      err.fileHandleForReading.readabilityHandler = nil
      lines.forEach(onStderrLine)
      group.leave()
    }

    out.fileHandleForReading.readabilityHandler = { [state] h in
      let data = h.availableData
      if data.isEmpty { return closeStdout() }
      let lines: [String] = state.withLock { s in
        s.stdoutClosed ? [] : s.stdoutSplitter.append(data)
      }
      lines.forEach(onStdoutLine)
    }
    err.fileHandleForReading.readabilityHandler = { [state] h in
      let data = h.availableData
      if data.isEmpty { return closeStderr() }
      let lines: [String] = state.withLock { s in
        guard !s.stderrClosed else { return [] }
        let lines = s.stderrSplitter.append(data)
        Self.appendTail(lines, to: &s)
        return lines
      }
      lines.forEach(onStderrLine)
    }
    process.terminationHandler = { _ in
      group.leave()
      DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
        closeStdout()
        closeStderr()
      }
    }

    do {
      try process.run()
    } catch {
      out.fileHandleForReading.readabilityHandler = nil
      err.fileHandleForReading.readabilityHandler = nil
      throw error
    }
    signalIfRequested()  // terminate() may have been called before the process started

    await withTaskCancellationHandler {
      await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
        group.notify(queue: .global()) { c.resume() }
      }
    } onCancel: {
      self.terminate()
    }

    let (tail, byUs) = state.withLock { ($0.stderrTail.joined(separator: "\n"), $0.terminated) }
    return Outcome(
      exitStatus: process.terminationStatus,
      wasSignalled: process.terminationReason == .uncaughtSignal,
      stderrTail: tail,
      terminatedByUs: byUs)
  }

  private static func appendTail(_ lines: [String], to s: inout State) {
    for line in lines {
      s.stderrTail.append(line)
      s.stderrTailBytes += line.utf8.count + 1
      while s.stderrTailBytes > stderrTailLimit, s.stderrTail.count > 1 {
        s.stderrTailBytes -= s.stderrTail.removeFirst().utf8.count + 1
      }
    }
  }

  func terminate() {
    state.withLock { $0.terminated = true }
    signalIfRequested()
  }

  private func signalIfRequested() {
    guard process.isRunning else { return }
    let send = state.withLock { s -> Bool in
      guard s.terminated, !s.signalled else { return false }
      s.signalled = true
      return true
    }
    guard send else { return }
    let pid = process.processIdentifier
    process.terminate()
    DispatchQueue.global().asyncAfter(deadline: .now() + killGracePeriod) { [self] in
      if process.isRunning { kill(pid, SIGKILL) }
    }
  }
}
