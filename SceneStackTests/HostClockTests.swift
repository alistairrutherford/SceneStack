import XCTest
@testable import SceneStack

/// mach host-time ⇄ seconds conversions used for sample-accurate scheduling.
final class HostClockTests: XCTestCase {

    func testTicksAndSecondsRoundTrip() {
        for seconds in [0.02, 0.1, 0.5, 1.0, 2.75] {
            let ticks = HostClock.ticks(forSeconds: seconds)
            let back = HostClock.seconds(fromTicks: ticks)
            XCTAssertEqual(back, seconds, accuracy: 1e-4, "\(seconds)s did not round-trip")
        }
    }

    func testZeroSecondsIsZeroTicks() {
        XCTAssertEqual(HostClock.ticks(forSeconds: 0), 0)
    }

    func testLongerDurationIsMoreTicks() {
        XCTAssertGreaterThan(HostClock.ticks(forSeconds: 1.0),
                             HostClock.ticks(forSeconds: 0.5))
    }

    func testNowAdvances() {
        let first = HostClock.now
        // Busy-wait a touch so the clock is guaranteed to move.
        var spin = 0
        while HostClock.now == first { spin += 1; if spin > 1_000_000 { break } }
        XCTAssertGreaterThan(HostClock.now, first)
    }
}
