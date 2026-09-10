import XCTest
@testable import CardScanMagic

/// Optional real iPhone fixture; generated fixtures do not claim device recall.
final class RealFrameReplayTests: XCTestCase {
    func testExportedProductionInputThroughFullEngineWhenProvided() throws {
        guard let path = ProcessInfo.processInfo.environment["RECOGNITION_TRACE_REPLAY_DIR"] else {
            throw XCTSkip("Set TEST_RUNNER_RECOGNITION_TRACE_REPLAY_DIR to an exported Recognition directory.")
        }
        let engine = try RecognitionEngine()
        let directory = URL(fileURLWithPath: path)
        let first = try RecognitionTraceReplay.run(recognitionDirectory: directory, engine: engine)
        let second = try RecognitionTraceReplay.run(recognitionDirectory: directory, engine: engine)
        XCTAssertEqual(first.detections, second.detections)
        XCTAssertEqual(first.callCounts, second.callCounts)
        XCTAssertGreaterThan(first.callCounts["coreML"] ?? 0, 0)
        XCTAssertEqual(first.callCounts["extractor"], 1)
        XCTAssertEqual(first.callCounts["fusion"], 2)
        let output = directory.appendingPathComponent("replay_trace.json")
        try RecognitionTraceJSON.data(first.trace).write(to: output, options: .atomic)
    }
}

