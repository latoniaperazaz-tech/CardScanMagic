import CoreVideo
import XCTest
@testable import CardScanMagic

final class CaptureSnapshotPoolTests: XCTestCase {
    func testDiagnosticDimensionsDescribeSuccessfulOutputAfterBudgetCompaction() throws {
        let pool = CaptureSnapshotPool(maximumDimension: 1280, minimumBufferCount: 58)
        XCTAssertEqual(pool.statistics.maximumDimension, 1280)
        XCTAssertEqual(pool.statistics.width, 0)
        XCTAssertEqual(pool.statistics.height, 0)
        let source = try buffer(width: 1920, height: 1080, format: kCVPixelFormatType_32BGRA, value: 42)
        let image = try XCTUnwrap(pool.copy(source, orientation: .up))
        let statistics = pool.statistics
        XCTAssertLessThan(statistics.width, 1280, "The owner budget compacts this BGRA snapshot below the configured cap")
        XCTAssertEqual(statistics.width, CVPixelBufferGetWidth(image.pixelBuffer))
        XCTAssertEqual(statistics.height, CVPixelBufferGetHeight(image.pixelBuffer))
        XCTAssertEqual(statistics.allocationFailures, 0)
        pool.reset()
        XCTAssertEqual(pool.statistics.width, statistics.width, "Reset retains the same pool and output format")
        XCTAssertEqual(pool.statistics.height, statistics.height)
        XCTAssertEqual(CVPixelBufferGetWidth(source), 1920)
    }

    func testDefaultBGRABudgetContinuesAfterRingAndPendingEventsFill() throws {
        let configuration = CaptureConfiguration()
        let pool = CaptureSnapshotPool(maximumDimension: configuration.snapshotMaximumDimension,
            byteLimit: configuration.snapshotByteLimit, minimumBufferCount: 58)
        let source = try buffer(width: 1280, height: 720, format: kCVPixelFormatType_32BGRA, value: 42)
        let scheduler = EventFrameScheduler<CapturedImage>()
        scheduler.reset(generation: 1)
        // Simulate one recognizer retaining its selected frame while the camera
        // fills both history and pending work, with no recognition progress.
        let inFlight = try XCTUnwrap(pool.copy(source, orientation: .right))
        var completedCounts: [Int] = []
        for id in UInt64(1)...90 {
            let image = try XCTUnwrap(pool.copy(source, orientation: .right), "Capture \(id) must not become permanently saturated")
            let frame = CaptureFrame(id: id, generation: 1, timestamp: Double(id) / 120,
                value: image, motionScore: 0, informationScore: id <= 26 ? 1 : 0)
            if let event = scheduler.ingest(frame, triggered: id == 7 || id == 20), event.isComplete {
                completedCounts.append(event.frames.count)
            }
        }
        XCTAssertEqual(completedCounts, [13, 13])
        XCTAssertEqual(scheduler.statistics.retainedFrames, 30)
        XCTAssertEqual(scheduler.statistics.pendingEventFrames, 26)
        XCTAssertEqual(pool.statistics.failures, 0)
        XCTAssertGreaterThanOrEqual(pool.statistics.allocationThreshold, 58)
        XCTAssertLessThanOrEqual(pool.statistics.maximumPixelBytes, configuration.snapshotByteLimit)
        XCTAssertLessThan(CVPixelBufferGetWidth(inFlight.pixelBuffer), 1280,
                          "BGRA snapshots must compact enough to reserve the required owners")
        XCTAssertEqual(try firstByte(inFlight.pixelBuffer), 42)
        XCTAssertEqual(CVPixelBufferGetWidth(source), 1280, "Native camera input must remain untouched")
    }

    func testNV12KeepsBothPlanesAndFitsRequiredOwnershipBudget() throws {
        let pool = CaptureSnapshotPool(minimumBufferCount: 58)
        let source = try buffer(width: 1920, height: 1080,
            format: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, value: 73)
        let image = try XCTUnwrap(pool.copy(source, orientation: .right))
        XCTAssertEqual(CVPixelBufferGetPlaneCount(image.pixelBuffer), 2)
        XCTAssertLessThanOrEqual(CVPixelBufferGetWidth(image.pixelBuffer), 1280)
        XCTAssertEqual(CVPixelBufferGetWidth(image.pixelBuffer) % 2, 0)
        XCTAssertEqual(CVPixelBufferGetHeight(image.pixelBuffer) % 2, 0)
        XCTAssertGreaterThanOrEqual(pool.statistics.allocationThreshold, 58)
        XCTAssertLessThanOrEqual(pool.statistics.maximumPixelBytes, 72 * 1_024 * 1_024)
        XCTAssertEqual(try firstByte(image.pixelBuffer), 73)
        XCTAssertEqual(try firstByte(image.pixelBuffer, plane: 1), 128)
        XCTAssertEqual(image.orientation, .right)
        XCTAssertGreaterThanOrEqual(image.bytes, CVPixelBufferGetDataSize(image.pixelBuffer))
    }

    func testResetCannotBypassBudgetWhileOldEventBuffersRemainOwned() throws {
        let budget = 1_024 * 1_024
        let pool = CaptureSnapshotPool(maximumDimension: 320, byteLimit: budget, minimumBufferCount: 6)
        let source = try buffer(width: 320, height: 240, format: kCVPixelFormatType_32BGRA, value: 17)
        var retained = [try XCTUnwrap(pool.copy(source, orientation: .up))]
        var allocationFailureDeltas: [Int] = []
        let capacity = pool.statistics.allocationThreshold
        for _ in 1..<capacity { retained.append(try XCTUnwrap(pool.copy(source, orientation: .up))) }
        XCTAssertNil(pool.copy(source, orientation: .up, diagnostics: { allocationFailureDeltas.append($0) }))
        XCTAssertEqual(allocationFailureDeltas, [1], "Even failed copies report their allocation delta")
        XCTAssertEqual(pool.statistics.failures, 1)
        XCTAssertEqual(pool.statistics.allocationFailures, 1, "CoreVideo threshold exhaustion is an allocation failure")
        pool.reset()
        XCTAssertEqual(pool.statistics.failures, 0)
        XCTAssertEqual(pool.statistics.allocationFailures, 0)
        XCTAssertEqual(pool.statistics.allocationThreshold, capacity)
        XCTAssertNil(pool.copy(source, orientation: .up, diagnostics: { allocationFailureDeltas.append($0) }),
                     "A new session cannot allocate around old event ownership")
        XCTAssertEqual(pool.statistics.allocationFailures, 1)
        retained.removeLast()
        retained.append(try XCTUnwrap(pool.copy(source, orientation: .up, diagnostics: { allocationFailureDeltas.append($0) })))
        XCTAssertEqual(allocationFailureDeltas, [1, 1, 0], "Attempt deltas remain correct across reset and successful reuse")
        XCTAssertEqual(pool.statistics.allocationFailures, 1, "Successful reuse does not count as a failure")
        XCTAssertEqual(retained.count, capacity)
        XCTAssertLessThanOrEqual(pool.statistics.maximumPixelBytes, budget)
        XCTAssertEqual(try firstByte(retained[0].pixelBuffer), 17)
    }

    func testLatchedSnapshotSurvivesRingOverwriteAndSourceMutation() throws {
        let pool = CaptureSnapshotPool(maximumDimension: 64, byteLimit: 1_024 * 1_024, minimumBufferCount: 4)
        let source = try buffer(width: 64, height: 64, format: kCVPixelFormatType_32BGRA, value: 19)
        let first = try XCTUnwrap(pool.copy(source, orientation: .up))
        let ring = RingFrameBuffer<CapturedImage>(capacity: 2)
        let event = [CaptureFrame(id: 1, generation: 1, timestamp: 1, value: first,
                                  motionScore: 0, informationScore: 0)]
        ring.append(event[0])
        for id in UInt64(2)...20 {
            try fill(source, value: Int32(id + 40))
            ring.append(CaptureFrame(id: id, generation: 1, timestamp: Double(id),
                value: try XCTUnwrap(pool.copy(source, orientation: .up)), motionScore: 0, informationScore: 0))
        }
        XCTAssertEqual(try firstByte(event[0].value.pixelBuffer), 19)
        XCTAssertEqual(try firstByte(try XCTUnwrap(ring.latest).value.pixelBuffer), 60)
        XCTAssertEqual(pool.statistics.failures, 0)
    }

    func testFormatChangeCannotCreateAnotherPoolAroundRetainedFrames() throws {
        let pool = CaptureSnapshotPool(maximumDimension: 320, byteLimit: 1_024 * 1_024, minimumBufferCount: 6)
        let bgra = try buffer(width: 320, height: 240, format: kCVPixelFormatType_32BGRA, value: 11)
        let nv12 = try buffer(width: 320, height: 240, format: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, value: 99)
        let retained = try XCTUnwrap(pool.copy(bgra, orientation: .up))
        let bound = pool.statistics.maximumPixelBytes
        XCTAssertNil(pool.copy(nv12, orientation: .up))
        XCTAssertEqual(pool.statistics.allocationFailures, 0, "Format rejection never calls CoreVideo allocation")
        pool.reset()
        XCTAssertNil(pool.copy(nv12, orientation: .up))
        XCTAssertEqual(pool.statistics.formatChangeRejections, 1)
        XCTAssertEqual(pool.statistics.failures, 1)
        XCTAssertEqual(pool.statistics.allocationFailures, 0)
        XCTAssertEqual(pool.statistics.maximumPixelBytes, bound)
        XCTAssertEqual(try firstByte(retained.pixelBuffer), 11)
    }

    func testImpossibleBudgetReturnsFailureInsteadOfPublishingUndersizedCapacity() throws {
        let pool = CaptureSnapshotPool(byteLimit: 1, minimumBufferCount: 58)
        let source = try buffer(width: 32, height: 32, format: kCVPixelFormatType_32BGRA, value: 0)
        var reportedDelta: Int?
        XCTAssertNil(pool.copy(source, orientation: .up, diagnostics: { reportedDelta = $0 }))
        XCTAssertEqual(reportedDelta, 0, "Pre-allocation rejection still invokes diagnostics exactly once")
        XCTAssertEqual(pool.statistics.maximumPixelBytes, 0)
        XCTAssertEqual(pool.statistics.allocationThreshold, 0)
        XCTAssertEqual(pool.statistics.failures, 1)
        XCTAssertEqual(pool.statistics.allocationFailures, 0, "Budget rejection occurs before CoreVideo allocation")
        XCTAssertEqual(pool.statistics.width, 0)
        XCTAssertEqual(pool.statistics.height, 0)
    }

    private func buffer(width: Int, height: Int, format: OSType, value: Int32) throws -> CVPixelBuffer {
        var result: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, width, height, format,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &result), kCVReturnSuccess)
        let buffer = try XCTUnwrap(result)
        try fill(buffer, value: value)
        return buffer
    }

    private func fill(_ buffer: CVPixelBuffer, value: Int32) throws {
        XCTAssertEqual(CVPixelBufferLockBaseAddress(buffer, []), kCVReturnSuccess)
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let planes = CVPixelBufferGetPlaneCount(buffer)
        if planes == 0 {
            memset(try XCTUnwrap(CVPixelBufferGetBaseAddress(buffer)), value,
                   CVPixelBufferGetBytesPerRow(buffer) * CVPixelBufferGetHeight(buffer))
        } else {
            for plane in 0..<planes {
                memset(try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(buffer, plane)), plane == 0 ? value : 128,
                    CVPixelBufferGetBytesPerRowOfPlane(buffer, plane) * CVPixelBufferGetHeightOfPlane(buffer, plane))
            }
        }
    }

    private func firstByte(_ buffer: CVPixelBuffer, plane: Int = 0) throws -> UInt8 {
        XCTAssertEqual(CVPixelBufferLockBaseAddress(buffer, .readOnly), kCVReturnSuccess)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let base = CVPixelBufferGetPlaneCount(buffer) == 0
            ? CVPixelBufferGetBaseAddress(buffer) : CVPixelBufferGetBaseAddressOfPlane(buffer, plane)
        return try XCTUnwrap(base).assumingMemoryBound(to: UInt8.self).pointee
    }
}
