import CKeyFinder
import Foundation

/// The detected key of a track.
public struct KeyEstimate: Sendable, Codable, Equatable {
  public var key: MusicalKey
  /// How far the best key's score leads the runner-up, as a share of the spread
  /// of libkeyfinder's 24 cosine scores: (best − second) / (best − worst), 0…1. Debug only.
  public var margin: Double

  public init(key: MusicalKey, margin: Double) {
    self.key = key
    self.margin = margin
  }
}

/// libkeyfinder (Mixxx's key detector) behind the CKeyFinder shim. Pure CPU, thread-safe.
public enum KeyDetector {
  /// Nil for silence, a rate under 4.4 kHz, or an internal failure. libkeyfinder
  /// decimates to about 4.4 kHz itself, so a 22.05 kHz decode gives the same keys.
  public static func detect(monoSamples: [Float], sampleRate: Double) -> KeyEstimate? {
    var tonic: Int32 = 0
    var isMinor: Int32 = 0
    var margin = 0.0
    let result = monoSamples.withUnsafeBufferPointer {
      ckf_detect($0.baseAddress, $0.count, sampleRate, &tonic, &isMinor, &margin)
    }
    guard Int(result) == CKF_KEY else { return nil }
    return KeyEstimate(key: MusicalKey(tonic: Int(tonic), isMinor: isMinor != 0), margin: margin)
  }
}
