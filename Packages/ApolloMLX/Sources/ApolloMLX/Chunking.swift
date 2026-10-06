// Bounded-memory chunked inference with padded context and normalized linear crossfades.
// Same scheme and defaults as apollo/src/apollo_repair/chunking.py (itself adapted from
// upstream Apollo inference.py, CC BY-SA 4.0), so both implementations see identical chunks.
import Foundation

public struct ChunkPlan: Sendable, Equatable {
  /// Samples per chunk, crossfade overlap, and real-audio context inferred on each side and discarded.
  public var chunk: Int
  public var overlap: Int
  public var pad: Int
  /// Inputs shorter than this are zero-padded before the model sees them (STFT needs > n_fft/2).
  public static let minSamples = 44_100

  public init(chunkSeconds: Double = 5, overlapSeconds: Double = 0.5, padSeconds: Double = 1, sampleRate: Int = 44_100) {
    chunk = Int(chunkSeconds * Double(sampleRate))
    overlap = Int(overlapSeconds * Double(sampleRate))
    pad = Int(padSeconds * Double(sampleRate))
    precondition(chunk > 0 && overlap >= 0 && pad >= 0 && overlap * 2 <= chunk, "invalid chunk plan")
  }

  public func starts(total: Int) -> [Int] {
    let hop = chunk - overlap
    var s = [0]
    while s.last! + chunk < total { s.append(s.last! + hop) }
    return s
  }

  public static func crossfade(length: Int, overlap: Int, fadeIn: Bool, fadeOut: Bool) -> [Float] {
    var w = [Float](repeating: 1, count: length)
    let n = min(overlap, length)
    guard n > 0 else { return w }
    let ramp: [Float] = n == 1 ? [0] : (0..<n).map { Float($0) / Float(n - 1) }
    if fadeIn { for i in 0..<n { w[i] = ramp[i] } }
    if fadeOut { for i in 0..<n { w[length - n + i] = min(w[length - n + i], ramp[n - 1 - i]) } }
    return w
  }

  /// One model call: the window [start, start+length) of the input (zero-padded past the end
  /// to `paddedLength`), and which part of the result is kept.
  public struct Segment: Sendable, Equatable {
    public var inputStart: Int
    public var inputLength: Int
    public var modelLength: Int
    public var keepOffset: Int
    public var outputStart: Int
    public var outputLength: Int
    public var fadeIn: Bool
    public var fadeOut: Bool
  }

  public func segments(total: Int) -> [Segment] {
    if total <= chunk {
      return [Segment(inputStart: 0, inputLength: total, modelLength: max(total, Self.minSamples),
                      keepOffset: 0, outputStart: 0, outputLength: total, fadeIn: false, fadeOut: false)]
    }
    let s = starts(total: total)
    let paddedLen = chunk + 2 * pad
    return s.enumerated().map { i, start in
      let end = min(start + chunk, total)
      var pStart = max(0, start - pad)
      if pad > 0 && end == total { pStart = max(0, total - paddedLen) }
      let available = min(paddedLen, total - pStart)
      return Segment(inputStart: pStart, inputLength: available, modelLength: max(paddedLen, Self.minSamples),
                     keepOffset: start - pStart, outputStart: start, outputLength: end - start,
                     fadeIn: i > 0, fadeOut: i < s.count - 1)
    }
  }
}
