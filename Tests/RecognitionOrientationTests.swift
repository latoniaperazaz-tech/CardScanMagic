import CoreGraphics
import ImageIO
import XCTest
@testable import CardScanMagic

final class RecognitionOrientationTests: XCTestCase {
    func testQuarterTurnSwapsOrientedImageDimensions() {
        let rawSize = CGSize(width: 1920, height: 1080)

        XCTAssertEqual(
            RecognitionEngine.orientedImageSize(rawImageSize: rawSize, orientation: .right),
            CGSize(width: 1080, height: 1920)
        )
        XCTAssertEqual(
            RecognitionEngine.orientedImageSize(rawImageSize: rawSize, orientation: .left),
            CGSize(width: 1080, height: 1920)
        )
    }

    func testUprightOrientationKeepsDimensions() {
        let rawSize = CGSize(width: 1080, height: 1920)

        XCTAssertEqual(
            RecognitionEngine.orientedImageSize(rawImageSize: rawSize, orientation: .up),
            rawSize
        )
        XCTAssertEqual(
            RecognitionEngine.orientedImageSize(rawImageSize: rawSize, orientation: .down),
            rawSize
        )
    }
}
