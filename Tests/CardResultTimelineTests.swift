import CoreGraphics
import XCTest
@testable import CardScanMagic

final class CardResultTimelineTests: XCTestCase {
    private func detection(_ code: String = "10c") -> CardDetection {
        CardDetection(card: CardFace.parse(code)!, confidence: 0.94,
            boundingBox: CGRect(x: 0.3, y: 0.3, width: 0.2, height: 0.3),
            hasIndependentSupport: true)
    }

    func testEmptyResultsAfterFourSecondsDoNotRepublishRetiredPass() {
        let timeline = CardResultTimeline()
        let first = timeline.insert(frameID: 1, timestamp: 100, detections: [detection()])
        XCTAssertEqual(first.decisions.count, 1)
        XCTAssertEqual(first.records.count, 1)

        // The retained history still contains the first card, while the legacy
        // coordinator has already discarded its retired track's footprint.
        for index in 0..<5 {
            let update = timeline.insert(frameID: UInt64(index + 2),
                timestamp: 105 + Double(index) / 60, detections: [])
            XCTAssertTrue(update.decisions.isEmpty)
            XCTAssertTrue(update.records.isEmpty)
        }
    }

    func testOutOfOrderLabelJitterKeepsOnePublishedDecision() {
        let timeline = CardResultTimeline()
        let first = timeline.insert(frameID: 3, timestamp: 100.04, detections: [detection()])
        XCTAssertEqual(first.decisions.count, 1)
        let earlier = timeline.insert(frameID: 1, timestamp: 100, detections: [detection()])
        let flicker = timeline.insert(frameID: 2, timestamp: 100.02, detections: [detection("9c")])
        let recovered = timeline.insert(frameID: 4, timestamp: 100.06, detections: [detection()])

        XCTAssertTrue((earlier.decisions + flicker.decisions + recovered.decisions).isEmpty)
        XCTAssertTrue((earlier.records + flicker.records + recovered.records).isEmpty)
    }

    func testLongLivedPassSurvivesCheckpointAndLaterHistoryInsertion() {
        let timeline = CardResultTimeline()
        var decisions: [CardPassDecision] = []
        var records: [CardRecord] = []
        // More than both the 180-result replay window and the coordinator's
        // 240-observation window. Later frames must refresh published identity
        // even though the checkpoint's confirmed track emits no new decision.
        for index in 0..<500 {
            if index == 450 { continue }
            let update = timeline.insert(frameID: UInt64(index + 1),
                timestamp: 100 + Double(index) / 60, detections: [detection()])
            decisions.append(contentsOf: update.decisions)
            records.append(contentsOf: update.records)
        }
        let historical = timeline.insert(frameID: 451, timestamp: 107.5,
                                         detections: [detection("9c")])
        XCTAssertTrue(historical.decisions.isEmpty)
        XCTAssertTrue(historical.records.isEmpty)
        XCTAssertEqual(decisions.count, 1)
        XCTAssertEqual(records.map(\.card.code), ["10c"])

        // An actually finished track may reappear as a new Debug event, but
        // the session identity guard still owns permanent card-value dedup.
        _ = timeline.insert(frameID: 501, timestamp: 109, detections: [])
        let reappearance = timeline.insert(frameID: 502, timestamp: 109.1, detections: [detection()])
        XCTAssertEqual(reappearance.decisions.count, 1)
        XCTAssertTrue(reappearance.decisions.first?.duplicateCard == true)
        XCTAssertNotEqual(decisions.first?.eventID, reappearance.decisions.first?.eventID)
        XCTAssertTrue(reappearance.records.isEmpty)
    }

    func testReappearanceAfterRetirementGetsNewDebugIdentityWithoutSecondRecord() {
        let timeline = CardResultTimeline()
        let first = timeline.insert(frameID: 1, timestamp: 100, detections: [detection()])
        _ = timeline.insert(frameID: 2, timestamp: 105, detections: [])
        let second = timeline.insert(frameID: 3, timestamp: 105.1, detections: [detection()])
        XCTAssertEqual(first.records.count, 1)
        XCTAssertEqual(second.decisions.count, 1)
        XCTAssertTrue(second.decisions.first?.duplicateCard == true)
        XCTAssertNotEqual(first.decisions.first?.eventID, second.decisions.first?.eventID)
        XCTAssertTrue(second.records.isEmpty)

        let repeatFrame = timeline.insert(frameID: 4, timestamp: 105.12, detections: [detection()])
        XCTAssertTrue(repeatFrame.decisions.isEmpty)
        XCTAssertTrue(repeatFrame.records.isEmpty)
    }
}
