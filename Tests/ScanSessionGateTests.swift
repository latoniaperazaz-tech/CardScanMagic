import XCTest
@testable import CardScanMagic

final class ScanSessionGateTests: XCTestCase {
    func testStartedSessionCannotSampleUntilCoordinatorIsReady() {
        let gate = ScanSessionGate()
        let sessionID = gate.start()

        XCTAssertNil(gate.activeSessionForSampling())
        XCTAssertFalse(gate.canStartInference(for: sessionID))
        XCTAssertTrue(gate.shouldResetCoordinator(for: sessionID))
        XCTAssertTrue(gate.markCoordinatorReady(for: sessionID))
        XCTAssertEqual(gate.activeSessionForSampling(), sessionID)
    }

    func testStoppingRejectsAnInFlightResult() {
        let gate = ScanSessionGate()
        let sessionID = readySession(in: gate)
        XCTAssertTrue(gate.beginInference(for: sessionID))

        gate.stop()

        XCTAssertFalse(gate.shouldDeliver(for: sessionID))
        XCTAssertFalse(gate.failCurrentSession(for: sessionID))
        XCTAssertNil(gate.activeSessionForSampling())
        gate.finishInference()
    }

    func testResetInvalidatesOldResultAndWaitsForItBeforeStartingNewInference() throws {
        let gate = ScanSessionGate()
        let firstSessionID = readySession(in: gate)
        XCTAssertTrue(gate.beginInference(for: firstSessionID))

        let secondSessionID = try XCTUnwrap(gate.resetRecordedState())

        XCTAssertNotEqual(firstSessionID, secondSessionID)
        XCTAssertFalse(gate.shouldDeliver(for: firstSessionID))
        XCTAssertFalse(gate.failCurrentSession(for: firstSessionID))
        XCTAssertNil(gate.activeSessionForSampling())
        XCTAssertTrue(gate.shouldResetCoordinator(for: secondSessionID))
        XCTAssertTrue(gate.markCoordinatorReady(for: secondSessionID))
        XCTAssertFalse(gate.canStartInference(for: secondSessionID))

        gate.finishInference()
        XCTAssertTrue(gate.canStartInference(for: secondSessionID))
    }

    func testRestartRejectsErrorFromFormerSession() {
        let gate = ScanSessionGate()
        let firstSessionID = readySession(in: gate)

        let secondSessionID = gate.start()

        XCTAssertNotEqual(firstSessionID, secondSessionID)
        XCTAssertFalse(gate.shouldDeliver(for: firstSessionID))
        XCTAssertFalse(gate.failCurrentSession(for: firstSessionID))
        XCTAssertTrue(gate.markCoordinatorReady(for: secondSessionID))
        XCTAssertTrue(gate.shouldDeliver(for: secondSessionID))
    }

    private func readySession(in gate: ScanSessionGate) -> ScanSessionGate.SessionID {
        let sessionID = gate.start()
        XCTAssertTrue(gate.markCoordinatorReady(for: sessionID))
        return sessionID
    }
}
