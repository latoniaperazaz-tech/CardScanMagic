import CoreMedia
import XCTest
@testable import CardScanMagic

final class CameraCapturePolicyTests: XCTestCase {
    func testPrefers60Then30FPS() {
        XCTAssertEqual(CameraCapturePolicy.preferredFrameRates, [60, 30])

        let selected = CameraCapturePolicy.preferredFormat(from: [
            CameraFormatOption(index: 0, width: 1920, height: 1080, frameRate: 30),
            CameraFormatOption(index: 1, width: 1920, height: 1080, frameRate: 60)
        ])

        XCTAssertEqual(selected?.index, 1)
    }

    func testPrefers1080pBeforeLargerFallbackFormat() {
        let selected = CameraCapturePolicy.preferredFormat(from: [
            CameraFormatOption(index: 0, width: 3840, height: 2160, frameRate: 60),
            CameraFormatOption(index: 1, width: 1920, height: 1080, frameRate: 30)
        ])

        XCTAssertEqual(selected?.index, 1)
    }

    func testUsesLargestFallbackAtPreferredFrameRate() {
        let selected = CameraCapturePolicy.preferredFormat(from: [
            CameraFormatOption(index: 0, width: 1280, height: 720, frameRate: 30),
            CameraFormatOption(index: 1, width: 1280, height: 720, frameRate: 60),
            CameraFormatOption(index: 2, width: 960, height: 540, frameRate: 60)
        ])

        XCTAssertEqual(selected?.index, 1)
    }

    func testFallsBackTo30FPSAndExcludes120FPS() {
        let selected = CameraCapturePolicy.preferredFormat(from: [
            CameraFormatOption(index: 0, width: 1920, height: 1080, frameRate: 120),
            CameraFormatOption(index: 1, width: 1280, height: 720, frameRate: 30)
        ])

        XCTAssertEqual(selected?.index, 1)
    }

    func testReturnsNoFormatWithoutSupportedPolicyRate() {
        XCTAssertNil(CameraCapturePolicy.preferredFormat(from: []))
        XCTAssertNil(CameraCapturePolicy.preferredFormat(from: [
            CameraFormatOption(index: 0, width: 1920, height: 1080, frameRate: 120),
            CameraFormatOption(index: 1, width: 1920, height: 1080, frameRate: 24)
        ]))
    }

    func testUsesExactRationalDurationForIntegerFrameRates() throws {
        for frameRate in [120, 60, 30] {
            let duration = try XCTUnwrap(CameraCapturePolicy.clampedFrameDuration(
                frameRate: frameRate,
                minimum: CMTime(value: 1, timescale: 240),
                maximum: CMTime(value: 1, timescale: 15)
            ))

            XCTAssertEqual(duration.value, 1)
            XCTAssertEqual(duration.timescale, CMTimeScale(frameRate))
            XCTAssertEqual(CMTimeCompare(
                duration,
                CMTime(value: 1, timescale: CMTimeScale(frameRate))
            ), 0)
        }
    }

    func testAvoidsNanosecondRoundingBelow120FPSMinimumDuration() throws {
        let minimum = CMTime(value: 1, timescale: 120)
        let rounded = CMTime(seconds: 1.0 / 120.0, preferredTimescale: 1_000_000_000)
        XCTAssertLessThan(CMTimeCompare(rounded, minimum), 0)

        let duration = try XCTUnwrap(CameraCapturePolicy.clampedFrameDuration(
            frameRate: 120,
            minimum: minimum,
            maximum: CMTime(value: 1, timescale: 30)
        ))

        XCTAssertEqual(CMTimeCompare(duration, minimum), 0)
        XCTAssertEqual(duration.value, 1)
        XCTAssertEqual(duration.timescale, 120)
    }

    func testPreservesFractionalHardwareMinimumDuration() throws {
        let minimum = CMTime(value: 1_001, timescale: 60_000)
        let duration = try XCTUnwrap(CameraCapturePolicy.clampedFrameDuration(
            frameRate: 60,
            minimum: minimum,
            maximum: CMTime(value: 1, timescale: 15)
        ))

        XCTAssertEqual(CMTimeCompare(duration, minimum), 0)
        XCTAssertEqual(duration.value, minimum.value)
        XCTAssertEqual(duration.timescale, minimum.timescale)
    }

    func testPreservesHardwareMaximumDurationWhenRequestedRateIsTooLow() throws {
        let maximum = CMTime(value: 1_001, timescale: 30_000)
        let duration = try XCTUnwrap(CameraCapturePolicy.clampedFrameDuration(
            frameRate: 15,
            minimum: CMTime(value: 1_001, timescale: 60_000),
            maximum: maximum
        ))

        XCTAssertEqual(CMTimeCompare(duration, maximum), 0)
        XCTAssertEqual(duration.value, maximum.value)
        XCTAssertEqual(duration.timescale, maximum.timescale)
    }

    func testAcceptsEqualHardwareBounds() throws {
        let bound = CMTime(value: 1_001, timescale: 60_000)
        let duration = try XCTUnwrap(CameraCapturePolicy.clampedFrameDuration(
            frameRate: 60,
            minimum: bound,
            maximum: bound
        ))

        XCTAssertEqual(duration.value, bound.value)
        XCTAssertEqual(duration.timescale, bound.timescale)
    }

    func testRejectsInvalidOrNonpositiveHardwareBounds() {
        let invalidBounds: [CMTime] = [
            .invalid,
            .indefinite,
            .positiveInfinity,
            .negativeInfinity,
            .zero,
            CMTime(value: -1, timescale: 60)
        ]
        for bound in invalidBounds {
            XCTAssertNil(CameraCapturePolicy.clampedFrameDuration(
                frameRate: 60,
                minimum: bound,
                maximum: CMTime(value: 1, timescale: 30)
            ))
            XCTAssertNil(CameraCapturePolicy.clampedFrameDuration(
                frameRate: 60,
                minimum: CMTime(value: 1, timescale: 120),
                maximum: bound
            ))
        }
    }

    func testRejectsReversedHardwareBounds() {
        XCTAssertNil(CameraCapturePolicy.clampedFrameDuration(
            frameRate: 60,
            minimum: CMTime(value: 1, timescale: 15),
            maximum: CMTime(value: 1, timescale: 30)
        ))
    }

    func testRejectsInvalidOrUnrepresentableFrameRates() {
        for frameRate in [0, -1, Int(Int32.max) + 1, Int.max] {
            XCTAssertNil(CameraCapturePolicy.clampedFrameDuration(
                frameRate: frameRate,
                minimum: CMTime(value: 1, timescale: 120),
                maximum: CMTime(value: 1, timescale: 30)
            ))
        }
    }

    func testAcceptsLargestRepresentableFrameRate() throws {
        let duration = try XCTUnwrap(
            CameraCapturePolicy.clampedFrameDuration(
                frameRate: Int(Int32.max),
                minimum: CMTime(value: 1, timescale: Int32.max),
                maximum: CMTime(value: 1, timescale: 1)
            )
        )

        XCTAssertEqual(duration.value, 1)
        XCTAssertEqual(duration.timescale, Int32.max)
    }
}
