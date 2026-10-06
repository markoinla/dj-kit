// Smoke-test CLI: stemsplit <input> <outdir> [--model htdemucs] [--models-dir DIR] [--verify]
@preconcurrency import AVFoundation
import Foundation
import StemsKit

func fail(_ message: String) -> Never {
  FileHandle.standardError.write(Data((message + "\n").utf8))
  exit(2)
}

let usage = """
  usage: stemsplit <input> <outdir> [--model htdemucs|htdemucsFT|htdemucs6s] [--models-dir DIR] [--verify]
    --models-dir  weight cache (default ~/Library/Application Support/DJTools/models)
    --verify      check stems: duration, level, and how well they sum back to the input
  """
var positional: [String] = []
var model = StemModel.htdemucs
var modelsDir = StemSeparator.defaultModelsDirectory
var verify = false
var args = CommandLine.arguments.dropFirst().makeIterator()
while let arg = args.next() {
  switch arg {
  case "--model":
    guard let name = args.next(), let m = StemModel(name: name) else { fail(usage) }
    model = m
  case "--models-dir":
    guard let dir = args.next() else { fail(usage) }
    modelsDir = URL(fileURLWithPath: dir, isDirectory: true)
  case "--verify": verify = true
  case "-h", "--help":
    print(usage)
    exit(0)
  default: positional.append(arg)
  }
}
guard positional.count == 2 else { fail(usage) }
let input = URL(fileURLWithPath: positional[0])
let outdir = URL(fileURLWithPath: positional[1], isDirectory: true)

/// Channel-averaged Float32 PCM at the file's own rate.
func readMono(_ url: URL) throws -> (samples: [Float], rate: Double) {
  let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
  let buffer = AVAudioPCMBuffer(
    pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
  try file.read(into: buffer)
  let n = Int(buffer.frameLength)
  let channels = Int(buffer.format.channelCount)
  var mono = [Float](repeating: 0, count: n)
  for c in 0..<channels {
    let p = buffer.floatChannelData![c]
    for i in 0..<n { mono[i] += p[i] / Float(channels) }
  }
  return (mono, file.processingFormat.sampleRate)
}

func dB(_ x: Double) -> String { String(format: "%.1f dB", 10 * log10(max(x, 1e-20))) }
func power(_ s: [Float]) -> Double {
  s.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(max(s.count, 1))
}

print("stemsplit: \(input.lastPathComponent) → \(outdir.path), model \(model.rawValue)")
print("models dir: \(modelsDir.path) (cached: \(StemSeparator(model: model, modelsDirectory: modelsDir).isModelDownloaded))")

let task = Task {
  let separator = StemSeparator(model: model, modelsDirectory: modelsDir)
  let start = Date()
  nonisolated(unsafe) var lastPrinted = -1
  let result = try await separator.separate(input: input, outputDirectory: outdir) { p in
    let pct = Int(p * 100)
    if pct / 5 != lastPrinted / 5 || pct == 100 {
      lastPrinted = pct
      FileHandle.standardError.write(Data("progress \(pct)%\n".utf8))
    }
  }
  let wall = Date().timeIntervalSince(start)
  print(String(format: "wall time: %.2f s", wall))
  for name in result.stems.keys.sorted() { print("  \(name): \(result.stems[name]!.path)") }

  // Second call on the same separator: weights already loaded (app steady state).
  let warmStart = Date()
  _ = try await separator.separate(input: input, outputDirectory: outdir) { _ in }
  print(String(format: "warm wall time (same separator): %.2f s", Date().timeIntervalSince(warmStart)))

  guard verify else { return true }
  var ok = true
  let mix = try readMono(input)
  let mixDuration = Double(mix.samples.count) / mix.rate
  print(String(format: "input: %.3f s @ %.0f Hz, level %@", mixDuration, mix.rate, dB(power(mix.samples))))
  var sum = [Float](repeating: 0, count: mix.samples.count)
  for name in result.stems.keys.sorted() {
    let stem = try readMono(result.stems[name]!)
    let duration = Double(stem.samples.count) / stem.rate
    let level = power(stem.samples)
    let durationOK = abs(duration - mixDuration) < 0.01 && stem.rate == mix.rate
    let audible = level > 1e-7  // above -70 dBFS
    ok = ok && durationOK && audible
    print(String(
      format: "  %-7@ %.3f s @ %.0f Hz, level %@ %@", name, duration, stem.rate, dB(level),
      durationOK && audible ? "ok" : "FAIL"))
    for i in 0..<min(sum.count, stem.samples.count) { sum[i] += stem.samples[i] }
  }
  var residual = 0.0
  for i in 0..<sum.count { let d = Double(mix.samples[i] - sum[i]); residual += d * d }
  residual /= Double(max(sum.count, 1))
  let snr = 10 * log10(power(mix.samples) / max(residual, 1e-20))
  let sumOK = snr > 15
  ok = ok && sumOK
  print(String(format: "sum of stems vs input: SNR %.1f dB %@", snr, sumOK ? "ok" : "FAIL"))
  return ok
}

signal(SIGINT, SIG_IGN)
let sigint = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
sigint.setEventHandler {
  FileHandle.standardError.write(Data("cancelling…\n".utf8))
  task.cancel()
}
sigint.resume()

Task {
  do {
    let ok = try await task.value
    print(ok ? "OK" : "VERIFY FAILED")
    exit(ok ? 0 : 1)
  } catch is CancellationError {
    fail("cancelled")
  } catch {
    fail("error: \(error.localizedDescription)")
  }
}
dispatchMain()
