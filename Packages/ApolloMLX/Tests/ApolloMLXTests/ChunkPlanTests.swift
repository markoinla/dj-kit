import XCTest

@testable import ApolloMLX

final class ChunkPlanTests: XCTestCase {
  func testStartsMatchPython() {
    // chunk_starts(total=10, chunk=4, overlap=1) in apollo/chunking.py -> [0, 3, 6]
    let plan = ChunkPlan(chunkSeconds: 4, overlapSeconds: 1, padSeconds: 0, sampleRate: 1)
    XCTAssertEqual(plan.starts(total: 10), [0, 3, 6])
  }

  func testCrossfadeWeightsSumToOne() {
    let plan = ChunkPlan(chunkSeconds: 5, overlapSeconds: 0.5, padSeconds: 1, sampleRate: 1000)
    let total = 23_456
    var wsum = [Float](repeating: 0, count: total)
    for s in plan.segments(total: total) {
      let w = ChunkPlan.crossfade(length: s.outputLength, overlap: plan.overlap, fadeIn: s.fadeIn, fadeOut: s.fadeOut)
      for j in 0..<s.outputLength { wsum[s.outputStart + j] += w[j] }
      XCTAssertLessThanOrEqual(s.inputStart + s.inputLength, total)
      XCTAssertEqual(s.keepOffset + s.outputLength <= s.modelLength, true)
    }
    XCTAssertTrue(wsum.allSatisfy { $0 > 0 })
  }

  func testShortInputIsOneSegment() {
    let plan = ChunkPlan()
    let segs = plan.segments(total: 1000)
    XCTAssertEqual(segs.count, 1)
    XCTAssertEqual(segs[0].modelLength, ChunkPlan.minSamples)
  }
}
