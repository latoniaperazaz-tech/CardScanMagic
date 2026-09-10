import CoreImage
import CoreVideo
import XCTest
@testable import CardScanMagic

final class RecognitionTraceStorageTests: XCTestCase {
    func testLosslessPlanarAndBGRAInputRoundTripWithOrientationAndAttachments() throws {
        for format in [kCVPixelFormatType_32BGRA, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
                       kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange] {
            let original = try makeBuffer(format)
            CVBufferSetAttachment(original, kCVImageBufferColorPrimariesKey,
                                  kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
            CVBufferSetAttachment(original, kCVImageBufferTransferFunctionKey,
                                  kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
            let first = try RecognitionTracePixels.capture(original, orientation: .right)
            let folder = temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: folder) }
            try first.write(to: folder)
            let read = try RecognitionTracePixels.read(from: folder)
            let restored = try read.restore()
            let second = try RecognitionTracePixels.capture(restored, orientation: .right)
            XCTAssertEqual(first.metadata.pixelFormat, second.metadata.pixelFormat)
            XCTAssertEqual(first.metadata.orientation, second.metadata.orientation)
            XCTAssertTrue(second.metadata.metadataComplete)
            XCTAssertEqual(first.attachments, second.attachments)
            for index in first.planes.indices {
                // Compare active bytes, including all original stride bytes when allocation preserves alignment.
                let lhs = first.metadata.planes[index], rhs = second.metadata.planes[index]
                for row in 0..<lhs.height {
                    let count = min(lhs.bytesPerRow, rhs.bytesPerRow)
                    XCTAssertEqual(first.planes[index].subdata(in: row * lhs.bytesPerRow ..< row * lhs.bytesPerRow + count),
                                   second.planes[index].subdata(in: row * rhs.bytesPerRow ..< row * rhs.bytesPerRow + count))
                }
            }
        }
    }

    func testCorruptLosslessPlaneIsRejectedBeforeProductionReplay() throws {
        let packet = try RecognitionTracePixels.capture(makeBuffer(kCVPixelFormatType_32BGRA), orientation: .up)
        let folder = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        try packet.write(to: folder)
        try Data([1]).write(to: folder.appendingPathComponent(packet.metadata.planes[0].file))
        XCTAssertThrowsError(try RecognitionTracePixels.read(from: folder))
    }

    func testTraceContextRestoresOnThrowAndCountsWhenTraceIsOff() throws {
        enum Failure: Error { case expected }
        let outer = RecognitionTrace(), inner = RecognitionTrace()
        try RecognitionTrace.withCurrent(outer) {
            XCTAssertThrowsError(try RecognitionTrace.withCurrent(inner) { throw Failure.expected })
            XCTAssertTrue(RecognitionTrace.current === outer)
        }
        XCTAssertNil(RecognitionTrace.current)
        let (_, calls) = RecognitionCallProbe.measure { RecognitionTrace.call("ocr") }
        XCTAssertEqual(calls["ocr"], 1)
        XCTAssertNil(RecognitionTrace.current)
    }

    func testSessionExportsEmptyCandidateTraceAndUIReceiptBeforeCompleteManifest() throws {
        var config = RecognitionTraceConfiguration()
        config.enabled = true; config.directory = temporaryDirectory(); config.testLabel = "FULL 9C"
        defer { try? FileManager.default.removeItem(at: config.directory) }
        let runID = UUID()
        let session = RecognitionTraceSession(runID: runID, sessionID: 4, configuration: config)
        let buffer = try makeBuffer(kCVPixelFormatType_32BGRA)
        session.sourceFrame(10, timestamp: 1, originalWidth: 64, originalHeight: 96, snapshotWidth: 64, snapshotHeight: 96)
        let trace = try XCTUnwrap(session.makeTrace(frameID: 10, source: "native", width: 64, height: 96,
                                                  timestamp: 1, orientation: .up))
        session.captureInput(buffer, orientation: .up, trace: trace)
        trace.event("extractor", ["state": "completed", "candidateCount": 0, "reason": "NO_PARTIAL_CANDIDATE"])
        session.complete(trace)
        session.recordUI(recognitionID: trace.recognitionID, records: [["recordAccepted": false, "recordRejectReason": "UI_REJECTED"]])
        let finished = expectation(description: "exported")
        session.onExport = { _, complete in XCTAssertTrue(complete); finished.fulfill() }
        let summary = Phase1DebugSummary(runID: runID, sessionID: 4, startedAt: Date(), finishedAt: Date(), reason: "stopped")
        session.finish(summary)
        wait(for: [finished], timeout: 10)
        let (manifest, traces) = try RecognitionTraceComparison.loadSession(session.directory)
        XCTAssertEqual(manifest["complete"] as? Bool, true)
        XCTAssertEqual(traces.count, 1)
        XCTAssertEqual((traces[0]["uiReceipts"] as? [[String: Any]])?.count, 1)
        XCTAssertEqual(traces[0]["inputSaved"] as? Bool, true)
    }

    func testCapacityFailureIsExplicitAndDoesNotPreventTraceCompletion() throws {
        var config = RecognitionTraceConfiguration()
        config.enabled = true; config.directory = temporaryDirectory(); config.maximumQueuedBytes = 1
        defer { try? FileManager.default.removeItem(at: config.directory) }
        let runID = UUID(), session = RecognitionTraceSession(runID: runID, sessionID: 7, configuration: config)
        let trace = try XCTUnwrap(session.makeTrace(frameID: 1, source: "native", width: 64, height: 96, timestamp: 1, orientation: .up))
        session.captureInput(try makeBuffer(kCVPixelFormatType_32BGRA), orientation: .up, trace: trace)
        trace.event("engine.final", ["finalDetections": []])
        session.complete(trace)
        let exported = expectation(description: "incomplete export")
        session.onExport = { _, complete in XCTAssertFalse(complete); exported.fulfill() }
        session.finish(Phase1DebugSummary(runID: runID, sessionID: 7, startedAt: Date(), finishedAt: Date(), reason: "stopped"))
        wait(for: [exported], timeout: 10)
        let (manifest, traces) = try RecognitionTraceComparison.loadSession(session.directory)
        XCTAssertFalse((manifest["errors"] as? [String] ?? []).isEmpty)
        XCTAssertEqual(traces.first?["inputSaved"] as? Bool, false)
    }

    func testNormalBuildDefaultsTraceOff() {
        XCTAssertFalse(RecognitionTraceConfiguration().enabled)
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("TraceTests-" + UUID().uuidString)
    }
    private func makeBuffer(_ format: OSType) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 64, 96, format,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer), kCVReturnSuccess)
        let result = try XCTUnwrap(buffer)
        CVPixelBufferLockBaseAddress(result, [])
        defer { CVPixelBufferUnlockBaseAddress(result, []) }
        let planar = CVPixelBufferIsPlanar(result)
        for plane in 0..<(planar ? CVPixelBufferGetPlaneCount(result) : 1) {
            let base = planar ? CVPixelBufferGetBaseAddressOfPlane(result, plane) : CVPixelBufferGetBaseAddress(result)
            let stride = planar ? CVPixelBufferGetBytesPerRowOfPlane(result, plane) : CVPixelBufferGetBytesPerRow(result)
            let height = planar ? CVPixelBufferGetHeightOfPlane(result, plane) : CVPixelBufferGetHeight(result)
            guard let base else { throw RecognitionTraceIOError.invalidBuffer }
            let pointer = base.assumingMemoryBound(to: UInt8.self)
            for index in 0..<(stride * height) { pointer[index] = UInt8((index * 7 + plane * 53) % 256) }
        }
        return result
    }
}
