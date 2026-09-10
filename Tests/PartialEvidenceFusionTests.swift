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

    func testPipTopologyRankConfirmsWithoutOCR() throws {
        let nine = topologyPoints("9")
        let layout = PartialRankEstimator.infer(points: nine, imageAspectRatio: 2.5 / 3.5,
                                               visibleRegion: "full", surfaceAnchored: true)
        XCTAssertEqual(layout.rank, "9")
        let local = evidence(rank: "9", suit: "club", pips: nine, layout: layout)
        XCTAssertNil(local.features.rankText)
        let result = fuse(local: [local])
        let found = try XCTUnwrap(result.first)
        XCTAssertEqual(found.card.code, "9c")
        XCTAssertTrue(found.hasIndependentSupport)
        XCTAssertEqual(CardEventCoordinator().processUpdate(result, at: Date()).records.map(\.card),
                      [CardFace.parse("9c")!])
    }

    func testEveryNumberRankUsesRealTopologyWithoutOCR() throws {
        for rank in ["A", "2", "3", "4", "5", "6", "7", "8", "9", "10"] {
            let points = topologyPoints(rank)
            let layout = PartialRankEstimator.infer(points: points, imageAspectRatio: 2.5 / 3.5,
                                                   visibleRegion: "full", surfaceAnchored: true)
            let local = evidence(rank: rank, suit: "club", pips: points, layout: layout)
            XCTAssertNil(local.features.rankText)
            let detections = fuse(local: [local])
            XCTAssertEqual(try XCTUnwrap(detections.first, "Rank \(rank)").card.rank,
                           rank, "Rank \(rank)")
            let coordinator = CardEventCoordinator()
            let start = Date(timeIntervalSinceReferenceDate: 100)
            let first = coordinator.processUpdate(detections, at: start)
            let second = coordinator.processUpdate(detections, at: start.addingTimeInterval(0.04))
            XCTAssertEqual(first.records.count + second.records.count, 1, "Rank \(rank)")
        }
    }

    func testPipOnlyNeedsVerifiedCardGeometry() {
        XCTAssertTrue(fuse(local: [evidence(surfaceAnchored: false)]).isEmpty)
        XCTAssertTrue(fuse(local: [evidence(localization: 0.49)]).isEmpty)
    }

    func testPipOnlyNeedsRepeatedStructureAndBodySuitAgreement() {
        XCTAssertTrue(fuse(local: [evidence(pipStructureConfidence: 0.2)]).isEmpty)
        XCTAssertTrue(fuse(local: [evidence(bodySuitSupportingPips: 1)]).isEmpty)
        XCTAssertTrue(fuse(local: [evidence(suitProbabilities: [
            "club": 0.49, "spade": 0.49, "diamond": 0.01, "heart": 0.01
        ])]).isEmpty)
    }

    func testPipOnlyCannotReplaceMissingTopologyDistributionWithCertainty() {
        let invented = PartialRankResult(rank: "5", confidence: 0.99, candidates: [])
        XCTAssertTrue(fuse(local: [evidence(layout: invented)]).isEmpty)
    }

    func testPipOnlyRejectsInvalidOrFlatTopologyDistribution() {
        let ranks = ["A", "2", "3", "4", "5", "6", "7", "8", "9", "10"]
        for probability in [0.1, 0.5, Double.nan] {
            let candidates = ranks.map {
                PartialRankCandidate(rank: $0, probability: probability, score: 0.99, matchedCount: 5)
            }
            let invented = PartialRankResult(rank: "5", confidence: 0.99, candidates: candidates)
            XCTAssertTrue(fuse(local: [evidence(layout: invented)]).isEmpty)
        }
    }

    func testPipOnlyCannotConfirmAmbiguousOccludedNineOrTen() {
        let points = topologyPoints("9").filter { abs($0.x - 0.5) > 0.1 }
        let layout = PartialRankEstimator.infer(points: points, imageAspectRatio: 2.5 / 3.5,
            visibleRegion: "full", uncertainRegions: [CGRect(x: 0.42, y: 0.20, width: 0.16, height: 0.60)],
            surfaceAnchored: true)
        XCTAssertNil(layout.rank)
        XCTAssertTrue(fuse(local: [evidence(rank: "9", suit: "club", pips: points, layout: layout)]).isEmpty)
    }

    func testNineRandomDarkComponentsAreNotNinePipTopology() {
        let points: [CGPoint] = [(0.1, 0.1), (0.2, 0.13), (0.31, 0.24), (0.47, 0.31),
            (0.66, 0.42), (0.79, 0.47), (0.88, 0.60), (0.17, 0.73), (0.91, 0.94)]
            .map { CGPoint(x: $0.0, y: $0.1) }
        let layout = PartialRankEstimator.infer(points: points, imageAspectRatio: 2.5 / 3.5,
                                               visibleRegion: "full", surfaceAnchored: true)
        XCTAssertNil(layout.rank)
        XCTAssertTrue(fuse(local: [evidence(rank: "9", suit: "club", pips: points, layout: layout)]).isEmpty)
    }

    func testRankAndSuitFromDifferentRegionsCannotFormACard() {
        let rankOnly = evidence(rank: "9", suitConfidence: 0.1)
        let suitOnly = evidence(rank: nil, suit: "club",
                               boundingBox: CGRect(x: 0.75, y: 0.2, width: 0.2, height: 0.5))
        XCTAssertTrue(fuse(local: [rankOnly]).isEmpty)
        XCTAssertTrue(fuse(local: [suitOnly]).isEmpty)
        XCTAssertTrue(fuse(local: [rankOnly, suitOnly]).isEmpty)
        XCTAssertTrue(fuse(local: [suitOnly, rankOnly]).isEmpty)
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

    func testDuplicatedPipCentersDoNotSupplyStrongLayoutSupport() {
        let pips = Array(repeating: CGPoint(x: 0.5, y: 0.5), count: 5)
        let result = fuse(local: [evidence(pips: pips)])
        XCTAssertTrue(result.isEmpty)
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
                          pips: [CGPoint]? = nil, boundingBox: CGRect? = nil,
                          layout: PartialRankResult? = nil, surfaceAnchored: Bool = true,
                          pipStructureConfidence: Double = 0.95,
                          bodySuitSupportingPips: Int? = nil) -> PartialEvidenceFusion.Evidence {
        let probabilities = suitProbabilities ?? Dictionary(uniqueKeysWithValues:
            ["diamond", "heart", "club", "spade"].map { ($0, $0 == suit ? 0.97 : 0.01) })
        let points = pips ?? topologyPoints(rank ?? "5")
        let features = PartialCardFeatures(boundingBox: boundingBox ?? box,
            pipCenters: points,
            imageAspectRatio: 2.5 / 3.5, visibleRegion: "full",
            suitProbabilities: probabilities,
            suitConfidence: suitConfidence, rankText: text, rankTextConfidence: text == nil ? 0 : textConfidence,
            localizationConfidence: localization,
            surfaceAnchored: surfaceAnchored, pipStructureConfidence: pipStructureConfidence,
            bodySuitSupportingPips: bodySuitSupportingPips ?? points.count, bodyPipCount: points.count)
        let actualLayout = PartialRankEstimator.infer(points: points, imageAspectRatio: 2.5 / 3.5,
                                                     visibleRegion: "full", surfaceAnchored: true)
        return .init(features: features,
                     layout: layout ?? PartialRankResult(rank: rank, confidence: rankConfidence,
                                                        candidates: actualLayout.candidates))
    }

    private func topologyPoints(_ rank: String) -> [CGPoint] {
        let layouts: [String: [(Double, Double)]] = [
            "A": [(0.5, 0.5)],
            "2": [(0.5, 0.18), (0.5, 0.82)],
            "3": [(0.5, 0.18), (0.5, 0.5), (0.5, 0.82)],
            "4": [(0.3, 0.18), (0.7, 0.18), (0.3, 0.82), (0.7, 0.82)],
            "5": [(0.3, 0.18), (0.7, 0.18), (0.5, 0.5), (0.3, 0.82), (0.7, 0.82)],
            "6": [(0.3, 0.18), (0.7, 0.18), (0.3, 0.5), (0.7, 0.5), (0.3, 0.82), (0.7, 0.82)],
            "7": [(0.3, 0.18), (0.7, 0.18), (0.5, 0.34), (0.3, 0.5), (0.7, 0.5), (0.3, 0.82), (0.7, 0.82)],
            "8": [(0.3, 0.18), (0.7, 0.18), (0.5, 0.34), (0.3, 0.5), (0.7, 0.5), (0.5, 0.66), (0.3, 0.82), (0.7, 0.82)],
            "9": [(0.3, 0.15), (0.7, 0.15), (0.3, 0.38), (0.7, 0.38), (0.5, 0.5),
                  (0.3, 0.62), (0.7, 0.62), (0.3, 0.85), (0.7, 0.85)],
            "10": [(0.3, 0.15), (0.7, 0.15), (0.5, 0.29), (0.3, 0.38), (0.7, 0.38),
                   (0.3, 0.62), (0.7, 0.62), (0.5, 0.71), (0.3, 0.85), (0.7, 0.85)]
        ]
        return (layouts[rank.uppercased()] ?? layouts["5"]!).map { CGPoint(x: $0.0, y: $0.1) }
    }
}
