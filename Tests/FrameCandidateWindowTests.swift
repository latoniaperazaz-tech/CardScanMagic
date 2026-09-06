import Foundation
import XCTest
@testable import CardScanMagic

final class FrameCandidateWindowTests: XCTestCase {
    func testKeepsRecentCandidateWhenItIsSharpEnough() {
        var window = FrameCandidateWindow(maximumAge: 0.075, recencySharpnessRatio: 0.72)

        XCTAssertTrue(window.insert(timestamp: 10, sharpness: 100))
        XCTAssertTrue(window.insert(timestamp: 10.02, sharpness: 72))

        XCTAssertEqual(
            window.candidate,
            FrameCandidateMetadata(timestamp: 10.02, sharpness: 72)
        )
    }

    func testKeepsSharperEarlierCandidateWhenNewFrameIsTooSoft() {
        var window = FrameCandidateWindow(maximumAge: 0.075, recencySharpnessRatio: 0.72)

        XCTAssertTrue(window.insert(timestamp: 10, sharpness: 100))
        XCTAssertFalse(window.insert(timestamp: 10.02, sharpness: 71.9))

        XCTAssertEqual(
            window.candidate,
            FrameCandidateMetadata(timestamp: 10, sharpness: 100)
        )
    }

    func testDiscardExpiredCandidateAtSeventyFiveMilliseconds() {
        var window = FrameCandidateWindow(maximumAge: 0.075)
        XCTAssertTrue(window.insert(timestamp: 10, sharpness: 100))

        XCTAssertNotNil(window.take(at: 10.075))

        XCTAssertTrue(window.insert(timestamp: 20, sharpness: 100))
        XCTAssertNil(window.take(at: 20.0751))
    }

    func testTakeClearsTheWindow() {
        var window = FrameCandidateWindow()
        XCTAssertTrue(window.insert(timestamp: 10, sharpness: 25))

        XCTAssertEqual(
            window.take(at: 10.01),
            FrameCandidateMetadata(timestamp: 10, sharpness: 25)
        )
        XCTAssertNil(window.take(at: 10.02))
    }

    func testRejectsOutOfOrderAndInvalidFrames() {
        var window = FrameCandidateWindow()

        XCTAssertFalse(window.insert(timestamp: .infinity, sharpness: 50))
        XCTAssertFalse(window.insert(timestamp: 10, sharpness: -1))
        XCTAssertTrue(window.insert(timestamp: 10, sharpness: 25))
        XCTAssertFalse(window.insert(timestamp: 9.99, sharpness: 50))
        XCTAssertEqual(window.candidate, FrameCandidateMetadata(timestamp: 10, sharpness: 25))
    }

    func testRecentModeratelySofterForegroundFrameSupersedesOldBackground() {
        var window = FrameCandidateWindow(maximumAge: 0.055, recencySharpnessRatio: 0.55)

        XCTAssertTrue(window.insert(timestamp: 10, sharpness: 100))
        // A close card can lower global luma sharpness while it is still
        // readable. Prefer this fresh card frame over an older empty table.
        XCTAssertTrue(window.insert(timestamp: 10.025, sharpness: 58))

        XCTAssertEqual(
            window.candidate,
            FrameCandidateMetadata(timestamp: 10.025, sharpness: 58)
        )
    }
}
