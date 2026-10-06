// Tempo from a list of beat times.
//
// Beat This! reports beats on a 50 fps frame grid, so single inter-beat intervals are quantized
// to 20 ms: 128 BPM (23.4 frames) comes out as a mix of 23 and 24, and 60 / median interval reads
// 130.4. The tempo is instead the slope of beat time against beat index, fitted by least squares
// over every run of beats that sits on one consistent grid (dropped beats bridged, breakdowns and
// double-time stretches cut the run), pooled with one intercept per run. On 15 real tracks this
// gave whole-number BPMs to ±0.02 on electronic music (128.000, 130.001, 133.000, 116.0…), where
// the median gave 125, 130.4, 115.4…
import Foundation

public struct TempoEstimate: Sendable, Codable, Equatable {
  /// From the beats, before folding.
  public var rawBPM: Double
  public var beatCount: Int
  /// Coefficient of variation of the inter-beat interval, measured over 4-beat spans on the
  /// tracked grid (which averages out the 20 ms frame quantization); over all single intervals
  /// when fewer than half the beats sit on a consistent grid.
  public var stability: Double

  /// Seen on real music (15 tracks): 0.002–0.0065 for electronic tracks, 0.0085 for 80s disco,
  /// 0.024 for a live-band funk track; a track the tracker never locks onto lands far above (0.54).
  /// A 112 → 136 BPM ramp over 5 minutes is unsteady.
  public static let steadyThreshold = 0.03
  /// Fewer beats than this give no estimate.
  public static let minimumBeats = 8

  public var isSteady: Bool { stability < Self.steadyThreshold }

  public init(rawBPM: Double, beatCount: Int, stability: Double) {
    self.rawBPM = rawBPM
    self.beatCount = beatCount
    self.stability = stability
  }

  /// Halves or doubles into `range` only when outside it.
  public func bpm(in range: ClosedRange<Double>) -> Double {
    var bpm = rawBPM
    guard bpm.isFinite, bpm > 0 else { return bpm }
    var steps = 0
    while bpm < range.lowerBound && steps < 8 { bpm *= 2; steps += 1 }
    while bpm > range.upperBound && steps < 16 { bpm /= 2; steps += 1 }
    return bpm
  }

  /// Estimate from ascending beat times in seconds; nil with fewer than `minimumBeats`.
  public init?(beatTimes beats: [Double]) {
    guard beats.count >= Self.minimumBeats else { return nil }
    let intervals = zip(beats.dropFirst(), beats).map { $0 - $1 }
    let median = Self.median(intervals)
    guard median > 0 else { return nil }
    let runs = Self.gridRuns(beats, period: median).filter { $0.count >= Self.minimumBeats }

    // Pooled least-squares slope of time against grid index, one intercept per run.
    var num = 0.0, den = 0.0, covered = 0
    var spans: [Double] = []
    for run in runs {
      let n = Double(run.count)
      let meanIndex = run.reduce(0) { $0 + Double($1.index) } / n
      let meanTime = run.reduce(0) { $0 + $1.time } / n
      for p in run {
        num += (Double(p.index) - meanIndex) * (p.time - meanTime)
        den += (Double(p.index) - meanIndex) * (Double(p.index) - meanIndex)
      }
      covered += run.count
      for i in 0..<(run.count - 4) {
        spans.append((run[i + 4].time - run[i].time) / Double(run[i + 4].index - run[i].index))
      }
    }
    let period = den > 0 ? num / den : median
    let onGrid = covered * 2 >= beats.count && spans.count >= 2
    self.init(
      rawBPM: 60 / period, beatCount: beats.count,
      stability: Self.coefficientOfVariation(onGrid ? spans : intervals))
  }

  struct GridPoint { var index: Int; var time: Double }

  /// Splits beats into runs on one grid of `period`: each interval must be k periods (k = 1…4,
  /// so up to three dropped beats) within ±10% of a period; anything else starts a new run.
  static func gridRuns(_ beats: [Double], period: Double) -> [[GridPoint]] {
    var runs: [[GridPoint]] = []
    var current = [GridPoint(index: 0, time: beats[0])]
    for i in 1..<beats.count {
      let d = beats[i] - beats[i - 1]
      let k = (d / period).rounded()
      if k >= 1, k <= 4, abs(d - k * period) <= 0.1 * period {
        current.append(GridPoint(index: current.last!.index + Int(k), time: beats[i]))
      } else {
        runs.append(current)
        current = [GridPoint(index: 0, time: beats[i])]
      }
    }
    runs.append(current)
    return runs
  }

  static func median(_ values: [Double]) -> Double {
    guard !values.isEmpty else { return 0 }
    let s = values.sorted()
    return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
  }

  static func coefficientOfVariation(_ values: [Double]) -> Double {
    guard values.count >= 2 else { return 1 }
    let mean = values.reduce(0, +) / Double(values.count)
    guard mean > 0 else { return 1 }
    let variance = values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(values.count)
    return variance.squareRoot() / mean
  }
}
