import CoreVideo
import XCTest
@testable import CardScanMagic

final class Phase1DiagnosticsIntegrationTests: XCTestCase {
    func testStopReturnsDuringInferenceAndExportsOnceAfterInferenceAndCameraCallbackFinish() throws {
        let entered = expectation(description: "recognition entered")
        let release = DispatchSemaphore(value: 0)
        let summaries = Locked<[Phase1DebugSummary]>([])
        let exported = expectation(description: "one completed summary")
        exported.assertForOverFulfill = true
        let pipeline = ScanPipeline(recognizer: { _, _ in
            entered.fulfill()
            XCTAssertEqual(release.wait(timeout: .now() + 5), .success)
            return []
        })
        defer { release.signal(); pipeline.stop() }
        pipeline.onDebugSummary = { summary in
            summaries.update { $0.append(summary) }
            exported.fulfill()
        }
        let sessionID = pipeline.start()
        waitUntilReady(pipeline)
        let image = try buffer(0)
        let finishCamera = try XCTUnwrap(pipeline.cameraCallbackBegan(timestamp: 100))
        pipeline.submit(pixelBuffer: image, timestamp: 100, orientation: .up, cameraCounted: true)
        wait(for: [entered], timeout: 2)

        let capturedAndStopped = expectation(description: "camera and stop return while recognition remains blocked")
        DispatchQueue.global().async {
            let callback = pipeline.cameraCallbackBegan(timestamp: 101)
            pipeline.submit(pixelBuffer: image, timestamp: 101, orientation: .up, cameraCounted: true)
            callback?(0.002)
            pipeline.stop()
            pipeline.stop()
            capturedAndStopped.fulfill()
        }
        wait(for: [capturedAndStopped], timeout: 2)
        XCTAssertTrue(summaries.value.isEmpty)

        release.signal()
        waitUntilReady(pipeline)
        XCTAssertTrue(summaries.value.isEmpty, "The original camera callback still owns an unfinished diagnostic activity")
        finishCamera(0.004)
        wait(for: [exported], timeout: 2)
        pipeline.stop()

        let summary = try XCTUnwrap(summaries.value.first)
        XCTAssertEqual(summaries.value.count, 1)
        XCTAssertEqual(summary.sessionID, sessionID)
        XCTAssertEqual(summary.cameraFrames, 2)
        XCTAssertEqual(summary.successfulSnapshots, 2)
        XCTAssertEqual(summary.recognitionCompletions, 1)
        XCTAssertEqual(summary.metrics["cameraCallback"]?.count, 2)
        XCTAssertEqual(summary.metrics["cameraCallback"]?.maxMs, 4)
        XCTAssertEqual(summary.recognitionAttempts.first?.acceptedBySession, false)
    }

    func testLateRecognitionAndCameraCallbackStayInTheirOriginalRunAfterRestart() throws {
        let entered = expectation(description: "old recognition entered")
        let release = DispatchSemaphore(value: 0)
        let card = try XCTUnwrap(CardFace.parse("10c"))
        let summaries = Locked<[Phase1DebugSummary]>([])
        let exported = expectation(description: "both runs exported")
        exported.expectedFulfillmentCount = 2
        exported.assertForOverFulfill = true
        var first = true
        let pipeline = ScanPipeline(recognizer: { _, _ in
            if first {
                first = false
                entered.fulfill()
                XCTAssertEqual(release.wait(timeout: .now() + 5), .success)
                return [CardDetection(card: card, confidence: 0.94,
                    boundingBox: CGRect(x: 0.2, y: 0.2, width: 0.5, height: 0.6),
                    hasIndependentSupport: true)]
            }
            return []
        })
        defer { release.signal(); pipeline.stop() }
        pipeline.onRecords = { _, _ in XCTFail("The old session's result cannot become a formal record") }
        pipeline.onDebugSummary = { summary in
            summaries.update { $0.append(summary) }
            exported.fulfill()
        }
        let oldID = pipeline.start()
        waitUntilReady(pipeline)
        let image = try buffer(0)
        let oldCallback = try XCTUnwrap(pipeline.cameraCallbackBegan(timestamp: 100))
        pipeline.submit(pixelBuffer: image, timestamp: 100, orientation: .up, cameraCounted: true)
        wait(for: [entered], timeout: 2)
        pipeline.stop()
        let newID = pipeline.start()
        let newCallback = try XCTUnwrap(pipeline.cameraCallbackBegan(timestamp: 200))
        release.signal()
        waitUntilReady(pipeline)
        pipeline.submit(pixelBuffer: image, timestamp: 200, orientation: .up, cameraCounted: true)
        waitUntilReady(pipeline)
        newCallback(0.002)
        pipeline.stop()
        oldCallback(0.003)
        wait(for: [exported], timeout: 2)

        let old = try XCTUnwrap(summaries.value.first { $0.sessionID == oldID })
        let new = try XCTUnwrap(summaries.value.first { $0.sessionID == newID })
        XCTAssertNotEqual(old.runID, new.runID)
        XCTAssertEqual(old.cameraFrames, 1)
        XCTAssertEqual(new.cameraFrames, 1)
        XCTAssertEqual(old.recognitionResults, 1)
        XCTAssertEqual(old.recognitionRejectedBySession, 1)
        XCTAssertEqual(old.recognitionAttempts.first?.resultCodes, [card.code])
        XCTAssertEqual(old.recognitionAttempts.first?.acceptedBySession, false)
        XCTAssertEqual(old.metrics["cameraCallback"]?.maxMs, 3)
        XCTAssertEqual(old.formalRecords, 0)
        XCTAssertEqual(new.recognitionCompletions, 1)
        XCTAssertEqual(new.recognitionResults, 0)
        XCTAssertEqual(new.recognitionRejectedBySession, 0)
        XCTAssertEqual(new.recognitionAttempts.first?.acceptedBySession, true)
        XCTAssertEqual(new.metrics["cameraCallback"]?.maxMs, 2)
        XCTAssertEqual(new.formalRecords, 0)
    }

    func testCameraFPSAndCallbackCountersIncludeFailedSnapshotsWithoutDoubleCounting() throws {
        var configuration = CaptureConfiguration()
        configuration.snapshotByteLimit = 1
        let pipeline = ScanPipeline(configuration: configuration, recognizer: { _, _ in
            XCTFail("A failed snapshot must not reach recognition")
            return []
        })
        defer { pipeline.stop() }
        let summaries = Locked<[Phase1DebugSummary]>([])
        let exported = expectation(description: "failed snapshot run exported")
        pipeline.onDebugSummary = { summary in
            summaries.update { $0.append(summary) }
            exported.fulfill()
        }
        pipeline.start()
        waitUntilReady(pipeline)
        let image = try buffer(0)
        for timestamp in [100.0, 101.0] {
            let callback = try XCTUnwrap(pipeline.cameraCallbackBegan(timestamp: timestamp))
            pipeline.submit(pixelBuffer: image, timestamp: timestamp, orientation: .up, cameraCounted: true)
            callback(0.001)
        }
        // Direct submit remains supported by tests/tools that have no CameraService.
        pipeline.submit(pixelBuffer: image, timestamp: 102, orientation: .up)
        pipeline.cameraDroppedFrame()
        pipeline.stop()
        wait(for: [exported], timeout: 2)

        let summary = try XCTUnwrap(summaries.value.first)
        XCTAssertEqual(summary.cameraFrames, 3)
        XCTAssertEqual(summary.averageFPS, 1, accuracy: 0.0001)
        XCTAssertEqual(summary.droppedFrames, 1)
        XCTAssertEqual(summary.snapshotFailures, 3)
        XCTAssertEqual(summary.snapshotAllocationFailures, 0, "Budget rejection occurs before CoreVideo allocation")
        XCTAssertEqual(summary.successfulSnapshots, 0)
        XCTAssertEqual(summary.recognitionFramesSent, 0)
        XCTAssertEqual(summary.metrics["cameraCallback"]?.count, 2)
        XCTAssertEqual(summary.metrics["motionMeasure"]?.count, 3)
    }

    func testFormalRecordHookCountsAcceptedRecordOnce() throws {
        let card = try XCTUnwrap(CardFace.parse("10c"))
        let pipeline = ScanPipeline(recognizer: { _, _ in
            [CardDetection(card: card, confidence: 0.94,
                boundingBox: CGRect(x: 0.2, y: 0.2, width: 0.5, height: 0.6),
                hasIndependentSupport: true)]
        })
        defer { pipeline.stop() }
        let accepted = expectation(description: "strong single frame formally recorded")
        let exported = expectation(description: "accepted record run exported")
        let summaries = Locked<[Phase1DebugSummary]>([])
        pipeline.onRecords = { [weak pipeline] sessionID, records in
            pipeline?.recordFormalRecords(records, sessionID: sessionID)
            pipeline?.recordFormalRecords(records, sessionID: sessionID)
            accepted.fulfill()
        }
        pipeline.onDebugSummary = { summary in
            summaries.update { $0.append(summary) }
            exported.fulfill()
        }
        pipeline.start()
        waitUntilReady(pipeline)
        pipeline.submit(pixelBuffer: try buffer(0), timestamp: 100, orientation: .up)
        wait(for: [accepted], timeout: 2)
        pipeline.stop()
        wait(for: [exported], timeout: 2)

        let summary = try XCTUnwrap(summaries.value.first)
        XCTAssertEqual(summary.trackDecisions, 1)
        XCTAssertEqual(summary.formalRecords, 1)
        XCTAssertEqual(summary.confirmedCards, 1)
        XCTAssertEqual(summary.sessionUniqueCards, 1)
        XCTAssertEqual(summary.decisions.first?.formallyRecorded, true)
        XCTAssertEqual(summary.decisions.first?.card, card.code)
    }

    func testResetBetweenCameraCallbackAndSubmitReportsBoundaryFrame() throws {
        let pipeline = ScanPipeline(recognizer: { _, _ in [] })
        defer { pipeline.stop() }
        let summaries = Locked<[Phase1DebugSummary]>([])
        let exported = expectation(description: "both boundary sessions exported")
        exported.expectedFulfillmentCount = 2
        pipeline.onDebugSummary = { summary in
            summaries.update { $0.append(summary) }
            exported.fulfill()
        }
        let oldID = pipeline.start()
        waitUntilReady(pipeline)
        let callback = try XCTUnwrap(pipeline.cameraCallbackBegan(timestamp: 100))
        let newID = try XCTUnwrap(pipeline.resetRecordedState())
        waitUntilReady(pipeline)
        pipeline.submit(pixelBuffer: try buffer(0), timestamp: 100, orientation: .up, cameraCounted: true)
        waitUntilReady(pipeline)
        callback(0.001)
        pipeline.stop()
        wait(for: [exported], timeout: 2)
        let old = try XCTUnwrap(summaries.value.first { $0.sessionID == oldID })
        let new = try XCTUnwrap(summaries.value.first { $0.sessionID == newID })
        XCTAssertEqual(old.cameraFrames, 1)
        XCTAssertEqual(old.successfulSnapshots, 0)
        XCTAssertEqual(new.cameraFrames, 0)
        XCTAssertEqual(new.successfulSnapshots, 1)
        XCTAssertEqual(new.cameraFramesFromOtherSessions, 1)
        XCTAssertEqual(new.cameraTransitions.first?.sourceSessionID, oldID)
        XCTAssertEqual(new.cameraTransitions.first?.frameID, Double(100).bitPattern)
    }

    func testRecognitionErrorWaitsForAsynchronousUIReceiptBeforeSummary() throws {
        enum Failure: Error { case injected }
        let card = try XCTUnwrap(CardFace.parse("10c"))
        var invocation = 0
        let pipeline = ScanPipeline(recognizer: { _, _ in
            invocation += 1
            if invocation == 2 { throw Failure.injected }
            return [CardDetection(card: card, confidence: 0.94,
                boundingBox: CGRect(x: 0.2, y: 0.2, width: 0.5, height: 0.6), hasIndependentSupport: true)]
        })
        defer { pipeline.stop() }
        let pending = Locked<([CardRecord], DiagnosticRecordReceipt)?>(nil)
        let delivered = expectation(description: "UI delivery has not acknowledged yet")
        let failed = expectation(description: "next recognition failed")
        let exported = expectation(description: "summary after UI acknowledgement")
        let summaries = Locked<[Phase1DebugSummary]>([])
        pipeline.onRecordsWithDiagnostics = { _, records, receipt in
            pending.update { $0 = (records, receipt) }
            delivered.fulfill()
        }
        pipeline.onError = { _, _ in failed.fulfill() }
        pipeline.onDebugSummary = { summary in
            summaries.update { $0.append(summary) }
            exported.fulfill()
        }
        pipeline.start()
        waitUntilReady(pipeline)
        let image = try buffer(0)
        pipeline.submit(pixelBuffer: image, timestamp: 100, orientation: .up)
        wait(for: [delivered], timeout: 2)
        waitUntilReady(pipeline)
        pipeline.submit(pixelBuffer: image, timestamp: 101, orientation: .up)
        wait(for: [failed], timeout: 2)
        waitUntilReady(pipeline)
        XCTAssertTrue(summaries.value.isEmpty)
        let receipt = try XCTUnwrap(pending.value)
        receipt.1.complete(accepted: receipt.0)
        receipt.1.complete(accepted: receipt.0)
        wait(for: [exported], timeout: 2)
        let summary = try XCTUnwrap(summaries.value.first)
        XCTAssertEqual(summary.reason, "recognitionError")
        XCTAssertEqual(summary.formalRecords, 1)
        XCTAssertEqual(summary.recognitionErrors, 1)
        XCTAssertTrue(summary.decisions.first?.formallyRecorded == true)
    }

    private func waitUntilReady(_ pipeline: ScanPipeline) {
        let ready = expectation(description: "recognition queue barrier")
        pipeline.whenReady { ready.fulfill() }
        wait(for: [ready], timeout: 2)
    }

    private func buffer(_ value: Int32) throws -> CVPixelBuffer {
        var result: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 32, 32,
            kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &result), kCVReturnSuccess)
        let image = try XCTUnwrap(result)
        XCTAssertEqual(CVPixelBufferLockBaseAddress(image, []), kCVReturnSuccess)
        defer { CVPixelBufferUnlockBaseAddress(image, []) }
        for plane in 0..<2 {
            memset(try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(image, plane)), plane == 0 ? value : 128,
                   CVPixelBufferGetBytesPerRowOfPlane(image, plane) * CVPixelBufferGetHeightOfPlane(image, plane))
        }
        return image
    }

    private final class Locked<Value> {
        private let lock = NSLock()
        private var stored: Value
        init(_ value: Value) { stored = value }
        var value: Value {
            lock.lock(); defer { lock.unlock() }
            return stored
        }
        func update(_ body: (inout Value) -> Void) {
            lock.lock(); defer { lock.unlock() }
            body(&stored)
        }
    }
}
