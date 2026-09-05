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
            confidence: 0.74,
            boundingBox: CGRect(x: 0.4, y: 0.3, width: 0.2, height: 0.3)
        )
        let start = Date(timeIntervalSinceReferenceDate: 100)

        XCTAssertTrue(coordinator.process([detection], at: start).isEmpty)
        XCTAssertEqual(coordinator.process([detection], at: start.addingTimeInterval(0.08)).count, 1)
        XCTAssertTrue(coordinator.process([detection], at: start.addingTimeInterval(0.16)).isEmpty)
    }

    func testVeryHighConfidenceCardRecordsOnTheFirstFrame() throws {
        let coordinator = CardEventCoordinator()
        let aceHearts = try XCTUnwrap(CardFace.parse("Ah"))
        let detection = CardDetection(
            card: aceHearts,
            confidence: 0.93,
            boundingBox: CGRect(x: 0.4, y: 0.3, width: 0.2, height: 0.3)
        )

        XCTAssertEqual(
            coordinator.process([detection], at: Date(timeIntervalSinceReferenceDate: 100)).count,
            1
        )
    }

    func testSameFaceIsNotRecordedAgainAfterThePreviousTrackLeaves() throws {
        let coordinator = CardEventCoordinator()
        let aceHearts = try XCTUnwrap(CardFace.parse("Ah"))
        let detection = CardDetection(
            card: aceHearts,
            confidence: 0.74,
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
                confidence: 0.74,
                boundingBox: CGRect(x: x, y: 0.3, width: 0.2, height: 0.3)
            )
        }

        _ = coordinator.process([detection(aceHearts, x: 0.1)], at: start)
        XCTAssertEqual(coordinator.process([detection(aceHearts, x: 0.1)], at: start.addingTimeInterval(0.08)).count, 1)
        _ = coordinator.process([], at: start.addingTimeInterval(0.8))

        _ = coordinator.process([detection(sevenHearts, x: 0.7)], at: start.addingTimeInterval(0.9))
        XCTAssertEqual(coordinator.process([detection(sevenHearts, x: 0.7)], at: start.addingTimeInterval(0.98)).count, 1)
    }

}
