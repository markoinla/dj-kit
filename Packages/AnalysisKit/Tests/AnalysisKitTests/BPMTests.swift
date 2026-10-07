import Foundation
import Testing
@testable import AnalysisKit

struct BPMTests {
  @Test func folding() {
    func t(_ raw: Double) -> TempoEstimate { TempoEstimate(rawBPM: raw, beatCount: 100, stability: 0.01) }
    #expect(t(124).bpm(in: BPMRange.standard) == 124)
    #expect(t(85).bpm(in: BPMRange.standard) == 85)
    #expect(t(174).bpm(in: BPMRange.standard) == 174)
    #expect(t(70).bpm(in: BPMRange.standard) == 70)
    #expect(t(64).bpm(in: BPMRange.standard) == 128)
    #expect(t(43.5).bpm(in: BPMRange.standard) == 87)
    #expect(t(190).bpm(in: BPMRange.standard) == 95)
    #expect(t(250).bpm(in: BPMRange.standard) == 125)
    #expect(t(350).bpm(in: BPMRange.standard) == 175)
    #expect(t(180).bpm(in: BPMRange.standard) == 180)
    #expect(t(140).bpm(in: BPMRange.slow) == 70)
    #expect(t(96).bpm(in: BPMRange.slow) == 96)
    #expect(t(50).bpm(in: BPMRange.slow) == 100)
    #expect(t(0).bpm(in: BPMRange.standard) == 0)
    // Just outside a range narrower than an octave: halving or doubling would overshoot the other end.
    let narrow: ClosedRange<Double> = 88...175
    #expect(t(175.4).bpm(in: narrow) == 175.4)
    #expect(t(176).bpm(in: narrow) == 88)
    #expect(t(87.8).bpm(in: narrow) == 87.8)
    #expect(t(87.5).bpm(in: narrow) == 175)
  }

  @Test func format() {
    #expect(BPMFormat.string(124) == "124")
    #expect(BPMFormat.string(124.04) == "124")
    #expect(BPMFormat.string(123.96) == "124")
    #expect(BPMFormat.string(123.5) == "123.5")
    #expect(BPMFormat.string(123.94) == "123.9")
    #expect(BPMFormat.string(99.97) == "100")
    #expect(BPMFormat.string(87.25) == "87.2" || BPMFormat.string(87.25) == "87.3")
  }

  @Test func genreRange() {
    for g in ["Downtempo", "Trip-Hop", "trip hop", "TripHop", "Chill", "Chillout", "Chill-Out", "chill out",
              "Lounge", "Reggae", "Dub", "Roots Reggae / Dub", "Ambient", "ambient pop", "Downtempo / Electronica"] {
      #expect(BPMRange.forGenre(g) == BPMRange.slow, "\(g)")
    }
    // A club style anywhere in the genre wins over a slow word.
    for g in ["Organic House / Downtempo", "Lounge House", "Chill House", "Ambient Techno", "Chillstep",
              "Downtempo Garage", "Chill Bass", "Ambient Trance", "Chill Breaks", "Lounge DnB", "Reggae Jungle",
              "Downtempo Electro", "Chillout Drum & Bass"] {
      #expect(BPMRange.forGenre(g) == BPMRange.standard, "\(g)")
    }
    for g in ["Dubstep", "Dub-Step", "Dub Techno", "Dub House", "Techno", "House", "Drum & Bass", "Hip-Hop", "", "Pop"] {
      #expect(BPMRange.forGenre(g) == BPMRange.standard, "\(g)")
    }
    #expect(BPMRange.forGenre(nil) == BPMRange.standard)
  }

  @Test func genresRange() {
    #expect(BPMRange.forGenres(["Downtempo", "Electronic"]) == BPMRange.slow)
    #expect(BPMRange.forGenres(["Electronic", "Downtempo"]) == BPMRange.slow)
    #expect(BPMRange.forGenres([nil, "Reggae"]) == BPMRange.slow)
    #expect(BPMRange.forGenres(["House", "Electronic"]) == BPMRange.standard)
    #expect(BPMRange.forGenres(["Chill House", "Dance"]) == BPMRange.standard)
    // A club style in either wins over a slow word in the other.
    #expect(BPMRange.forGenres(["Lounge", "House"]) == BPMRange.standard)
    #expect(BPMRange.forGenres(["Techno", "Ambient"]) == BPMRange.standard)
    #expect(BPMRange.forGenres(["Downtempo", nil]) == BPMRange.slow)
    #expect(BPMRange.forGenres([nil, nil]) == BPMRange.standard)
    #expect(BPMRange.forGenres([]) == BPMRange.standard)
  }
}

struct TempoEstimateTests {
  /// Beats at `bpm` snapped to the 50 fps frame grid, like the tracker reports them.
  static func gridBeats(bpm: Double, seconds: Double, offset: Double = 0.13) -> [Double] {
    stride(from: offset, to: seconds, by: 60 / bpm).map { ($0 * 50).rounded() / 50 }
  }

  @Test func wholeNumberTempoDespiteFrameQuantization() throws {
    for bpm in [87.0, 120, 124, 128, 133, 140, 174] {
      let e = try #require(TempoEstimate(beatTimes: Self.gridBeats(bpm: bpm, seconds: 300)))
      #expect(abs(e.rawBPM - bpm) < 0.02, "\(bpm): \(e.rawBPM)")
      #expect(e.isSteady, "\(bpm): \(e.stability)")
    }
  }

  @Test func bridgesDroppedBeatsAndBreakdowns() throws {
    var beats = Self.gridBeats(bpm: 128, seconds: 300)
    beats.remove(at: 50)  // one missed beat
    beats.removeSubrange(200..<264)  // a 30 s breakdown without beats
    let half = (beats[300] + beats[301]) / 2
    beats.insert(contentsOf: [half], at: 301)  // a double-time blip
    let e = try #require(TempoEstimate(beatTimes: beats))
    #expect(abs(e.rawBPM - 128) < 0.02)
    #expect(e.isSteady)
  }

  @Test func driftingTempoIsNotSteady() throws {
    // 112 → 136 BPM over five minutes.
    var beats: [Double] = []
    var t = 0.1
    while t < 300 {
      beats.append((t * 50).rounded() / 50)
      t += 60 / (112 + 24 * t / 300)
    }
    let e = try #require(TempoEstimate(beatTimes: beats))
    #expect(!e.isSteady, "\(e.stability)")
  }

  @Test func randomBeatsAreNotSteady() throws {
    var rng = SystemRandomNumberGenerator()
    var t = 0.0
    var beats: [Double] = []
    for _ in 0..<300 {
      t += Double.random(in: 0.2...0.9, using: &rng)
      beats.append(t)
    }
    let e = try #require(TempoEstimate(beatTimes: beats))
    #expect(!e.isSteady, "\(e.stability)")
  }

  @Test func tooFewBeats() {
    #expect(TempoEstimate(beatTimes: [0.5, 1.0, 1.5, 2.0]) == nil)
    #expect(TempoEstimate(beatTimes: []) == nil)
  }

  @Test func peakPicking() {
    var logits = [Float](repeating: -5, count: 100)
    logits[10] = 2; logits[11] = 2  // adjacent equal peaks -> merged at 10.5
    logits[30] = 1; logits[32] = 3  // within ±3 frames -> only 32
    logits[60] = -0.5  // below threshold
    logits[80] = 0.1
    #expect(BeatTracker.pickPeaks(logits) == [10.5, 32, 80])
  }

  @Test func chunkStartsMatchUpstream() {
    // beat_this split_piece(chunk 1500, border 6, avoid_short_end=True)
    #expect(BeatTracker.chunkStarts(frames: 1000) == [-6])
    #expect(BeatTracker.chunkStarts(frames: 1488) == [-6])
    #expect(BeatTracker.chunkStarts(frames: 1489) == [-6, -5])
    #expect(BeatTracker.chunkStarts(frames: 12001) == [-6, 1482, 2970, 4458, 5946, 7434, 8922, 10410, 10507])
  }
}
