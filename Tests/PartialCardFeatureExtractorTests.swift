import CoreGraphics
import CoreImage
import CoreVideo
import ImageIO
import XCTest
@testable import CardScanMagic

final class PartialCardFeatureExtractorTests: XCTestCase {
    private let frame = CGRect(x: 0, y: 0, width: 320, height: 380)
    private let card = CGRect(x: 60, y: 54, width: 180, height: 252)
    private let points = [CGPoint(x: 0.25, y: 0.24), CGPoint(x: 0.75, y: 0.24),
                          CGPoint(x: 0.5, y: 0.5), CGPoint(x: 0.25, y: 0.76),
                          CGPoint(x: 0.75, y: 0.76)]
    private let canonicalPoints = [CGPoint(x: 0.30, y: 0.18), CGPoint(x: 0.70, y: 0.18),
                          CGPoint(x: 0.5, y: 0.5), CGPoint(x: 0.30, y: 0.82),
                          CGPoint(x: 0.70, y: 0.82)]

    func testFullCardExtractsFiveDiamondPips() throws {
        let features = try PartialCardFeatureExtractor().extract(image: makeImage())
        let feature = try XCTUnwrap(features.first(where: { $0.pipCenters.count == 5 }))
        XCTAssertEqual(feature.visibleRegion, "full")
        XCTAssertEqual(feature.imageAspectRatio, 180.0 / 252.0, accuracy: 0.08)
        XCTAssertEqual(feature.suitProbabilities.max(by: { $0.value < $1.value })?.key, "diamond")
        XCTAssertGreaterThan(feature.suitConfidence, 0.45)
        XCTAssertTrue(feature.pipCenters.contains { abs($0.x - 0.5) < 0.04 && abs($0.y - 0.5) < 0.04 })
        XCTAssertLessThanOrEqual(features.count, 3)
    }

    func testOffscreenRightSideStillProducesLeftRegionAndPips() throws {
        let image = makeImage().cropped(to: CGRect(x: 0, y: 0, width: 185, height: 380))
        let features = try PartialCardFeatureExtractor().extract(image: image)
        let feature = try XCTUnwrap(features.first(where: { $0.visibleRegion == "left" }))
        XCTAssertGreaterThanOrEqual(feature.pipCenters.count, 3)
        XCTAssertEqual(feature.boundingBox.maxX, 1, accuracy: 0.02)
        XCTAssertLessThan(feature.imageAspectRatio, 0.55)
    }

    func testMildMotionBlurRetainsPipEvidence() throws {
        let image = makeImage().applyingFilter("CIMotionBlur", parameters: [
            kCIInputRadiusKey: 3.0, kCIInputAngleKey: 0.0
        ]).cropped(to: frame)
        let features = try PartialCardFeatureExtractor().extract(image: image)
        let feature = try XCTUnwrap(features.first(where: { $0.pipCenters.count >= 4 }))
        XCTAssertEqual(feature.suitProbabilities.max(by: { $0.value < $1.value })?.key, "diamond")
        XCTAssertGreaterThan(feature.suitConfidence, 0.20)
    }

    func testCornerSuitIndexesAreNotCountedAsBodyPips() throws {
        let features = try PartialCardFeatureExtractor().extract(
            image: makeImage(cornerIndexes: true, pipPoints: canonicalPoints))
        let feature = try XCTUnwrap(features.first(where: { $0.visibleRegion == "full" }))
        XCTAssertEqual(feature.pipCenters.count, 5)
        let rank = PartialRankEstimator.infer(points: feature.pipCenters,
                                             imageAspectRatio: feature.imageAspectRatio,
                                             visibleRegion: feature.visibleRegion)
        XCTAssertEqual(rank.rank, "5")
        XCTAssertEqual(feature.suitProbabilities.max(by: { $0.value < $1.value })?.key, "diamond")
    }

    func testClippedCornerIndexDoesNotBecomeAnExtraBodyPip() throws {
        let image = makeImage(cornerIndexes: true)
            .cropped(to: CGRect(x: 0, y: 0, width: 185, height: 380))
        let features = try PartialCardFeatureExtractor().extract(image: image)
        let feature = try XCTUnwrap(features.first(where: { $0.visibleRegion == "left" }))
        XCTAssertEqual(feature.pipCenters.count, 3)
        XCTAssertFalse(feature.clippedPipCandidates.isEmpty)
    }

    func testMildBlurredFrameThroughFusionRecordsOneSupportedCard() throws {
        let image = makeImage(cornerIndexes: true, pipPoints: canonicalPoints)
            .applyingFilter("CIMotionBlur", parameters: [
            kCIInputRadiusKey: 2.0, kCIInputAngleKey: 0.0
        ]).cropped(to: frame)
        let features = try PartialCardFeatureExtractor().extract(image: image)
        let feature = try XCTUnwrap(features.first(where: { $0.pipCenters.count == 5 }))
        let inferred = PartialRankEstimator.infer(points: feature.pipCenters,
                                                 imageAspectRatio: feature.imageAspectRatio,
                                                 visibleRegion: feature.visibleRegion)
        XCTAssertEqual(inferred.rank, "5")
        XCTAssertEqual(feature.suitProbabilities.max(by: { $0.value < $1.value })?.key, "diamond")
        let card = try XCTUnwrap(CardFace.parse("5d"))
        // Model output is supplied as a fixture; the local image path
        // independently supplies the pip layout and suit evidence.
        let modelObservation = CardDetection(card: card, confidence: 0.94,
                                             boundingBox: feature.boundingBox,
                                             orientedImageSize: frame.size)
        let evidence = PartialEvidenceFusion.Evidence(features: feature, layout: inferred)
        let detections = PartialEvidenceFusion.fuse(model: [modelObservation],
                                                    local: [evidence], imageSize: frame.size)
        XCTAssertTrue(detections.contains { $0.card == card && $0.hasIndependentSupport })
        let coordinator = CardEventCoordinator()
        let captureDate = Date(timeIntervalSinceReferenceDate: 100)
        let update = coordinator.processUpdate(detections, at: captureDate)
        XCTAssertEqual(update.records.map(\.card), [card])
        XCTAssertEqual(update.stableDetections.map(\.card), [card])
        XCTAssertTrue(coordinator.process(detections, at: captureDate).isEmpty)
    }

    func testCanonicalBlurredImageProducesStandaloneFusedFiveDiamonds() throws {
        let image = makeImage(pipPoints: canonicalPoints).applyingFilter("CIMotionBlur", parameters: [
            kCIInputRadiusKey: 2.0, kCIInputAngleKey: 0.0
        ]).cropped(to: frame)
        let features = try PartialCardFeatureExtractor().extract(image: image)
        let feature = try XCTUnwrap(features.first(where: { $0.pipCenters.count == 5 }))
        let inferred = PartialRankEstimator.infer(points: feature.pipCenters,
                                                 imageAspectRatio: feature.imageAspectRatio,
                                                 visibleRegion: feature.visibleRegion)
        XCTAssertEqual(inferred.rank, "5")
        XCTAssertEqual(feature.suitProbabilities.max(by: { $0.value < $1.value })?.key, "diamond")
        let detections = PartialEvidenceFusion.fuse(model: [],
            local: [PartialEvidenceFusion.Evidence(features: feature, layout: inferred)], imageSize: frame.size)
        let card = try XCTUnwrap(CardFace.parse("5d"))
        XCTAssertEqual(detections.map(\.card), [card])
        let coordinator = CardEventCoordinator()
        let start = Date(timeIntervalSinceReferenceDate: 200)
        let first = coordinator.processUpdate(detections, at: start)
        let next = coordinator.processUpdate(detections, at: start.addingTimeInterval(0.04))
        XCTAssertEqual((first.records + next.records).map(\.card), [card])
    }

    func testBlankSurfaceDoesNotGenerateCardEvidence() throws {
        let features = try PartialCardFeatureExtractor().extract(image: makeImage(drawPips: false))
        XCTAssertTrue(features.isEmpty)
    }

    func testUnboundedImageIsRejectedBeforeRasterAllocation() throws {
        XCTAssertTrue(try PartialCardFeatureExtractor().extract(image: CIImage(color: .white)).isEmpty)
    }

    func testSquareWhiteRegionIsNotClaimedAsCompleteCard() throws {
        let square = CGRect(x: 50, y: 60, width: 220, height: 220)
        let features = try PartialCardFeatureExtractor().extract(image: makeImage(cardRect: square))
        XCTAssertTrue(features.allSatisfy { $0.visibleRegion != "full" && $0.localizationConfidence < 0.5 })
    }

    func testRedInkWithoutSuitShapeDoesNotClaimCertainSuit() throws {
        let features = try PartialCardFeatureExtractor().extract(image: makeImage(squareInk: true))
        XCTAssertTrue(features.allSatisfy { $0.suitConfidence < 0.6 })
        XCTAssertTrue(features.contains { !$0.pipCenters.isEmpty })
    }

    func testVisibleRegionMapsImageClippingToRemainingCardSide() {
        XCTAssertEqual(PartialCardFeatureExtractor.visibleRegion(
            for: CGRect(x: 0.2, y: 0.2, width: 0.8, height: 0.6)), "left")
        XCTAssertEqual(PartialCardFeatureExtractor.visibleRegion(
            for: CGRect(x: 0, y: 0.2, width: 0.8, height: 0.6)), "right")
        XCTAssertEqual(PartialCardFeatureExtractor.visibleRegion(
            for: CGRect(x: 0.2, y: 0, width: 0.6, height: 0.8)), "top")
        XCTAssertEqual(PartialCardFeatureExtractor.visibleRegion(
            for: CGRect(x: 0.2, y: 0.2, width: 0.6, height: 0.8)), "bottom")
        XCTAssertEqual(PartialCardFeatureExtractor.visibleRegion(
            for: CGRect(x: 0, y: 0, width: 1, height: 1)), "unknown")
    }

    func testBoxesAreInVisionCoordinatesForAsymmetricScene() throws {
        // CI/CoreGraphics use a lower-left canvas; the card is placed near
        // the bottom so a vertical flip would be visible in this assertion.
        let smallCard = CGRect(x: 25, y: 18, width: 110, height: 154)
        let features = try PartialCardFeatureExtractor().extract(image: makeImage(cardRect: smallCard))
        let feature = try XCTUnwrap(features.first(where: { $0.pipCenters.count >= 4 }))
        XCTAssertEqual(feature.boundingBox.minX, smallCard.minX / frame.width, accuracy: 0.03)
        XCTAssertEqual(feature.boundingBox.minY, smallCard.minY / frame.height, accuracy: 0.03)
    }

    func testPixelBufferEntryPointHonorsOrientation() throws {
        var optionalBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(kCFAllocatorDefault, 320, 380, kCVPixelFormatType_32BGRA,
                                        nil, &optionalBuffer)
        XCTAssertEqual(status, kCVReturnSuccess)
        let buffer = try XCTUnwrap(optionalBuffer)
        CIContext().render(makeImage(), to: buffer)
        let features = try PartialCardFeatureExtractor().extract(pixelBuffer: buffer, orientation: .right)
        let feature = try XCTUnwrap(features.first(where: { $0.pipCenters.count >= 4 }))
        XCTAssertEqual(feature.boundingBox.width, card.height / frame.height, accuracy: 0.04)
        XCTAssertEqual(feature.boundingBox.height, card.width / frame.width, accuracy: 0.04)
    }

    private func makeImage(drawPips: Bool = true, squareInk: Bool = false, cornerIndexes: Bool = false,
                           pipPoints: [CGPoint]? = nil, cardRect: CGRect? = nil) -> CIImage {
        let canvas = CGContext(data: nil, width: 320, height: 380, bitsPerComponent: 8,
                               bytesPerRow: 320 * 4, space: CGColorSpaceCreateDeviceRGB(),
                               bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        canvas.setFillColor(CGColor(red: 0.04, green: 0.12, blue: 0.12, alpha: 1))
        canvas.fill(frame)
        let card = cardRect ?? self.card
        canvas.setFillColor(CGColor(gray: 0.98, alpha: 1))
        canvas.fill(card)
        if drawPips {
            canvas.setFillColor(CGColor(red: 0.85, green: 0.04, blue: 0.06, alpha: 1))
            for point in pipPoints ?? points {
                let x = card.minX + point.x * card.width
                let y = card.minY + point.y * card.height
                let rx = card.width * 0.075
                let ry = card.height * 0.064
                if squareInk {
                    canvas.fill(CGRect(x: x - rx, y: y - ry, width: rx * 2, height: ry * 2))
                } else {
                    canvas.beginPath()
                    canvas.move(to: CGPoint(x: x, y: y + ry))
                    canvas.addLine(to: CGPoint(x: x + rx, y: y))
                    canvas.addLine(to: CGPoint(x: x, y: y - ry))
                    canvas.addLine(to: CGPoint(x: x - rx, y: y))
                    canvas.closePath()
                    canvas.fillPath()
                }
            }
            if cornerIndexes {
                for point in [CGPoint(x: 0.10, y: 0.20), CGPoint(x: 0.90, y: 0.80)] {
                    let x = card.minX + point.x * card.width
                    let y = card.minY + point.y * card.height
                    canvas.beginPath()
                    canvas.move(to: CGPoint(x: x, y: y + 7))
                    canvas.addLine(to: CGPoint(x: x + 5, y: y))
                    canvas.addLine(to: CGPoint(x: x, y: y - 7))
                    canvas.addLine(to: CGPoint(x: x - 5, y: y))
                    canvas.closePath()
                    canvas.fillPath()
                }
            }
        }
        return CIImage(cgImage: canvas.makeImage()!)
    }
}
