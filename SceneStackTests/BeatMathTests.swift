import XCTest
@testable import SceneStack

/// Pure transport/beat math — the timing logic clip launching, recording, and
/// scene reordering depend on.
final class BeatMathTests: XCTestCase {

    // MARK: - Quantised launch boundary

    func testQuantizeNoneReturnsBeatsPlusLead() {
        // With no quantise, the boundary is just now + the schedule lead.
        let result = BeatMath.quantizedBoundary(afterBeats: 3.2, tempo: 120,
                                                beatsPerBar: 4, quantize: .none)
        let lead = 0.05 * 120 / 60
        XCTAssertEqual(result, 3.2 + lead, accuracy: 1e-9)
    }

    func testQuantizeToBeatRoundsUp() {
        let result = BeatMath.quantizedBoundary(afterBeats: 2.1, tempo: 120,
                                                beatsPerBar: 4, quantize: .beat)
        XCTAssertEqual(result, 3, accuracy: 1e-9)
    }

    func testQuantizeToBarRoundsUpToBarMultiple() {
        // 5.1 beats in 4/4 → next bar boundary is beat 8.
        let result = BeatMath.quantizedBoundary(afterBeats: 5.1, tempo: 120,
                                                beatsPerBar: 4, quantize: .bar)
        XCTAssertEqual(result, 8, accuracy: 1e-9)
    }

    func testQuantizeFromStoppedClampsNegativeBeats() {
        // A negative clock (pre-roll) shouldn't push the boundary before 0.
        let result = BeatMath.quantizedBoundary(afterBeats: -3, tempo: 120,
                                                beatsPerBar: 4, quantize: .bar)
        XCTAssertGreaterThanOrEqual(result, 0)
        XCTAssertLessThanOrEqual(result, 4)
    }

    // MARK: - Recorded bar count

    func testRecordedBarsUsesFixedLengthVerbatim() {
        // Even a take cut short keeps the chosen fixed length.
        XCTAssertEqual(BeatMath.recordedBars(beatsRecorded: 2.5, beatsPerBar: 4, fixed: 4), 4)
    }

    func testRecordedBarsFreeRoundsUpToWholeBars() {
        // 5 beats in 4/4 → rounds up to 2 bars.
        XCTAssertEqual(BeatMath.recordedBars(beatsRecorded: 5, beatsPerBar: 4, fixed: nil), 2)
    }

    func testRecordedBarsFreeIsAtLeastOneBar() {
        XCTAssertEqual(BeatMath.recordedBars(beatsRecorded: 0.5, beatsPerBar: 4, fixed: nil), 1)
    }

    func testRecordedBarsFreeAllowsBoundaryEpsilon() {
        // A take a hair short of exactly 4 bars still counts as 4.
        XCTAssertEqual(BeatMath.recordedBars(beatsRecorded: 15.98, beatsPerBar: 4, fixed: nil), 4)
    }

    // MARK: - Scene reorder index mapping

    func testSceneMoveDownRemapsIntermediateRows() {
        // Move row 0 to 2: [A,B,C,D] -> [B,C,A,D]
        XCTAssertEqual(BeatMath.sceneIndexAfterMove(0, from: 0, to: 2), 2) // the moved row
        XCTAssertEqual(BeatMath.sceneIndexAfterMove(1, from: 0, to: 2), 0)
        XCTAssertEqual(BeatMath.sceneIndexAfterMove(2, from: 0, to: 2), 1)
        XCTAssertEqual(BeatMath.sceneIndexAfterMove(3, from: 0, to: 2), 3) // untouched
    }

    func testSceneMoveUpRemapsIntermediateRows() {
        // Move row 3 to 1: [A,B,C,D] -> [A,D,B,C]
        XCTAssertEqual(BeatMath.sceneIndexAfterMove(3, from: 3, to: 1), 1) // the moved row
        XCTAssertEqual(BeatMath.sceneIndexAfterMove(1, from: 3, to: 1), 2)
        XCTAssertEqual(BeatMath.sceneIndexAfterMove(2, from: 3, to: 1), 3)
        XCTAssertEqual(BeatMath.sceneIndexAfterMove(0, from: 3, to: 1), 0) // untouched
    }

    func testSceneMoveIsInvertible() {
        // Applying the inverse move restores every index.
        for index in 0..<6 {
            let moved = BeatMath.sceneIndexAfterMove(index, from: 1, to: 4)
            let back = BeatMath.sceneIndexAfterMove(moved, from: 4, to: 1)
            XCTAssertEqual(back, index, "index \(index) did not round-trip")
        }
    }
}
