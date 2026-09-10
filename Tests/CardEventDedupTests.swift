import XCTest
@testable import CardScanMagic

final class CardEventDedupTests: XCTestCase {
    private func detection(_ code: String = "10c", x: CGFloat = 0.3) -> CardDetection {
        CardDetection(card: CardFace.parse(code)!, confidence: 0.94,
            boundingBox: CGRect(x: x, y: 0.3, width: 0.2, height: 0.3), hasIndependentSupport: true)
    }
    private func date(_ t: Double) -> Date { Date(timeIntervalSinceReferenceDate: 100 + t) }
    func testFiveFramesProduceOnePhysicalEventDecisionAndRecord() {
        let coordinator = CardEventCoordinator()
        let updates = (0..<5).map { coordinator.processUpdate([detection()], at: date(Double($0) / 60)) }
        XCTAssertEqual(updates.flatMap(\.decisions).count, 1)
        XCTAssertEqual(updates.flatMap(\.records).count, 1)
        XCTAssertEqual(Set(updates.flatMap(\.decisions).map(\.eventID)).count, 1)
    }
    func testTwoMissedDetectionsDoNotSplitContinuousTrack() {
        let coordinator = CardEventCoordinator()
        let first = coordinator.processUpdate([detection(x: 0.2)], at: date(0))
        _ = coordinator.processUpdate([], at: date(0.016))
        _ = coordinator.processUpdate([], at: date(0.033))
        let recovered = coordinator.processUpdate([detection(x: 0.22)], at: date(0.050))
        XCTAssertEqual(first.decisions.count, 1)
        XCTAssertTrue(recovered.decisions.isEmpty)
        XCTAssertTrue(recovered.records.isEmpty)
    }
    func testLabelJitterRemainsOneTrackAndOneDecision() {
        let coordinator = CardEventCoordinator()
        var updates: [CardEventUpdate] = []
        for (index, code) in ["10c", "9c", "10c", "10c", "10c"].enumerated() {
            updates.append(coordinator.processUpdate([detection(code)], at: date(Double(index) / 60)))
        }
        XCTAssertEqual(updates.flatMap(\.decisions).count, 1)
        XCTAssertEqual(updates.flatMap(\.records).map(\.card.code), ["10c"])
    }
    func testRepeatedRecognitionCallbackNeverCreatesSecondDecision() {
        let timeline = CardResultTimeline()
        XCTAssertEqual(timeline.insert(frameID: 1, timestamp: 100, detections: [detection()]).decisions.count, 1)
        for _ in 0..<5 {
            let update = timeline.insert(frameID: 1, timestamp: 100, detections: [detection()])
            XCTAssertTrue(update.decisions.isEmpty); XCTAssertTrue(update.records.isEmpty)
        }
    }
    func testReappearanceCreatesDebugEventButSessionRejectsDuplicateCard() {
        let coordinator = CardEventCoordinator()
        let first = coordinator.processUpdate([detection()], at: date(0))
        _ = coordinator.processUpdate([], at: date(0.5))
        let second = coordinator.processUpdate([detection()], at: date(0.6))
        XCTAssertEqual(first.records.count, 1)
        XCTAssertEqual(second.decisions.count, 1)
        XCTAssertTrue(second.decisions.first?.duplicateCard == true)
        XCTAssertNotEqual(first.decisions.first?.eventID, second.decisions.first?.eventID)
        XCTAssertTrue(second.records.isEmpty)
    }
    func testAdjacentDifferentCardsHaveSeparatePhysicalDecisions() {
        let coordinator = CardEventCoordinator()
        let first = coordinator.processUpdate([detection("10c", x: 0.7)], at: date(0))
        let second = coordinator.processUpdate([detection("9h", x: 0.05)], at: date(0.04))
        XCTAssertEqual(first.records.map(\.card.code), ["10c"])
        XCTAssertEqual(second.records.map(\.card.code), ["9h"])
        XCTAssertNotEqual(first.decisions.first?.eventID, second.decisions.first?.eventID)
    }
    func testHistoricalResultIsAnalyzedInCaptureOrderWithoutDuplicatingPublishedPass() {
        let timeline = CardResultTimeline()
        let first = timeline.insert(frameID: 3, timestamp: 100.03, detections: [detection()])
        XCTAssertEqual(first.decisions.count, 1)
        let earlier = timeline.insert(frameID: 2, timestamp: 100.02, detections: [detection()])
        XCTAssertTrue(earlier.decisions.isEmpty)
        XCTAssertTrue(earlier.records.isEmpty)
        XCTAssertEqual(timeline.insert(frameID: 4, timestamp: 100.04, detections: [detection()]).decisions.count, 0)
    }
    func testWeakVotesFromSeparatePassesCannotBeCombined() {
        let timeline = CardResultTimeline()
        let weak = CardDetection(card: CardFace.parse("10c")!, confidence: 0.7,
            boundingBox: CGRect(x: 0.3, y: 0.3, width: 0.2, height: 0.3))
        XCTAssertTrue(timeline.insert(frameID: 1, timestamp: 100, detections: [weak]).records.isEmpty)
        XCTAssertTrue(timeline.insert(frameID: 2, timestamp: 100.5, detections: []).records.isEmpty)
        XCTAssertTrue(timeline.insert(frameID: 3, timestamp: 100.6, detections: [weak]).records.isEmpty)
    }
}
