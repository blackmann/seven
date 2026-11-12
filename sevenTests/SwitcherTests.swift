import XCTest
@testable import seven

final class SwitcherTests: XCTestCase {
    func testDiscreteWheelSelectsDirectionalModes() {
        var scroll = ScrollSelector()
        XCTAssertEqual(scroll.selection(delta: -1, precise: false, momentum: false, timestamp: 1), .notes)
        XCTAssertEqual(scroll.selection(delta: 1, precise: false, momentum: false, timestamp: 2), .text)
    }

    func testTrackpadRequiresIntentAndIgnoresMomentum() {
        var scroll = ScrollSelector()
        XCTAssertNil(scroll.selection(delta: -2, precise: true, momentum: false, timestamp: 1))
        XCTAssertNil(scroll.selection(delta: -3, precise: true, momentum: false, timestamp: 1.01))
        XCTAssertEqual(scroll.selection(delta: -3, precise: true, momentum: false, timestamp: 1.02), .notes)
        XCTAssertNil(scroll.selection(delta: 40, precise: true, momentum: true, timestamp: 1.03))
    }

    func testDirectionChangeDiscardsOldDeltas() {
        var scroll = ScrollSelector()
        XCTAssertNil(scroll.selection(delta: 6, precise: true, momentum: false, timestamp: 1))
        XCTAssertEqual(scroll.selection(delta: -8, precise: true, momentum: false, timestamp: 1.01), .notes)
    }

    func testSeparateGesturesDoNotAccumulateNoise() {
        var scroll = ScrollSelector()
        XCTAssertNil(scroll.selection(delta: 4, precise: true, momentum: false, timestamp: 1))
        XCTAssertNil(scroll.selection(delta: 4, precise: true, momentum: false, timestamp: 2))
        XCTAssertNil(scroll.selection(delta: .nan, precise: true, momentum: false, timestamp: 3))
        XCTAssertNil(scroll.selection(delta: .infinity, precise: true, momentum: false, timestamp: 3))
    }

    func testOptionReleaseCommitsSelection() {
        var session = SwitcherSession(mode: .text)
        session.open(activation: .holdOption)
        session.select(.notes)
        XCTAssertFalse(session.shouldDismiss(isOptionDown: true))
        XCTAssertTrue(session.shouldDismiss(isOptionDown: false))
        session.close()
        XCTAssertEqual(session.mode, .notes)
        XCTAssertFalse(session.isVisible)
    }

    func testCancelRestoresModeAtStartOfEachSession() {
        var session = SwitcherSession(mode: .text)
        session.open(activation: .holdOption)
        session.select(.notes)
        session.close(cancelled: true)
        XCTAssertEqual(session.mode, .text)
        session.open(activation: .toggle)
        session.select(.notes)
        session.close()
        session.open(activation: .toggle)
        session.select(.text)
        session.close(cancelled: true)
        XCTAssertEqual(session.mode, .notes)
    }

    func testToggleModeSurvivesOptionRelease() {
        var session = SwitcherSession(mode: .text)
        session.open(activation: .toggle)
        XCTAssertFalse(session.shouldDismiss(isOptionDown: false))
        XCTAssertTrue(session.isVisible)
        session.close()
        XCTAssertFalse(session.isVisible)
    }
}
