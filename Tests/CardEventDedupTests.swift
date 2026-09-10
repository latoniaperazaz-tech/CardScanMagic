import XCTest
@testable import CardScanMagic

final class CardEventDedupTests: XCTestCase {
    private func detection(_ code: String = "10c", x: CGFloat = 0.3,
                           supported: Bool = true) -> CardDetection {
        CardDetection(card: CardFace.parse(code)!, confidence: 0.94,
            boundingBox: CGRect(x: x, y: 0.3, width: 0.2, height: 0.3), hasIndependentSupport: supported)
    }
    private func date(_ t: Double) -> Date { Date(timeIntervalSinceReferenceDate: 100 + t) }
    func testFiveFramesProduceOnePhysicalEventDecisionAndRecord() {
        let coordinator = CardEventCoordinator()
        let updates = (0..<5).map { coordinator.processUpdate([detection()], at: date(Double($0) / 60)) }
        XCTAssertEqual(updates.flatMap(\.decisions).count, 1)
        XCTAssertEqual(updates.flatMap(\.records).count, 1)
        XCTAssertEqual(Set(updates.flatMap(\.decisions).map(\.eventID)).count, 1)
        XCTAssertEqual(coordinator.trackCaptureMemberships.count, 1)
        XCTAssertEqual(coordinator.trackCaptureMemberships.values.first?.count, 5)
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
        XCTAssertEqual(coordinator.trackCaptureMemberships.count, 1)
        XCTAssertEqual(coordinator.trackCaptureMemberships[first.decisions[0].eventID]?.count, 2)
    }
    func testLabelJitterRemainsOneTrackAndOneDecision() {
        let coordinator = CardEventCoordinator()
        var updates: [CardEventUpdate] = []
        for (index, code) in ["10c", "9c", "10c", "10c", "10c"].enumerated() {
            updates.append(coordinator.processUpdate([detection(code)], at: date(Double(index) / 60)))
        }
        XCTAssertEqual(updates.flatMap(\.decisions).count, 1)
        XCTAssertEqual(updates.flatMap(\.records).map(\.card.code), ["10c"])
        XCTAssertEqual(coordinator.trackCaptureMemberships.count, 1)
    }
    func testLabelJitterBeforeFirstConfirmationStillHasOneTrack() {
        let coordinator = CardEventCoordinator()
        var updates: [CardEventUpdate] = []
        for (index, code) in ["10c", "9c", "10c", "10c", "10c"].enumerated() {
            updates.append(coordinator.processUpdate([detection(code, supported: false)],
                at: date(Double(index) / 60)))
        }
        XCTAssertTrue(updates[0].decisions.isEmpty)
        XCTAssertTrue(updates[1].decisions.isEmpty)
        XCTAssertEqual(updates.flatMap(\.decisions).count, 1)
        XCTAssertEqual(updates.flatMap(\.records).map(\.card.code), ["10c"])
        XCTAssertEqual(coordinator.trackCaptureMemberships.count, 1)
        XCTAssertEqual(coordinator.trackCaptureMemberships.values.first?.count, 5)
    }
    func testUnresolvedLabelChangeCannotRewriteAConfirmedPhysicalPass() {
        let coordinator = CardEventCoordinator()
        let first = coordinator.processUpdate([detection()], at: date(0))
        for index in 1...6 {
            let update = coordinator.processUpdate([detection("9h")], at: date(Double(index) / 60))
            XCTAssertTrue(update.decisions.isEmpty)
            XCTAssertTrue(update.records.isEmpty)
            XCTAssertEqual(update.stableDetections.map(\.card.code), ["10c"])
        }
        XCTAssertEqual(coordinator.trackCaptureMemberships.count, 1)
        XCTAssertEqual(coordinator.trackCaptureMemberships[first.decisions[0].eventID]?.count, 7)
    }
    func testAdjacentOverlappingEntrantBreaksPreviousMovementAndKeepsVotesSeparate() {
        let coordinator = CardEventCoordinator()
        let first = coordinator.processUpdate([detection("10c", x: 0.5)], at: date(0))
        _ = coordinator.processUpdate([detection("10c", x: 0.58)], at: date(0.04))
        _ = coordinator.processUpdate([detection("10c", x: 0.66)], at: date(0.08))
        // A following card re-enters behind the moving target while their
        // boxes still overlap. It must not borrow the first card's support.
        let entered = coordinator.processUpdate([detection("9h", x: 0.60, supported: false)], at: date(0.12))
        XCTAssertTrue(entered.decisions.isEmpty)
        let second = coordinator.processUpdate([detection("9h", x: 0.68, supported: false)], at: date(0.16))
        XCTAssertEqual(second.records.map(\.card.code), ["9h"])
        XCTAssertNotEqual(first.decisions.first?.eventID, second.decisions.first?.eventID)
        XCTAssertEqual(coordinator.trackCaptureMemberships.count, 2)
        XCTAssertEqual(first.decisions.count, 1)
        XCTAssertEqual(second.decisions[0].captureTimestamps, Set([100.12, 100.16]))
    }
    func testRepeatedRecognitionCallbackNeverCreatesSecondDecision() {
        let timeline = CardResultTimeline()
        XCTAssertEqual(timeline.insert(frameID: 1, timestamp: 100, detections: [detection()]).decisions.count, 1)
        for _ in 0..<5 {
            let update = timeline.insert(frameID: 1, timestamp: 100, detections: [detection()])
            XCTAssertTrue(update.decisions.isEmpty); XCTAssertTrue(update.records.isEmpty)
        }
    }
    func testOneVisibleCardCanReverseDirectionWithoutAnotherDecision() {
        let coordinator = CardEventCoordinator()
        var decisions: [CardPassDecision] = []
        for (index, x) in [0.50, 0.58, 0.66, 0.60, 0.54].enumerated() {
            decisions += coordinator.processUpdate([detection(x: CGFloat(x))],
                at: date(Double(index) * 0.04)).decisions
        }
        XCTAssertEqual(decisions.count, 1)
        XCTAssertEqual(coordinator.trackCaptureMemberships.count, 1)
    }
    func testSimultaneousEntrantDoesNotCloseStillVisibleFirstCardInEitherOrder() {
        for entrantFirst in [true, false] {
            let coordinator = CardEventCoordinator()
            let first = coordinator.processUpdate([detection(x: 0.50)], at: date(0))
            _ = coordinator.processUpdate([detection(x: 0.58)], at: date(0.04))
            _ = coordinator.processUpdate([detection(x: 0.66)], at: date(0.08))
            let entrant = CardDetection(card: CardFace.parse("9h")!,
                confidence: entrantFirst ? 0.96 : 0.90,
                boundingBox: CGRect(x: 0.60, y: 0.3, width: 0.2, height: 0.3),
                hasIndependentSupport: true)
            let update = coordinator.processUpdate([entrant, detection(x: 0.74)], at: date(0.12))
            XCTAssertEqual(update.decisions.map(\.record.card.code), ["9h"])
            XCTAssertEqual(update.records.map(\.card.code), ["9h"])
            XCTAssertEqual(coordinator.trackCaptureMemberships.count, 2)
            XCTAssertEqual(coordinator.trackCaptureMemberships[first.decisions[0].eventID]?.count, 4)
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
