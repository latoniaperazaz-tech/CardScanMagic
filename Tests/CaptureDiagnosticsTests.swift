import CoreGraphics
import XCTest
@testable import CardScanMagic

final class CaptureDiagnosticsTests: XCTestCase {
    private func recorder(limits: Phase1DebugLimits = Phase1DebugLimits(), sessionID: UInt64 = 1) -> CaptureDiagnostics {
        CaptureDiagnostics(sessionID: sessionID, configuration: CaptureConfiguration(), limits: limits)
    }

    private func frame(_ id: UInt64, generation: UInt64 = 1) -> CaptureFrame<Int> {
        CaptureFrame(id: id, generation: generation, timestamp: Double(id) / 60, value: Int(id),
            motionScore: 0.1, informationScore: Double(id) / 100,
            arrivalUptime: 10 + Double(id) / 60)
    }

    private func detection(_ code: String = "10c") -> CardDetection {
        CardDetection(card: CardFace.parse(code)!, confidence: 0.95,
                      boundingBox: CGRect(x: 0.2, y: 0.2, width: 0.3, height: 0.5))
    }

    private func event(_ id: UInt64, frames: [CaptureFrame<Int>], trigger: CaptureFrame<Int>,
                       complete: Bool = true, missingPre: Int = 0) -> CardEvent<Int> {
        CardEvent(id: id, generation: 1, triggerTimestamp: trigger.timestamp,
                  frames: frames, isComplete: complete, missingPreFrames: missingPre)
    }

    private func finish(_ value: CaptureDiagnostics, reason: String = "test") -> Phase1DebugSummary {
        let done = expectation(description: "diagnostic completion")
        var result: Phase1DebugSummary?
        value.close(reason: reason) { summary in result = summary; done.fulfill() }
        wait(for: [done], timeout: 3)
        return result!
    }

    private func select(_ value: CaptureDiagnostics, _ sample: CaptureFrame<Int>, source: String = "snapshot") {
        value.selected(sample, source: source, width: source == "native" ? 1920 : 1280,
                       height: source == "native" ? 1080 : 720)
        value.recognitionStarted(frameID: sample.id, at: sample.arrivalUptime + 0.001)
    }

    func testSingleUsablePreTriggerResultJoinsLaterWindowAndKeepsActualInput() {
        let value = recorder()
        let samples = (UInt64(1)...13).map { frame($0) }
        for sample in samples { value.capture(sample, width: 1088, height: 612) }
        select(value, samples[3], source: "native")
        value.recognitionCompleted(frameID: 4, at: samples[3].arrivalUptime + 0.020,
                                   detections: [detection()], acceptedBySession: true)
        value.event(event(7, frames: Array(samples.prefix(7)), trigger: samples[6], complete: false), latency: 0.002)
        value.event(event(7, frames: samples, trigger: samples[6]), latency: 0.003)
        let summary = finish(value)
        XCTAssertEqual(summary.captureEvents, 1)
        XCTAssertEqual(summary.recognitionResults, 1)
        XCTAssertEqual(summary.events[0].frameIDs, Array(UInt64(1)...13))
        XCTAssertEqual(summary.events[0].selectedFrameIDs, [4])
        XCTAssertEqual(summary.events[0].recognitionResults[0].resultCodes, ["10c"])
        XCTAssertEqual(summary.events[0].recognitionAttempts[0].source, "native")
        XCTAssertEqual(summary.events[0].recognitionAttempts[0].width, 1920)
        XCTAssertEqual(summary.frames[0].snapshotWidth, 1088)
        XCTAssertEqual(summary.snapshotMaximumDimension, 1280)
        XCTAssertTrue(summary.events[0].obtainedRequestedPreFrames)
        XCTAssertTrue(summary.events[0].obtainedRequestedPostFrames)
        XCTAssertEqual(summary.events[0].preFramesReceived, 6)
        XCTAssertEqual(summary.events[0].postFramesReceived, 6)
        XCTAssertEqual(summary.events[0].outcome, "detectionsWithoutDecision")
        XCTAssertEqual(summary.metrics["eventCreation"]?.count, 1)
        XCTAssertEqual(summary.metrics["eventUpdate"]?.count, 2)
        XCTAssertEqual(summary.metrics["captureToResult"]?.maxMs ?? 0, 20, accuracy: 0.001)
    }

    func testOverlappingWindowsDoNotDoubleGlobalRecognitionOrDecisionCounts() {
        let value = recorder()
        let sample = frame(1)
        value.capture(sample, width: 1280, height: 720)
        select(value, sample)
        value.recognitionCompleted(frameID: 1, at: 10.1, detections: [detection()], acceptedBySession: true)
        value.recognitionCompleted(frameID: 1, at: 10.2, detections: [detection()], acceptedBySession: true)
        value.event(event(1, frames: [sample], trigger: sample), latency: 0.001)
        value.event(event(2, frames: [sample], trigger: sample), latency: 0.001)
        let record = CardRecord(card: detection().card, confidence: 0.95, recordedAt: Date())
        let decision = CardPassDecision(eventID: record.id, record: record,
                                       captureTimestamps: [sample.timestamp], duplicateCard: false)
        value.decisions([decision, decision], at: 10.15)
        value.formalRecords([record, record])
        let summary = finish(value)
        XCTAssertEqual(summary.recognitionCompletions, 1)
        XCTAssertEqual(summary.recognitionResults, 1)
        XCTAssertEqual(summary.recognitionFramesSent, 1)
        XCTAssertEqual(summary.trackDecisions, 1)
        XCTAssertEqual(summary.confirmedCards, 1)
        XCTAssertEqual(summary.eventsSentToRecognition, 2)
        XCTAssertEqual(summary.events.map { $0.finalDecision.count }, [1, 1])
        XCTAssertEqual(summary.metrics["captureToConfirmed"]?.count, 1)
    }

    func testEmptyCancelledErrorNeverSelectedAndRejectedResultsRemainDistinct() {
        let value = recorder()
        for id in UInt64(1)...5 {
            let sample = frame(id)
            value.capture(sample, width: 1280, height: 720)
            value.event(event(id, frames: [sample], trigger: sample, complete: false, missingPre: 6), latency: 0)
            if id != 4 { select(value, sample) }
        }
        value.recognitionCompleted(frameID: 1, at: 11, detections: [], acceptedBySession: true)
        value.recognitionCancelled(frameID: 2)
        value.recognitionFailed(frameID: 3, at: 11, error: "model failure")
        value.recognitionCompleted(frameID: 5, at: 11, detections: [detection()], acceptedBySession: false)
        let summary = finish(value)
        XCTAssertEqual(summary.events.map(\.outcome), ["completedEmpty", "cancelled", "error", "neverSelected", "detectionsWithoutDecision"])
        XCTAssertEqual(summary.eventsWithNoRecognitionResult, 4)
        XCTAssertEqual(summary.recognitionCompletions, 2)
        XCTAssertEqual(summary.recognitionResults, 1)
        XCTAssertEqual(summary.recognitionErrors, 1)
        XCTAssertEqual(summary.recognitionCancelled, 1)
        XCTAssertEqual(summary.recognitionRejectedBySession, 1)
        XCTAssertFalse(summary.events[4].recognitionResults[0].acceptedBySession!)
        XCTAssertEqual(summary.events[0].missingPostFrames, 6)
        XCTAssertFalse(summary.events[0].complete)
    }

    func testWindowPreservesMultiplePhysicalDecisionsAndSessionDuplicate() {
        let value = recorder()
        let a = frame(1), b = frame(2)
        value.capture(a, width: 1280, height: 720)
        value.capture(b, width: 1280, height: 720)
        value.event(event(1, frames: [a, b], trigger: a), latency: 0)
        let first = CardRecord(card: detection().card, confidence: 0.9, recordedAt: Date())
        let second = CardRecord(card: detection().card, confidence: 0.9, recordedAt: Date())
        value.decisions([
            CardPassDecision(eventID: first.id, record: first, captureTimestamps: [a.timestamp], duplicateCard: false),
            CardPassDecision(eventID: second.id, record: second, captureTimestamps: [b.timestamp], duplicateCard: true)
        ], at: 10.2)
        value.formalRecords([first])
        let summary = finish(value)
        XCTAssertEqual(summary.events[0].finalDecision.count, 2)
        XCTAssertEqual(Set(summary.events[0].finalDecision.map(\.trackID)).count, 2)
        XCTAssertEqual(summary.trackDecisions, 2)
        XCTAssertEqual(summary.duplicateDecisions, 1)
        XCTAssertEqual(summary.confirmedCards, 1)
        XCTAssertEqual(summary.sessionUniqueCards, 1)
        XCTAssertTrue(summary.events[0].hasConcreteCardValue)
    }

    func testFullSessionHistogramKeepsOldMaximumAndCameraFPSCountsFailedSnapshots() {
        let value = recorder()
        value.cameraCallback(duration: 0.5)
        for _ in 0..<600 { value.cameraCallback(duration: 0.001) }
        for index in 0...60 { value.cameraFrame(timestamp: Double(index) / 60) }
        value.snapshotFailed(); value.snapshotFailed()
        value.allocationFailures(1)
        value.cameraDropped()
        value.motion(duration: 0.002, triggered: true)
        value.motion(duration: 0.003, triggered: true)
        value.motion(duration: 0.001, triggered: false)
        value.motion(duration: 0.001, triggered: true)
        let summary = finish(value)
        XCTAssertEqual(summary.cameraFrames, 61)
        XCTAssertEqual(summary.averageFPS, 60, accuracy: 0.0001)
        XCTAssertEqual(summary.successfulSnapshots, 0)
        XCTAssertEqual(summary.snapshotFailures, 2)
        XCTAssertEqual(summary.snapshotAllocationFailures, 1)
        XCTAssertEqual(summary.droppedFrames, 1)
        XCTAssertEqual(summary.motionTriggers, 2)
        XCTAssertEqual(summary.motionActiveSamples, 3)
        XCTAssertEqual(summary.metrics["cameraCallback"]?.count, 601)
        XCTAssertEqual(summary.metrics["cameraCallback"]?.maxMs, 500)
        let p95 = summary.metrics["cameraCallback"]?.p95Ms ?? 0
        XCTAssertGreaterThanOrEqual(p95, 1)
        XCTAssertLessThanOrEqual(p95, 1.011)
        XCTAssertGreaterThan(summary.residentMemorySamples, 0)
    }

    func testCloseDrainsAdmittedActivityOnlyOnceAndNewSessionIsIndependent() {
        let old = recorder()
        XCTAssertTrue(old.beginActivity())
        old.cameraFrame(timestamp: 1)
        let finished = expectation(description: "sealed run drains")
        finished.assertForOverFulfill = true
        old.close(reason: "stop") { summary in
            XCTAssertEqual(summary.cameraFrames, 2)
            XCTAssertEqual(summary.reason, "stop")
            finished.fulfill()
        }
        old.close(reason: "duplicate close") { _ in XCTFail("close must export only once") }
        XCTAssertFalse(old.beginActivity())
        old.cameraFrame(timestamp: 2)
        old.endActivity()
        wait(for: [finished], timeout: 3)
        old.cameraFrame(timestamp: 3)
        let next = recorder(sessionID: 2)
        next.cameraFrame(timestamp: 9)
        next.capture(frame(1), width: 1280, height: 720)
        let nextSummary = finish(next)
        XCTAssertEqual(nextSummary.cameraFrames, 1)
        XCTAssertEqual(nextSummary.successfulSnapshots, 0, "old generation is rejected")
        XCTAssertNotEqual(old.runID, next.runID)
        XCTAssertEqual(nextSummary.metrics["cameraCallback"]?.count, 0)
    }

    func testDetailTruncationIsExplicitWhileGlobalCountersContinue() {
        var limits = Phase1DebugLimits()
        limits.frames = 1; limits.events = 1; limits.recognitions = 1; limits.decisions = 1
        let value = recorder(limits: limits)
        for id in UInt64(1)...3 {
            let sample = frame(id)
            value.cameraFrame(timestamp: sample.timestamp)
            value.capture(sample, width: 1280, height: 720)
            value.event(event(id, frames: [sample], trigger: sample), latency: 0)
            select(value, sample)
            value.recognitionCompleted(frameID: id, at: 11, detections: [detection()], acceptedBySession: true)
            let record = CardRecord(card: detection().card, confidence: 0.9, recordedAt: Date())
            value.decisions([CardPassDecision(eventID: record.id, record: record,
                captureTimestamps: [sample.timestamp], duplicateCard: id > 1)], at: 11)
        }
        let summary = finish(value)
        XCTAssertEqual(summary.frames.count, 1)
        XCTAssertEqual(summary.events.count, 1)
        XCTAssertEqual(summary.recognitionAttempts.count, 1)
        XCTAssertEqual(summary.decisions.count, 1)
        XCTAssertEqual(summary.truncation.frames, 2)
        XCTAssertEqual(summary.truncation.events, 2)
        XCTAssertEqual(summary.truncation.recognitions, 2)
        XCTAssertEqual(summary.truncation.decisions, 2)
        XCTAssertFalse(summary.metadataComplete)
        XCTAssertTrue(summary.uniqueCountersExact)
        XCTAssertEqual(summary.captureEvents, 3)
        XCTAssertEqual(summary.recognitionFramesSent, 3)
        XCTAssertEqual(summary.recognitionResults, 3)
        XCTAssertEqual(summary.trackDecisions, 3)
        XCTAssertEqual(summary.metrics["captureToResult"]?.count, 3)
        XCTAssertEqual(summary.metrics["captureToConfirmed"]?.count, 3)
        XCTAssertEqual(summary.metrics["recognitionDuration"]?.count, 3,
                       "Duration must remain full-session after recognition detail truncation")
    }

    func testJSONRoundTripContainsEventTimesResultsAndReadableText() throws {
        let value = recorder()
        let sample = frame(1)
        value.capture(sample, width: 1280, height: 720)
        select(value, sample)
        value.recognitionCompleted(frameID: 1, at: 11, detections: [detection()], acceptedBySession: true)
        value.event(event(1, frames: [sample], trigger: sample), latency: 0.001)
        let summary = finish(value)
        let encoded = try JSONEncoder().encode(summary)
        let decoded = try JSONDecoder().decode(Phase1DebugSummary.self, from: encoded)
        XCTAssertEqual(decoded.runID, summary.runID)
        XCTAssertEqual(decoded.events[0].recognitionResults[0].resultCodes, ["10c"])
        XCTAssertNotNil(decoded.events[0].recognitionAttempts[0].startUptime)
        XCTAssertNotNil(decoded.events[0].recognitionAttempts[0].completedUptime)
        XCTAssertTrue(decoded.text.contains("## TEST SESSION"))
        XCTAssertTrue(decoded.text.contains("selectedFrameIDs = [1]"))
        XCTAssertTrue(decoded.text.contains("finalDecision = []"))
    }

    func testInvalidCameraTimestampsAreCountedWithoutInflatingFPS() throws {
        let value = recorder()
        for timestamp in [1.0, Double.nan, 2.0, -1.0] { value.cameraFrame(timestamp: timestamp) }
        let summary = finish(value)
        XCTAssertEqual(summary.cameraFrames, 4)
        XCTAssertEqual(summary.invalidCameraTimestamps, 2)
        XCTAssertEqual(summary.averageFPS, 1)
        XCTAssertNoThrow(try JSONEncoder().encode(summary))
    }

    func testRecorderDoesNotRetainFramePayload() {
        final class Payload {}
        let value = recorder()
        weak var weakPayload: Payload?
        do {
            let payload = Payload()
            weakPayload = payload
            let sample = CaptureFrame(id: 1, generation: 1, timestamp: 1, value: payload,
                                      motionScore: 0, informationScore: 1)
            value.capture(sample, width: 1280, height: 720)
            value.event(CardEvent(id: 1, generation: 1, triggerTimestamp: 1, frames: [sample],
                                 isComplete: false, missingPreFrames: 6), latency: 0)
            value.selected(sample, source: "snapshot", width: 1280, height: 720)
        }
        XCTAssertNil(weakPayload)
        value.recognitionCancelled(frameID: 1)
        _ = finish(value)
    }
}
