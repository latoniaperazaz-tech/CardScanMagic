import CoreImage
import CoreVideo
import XCTest
@testable import CardScanMagic

final class RecognitionTraceIsolationTests: XCTestCase {
    func testNonFiniteDiagnosticValuesExportAsNull() throws {
        let trace = RecognitionTrace()
        trace.event("invalidProductionInput", ["score": Double.nan, "nested": [Double.infinity, 0.7]])
        let snapshot = trace.snapshot()
        XCTAssertNoThrow(try JSONSerialization.data(withJSONObject: snapshot))
        let entry = try XCTUnwrap((snapshot["entries"] as? [[String: Any]])?.first)
        XCTAssertTrue(entry["score"] is NSNull)
        XCTAssertTrue((entry["nested"] as? [Any])?.first is NSNull)
    }

    func testNestedMetadataBudgetIsBoundedAndExplicit() {
        let trace = RecognitionTrace(maximumEntries: 100, maximumBytes: 1024)
        trace.event("oversized", ["values": Array(repeating: "diagnostic", count: 1000)])
        XCTAssertTrue(trace.entries.isEmpty)
        XCTAssertEqual(trace.truncatedEntries, 1)
        XCTAssertEqual(trace.snapshot()["metadataComplete"] as? Bool, false)
    }

    func testFullEngineCannotWaitForStalledTraceWriter() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        var config = RecognitionTraceConfiguration()
        config.directory = root; config.enabled = true
        let session = RecognitionTraceSession(runID: UUID(), sessionID: 1, configuration: config)
        let blocked = expectation(description: "writer stalled")
        let release = DispatchSemaphore(value: 0)
        session.flush {
            blocked.fulfill()
            if release.wait(timeout: .now() + 20) == .timedOut {
                XCTFail("Recognition failed to complete while disk writer was blocked")
            }
        }
        wait(for: [blocked], timeout: 2)
        defer { release.signal() }
        let input = try makeBuffer()
        let engine = try RecognitionEngine()
        let off = try RecognitionCallProbe.measure { try engine.recognize(pixelBuffer: input, orientation: .up) }
        let trace = try XCTUnwrap(session.makeTrace(frameID: 1, source: "native", width: 128, height: 192,
                                                   timestamp: 1, orientation: .up))
        // The writer is blocked throughout capture, inference, and trace completion.
        session.captureInput(input, orientation: .up, trace: trace)
        let on = try RecognitionCallProbe.measure {
            try RecognitionTrace.withCurrent(trace) { try engine.recognize(pixelBuffer: input, orientation: .up) }
        }
        session.complete(trace)
        XCTAssertEqual(off.0, on.0)
        XCTAssertEqual(off.1, on.1)
        release.signal()
        let flushed = expectation(description: "writer drained")
        session.flush { flushed.fulfill() }
        wait(for: [flushed], timeout: 10)
    }

    func testWindowAssociationCanArriveAfterRecognitionCompletes() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        var config = RecognitionTraceConfiguration(); config.directory = root; config.enabled = true
        let runID = UUID(), session = RecognitionTraceSession(runID: runID, sessionID: 3, configuration: config)
        let trace = try XCTUnwrap(session.makeTrace(frameID: 7, source: "snapshot", width: 128, height: 192,
                                                   timestamp: 7, orientation: .up))
        session.captureInput(try makeBuffer(), orientation: .up, trace: trace)
        session.complete(trace)
        var summary = Phase1DebugSummary(runID: runID, sessionID: 3, startedAt: Date(), finishedAt: Date(), reason: "stopped")
        summary.events = [window(100), window(101)]
        let exported = expectation(description: "linked")
        session.onExport = { _, complete in XCTAssertTrue(complete); exported.fulfill() }
        session.finish(summary)
        wait(for: [exported], timeout: 10)
        let (_, traces) = try RecognitionTraceComparison.loadSession(session.directory)
        XCTAssertEqual(traces.first?["captureWindowIDs"] as? [String], ["100", "101"])
        XCTAssertEqual(traces.first?["frameID"] as? String, "7")
        XCTAssertEqual(traces.first?["recognitionID"] as? String, trace.recognitionID)
        for id in [100, 101] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: session.directory.appendingPathComponent("Event-\(id)/event_manifest.json").path))
        }
    }

    private func window(_ id: UInt64) -> Phase1DebugEvent {
        Phase1DebugEvent(eventID: id, triggerFrameID: 7, triggerTimestamp: 7, frameIDs: [7],
            selectedFrameIDs: [7], timestamps: [7], informationScores: [0.8], frames: [],
            missingPreFrames: 6, preFramesReceived: 0, postFramesReceived: 0, missingPostFrames: 6,
            obtainedRequestedPreFrames: false, obtainedRequestedPostFrames: false, complete: false,
            recognitionAttempts: [], recognitionResults: [], finalDecision: [], hasRecognitionResult: false,
            hasConcreteCardValue: false, hasUsableFrame: true, wasSentToRecognition: true, outcome: "completedEmpty")
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("TraceIsolation-" + UUID().uuidString)
    }
    private func makeBuffer() throws -> CVPixelBuffer {
        var value: CVPixelBuffer?
        let status = CVPixelBufferCreate(kCFAllocatorDefault, 128, 192, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &value)
        XCTAssertEqual(status, kCVReturnSuccess)
        let buffer = try XCTUnwrap(value)
        CIContext().render(CIImage(color: CIColor(red: 0.1, green: 0.18, blue: 0.15))
            .cropped(to: CGRect(x: 0, y: 0, width: 128, height: 192)), to: buffer)
        return buffer
    }
}
