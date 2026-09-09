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

    func testContradictoryLocalRanksVetoRegionInEitherOrder() {
        let first = evidence(rank: "5")
        let second = evidence(rank: "7")
        XCTAssertTrue(fuse(local: [first, second]).isEmpty)
        XCTAssertTrue(fuse(local: [second, first]).isEmpty)
    }

    func testLaterInternalRankConflictVetoesEarlierLocalResult() {
        let first = evidence()
        let conflicting = evidence(text: "8")
        XCTAssertTrue(fuse(local: [first, conflicting]).isEmpty)
        XCTAssertTrue(fuse(local: [conflicting, first]).isEmpty)
    }

    func testContradictoryLocalSuitsVetoRegionInEitherOrder() {
        let first = evidence(suit: "diamond")
        let second = evidence(suit: "heart")
        XCTAssertTrue(fuse(local: [first, second]).isEmpty)
        XCTAssertTrue(fuse(local: [second, first]).isEmpty)
    }

    func testLaterAgreeingCropCannotResurrectModelConflictedRegion() {
        let model = [detection("5d", confidence: 0.95)]
        let agreeing = evidence()
        let conflicting = evidence(rank: "7")
        XCTAssertTrue(fuse(model: model, local: [agreeing, conflicting]).isEmpty)
        XCTAssertTrue(fuse(model: model, local: [conflicting, agreeing]).isEmpty)
    }

    func testConflictInOneRegionDoesNotSuppressDifferentCard() {
        let otherBox = CGRect(x: 0.75, y: 0.2, width: 0.2, height: 0.5)
        let independent = evidence(rank: "7", boundingBox: otherBox)
        let result = fuse(local: [evidence(), evidence(rank: "8"), independent])
        XCTAssertEqual(result.map { $0.card.code }, ["7d"])
    }

    func testRepeatingWeakLocalEvidenceDoesNotIncreaseConfidenceOrSupport() throws {
        let weak = evidence(rankConfidence: 0.78)
        let single = try XCTUnwrap(fuse(local: [weak]).first)
        let repeated = fuse(local: [weak, weak, weak])
        XCTAssertEqual(repeated.count, 1)
        XCTAssertEqual(repeated.first?.confidence, single.confidence)
        XCTAssertFalse(try XCTUnwrap(repeated.first).hasIndependentSupport)
        XCTAssertTrue(CardEventCoordinator().process(repeated, at: Date()).isEmpty)
    }

    func testDuplicatedPipCentersDoNotSupplyStrongLayoutSupport() throws {
        let pips = Array(repeating: CGPoint(x: 0.5, y: 0.5), count: 5)
        let result = fuse(local: [evidence(pips: pips)])
        XCTAssertFalse(try XCTUnwrap(result.first).hasIndependentSupport)
        XCTAssertTrue(CardEventCoordinator().process(result, at: Date()).isEmpty)
    }

    func testModelOnlyConflictingLabelsReachCoordinatorConflictGate() {
        let result = fuse(model: [detection("5d", confidence: 0.96), detection("7h", confidence: 0.95)])
        XCTAssertEqual(result.count, 2)
        XCTAssertTrue(result.allSatisfy { !$0.hasIndependentSupport })
        let coordinator = CardEventCoordinator()
        let start = Date(timeIntervalSinceReferenceDate: 100)
        XCTAssertTrue(coordinator.process(result, at: start).isEmpty)
        let next = coordinator.processUpdate(result, at: start.addingTimeInterval(0.04))
        XCTAssertTrue(next.records.isEmpty)
        XCTAssertTrue(next.stableDetections.isEmpty)
    }

    func testRepeatedModelCropDoesNotSupplyIndependentSupport() throws {
        let model = detection("5d", confidence: 0.96)
        let result = fuse(model: [model, model])
        XCTAssertEqual(result.count, 1)
        XCTAssertFalse(try XCTUnwrap(result.first).hasIndependentSupport)
        XCTAssertTrue(CardEventCoordinator().process(result, at: Date()).isEmpty)
    }

    func testInvalidConfidenceCannotCreateOrVetoFace() {
        let invalid: [Double] = [.nan, .infinity, -.infinity, -0.01, 1.01]
        let model = [detection("7h", confidence: 0.96)]
        for score in invalid {
            let candidates = [
                evidence(rankConfidence: score),
                evidence(suitConfidence: score),
                evidence(text: "5", textConfidence: score),
                evidence(localization: score),
                evidence(suitProbabilities: ["diamond": score, "heart": 0.02, "club": 0.005, "spade": 0.005])
            ]
            for candidate in candidates {
                XCTAssertTrue(fuse(local: [candidate]).isEmpty)
                XCTAssertEqual(fuse(model: model, local: [candidate]).map { $0.card.code }, ["7h"])
            }
            XCTAssertTrue(fuse(model: [detection("5d", confidence: Float(score))]).isEmpty)
        }
    }

    func testInvalidProbabilityDistributionCannotResolveSuit() {
        XCTAssertTrue(fuse(local: [evidence(suitProbabilities: ["diamond": 0.97])]).isEmpty)
        XCTAssertTrue(fuse(local: [evidence(suitProbabilities: [
            "diamond": 0.97, "heart": 0.4, "club": 0.4, "spade": 0.4
        ])]).isEmpty)
    }

    func testInvalidRegionCannotVetoValidModel() {
        let invalid = evidence(boundingBox: CGRect(x: CGFloat.infinity, y: 0, width: 0.2, height: 0.2))
        let result = fuse(model: [detection("7h", confidence: 0.96)], local: [invalid])
        XCTAssertEqual(result.map { $0.card.code }, ["7h"])
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
                          textConfidence: Double = 0.96, localization: Double = 0.90,
                          suit: String = "diamond", suitProbabilities: [String: Double]? = nil,
                          pips: [CGPoint]? = nil, boundingBox: CGRect? = nil) -> PartialEvidenceFusion.Evidence {
        let probabilities = suitProbabilities ?? Dictionary(uniqueKeysWithValues:
            ["diamond", "heart", "club", "spade"].map { ($0, $0 == suit ? 0.97 : 0.01) })
        let features = PartialCardFeatures(boundingBox: boundingBox ?? box,
            pipCenters: pips ?? [CGPoint(x: 0.3, y: 0.18), CGPoint(x: 0.7, y: 0.18),
                                CGPoint(x: 0.5, y: 0.5), CGPoint(x: 0.3, y: 0.82), CGPoint(x: 0.7, y: 0.82)],
            imageAspectRatio: 2.5 / 3.5, visibleRegion: "full",
            suitProbabilities: probabilities,
            suitConfidence: suitConfidence, rankText: text, rankTextConfidence: text == nil ? 0 : textConfidence,
            localizationConfidence: localization)
        return .init(features: features,
                     layout: PartialRankResult(rank: rank, confidence: rankConfidence, candidates: []))
    }
}
