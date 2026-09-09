import CoreVideo
import XCTest
@testable import CardScanMagic

final class CaptureBacklogTests: XCTestCase {
    func testPreservesTransientFrameWhileModelIsBusy() {
        let queue = CaptureBacklog<String>(capacity: 3, maximumAge: 1)
        queue.reset(generation: 1)
        queue.insert("before", timestamp: 0, priority: 0, bytes: 1, generation: 1)
        queue.insert("card", timestamp: 0.008, priority: 0.9, bytes: 1, generation: 1)
        queue.insert("after", timestamp: 0.016, priority: 0, bytes: 1, generation: 1)
        queue.insert("background", timestamp: 0.024, priority: 0, bytes: 1, generation: 1)
        XCTAssertEqual(queue.take(generation: 1)?.value, "card")
        XCTAssertEqual(queue.take(generation: 1)?.value, "after")
        XCTAssertEqual(queue.take(generation: 1)?.value, "background")
        XCTAssertNil(queue.take(generation: 1))
    }

    func testDoesNotNeedAnotherCameraFrameToDrain() {
        let queue = CaptureBacklog<Int>()
        queue.reset(generation: 1)
        queue.insert(42, timestamp: 10, priority: 1, bytes: 4, generation: 1)
        XCTAssertTrue(queue.hasFrames(generation: 1))
        XCTAssertEqual(queue.take(generation: 1)?.value, 42)
        XCTAssertFalse(queue.hasFrames(generation: 1))
    }

    func testBoundsMemoryAndRejectsStaleGeneration() {
        let queue = CaptureBacklog<Int>(capacity: 10, byteLimit: 8)
        queue.reset(generation: 1)
        queue.insert(1, timestamp: 0, priority: 1, bytes: 4, generation: 1)
        queue.insert(2, timestamp: 0.01, priority: 0, bytes: 4, generation: 1)
        queue.insert(3, timestamp: 0.02, priority: 1, bytes: 4, generation: 1)
        XCTAssertEqual(queue.statistics.bytes, 8)
        XCTAssertEqual(queue.statistics.dropped, 1)
        XCTAssertFalse(queue.insert(4, timestamp: 0.03, priority: 2, bytes: 9, generation: 1))
        queue.reset(generation: 2)
        XCTAssertFalse(queue.insert(5, timestamp: 0.04, priority: 1, bytes: 4, generation: 1))
        XCTAssertNil(queue.take(generation: 1))
        XCTAssertEqual(queue.statistics.bytes, 0)
    }

    func testRejectsDuplicateAndInvalidTimestamps() {
        let queue = CaptureBacklog<Int>()
        queue.reset(generation: 1)
        XCTAssertTrue(queue.insert(1, timestamp: 1, priority: 1, bytes: 1, generation: 1))
        XCTAssertFalse(queue.insert(2, timestamp: 1, priority: 1, bytes: 1, generation: 1))
        XCTAssertFalse(queue.insert(3, timestamp: .nan, priority: 1, bytes: 1, generation: 1))
        XCTAssertFalse(queue.insert(4, timestamp: 0.9, priority: 1, bytes: 1, generation: 1))
    }

    func testExpiresOldCaptures() {
        let queue = CaptureBacklog<Int>(maximumAge: 0.5)
        queue.reset(generation: 1)
        queue.insert(1, timestamp: 0, priority: 1, bytes: 1, generation: 1)
        queue.insert(2, timestamp: 0.6, priority: 0, bytes: 1, generation: 1)
        XCTAssertEqual(queue.take(generation: 1)?.value, 2)
    }

    func testLowPriorityIncomingCaptureDoesNotEvictTransientEvidence() {
        let queue = CaptureBacklog<Int>(capacity: 1, byteLimit: 8)
        queue.reset(generation: 1)
        XCTAssertTrue(queue.insert(1, timestamp: 1, priority: 1, bytes: 8, generation: 1))
        XCTAssertFalse(queue.insert(2, timestamp: 1.01, priority: 0, bytes: 4, generation: 1))
        XCTAssertEqual(queue.statistics.bytes, 8)
        XCTAssertEqual(queue.statistics.dropped, 1)
        XCTAssertEqual(queue.take(generation: 1)?.value, 1)
    }

    func testByteAccountingDoesNotOverflowBeforeEviction() {
        let queue = CaptureBacklog<Int>(capacity: 2, byteLimit: Int.max)
        queue.reset(generation: 1)
        XCTAssertTrue(queue.insert(1, timestamp: 1, priority: 0, bytes: Int.max - 4, generation: 1))
        XCTAssertTrue(queue.insert(2, timestamp: 1.01, priority: 1, bytes: 8, generation: 1))
        XCTAssertEqual(queue.statistics.bytes, 8)
        XCTAssertEqual(queue.statistics.pending, 1)
        XCTAssertEqual(queue.take(generation: 1)?.value, 2)
    }

    func testFailedOldGenerationCannotDiscardNewSessionFrames() {
        let queue = CaptureBacklog<Int>()
        queue.reset(generation: 1)
        queue.insert(1, timestamp: 1, priority: 1, bytes: 8, generation: 1)
        queue.discard(generation: 1)
        XCTAssertEqual(queue.statistics.bytes, 0)
        XCTAssertEqual(queue.statistics.dropped, 1)
        queue.reset(generation: 2)
        queue.insert(2, timestamp: 2, priority: 1, bytes: 8, generation: 2)
        queue.discard(generation: 1)
        XCTAssertEqual(queue.statistics.bytes, 8)
        XCTAssertEqual(queue.take(generation: 2)?.value, 2)
    }

    func testDiscardReleasesCapturedValues() {
        final class Capture {}
        let queue = CaptureBacklog<Capture>()
        queue.reset(generation: 1)
        weak var retained: Capture?
        do {
            let capture = Capture()
            retained = capture
            queue.insert(capture, timestamp: 1, priority: 1, bytes: 8, generation: 1)
        }
        XCTAssertNotNil(retained)
        queue.discard(generation: 1)
        XCTAssertNil(retained)
    }

    func testSnapshotOwnsPixelStorage() throws {
        var source: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 16, 16, kCVPixelFormatType_32BGRA, nil, &source), kCVReturnSuccess)
        let original = try XCTUnwrap(source)
        XCTAssertEqual(CVPixelBufferLockBaseAddress(original, []), kCVReturnSuccess)
        let originalBase = try XCTUnwrap(CVPixelBufferGetBaseAddress(original))
        memset(originalBase, 17, CVPixelBufferGetDataSize(original))
        CVPixelBufferUnlockBaseAddress(original, [])
        let snapshot = try XCTUnwrap(CapturedImage.copy(original, orientation: .up))
        XCTAssertEqual(CVPixelBufferLockBaseAddress(original, []), kCVReturnSuccess)
        memset(try XCTUnwrap(CVPixelBufferGetBaseAddress(original)), 99, CVPixelBufferGetDataSize(original))
        CVPixelBufferUnlockBaseAddress(original, [])
        XCTAssertEqual(CVPixelBufferLockBaseAddress(snapshot.pixelBuffer, .readOnly), kCVReturnSuccess)
        defer { CVPixelBufferUnlockBaseAddress(snapshot.pixelBuffer, .readOnly) }
        let pixel = try XCTUnwrap(CVPixelBufferGetBaseAddress(snapshot.pixelBuffer))
        XCTAssertEqual(pixel.assumingMemoryBound(to: UInt8.self).pointee, 17)
    }

    func testPlanarSnapshotCopiesBothPlanesAndAccountsForAllocation() throws {
        let source = try planarBuffer(luma: 17)
        let snapshot = try XCTUnwrap(CapturedImage.copy(source, orientation: .right))
        try fill(source, luma: 99)

        XCTAssertEqual(snapshot.orientation, .right)
        XCTAssertEqual(CVPixelBufferGetPlaneCount(snapshot.pixelBuffer), 2)
        XCTAssertGreaterThanOrEqual(snapshot.bytes, CVPixelBufferGetDataSize(snapshot.pixelBuffer))
        XCTAssertEqual(CVPixelBufferLockBaseAddress(snapshot.pixelBuffer, .readOnly), kCVReturnSuccess)
        defer { CVPixelBufferUnlockBaseAddress(snapshot.pixelBuffer, .readOnly) }
        let luma = try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(snapshot.pixelBuffer, 0))
        let chroma = try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(snapshot.pixelBuffer, 1))
        XCTAssertEqual(luma.assumingMemoryBound(to: UInt8.self).pointee, 17)
        XCTAssertEqual(chroma.assumingMemoryBound(to: UInt8.self).pointee, 128)
    }

    func testStaleGenerationCannotChangeActivityReference() throws {
        let meter = CaptureActivityMeter()
        let dark = try planarBuffer(luma: 0)
        let bright = try planarBuffer(luma: 255)
        meter.reset(generation: 2)

        XCTAssertEqual(meter.measure(dark, generation: 2), 0)
        XCTAssertEqual(meter.measure(bright, generation: 1), 0)
        XCTAssertEqual(meter.measure(dark, generation: 2), 0)
        XCTAssertEqual(meter.measure(bright, generation: 2), 1, accuracy: 0.001)
        meter.reset(generation: 3)
        XCTAssertEqual(meter.measure(dark, generation: 3), 0)
    }

    private func planarBuffer(luma: Int32) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        XCTAssertEqual(
            CVPixelBufferCreate(
                kCFAllocatorDefault,
                32,
                32,
                kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
                [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary,
                &buffer
            ),
            kCVReturnSuccess
        )
        let result = try XCTUnwrap(buffer)
        try fill(result, luma: luma)
        return result
    }

    private func fill(_ buffer: CVPixelBuffer, luma: Int32) throws {
        XCTAssertEqual(CVPixelBufferLockBaseAddress(buffer, []), kCVReturnSuccess)
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        for plane in 0..<CVPixelBufferGetPlaneCount(buffer) {
            let base = try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(buffer, plane))
            let bytes = CVPixelBufferGetBytesPerRowOfPlane(buffer, plane)
                * CVPixelBufferGetHeightOfPlane(buffer, plane)
            memset(base, plane == 0 ? luma : 128, bytes)
        }
    }
}
