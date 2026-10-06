import CKeyFinder
import Foundation
import Testing
@testable import AnalysisKit

/// Deterministic noise in −1…1.
struct Noise {
  var state: UInt64
  mutating func next() -> Double {
    state = state &* 6364136223846793005 &+ 1442695040888963407
    return Double(state >> 11) / Double(1 << 52) - 1
  }
}

@Suite struct KeyFFTTests {
  /// vDSP forward adapter against a naive DFT, r2c layout (bins above n / 2 zero).
  @Test(arguments: [64, 2048])
  func forwardMatchesNaiveDFT(n: Int) {
    var noise = Noise(state: UInt64(n))
    let x = (0..<n).map { _ in noise.next() }
    var re = [Double](repeating: .nan, count: n)
    var im = [Double](repeating: .nan, count: n)
    #expect(ckf_test_forward_fft(x, UInt32(n), &re, &im) == 0)
    var worst = 0.0
    for k in 0..<n {
      var (sr, si) = (0.0, 0.0)
      if k <= n / 2 {
        for t in 0..<n {
          let phase = -2 * Double.pi * Double(k * t % n) / Double(n)
          sr += x[t] * cos(phase)
          si += x[t] * sin(phase)
        }
      }
      worst = max(worst, abs(re[k] - sr), abs(im[k] - si))
    }
    #expect(worst < 1e-9)
  }

  /// Frame size libkeyfinder analyses with: spot-check bins against the DFT sum.
  @Test func forwardAt16384() {
    let n = 16384
    var noise = Noise(state: 7)
    let x = (0..<n).map { _ in noise.next() }
    var re = [Double](repeating: 0, count: n)
    var im = [Double](repeating: 0, count: n)
    #expect(ckf_test_forward_fft(x, UInt32(n), &re, &im) == 0)
    for k in [0, 1, 37, 1000, 4097, 8191, 8192] {
      var (sr, si) = (0.0, 0.0)
      for t in 0..<n {
        let phase = -2 * Double.pi * Double(k * t % n) / Double(n)
        sr += x[t] * cos(phase)
        si += x[t] * sin(phase)
      }
      #expect(abs(re[k] - sr) < 1e-8 && abs(im[k] - si) < 1e-8)
    }
    #expect(re[8193] == 0 && im[n - 1] == 0)
  }

  /// c2r: bins 0…n / 2 define a Hermitian spectrum; DC / Nyquist imaginary parts
  /// and the upper half are ignored; output divided by n.
  @Test(arguments: [64, 2048])
  func inverseMatchesNaiveC2R(n: Int) {
    var noise = Noise(state: UInt64(n) + 1)
    let re = (0..<n).map { _ in noise.next() }
    let im = (0..<n).map { _ in noise.next() }
    var out = [Double](repeating: .nan, count: n)
    #expect(ckf_test_inverse_fft(re, im, UInt32(n), &out) == 0)
    var worst = 0.0
    for t in 0..<n {
      var sum = re[0] + re[n / 2] * (t % 2 == 0 ? 1 : -1)
      for k in 1..<(n / 2) {
        let phase = 2 * Double.pi * Double(k * t % n) / Double(n)
        sum += 2 * (re[k] * cos(phase) - im[k] * sin(phase))
      }
      worst = max(worst, abs(out[t] - sum / Double(n)))
    }
    #expect(worst < 1e-12)
  }
}

@Suite struct KeyDetectorTests {
  static let rate = 44_100.0

  /// One chord: a bass root plus a close voicing, each note 8 harmonics at 1/h,
  /// with a short fade so the chord changes don't click.
  static func chord(_ midi: [Int], seconds: Double, rate: Double) -> [Float] {
    let n = Int(seconds * rate)
    var out = [Float](repeating: 0, count: n)
    let fade = Int(0.02 * rate)
    for note in midi {
      let f0 = 440 * pow(2, Double(note - 69) / 12)
      for h in 1...8 where Double(h) * f0 < rate / 2 {
        let step = 2 * Double.pi * f0 * Double(h) / rate
        let amp = 0.05 / Double(h)
        for i in 0..<n { out[i] += Float(amp * sin(step * Double(i))) }
      }
    }
    for i in 0..<fade {
      let g = Float(i) / Float(fade)
      out[i] *= g
      out[n - 1 - i] *= g
    }
    return out
  }

  /// I–IV–V–I (minor: i–iv–V–i, harmonic-minor V), 3 s a chord, played twice.
  static func progression(tonic: Int, isMinor: Bool, rate: Double = rate) -> [Float] {
    let third = isMinor ? 3 : 4
    let root = 48 + tonic  // C3…B3
    let triads: [[Int]] = [
      [0, third, 7], [5, 5 + third, 12], [7, 11, 14], [0, third, 7],
    ]
    var out: [Float] = []
    for _ in 0..<2 {
      for triad in triads {
        let bass = root + triad[0] - 12
        out += chord([bass] + triad.map { root + 12 + $0 }, seconds: 3, rate: rate)
      }
    }
    return out
  }

  @Test(arguments: [
    (0, false), (7, false), (3, false), (6, false), (10, false),
    (9, true), (4, true), (0, true), (6, true), (5, true),
  ])
  func progressionKey(tonic: Int, isMinor: Bool) throws {
    let expected = MusicalKey(tonic: tonic, isMinor: isMinor)
    let samples = Self.progression(tonic: tonic, isMinor: isMinor)
    let estimate = try #require(KeyDetector.detect(monoSamples: samples, sampleRate: Self.rate))
    #expect(estimate.key == expected, "\(expected.musical): got \(estimate.key.musical), margin \(estimate.margin)")
    #expect(estimate.margin > 0 && estimate.margin <= 1)
  }

  @Test(arguments: [11_025.0, 22_050.0, 48_000.0, 96_000.0])
  func otherRates(rate: Double) throws {
    let samples = Self.progression(tonic: 2, isMinor: true, rate: rate)
    let estimate = try #require(KeyDetector.detect(monoSamples: samples, sampleRate: rate))
    #expect(estimate.key == MusicalKey(tonic: 2, isMinor: true))
  }

  @Test func silenceIsNil() {
    #expect(KeyDetector.detect(monoSamples: [Float](repeating: 0, count: 44_100 * 5), sampleRate: Self.rate) == nil)
    #expect(KeyDetector.detect(monoSamples: [], sampleRate: Self.rate) == nil)
    #expect(KeyDetector.detect(monoSamples: [Float](repeating: 1e-7, count: 44_100), sampleRate: Self.rate) == nil)
    #expect(KeyDetector.detect(monoSamples: [Float](repeating: 0.1, count: 4_000), sampleRate: 4_000) == nil)
  }

  @Test func shortAndNonFiniteInputStillWork() throws {
    var samples = Array(Self.progression(tonic: 9, isMinor: true).prefix(Int(Self.rate * 2)))
    samples[100] = .nan
    samples[200] = .infinity
    let estimate = try #require(KeyDetector.detect(monoSamples: samples, sampleRate: Self.rate))
    #expect(estimate.key == MusicalKey(tonic: 9, isMinor: true))
  }
}
