import XCTest
import CoreGraphics
@testable import CardScanMagic

final class CardEventCoordinatorTests: XCTestCase {
    func testCardLabelParsing() throws {
        let aceHearts = try XCTUnwrap(CardFace.parse("Ah"))
        XCTAssertEqual(aceHearts.code, "ah")
        XCTAssertEqual(aceHearts.displayText, "A♥")
        XCTAssertEqual(aceHearts.chineseName, "红桃A")
        XCTAssertNil(CardFace.parse("not-a-card"))
    }

    func testOneVisibleCardProducesOnlyOneRecord() throws {
        let coordinator = CardEventCoordinator()
        let aceHearts = try XCTUnwrap(CardFace.parse("Ah"))
        let detection = CardDetection(
            card: aceHearts,
            confidence: 0.90,
            boundingBox: CGRect(x: 0.4, y: 0.3, width: 0.2, height: 0.3)
        )
        let start = Date(timeIntervalSinceReferenceDate: 100)

        XCTAssertTrue(coordinator.process([detection], at: start).isEmpty)
        XCTAssertEqual(coordinator.process([detection], at: start.addingTimeInterval(0.08)).count, 1)
        XCTAssertTrue(coordinator.process([detection], at: start.addingTimeInterval(0.16)).isEmpty)
    }

    func testOrdinaryHighConfidenceCardWaitsForConfirmation() throws {
        let coordinator = CardEventCoordinator()
        let aceHearts = try XCTUnwrap(CardFace.parse("Ah"))
        let detection = CardDetection(
            card: aceHearts,
            confidence: 0.93,
            boundingBox: CGRect(x: 0.4, y: 0.3, width: 0.2, height: 0.3)
        )

        let start = Date(timeIntervalSinceReferenceDate: 100)
        XCTAssertTrue(coordinator.process([detection], at: start).isEmpty)
        XCTAssertEqual(coordinator.process([detection], at: start.addingTimeInterval(0.04)).count, 1)
    }

    func testConflictingLatestHighConfidenceDoesNotOverrideConsensus() throws {
        let coordinator = CardEventCoordinator()
        let aceHearts = try XCTUnwrap(CardFace.parse("Ah"))
        let sevenHearts = try XCTUnwrap(CardFace.parse("7h"))
        let start = Date(timeIntervalSinceReferenceDate: 100)
        let box = CGRect(x: 0.35, y: 0.3, width: 0.2, height: 0.3)

        func detection(_ card: CardFace, _ confidence: Float) -> CardDetection {
            CardDetection(card: card, confidence: confidence, boundingBox: box)
        }

        XCTAssertTrue(coordinator.process([detection(aceHearts, 0.90)], at: start).isEmpty)
        XCTAssertTrue(coordinator.process([detection(aceHearts, 0.91)], at: start.addingTimeInterval(0.04)).isEmpty == false)
        // A later sharp but conflicting label must not create a second record.
        XCTAssertTrue(coordinator.process([detection(sevenHearts, 0.98)], at: start.addingTimeInterval(0.08)).isEmpty)
    }

    func testNextCardOnTheSamePathIsNotSwallowedByRecordedTrack() throws {
        let coordinator = CardEventCoordinator()
        let aceHearts = try XCTUnwrap(CardFace.parse("Ah"))
        let sevenHearts = try XCTUnwrap(CardFace.parse("7h"))
        let start = Date(timeIntervalSinceReferenceDate: 100)
        let box = CGRect(x: 0.35, y: 0.3, width: 0.2, height: 0.3)

        func detection(_ card: CardFace) -> CardDetection {
            CardDetection(card: card, confidence: 0.90, boundingBox: box)
        }

        XCTAssertTrue(coordinator.process([detection(aceHearts)], at: start).isEmpty)
        XCTAssertEqual(coordinator.process([detection(aceHearts)], at: start.addingTimeInterval(0.04)).count, 1)

        // The next physical card follows the same centre path shortly after
        // the first one. It must get a fresh track and a second record.
        XCTAssertTrue(coordinator.process([detection(sevenHearts)], at: start.addingTimeInterval(0.20)).isEmpty)
        XCTAssertEqual(coordinator.process([detection(sevenHearts)], at: start.addingTimeInterval(0.24)).count, 1)
    }

    func testLowConfidenceAndInvalidBoxesAreIgnored() throws {
        let coordinator = CardEventCoordinator()
        let aceHearts = try XCTUnwrap(CardFace.parse("Ah"))
        let start = Date(timeIntervalSinceReferenceDate: 100)

        let low = CardDetection(
            card: aceHearts,
            confidence: 0.2,
            boundingBox: CGRect(x: 0.2, y: 0.2, width: 0.4, height: 0.5)
        )
        let invalid = CardDetection(
            card: aceHearts,
            confidence: 0.9,
            boundingBox: CGRect(x: .infinity, y: 0, width: 0.2, height: 0.3)
        )

        XCTAssertTrue(coordinator.process([low, invalid], at: start).isEmpty)
        XCTAssertTrue(coordinator.process([], at: start.addingTimeInterval(0.04)).isEmpty)
    }

    func testFastMovingBoxStaysOnOneTrack() throws {
        let coordinator = CardEventCoordinator()
        let aceHearts = try XCTUnwrap(CardFace.parse("Ah"))
        let start = Date(timeIntervalSinceReferenceDate: 100)

        func detection(x: CGFloat) -> CardDetection {
            CardDetection(
                card: aceHearts,
                confidence: 0.90,
                boundingBox: CGRect(x: x, y: 0.3, width: 0.16, height: 0.26)
            )
        }

        XCTAssertTrue(coordinator.process([detection(x: 0.02)], at: start).isEmpty)
        XCTAssertEqual(coordinator.process([detection(x: 0.34)], at: start.addingTimeInterval(0.04)).count, 1)
        XCTAssertTrue(coordinator.process([detection(x: 0.66)], at: start.addingTimeInterval(0.08)).isEmpty)
    }

    func testSameFaceIsNotRecordedAgainAfterThePreviousTrackLeaves() throws {
        let coordinator = CardEventCoordinator()
        let aceHearts = try XCTUnwrap(CardFace.parse("Ah"))
        let detection = CardDetection(
            card: aceHearts,
            confidence: 0.90,
            boundingBox: CGRect(x: 0.4, y: 0.3, width: 0.2, height: 0.3)
        )
        let start = Date(timeIntervalSinceReferenceDate: 100)

        _ = coordinator.process([detection], at: start)
        XCTAssertEqual(coordinator.process([detection], at: start.addingTimeInterval(0.08)).count, 1)

        _ = coordinator.process([], at: start.addingTimeInterval(0.8))
        _ = coordinator.process([detection], at: start.addingTimeInterval(0.9))
        XCTAssertTrue(coordinator.process([detection], at: start.addingTimeInterval(0.98)).isEmpty)
    }

    func testDifferentCardsWithTheSameSuitAreBothRecorded() throws {
        let coordinator = CardEventCoordinator()
        let aceHearts = try XCTUnwrap(CardFace.parse("Ah"))
        let sevenHearts = try XCTUnwrap(CardFace.parse("7h"))
        let start = Date(timeIntervalSinceReferenceDate: 100)

        func detection(_ card: CardFace, x: CGFloat) -> CardDetection {
            CardDetection(
                card: card,
                confidence: 0.90,
                boundingBox: CGRect(x: x, y: 0.3, width: 0.2, height: 0.3)
            )
        }

        _ = coordinator.process([detection(aceHearts, x: 0.1)], at: start)
        XCTAssertEqual(coordinator.process([detection(aceHearts, x: 0.1)], at: start.addingTimeInterval(0.08)).count, 1)
        _ = coordinator.process([], at: start.addingTimeInterval(0.8))

        _ = coordinator.process([detection(sevenHearts, x: 0.7)], at: start.addingTimeInterval(0.9))
        XCTAssertEqual(coordinator.process([detection(sevenHearts, x: 0.7)], at: start.addingTimeInterval(0.98)).count, 1)
    }

    func testOverlayOnlyContainsAConfirmedTrack() throws {
        let coordinator = CardEventCoordinator()
        let aceHearts = try XCTUnwrap(CardFace.parse("Ah"))
        let detection = CardDetection(
            card: aceHearts,
            confidence: 0.92,
            boundingBox: CGRect(x: 0.4, y: 0.3, width: 0.2, height: 0.3)
        )
        let start = Date(timeIntervalSinceReferenceDate: 100)

        let first = coordinator.processUpdate([detection], at: start)
        XCTAssertTrue(first.records.isEmpty)
        XCTAssertTrue(first.stableDetections.isEmpty)

        let second = coordinator.processUpdate(
            [detection],
            at: start.addingTimeInterval(0.04)
        )
        XCTAssertEqual(second.records.map(\.card), [aceHearts])
        XCTAssertEqual(second.stableDetections.map(\.card), [aceHearts])
    }

    func testCardCornerDetectionIsAcceptedAndConfirmed() throws {
        let coordinator = CardEventCoordinator()
        let sevenDiamonds = try XCTUnwrap(CardFace.parse("7d"))
        // The upstream model returns a small rank/suit corner box rather than
        // a rectangle around the whole physical card.
        let detection = CardDetection(
            card: sevenDiamonds,
            confidence: 0.70,
            boundingBox: CGRect(x: 0.55, y: 0.25, width: 0.04, height: 0.06)
        )
        let start = Date(timeIntervalSinceReferenceDate: 300)

        let first = coordinator.processUpdate([detection], at: start)
        XCTAssertTrue(first.records.isEmpty)
        XCTAssertTrue(first.stableDetections.isEmpty)

        let second = coordinator.processUpdate(
            [detection],
            at: start.addingTimeInterval(0.04)
        )
        XCTAssertEqual(second.records.map(\.card), [sevenDiamonds])
        XCTAssertEqual(second.stableDetections.map(\.card), [sevenDiamonds])
    }

    func testTwoStableCornerBoxesForOneFaceProduceOneOverlayAndRecord() throws {
        let coordinator = CardEventCoordinator()
        let fourClubs = try XCTUnwrap(CardFace.parse("4c"))
        let leftBox = CGRect(x: 0.15, y: 0.20, width: 0.04, height: 0.06)
        let rightBox = CGRect(x: 0.75, y: 0.20, width: 0.04, height: 0.06)
        let detections = [
            CardDetection(card: fourClubs, confidence: 0.72, boundingBox: leftBox),
            CardDetection(card: fourClubs, confidence: 0.70, boundingBox: rightBox)
        ]
        let start = Date(timeIntervalSinceReferenceDate: 400)

        XCTAssertTrue(coordinator.processUpdate(detections, at: start).records.isEmpty)
        let second = coordinator.processUpdate(
            detections,
            at: start.addingTimeInterval(0.04)
        )

        // A card can expose both its rank and suit corners. They are separate
        // tracks internally, but must not become duplicate UI/history entries.
        XCTAssertEqual(second.records.map(\.card), [fourClubs])
        XCTAssertEqual(second.stableDetections.map(\.card), [fourClubs])
    }

}
