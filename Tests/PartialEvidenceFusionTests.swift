import CoreGraphics
import XCTest
@testable import CardScanMagic

final class PartialEvidenceFusionTests: XCTestCase {
    private let box = CGRect(x: 0.2, y: 0.2, width: 0.4, height: 0.6)
    private let size = CGSize(width: 1080, height: 1920)

    func testModelAndLocalLayoutConfirmOneCapture() throws {
        let result = fuse(model: [detection("5d", confidence: 0.92)], local: [evidence()])
        let found = try XCTUnwrap(result.first)
        XCTAssertEqual(found.card.code, "5d")
        XCTAssertTrue(found.hasIndependentSupport)
        XCTAssertGreaterThanOrEqual(found.confidence, 0.85)
        let coordinator = CardEventCoordinator()
        XCTAssertEqual(coordinator.processUpdate(result, at: Date()).records.count, 1)
    }

    func testStrongLayoutAndSuitWorkWithoutModelOrReadableDigit() throws {
        let result = fuse(local: [evidence()])
        let found = try XCTUnwrap(result.first)
        XCTAssertEqual(found.card.code, "5d")
        XCTAssertTrue(found.hasIndependentSupport)
        XCTAssertEqual(CardEventCoordinator().processUpdate(result, at: Date()).records.count, 1)
    }

    func testModelOnlyDoesNotAcquireIndependentSupport() {
        let result = fuse(model: [detection("5d", confidence: 0.96)])
        XCTAssertFalse(result[0].hasIndependentSupport)
        XCTAssertTrue(CardEventCoordinator().processUpdate(result, at: Date()).records.isEmpty)
    }

    func testColorWithoutSuitShapeDoesNotInventFace() {
        XCTAssertTrue(fuse(local: [evidence(suitConfidence: 0.15)]).isEmpty)
    }

    func testUnresolvedLayoutDoesNotInventRank() {
        XCTAssertTrue(fuse(local: [evidence(rank: nil)]).isEmpty)
    }

    func testStrongModelLocalDisagreementSuppressesRegion() {
        XCTAssertTrue(fuse(model: [detection("7h", confidence: 0.95)], local: [evidence()]).isEmpty)
    }

    func testOCRAndLayoutConflictSuppressesRegion() {
        XCTAssertTrue(fuse(model: [detection("5d", confidence: 0.95)],
                           local: [evidence(text: "8")]).isEmpty)
    }

    func testFaceCardUsesOCRInsteadOfPipCount() throws {
        let result = fuse(local: [evidence(rank: nil, text: "K")])
        XCTAssertEqual(try XCTUnwrap(result.first).card.code, "kd")
        XCTAssertFalse(result[0].hasIndependentSupport)
    }

    func testNonOverlappingCardsDoNotSupportEachOther() {
        let far = detection("5d", confidence: 0.96,
                            box: CGRect(x: 0.75, y: 0.2, width: 0.2, height: 0.5))
        let result = fuse(model: [far], local: [evidence(rankConfidence: 0.78)])
        XCTAssertEqual(result.count, 2)
        XCTAssertTrue(result.allSatisfy { !$0.hasIndependentSupport })
    }

    func testRepeatedLocalCropIsOneObservation() {
        let result = fuse(local: [evidence(), evidence()])
        XCTAssertEqual(result.count, 1)
    }

    func testWeakLocalizationDoesNotVetoModel() {
        let result = fuse(model: [detection("7h", confidence: 0.95)],
                          local: [evidence(localization: 0.3)])
        XCTAssertEqual(result.first?.card.code, "7h")
    }

    private func fuse(model: [CardDetection] = [], local: [PartialEvidenceFusion.Evidence] = []) -> [CardDetection] {
        PartialEvidenceFusion.fuse(model: model, local: local, imageSize: size)
    }

    private func detection(_ code: String, confidence: Float, box: CGRect? = nil) -> CardDetection {
        CardDetection(card: CardFace.parse(code)!, confidence: confidence,
                      boundingBox: box ?? self.box, orientedImageSize: size)
    }

    private func evidence(rank: String? = "5", rankConfidence: Double = 0.94,
                          suitConfidence: Double = 0.94, text: String? = nil,
                          localization: Double = 0.90) -> PartialEvidenceFusion.Evidence {
        let features = PartialCardFeatures(boundingBox: box,
            pipCenters: [CGPoint(x: 0.3, y: 0.18), CGPoint(x: 0.7, y: 0.18),
                         CGPoint(x: 0.5, y: 0.5), CGPoint(x: 0.3, y: 0.82), CGPoint(x: 0.7, y: 0.82)],
            imageAspectRatio: 2.5 / 3.5, visibleRegion: "full",
            suitProbabilities: ["diamond": 0.97, "heart": 0.02, "club": 0.005, "spade": 0.005],
            suitConfidence: suitConfidence, rankText: text, rankTextConfidence: text == nil ? 0 : 0.96,
            localizationConfidence: localization)
        return .init(features: features,
                     layout: PartialRankResult(rank: rank, confidence: rankConfidence, candidates: []))
    }
}
