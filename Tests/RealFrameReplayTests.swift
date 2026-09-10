import CoreImage
import CoreVideo
import ImageIO
import XCTest
@testable import CardScanMagic

/// Optional real iPhone fixture; generated fixtures do not claim device recall.
final class RealFrameReplayTests: XCTestCase {
    func testLosslessExportReplayMatchesOriginalFullEngineAndAllCallCounts() throws {
        // Generated input validates the replay path and observer equivalence;
        // it does not establish the recall of an actual iPhone failure frame.
        let engine = try RecognitionEngine()
        let input = try makeInput()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("FullEngineReplay-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let orientation = CGImagePropertyOrientation.leftMirrored
        let original = try RecognitionCallProbe.measure {
            try RecognitionTrace.withCurrent(nil) { try engine.recognize(pixelBuffer: input, orientation: orientation) }
        }
        let packet = try RecognitionTracePixels.capture(input, orientation: orientation)
        try packet.write(to: folder)
        let replayed = try RecognitionTraceReplay.run(recognitionDirectory: folder, engine: engine)
        XCTAssertEqual(original.0, replayed.detections)
        XCTAssertEqual(original.1, replayed.callCounts)
        XCTAssertGreaterThan(replayed.callCounts["coreML"] ?? 0, 0)
        XCTAssertEqual(replayed.callCounts["extractor"], 1)
        XCTAssertEqual(replayed.callCounts["fusion"], 2)
        let entry = try XCTUnwrap((replayed.trace["entries"] as? [[String: Any]])?.first)
        XCTAssertEqual(entry["strict"] as? Bool, true)
        XCTAssertEqual(entry["pixelPlaneHashes"] as? [String], packet.metadata.planes.map(\.sha256))
        XCTAssertEqual(entry["attachmentsSHA256"] as? String, packet.metadata.attachmentsSHA256)
    }

    func testTraceCapacityAndDiskFailuresCannotChangeFullEngineResultOrCalls() throws {
        let engine = try RecognitionEngine()
        let input = try makeInput()
        let original = try RecognitionCallProbe.measure {
            try RecognitionTrace.withCurrent(nil) { try engine.recognize(pixelBuffer: input, orientation: .up) }
        }
        for diskFailure in [false, true] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("TraceEngineFailure-" + UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            var config = RecognitionTraceConfiguration()
            config.enabled = true; config.directory = root
            if diskFailure {
                // A regular file prevents the writer from creating its Session directory.
                try Data([1]).write(to: root)
            } else {
                config.maximumQueuedBytes = 1
            }
            let runID = UUID()
            let session = RecognitionTraceSession(runID: runID, sessionID: 1, configuration: config)
            let trace = try XCTUnwrap(session.makeTrace(frameID: 1, source: "native",
                width: CVPixelBufferGetWidth(input), height: CVPixelBufferGetHeight(input), timestamp: 1, orientation: .up))
            session.captureInput(input, orientation: .up, trace: trace)
            let traced = try RecognitionCallProbe.measure {
                try RecognitionTrace.withCurrent(trace) { try engine.recognize(pixelBuffer: input, orientation: .up) }
            }
            XCTAssertEqual(original.0, traced.0)
            XCTAssertEqual(original.1, traced.1)
            session.complete(trace)
            let finished = expectation(description: "failed trace writer finishes without changing Recognition")
            session.onExport = { _, complete in XCTAssertFalse(complete); finished.fulfill() }
            session.finish(Phase1DebugSummary(runID: runID, sessionID: 1,
                startedAt: Date(), finishedAt: Date(), reason: "stopped"))
            wait(for: [finished], timeout: 15)
        }
    }

    func testExportedProductionInputThroughFullEngineWhenProvided() throws {
        guard let path = ProcessInfo.processInfo.environment["RECOGNITION_TRACE_REPLAY_DIR"] else {
            throw XCTSkip("Set TEST_RUNNER_RECOGNITION_TRACE_REPLAY_DIR to an exported Recognition directory.")
        }
        let engine = try RecognitionEngine()
        let directory = URL(fileURLWithPath: path)
        let packet = try RecognitionTracePixels.read(from: directory)
        let orientation = try XCTUnwrap(CGImagePropertyOrientation(rawValue: packet.metadata.orientation))
        let input = try packet.restore()
        let withoutTrace = try RecognitionCallProbe.measure {
            try RecognitionTrace.withCurrent(nil) { try engine.recognize(pixelBuffer: input, orientation: orientation) }
        }
        let first = try RecognitionTraceReplay.run(recognitionDirectory: directory, engine: engine)
        let second = try RecognitionTraceReplay.run(recognitionDirectory: directory, engine: engine)
        XCTAssertEqual(first.detections, second.detections)
        XCTAssertEqual(first.callCounts, second.callCounts)
        XCTAssertEqual(withoutTrace.0, first.detections)
        XCTAssertEqual(withoutTrace.1, first.callCounts)
        XCTAssertGreaterThan(first.callCounts["coreML"] ?? 0, 0)
        XCTAssertEqual(first.callCounts["extractor"], 1)
        XCTAssertEqual(first.callCounts["fusion"], 2)
        let output = directory.appendingPathComponent("replay_trace.json")
        try RecognitionTraceJSON.data(first.trace).write(to: output, options: .atomic)
    }

    private func makeInput() throws -> CVPixelBuffer {
        // Plausible ink structure makes the fixture exercise the actual
        // Extractor; no points, rank candidates or model outputs are injected.
        let width = 320, height = 448
        let canvas = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        canvas.setFillColor(CGColor(red: 0.05, green: 0.16, blue: 0.14, alpha: 1))
        canvas.fill(CGRect(x: 0, y: 0, width: width, height: height))
        canvas.setFillColor(CGColor(gray: 0.98, alpha: 1))
        canvas.fill(CGRect(x: 40, y: 40, width: 240, height: 336))
        canvas.setFillColor(CGColor(gray: 0.03, alpha: 1))
        for row in 0..<3 {
            for column in 0..<3 {
                canvas.fillEllipse(in: CGRect(x: 90 + 50 * column, y: 100 + 100 * row, width: 20, height: 24))
            }
        }
        let image = CIImage(cgImage: try XCTUnwrap(canvas.makeImage()))
        var result: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &result), kCVReturnSuccess)
        let buffer = try XCTUnwrap(result)
        CIContext(options: [.cacheIntermediates: false]).render(image, to: buffer)
        return buffer
    }
}
