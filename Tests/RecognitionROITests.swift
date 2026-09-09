import CoreGraphics
import XCTest
@testable import CardScanMagic

final class RecognitionROITests: XCTestCase {
    func testPortraitRegionsCoverFrameWithVerticalOverlap() {
        let regions = RecognitionEngine.nearRegions(for: CGSize(width: 1080, height: 1920))

        XCTAssertEqual(regions.count, 2)
        XCTAssertEqual(regions[0], CGRect(x: 0, y: 0, width: 1, height: 0.5625))
        XCTAssertEqual(regions[1], CGRect(x: 0, y: 0.4375, width: 1, height: 0.5625))
        XCTAssertEqual(regions[0].intersection(regions[1]).height, 0.125, accuracy: 0.000001)
        XCTAssertEqual(regions[0].union(regions[1]), CGRect(x: 0, y: 0, width: 1, height: 1))
    }

    func testLandscapeRegionsUseHorizontalOverlap() {
        let regions = RecognitionEngine.nearRegions(for: CGSize(width: 1920, height: 1080))

        XCTAssertEqual(regions.count, 2)
        XCTAssertEqual(regions[0], CGRect(x: 0, y: 0, width: 0.5625, height: 1))
        XCTAssertEqual(regions[1], CGRect(x: 0.4375, y: 0, width: 0.5625, height: 1))
        XCTAssertEqual(regions[0].intersection(regions[1]).width, 0.125, accuracy: 0.000001)
        XCTAssertEqual(regions[0].union(regions[1]), CGRect(x: 0, y: 0, width: 1, height: 1))
    }

    func testMapsROILocalBoundingBoxToFullImageCoordinates() {
        let upperRegion = CGRect(x: 0, y: 0.4375, width: 1, height: 0.5625)
        let localBox = CGRect(x: 0.2, y: 0.3, width: 0.4, height: 0.2)

        let mappedBox = RecognitionEngine.mapBoundingBox(localBox, from: upperRegion)
        XCTAssertEqual(mappedBox.minX, 0.2, accuracy: 0.000001)
        XCTAssertEqual(mappedBox.minY, 0.60625, accuracy: 0.000001)
        XCTAssertEqual(mappedBox.width, 0.4, accuracy: 0.000001)
        XCTAssertEqual(mappedBox.height, 0.1125, accuracy: 0.000001)
    }

    func testInvalidImageSizeProducesNoRegions() {
        XCTAssertTrue(RecognitionEngine.nearRegions(for: .zero).isEmpty)
        XCTAssertTrue(
            RecognitionEngine.nearRegions(
                for: CGSize(width: CGFloat.infinity, height: 1920)
            ).isEmpty
        )
    }

    func testWeakFullFrameDetectionDoesNotSuppressNearFallback() throws {
        let aceHearts = try XCTUnwrap(CardFace.parse("Ah"))
        let weakDetection = CardDetection(
            card: aceHearts,
            confidence: 0.44,
            boundingBox: CGRect(x: 0.42, y: 0.31, width: 0.04, height: 0.06)
        )

        XCTAssertTrue(
            RecognitionEngine.shouldUseNearFallback(for: [weakDetection])
        )
    }

    func testTinyFullFrameDetectionDoesNotSuppressNearFallback() throws {
        let aceHearts = try XCTUnwrap(CardFace.parse("Ah"))
        let tinyDetection = CardDetection(
            card: aceHearts,
            confidence: 0.90,
            boundingBox: CGRect(x: 0.42, y: 0.31, width: 0.01, height: 0.02)
        )

        XCTAssertTrue(
            RecognitionEngine.shouldUseNearFallback(for: [tinyDetection])
        )
    }

    func testUsableFullFrameDetectionSkipsNearFallback() throws {
        let aceHearts = try XCTUnwrap(CardFace.parse("Ah"))
        let usableDetection = CardDetection(
            card: aceHearts,
            confidence: 0.90,
            boundingBox: CGRect(x: 0.42, y: 0.31, width: 0.04, height: 0.06)
        )

        XCTAssertFalse(
            RecognitionEngine.shouldUseNearFallback(for: [usableDetection])
        )
    }
}
