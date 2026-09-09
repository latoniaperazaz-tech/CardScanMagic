import CoreGraphics
import XCTest
@testable import CardScanMagic

final class PartialRankEstimatorTests: XCTestCase {
    private let aspect = 2.5 / 3.5
    private let five: [CGPoint] = [CGPoint(x: 0.3, y: 0.18), CGPoint(x: 0.7, y: 0.18),
        CGPoint(x: 0.5, y: 0.5), CGPoint(x: 0.3, y: 0.82), CGPoint(x: 0.7, y: 0.82)]

    func testCompleteFiveRanksFirstAndResolves() {
        let result = PartialRankEstimator.infer(points: five, imageAspectRatio: aspect, visibleRegion: "full")
        XCTAssertEqual(result.candidates.first?.rank, "5")
        XCTAssertEqual(result.rank, "5")
        XCTAssertEqual(result.candidates.first?.matchedCount, 5)
    }

    func testLeftCropRetainsCenterAndLeftStructure() {
        let points = five.filter { $0.x <= 0.56 }.map { CGPoint(x: $0.x / 0.56, y: $0.y) }
        let result = PartialRankEstimator.infer(points: points, imageAspectRatio: aspect * 0.56, visibleRegion: "left")
        XCTAssertEqual(result.candidates.first?.rank, "5")
        XCTAssertEqual(result.candidates.first?.matchedCount, 3)
    }

    func testBottomCropRetainsCenterAndBottomStructure() {
        let points = five.filter { $0.y >= 0.35 }.map { CGPoint(x: $0.x, y: ($0.y - 0.35) / 0.65) }
        let result = PartialRankEstimator.infer(points: points, imageAspectRatio: aspect / 0.65, visibleRegion: "bottom")
        XCTAssertEqual(result.candidates.first?.rank, "5")
        XCTAssertEqual(result.candidates.first?.matchedCount, 3)
    }

    func testRotationByFifteenDegreesPreservesRank() {
        let angle = Double.pi / 12
        let points = five.map { point -> CGPoint in
            let x = (Double(point.x) - 0.5) * aspect
            let y = Double(point.y) - 0.5
            return CGPoint(x: 0.5 + (cos(angle) * x - sin(angle) * y) / aspect,
                           y: 0.5 + sin(angle) * x + cos(angle) * y)
        }
        let result = PartialRankEstimator.infer(points: points, imageAspectRatio: aspect, visibleRegion: "full")
        XCTAssertEqual(result.candidates.first?.rank, "5")
        XCTAssertEqual(result.rank, "5")
    }

    func testCompleteTenRanksFirst() {
        let points: [CGPoint] = [(0.3, 0.15), (0.7, 0.15), (0.5, 0.29), (0.3, 0.38), (0.7, 0.38),
            (0.3, 0.62), (0.7, 0.62), (0.5, 0.71), (0.3, 0.85), (0.7, 0.85)].map { CGPoint(x: $0.0, y: $0.1) }
        let result = PartialRankEstimator.infer(points: points, imageAspectRatio: aspect, visibleRegion: "full")
        XCTAssertEqual(result.candidates.first?.rank, "10")
        XCTAssertEqual(result.candidates.first?.matchedCount, 10)
    }

    func testOtherCompleteNumberLayoutsRankFirst() {
        let layouts: [(String, [(Double, Double)])] = [
            ("A", [(0.5, 0.5)]),
            ("2", [(0.5, 0.18), (0.5, 0.82)]),
            ("3", [(0.5, 0.18), (0.5, 0.5), (0.5, 0.82)]),
            ("4", [(0.3, 0.18), (0.7, 0.18), (0.3, 0.82), (0.7, 0.82)]),
            ("6", [(0.3, 0.18), (0.7, 0.18), (0.3, 0.5), (0.7, 0.5), (0.3, 0.82), (0.7, 0.82)]),
            ("7", [(0.3, 0.18), (0.7, 0.18), (0.5, 0.34), (0.3, 0.5), (0.7, 0.5), (0.3, 0.82), (0.7, 0.82)]),
            ("8", [(0.3, 0.18), (0.7, 0.18), (0.5, 0.34), (0.3, 0.5), (0.7, 0.5), (0.5, 0.66), (0.3, 0.82), (0.7, 0.82)]),
            ("9", [(0.3, 0.15), (0.7, 0.15), (0.3, 0.38), (0.7, 0.38), (0.5, 0.5), (0.3, 0.62), (0.7, 0.62), (0.3, 0.85), (0.7, 0.85)])
        ]
        for (rank, coordinates) in layouts {
            let points = coordinates.map { CGPoint(x: $0.0, y: $0.1) }
            let result = PartialRankEstimator.infer(points: points, imageAspectRatio: aspect, visibleRegion: "full")
            XCTAssertEqual(result.candidates.first?.rank, rank)
        }
    }

    func testSinglePipInUnknownCropRemainsUnresolved() {
        let result = PartialRankEstimator.infer(points: [CGPoint(x: 0.5, y: 0.5)], imageAspectRatio: aspect)
        XCTAssertNil(result.rank)
        XCTAssertEqual(result.candidates.count, 10)
        XCTAssertLessThan(result.confidence, 0.5)
    }

    func testTwoPipsInUnknownCropRemainUnresolved() {
        let result = PartialRankEstimator.infer(points: [CGPoint(x: 0.3, y: 0.18), CGPoint(x: 0.3, y: 0.82)], imageAspectRatio: aspect)
        XCTAssertNil(result.rank)
        XCTAssertEqual(result.candidates.count, 10)
    }

    func testEmptyAndInvalidInputHaveNoLabel() {
        for points in [[], [CGPoint(x: Double.nan, y: 0.5)], [CGPoint(x: -1, y: 2)]] {
            let result = PartialRankEstimator.infer(points: points, imageAspectRatio: aspect)
            XCTAssertNil(result.rank)
            XCTAssertEqual(result.confidence, 0)
            XCTAssertEqual(result.candidates.count, 10)
            XCTAssertEqual(result.candidates.reduce(0) { $0 + $1.probability }, 1, accuracy: 0.000001)
        }
        for ratio in [Double.nan, Double.infinity, 0, -1] {
            XCTAssertNil(PartialRankEstimator.infer(points: five, imageAspectRatio: ratio).rank)
        }
    }

    func testDuplicateContoursDoNotInventAdditionalPips() {
        let result = PartialRankEstimator.infer(points: Array(repeating: CGPoint(x: 0.5, y: 0.5), count: 30), imageAspectRatio: aspect)
        XCTAssertNil(result.rank)
        XCTAssertEqual(result.candidates.map(\.matchedCount).max(), 1)
    }

    func testCandidateProbabilitiesAreFiniteAndNoFaceRankIsInvented() {
        let result = PartialRankEstimator.infer(points: five, imageAspectRatio: aspect)
        XCTAssertTrue(result.candidates.allSatisfy { $0.probability.isFinite && $0.score.isFinite })
        XCTAssertEqual(result.candidates.reduce(0) { $0 + $1.probability }, 1, accuracy: 0.000001)
        XCTAssertFalse(result.candidates.contains { ["J", "Q", "K"].contains($0.rank) })
    }

    func testInputOrderDoesNotChangeBoundedSearch() {
        let forward = PartialRankEstimator.infer(points: five, imageAspectRatio: aspect)
        let reverse = PartialRankEstimator.infer(points: Array(five.reversed()), imageAspectRatio: aspect)
        XCTAssertEqual(forward.candidates.map(\.rank), reverse.candidates.map(\.rank))
        XCTAssertEqual(forward.confidence, reverse.confidence, accuracy: 0.000001)
    }
}
