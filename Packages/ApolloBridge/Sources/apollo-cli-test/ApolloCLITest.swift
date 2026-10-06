// apollo-cli-test <input> <output> [--support DIR] [--project DIR] [--device auto|mps|cpu]
//                 [--cancel-after SECONDS]
// End-to-end check of ApolloBridge: install-if-needed, then repair one file.
// Defaults: --support $APOLLO_SUPPORT_DIR or ./out/support; --project $APOLLO_PROJECT_DIR or
// the repo's apollo/ (found relative to this source file).
import ApolloBridge
import Foundation

@main
struct ApolloCLITest {
  static func main() async {
    exit(await run())
  }

  static func usage() -> Never {
    FileHandle.standardError.write(Data("""
      usage: apollo-cli-test <input> <output> [--support DIR] [--project DIR] \
      [--device auto|mps|cpu] [--cancel-after SECONDS]

      """.utf8))
    exit(2)
  }

  static func log(_ s: String) {
    FileHandle.standardOutput.write(Data((s + "\n").utf8))
  }

  static func elapsed(since t: Date) -> String {
    String(format: "%.1f s", Date().timeIntervalSince(t))
  }

  static func run() async -> Int32 {
    var positional: [String] = []
    var options: [String: String] = [:]
    var it = CommandLine.arguments.dropFirst().makeIterator()
    while let arg = it.next() {
      if arg.hasPrefix("--") {
        guard let value = it.next() else { usage() }
        options[String(arg.dropFirst(2))] = value
      } else {
        positional.append(arg)
      }
    }
    guard positional.count == 2 else { usage() }

    let env = ProcessInfo.processInfo.environment
    let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
    func absolute(_ path: String) -> URL {
      URL(fileURLWithPath: path, relativeTo: cwd).standardizedFileURL
    }
    let input = absolute(positional[0])
    let output = absolute(positional[1])
    let support = absolute(options["support"] ?? env["APOLLO_SUPPORT_DIR"] ?? "out/support")
    let project = options["project"].map(absolute) ?? env["APOLLO_PROJECT_DIR"].map(absolute)
      ?? URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()  // apollo-cli-test
      .deletingLastPathComponent()  // Sources
      .deletingLastPathComponent()  // ApolloBridge
      .deletingLastPathComponent()  // Packages
      .deletingLastPathComponent()  // repo root
      .appending(path: "apollo")
    let device = ApolloDevice(rawValue: options["device"] ?? "auto") ?? .auto

    let runtime = ApolloRuntime(projectDirectory: project, supportDirectory: support)
    await runtime.setDevice(device)
    log("project: \(project.path)")
    log("support: \(support.path)")
    log("device:  \(device.rawValue)")

    // Ctrl-C cancels the running job instead of orphaning the Python process.
    signal(SIGINT, SIG_IGN)
    let sigint = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
    sigint.setEventHandler { Task { await runtime.cancel() } }
    sigint.resume()

    do {
      let state = await runtime.state()
      log("state: \(state)")
      if state != .ready {
        let t = Date()
        try await runtime.install { message in log("[install] \(message)") }
        log("install finished in \(elapsed(since: t)); state: \(await runtime.state())")
      }

      if let s = options["cancel-after"], let seconds = Double(s) {
        Task {
          try? await Task.sleep(for: .seconds(seconds))
          log("cancelling after \(seconds) s")
          await runtime.cancel()
        }
      }

      let t = Date()
      let throttle = Throttle()
      let result = try await runtime.repair(
        input: input, output: output,
        progress: { f in
          if throttle.shouldPrint(f) { log(String(format: "[repair] %5.1f%%", f * 100)) }
        },
        status: { m in log("[repair] \(m)") })
      log("done: \(result.path) in \(elapsed(since: t))")
      return 0
    } catch is CancellationError {
      log("cancelled")
      return 130
    } catch {
      log("error: \((error as? LocalizedError)?.errorDescription ?? "\(error)")")
      return 1
    }
  }
}

final class Throttle: @unchecked Sendable {
  private let lock = NSLock()
  private var last = -1.0
  func shouldPrint(_ f: Double) -> Bool {
    lock.withLock {
      guard (f >= 1 && last < 1) || f - last >= 0.05 else { return false }
      last = f
      return true
    }
  }
}
