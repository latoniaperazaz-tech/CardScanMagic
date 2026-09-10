import CoreGraphics
import CoreImage
import XCTest
@testable import CardScanMagic

/// Generated image fixtures exercise Vision localization, ink extraction,
/// production topology handoff, Fusion and physical/session dedup. They are
/// deterministic regression coverage, not a real-camera recall benchmark.
final class PipOnlyImageIntegrationTests: XCTestCase {
    private let frame = CGRect(x: 0, y: 0, width: 560, height: 720)
    private let card = CGRect(x: 80, y: 60, width: 400, height: 560)

    func testCoveredCornersNineClubsProducesOnePhysicalDecisionAndRecord() throws {
        let (features, detections) = try analyze(makeImage(rank: "9", coverCorners: true))
        let feature = try XCTUnwrap(features.first { $0.pipCenters.count == 9 }, describe(features))
        XCTAssertNil(feature.rankText)
        XCTAssertGreaterThanOrEqual(feature.bodySuitSupportingPips, 6)
        XCTAssertFalse(feature.uncertainRegions.isEmpty)
        XCTAssertEqual(detections.map { $0.card.code }, ["9c"], describe(features))
        let coordinator = CardEventCoordinator()
        let updates = (0..<5).map {
            coordinator.processUpdate(detections, at: Date(timeIntervalSinceReferenceDate: 100 + Double($0) / 30))
        }
        XCTAssertEqual(updates.flatMap(\.records).map { $0.card.code }, ["9c"])
        XCTAssertEqual(updates.flatMap(\.decisions).count, 1)
        _ = coordinator.processUpdate([], at: Date(timeIntervalSinceReferenceDate: 101))
        let reappearance = coordinator.processUpdate(detections, at: Date(timeIntervalSinceReferenceDate: 102))
        let repeated = coordinator.processUpdate(detections, at: Date(timeIntervalSinceReferenceDate: 102.04))
        XCTAssertTrue(reappearance.records.isEmpty && repeated.records.isEmpty)
    }

    func testEveryNumberRankReachesRecordingWithoutPrintedRank() throws {
        for rank in ["A", "2", "3", "4", "5", "6", "7", "8", "9", "10"] {
            let (features, detections) = try analyze(makeImage(rank: rank))
            XCTAssertTrue(features.allSatisfy { $0.rankText == nil }, "OCR fixture \(rank)")
            XCTAssertEqual(detections.map { $0.card.code }, [rank.lowercased() + "c"], "\(rank): \(describe(features))")
            let coordinator = CardEventCoordinator()
            let first = coordinator.processUpdate(detections, at: Date(timeIntervalSinceReferenceDate: 100))
            let next = coordinator.processUpdate(detections, at: Date(timeIntervalSinceReferenceDate: 100.04))
            XCTAssertEqual((first.records + next.records).count, 1, "Rank \(rank)")
        }
    }

    func testEdgeOcclusionKeepsVisibleNineTopology() throws {
        // Foreground covers the two lower-middle pips, but the middle pip
        // distinguishing nine from ten remains visible.
        let occlusion = CGRect(x: 0, y: 0.55, width: 0.85, height: 0.14)
        let (features, detections) = try analyze(makeImage(rank: "9", occlusion: occlusion))
        XCTAssertTrue(features.contains { !$0.uncertainRegions.isEmpty }, describe(features))
        XCTAssertEqual(detections.map { $0.card.code }, ["9c"], describe(features))
    }

    func testHiddenNineTenDistinguishingStripRemainsUnknown() throws {
        let occlusion = CGRect(x: 0.42, y: 0, width: 0.16, height: 0.79)
        let (features, detections) = try analyze(makeImage(rank: "9", occlusion: occlusion))
        XCTAssertTrue(features.contains { $0.pipCenters.count >= 6 }, describe(features))
        XCTAssertTrue(detections.isEmpty, describe(features))
    }

    func testMildMotionBlurredNineWithoutOCR() throws {
        let image = makeImage(rank: "9", coverCorners: true).applyingFilter("CIMotionBlur", parameters: [
            kCIInputRadiusKey: 2.0, kCIInputAngleKey: 0.0
        ]).cropped(to: frame)
        let (features, detections) = try analyze(image)
        XCTAssertTrue(features.allSatisfy { $0.rankText == nil })
        XCTAssertEqual(detections.map { $0.card.code }, ["9c"], describe(features))
    }

    func testNinePlainBlocksKeepPipCandidatesButCannotConfirmSuit() throws {
        let (features, detections) = try analyze(makeImage(rank: "9", blocks: true))
        XCTAssertTrue(features.contains { $0.pipCenters.count >= 7 }, describe(features))
        XCTAssertTrue(detections.isEmpty, describe(features))
    }

    func testOneClubCannotSupplySuitForEightOrdinaryBlocks() throws {
        let (features, detections) = try analyze(makeImage(rank: "9", blocks: true, firstClub: true))
        XCTAssertTrue(features.contains { $0.pipCenters.count >= 7 }, describe(features))
        XCTAssertTrue(detections.isEmpty, describe(features))
    }

    func testNineClubsAtRandomPositionsDoNotBecomeNine() throws {
        let random: [CGPoint] = [(0.24, 0.13), (0.61, 0.17), (0.38, 0.29), (0.76, 0.35),
            (0.24, 0.46), (0.56, 0.56), (0.78, 0.70), (0.32, 0.79), (0.59, 0.88)]
            .map { CGPoint(x: $0.0, y: $0.1) }
        let (features, detections) = try analyze(makeImage(rank: "9", points: random))
        XCTAssertTrue(features.contains { $0.pipCenters.count >= 7 }, describe(features))
        XCTAssertTrue(detections.isEmpty, describe(features))
    }

    private func analyze(_ image: CIImage) throws -> ([PartialCardFeatures], [CardDetection]) {
        let features = try PartialCardFeatureExtractor().extract(image: image)
        let evidence = RecognitionEngine.partialEvidence(from: features)
        return (features, PartialEvidenceFusion.fuse(model: [], local: evidence, imageSize: frame.size))
    }

    private func describe(_ features: [PartialCardFeatures]) -> String {
        RecognitionEngine.partialEvidence(from: features).map {
            "pips=\($0.features.pipCenters.count) bodySuit=\($0.features.bodySuitSupportingPips) "
                + "suit=\($0.features.suitConfidence) region=\($0.features.visibleRegion) "
                + "unknown=\($0.features.uncertainRegions.count) OCR=\($0.features.rankText ?? "nil") "
                + "rank=\($0.layout.rank ?? "nil") confidence=\($0.layout.confidence) "
                + "candidates=\($0.layout.candidates.prefix(3).map { ($0.rank, $0.probability) })"
        }.joined(separator: "; ")
    }

    private func makeImage(rank: String, coverCorners: Bool = false, occlusion: CGRect? = nil,
                           blocks: Bool = false, firstClub: Bool = false,
                           points: [CGPoint]? = nil) -> CIImage {
        let canvas = CGContext(data: nil, width: 560, height: 720, bitsPerComponent: 8,
            bytesPerRow: 560 * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        canvas.setFillColor(CGColor(red: 0.05, green: 0.16, blue: 0.14, alpha: 1))
        canvas.fill(frame)
        canvas.setFillColor(CGColor(gray: 0.98, alpha: 1))
        canvas.fill(card)
        for (index, point) in (points ?? layout(rank)).enumerated() {
            let center = CGPoint(x: card.minX + point.x * card.width,
                                 y: card.maxY - point.y * card.height)
            let box = CGRect(x: center.x - 19, y: center.y - 22, width: 38, height: 44)
            canvas.setFillColor(CGColor(gray: 0.025, alpha: 1))
            if blocks && !(firstClub && index == 0) {
                canvas.fill(box)
            } else {
                drawClub(canvas, in: box)
            }
        }
        func cover(_ region: CGRect) {
            canvas.setFillColor(CGColor(red: 0.69, green: 0.43, blue: 0.30, alpha: 1))
            canvas.fill(CGRect(x: card.minX + region.minX * card.width,
                y: card.maxY - region.maxY * card.height,
                width: region.width * card.width, height: region.height * card.height))
        }
        if coverCorners {
            cover(CGRect(x: 0, y: 0, width: 0.19, height: 0.28))
            cover(CGRect(x: 0.81, y: 0.72, width: 0.19, height: 0.28))
        }
        if let occlusion { cover(occlusion) }
        return CIImage(cgImage: canvas.makeImage()!)
    }

    private func drawClub(_ canvas: CGContext, in box: CGRect) {
        canvas.saveGState()
        canvas.translateBy(x: box.minX, y: box.minY)
        canvas.scaleBy(x: box.width / 112, y: box.height / 120)
        canvas.fillEllipse(in: CGRect(x: 31, y: 66, width: 50, height: 50))
        canvas.fillEllipse(in: CGRect(x: 7, y: 38, width: 50, height: 50))
        canvas.fillEllipse(in: CGRect(x: 55, y: 38, width: 50, height: 50))
        canvas.fill(CGRect(x: 47, y: 10, width: 18, height: 54))
        canvas.beginPath()
        canvas.move(to: CGPoint(x: 29, y: 8))
        canvas.addLine(to: CGPoint(x: 83, y: 8))
        canvas.addLine(to: CGPoint(x: 56, y: 36))
        canvas.closePath()
        canvas.fillPath()
        canvas.restoreGState()
    }

    private func layout(_ rank: String) -> [CGPoint] {
        let layouts: [String: [(Double, Double)]] = [
            "A": [(0.5, 0.5)], "2": [(0.5, 0.18), (0.5, 0.82)],
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
        return layouts[rank]!.map { CGPoint(x: $0.0, y: $0.1) }
    }
}
