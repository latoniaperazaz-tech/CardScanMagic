import XCTest
@testable import CardScanMagic

final class CameraCapturePolicyTests: XCTestCase {
    func testPrefers1080p120Over1080p60() {
        let selected = CameraCapturePolicy.preferredFormat(from: [
            CameraFormatOption(index: 0, width: 1920, height: 1080, frameRate: 60),
            CameraFormatOption(index: 1, width: 1920, height: 1080, frameRate: 120)
        ])

        XCTAssertEqual(selected?.index, 1)
    }

    func testPrefers1080pBeforeLargerFallbackFormat() {
        let selected = CameraCapturePolicy.preferredFormat(from: [
            CameraFormatOption(index: 0, width: 3840, height: 2160, frameRate: 120),
            CameraFormatOption(index: 1, width: 1920, height: 1080, frameRate: 60)
        ])

        XCTAssertEqual(selected?.index, 1)
    }

    func testUsesLargestFallbackAtPreferredFrameRate() {
        let selected = CameraCapturePolicy.preferredFormat(from: [
            CameraFormatOption(index: 0, width: 1280, height: 720, frameRate: 60),
            CameraFormatOption(index: 1, width: 1280, height: 720, frameRate: 120),
            CameraFormatOption(index: 2, width: 960, height: 540, frameRate: 120)
        ])

        XCTAssertEqual(selected?.index, 1)
    }

    func testClampsExposureCeilingToFormatRange() {
        XCTAssertEqual(
            CameraCapturePolicy.clampedMaximumExposureSeconds(
                minimum: 1.0 / 1_000.0,
                maximum: 1.0 / 30.0
            ),
            1.0 / 500.0,
            accuracy: 0.000_000_1
        )
        XCTAssertEqual(
            CameraCapturePolicy.clampedMaximumExposureSeconds(
                minimum: 1.0 / 240.0,
                maximum: 1.0 / 30.0
            ),
            1.0 / 240.0,
            accuracy: 0.000_000_1
        )
    }
}
