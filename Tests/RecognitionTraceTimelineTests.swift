import CoreGraphics
import XCTest
@testable import CardScanMagic

final class RecognitionTraceTimelineTests: XCTestCase {
    private struct Input {
        let id: UInt64
        let timestamp: TimeInterval
        let detections: [CardDetection]
    }

    private func detection(_ code: String = "10c", confidence: Float = 0.94,
                           supported: Bool = true, x: CGFloat = 0.3) -> CardDetection {
        CardDetection(card: CardFace.parse(code)!, confidence: confidence,
            boundingBox: CGRect(x: x, y: 0.3, width: 0.2, height: 0.3),
            hasIndependentSupport: supported)
    }

    /// Random UUIDs differ between independent executions. Compare all actual
    /// decision content and preserve UUID equality relationships as ordinals.
    private func signature(_ updates: [CardEventUpdate]) -> [String] {
        var identities: [UUID: Int] = [:]
        return updates.map { update in
            let records = update.records.map { "\($0.card.code):\($0.confidence):\($0.recordedAt.timeIntervalSinceReferenceDate)" }
            let decisions = update.decisions.map { decision -> String in
                if identities[decision.eventID] == nil { identities[decision.eventID] = identities.count }
                return "\(identities[decision.eventID]!):\(decision.record.card.code):\(decision.record.confidence):\(decision.duplicateCard):\(decision.captureTimestamps.sorted())"
            }
            let overlays = update.stableDetections.map {
                "\($0.card.code):\($0.confidence):\($0.boundingBox):\($0.orientedImageSize):\($0.hasIndependentSupport)"
            }
            return "\(records)|\(decisions)|\(overlays)"
        }
    }

    private func run(_ inputs: [Input], traced: Bool, capacity: Int = 180)
        -> (updates: [CardEventUpdate], entries: [[String: Any]], calls: [String: Int]) {
        let timeline = CardResultTimeline(capacity: capacity)
        var entries: [[String: Any]] = []
        let (updates, calls) = RecognitionCallProbe.measure {
            inputs.map { input in
                let trace = traced ? RecognitionTrace(recognitionID: "recognition-\(input.id)",
                    frameID: input.id, maximumEntries: 100000) : nil
                let update = RecognitionTrace.withCurrent(trace) {
                    timeline.insert(frameID: input.id, timestamp: input.timestamp, detections: input.detections)
                }
                if let trace { entries.append(contentsOf: trace.entries) }
                return update
            }
        }
        return (updates, entries, calls)
    }

    func testTraceOnOffEquivalentAcrossJitterMissesCallbacksAndReappearance() {
        let inputs = [
            Input(id: 3, timestamp: 100.04, detections: [detection()]),
            Input(id: 1, timestamp: 100, detections: [detection()]),
            Input(id: 2, timestamp: 100.02, detections: [detection("9c")]),
            Input(id: 4, timestamp: 100.06, detections: []),
            Input(id: 5, timestamp: 100.08, detections: []),
            Input(id: 6, timestamp: 100.10, detections: [detection()]),
            Input(id: 6, timestamp: 100.10, detections: [detection()]),
            Input(id: 7, timestamp: 101, detections: []),
            Input(id: 8, timestamp: 101.1, detections: [detection()]),
            Input(id: 9, timestamp: 102, detections: [detection("9c")])
        ]
        let off = run(inputs, traced: false)
        let on = run(inputs, traced: true)
        XCTAssertEqual(signature(off.updates), signature(on.updates))
        XCTAssertEqual(off.calls, on.calls, "Tracing must not rerun association or consensus")
        XCTAssertGreaterThan(on.calls["Coordinator.bestTrack"] ?? 0, 0)
        XCTAssertGreaterThan(on.calls["Coordinator.stableCard"] ?? 0, 0)
        XCTAssertEqual(on.updates.flatMap(\.records).map(\.card.code), ["10c", "9c"])
        XCTAssertEqual(on.updates.flatMap(\.decisions).count, 3)
        let publications = on.entries.filter { $0["stage"] as? String == "timeline.published" }
        XCTAssertEqual(publications.count, 3)
        XCTAssertEqual(publications.filter { $0["duplicateCard"] as? Bool == true }.count, 1)
        XCTAssertTrue(on.entries.contains { $0["reason"] as? String == "DUPLICATE_FRAME_OR_TIMESTAMP" })
        XCTAssertTrue(on.entries.contains { $0["reason"] as? String == "PHYSICAL_PASS_ALREADY_PUBLISHED" })
        XCTAssertTrue(on.entries.filter { ($0["stage"] as? String)?.hasPrefix("track.") == true }
            .allSatisfy { $0["decisionPublished"] as? Bool != true })
    }

    func testFiveCapturesProduceOnePublicationAndReplayKeepsEvidenceIdentity() throws {
        let inputs = (0..<5).map {
            Input(id: UInt64($0 + 1), timestamp: 100 + Double($0) * 0.02, detections: [detection()])
        }
        let result = run(inputs, traced: true)
        XCTAssertEqual(result.updates.flatMap(\.decisions).count, 1)
        XCTAssertEqual(result.updates.flatMap(\.records).count, 1)
        XCTAssertEqual(result.entries.filter { $0["stage"] as? String == "timeline.published" }.count, 1)
        let historical = try XCTUnwrap(result.entries.first {
            $0["stage"] as? String == "timeline.replay"
                && $0["processingRecognitionID"] as? String == "recognition-5"
                && $0["evidenceFrameID"] as? String == "1"
        })
        XCTAssertEqual(historical["evidenceRecognitionID"] as? String, "recognition-1")
        XCTAssertEqual(historical["replayMode"] as? String, "history")
        XCTAssertNotNil(historical["replayPassID"] as? String)
        XCTAssertEqual(historical["decisionPublished"] as? Bool, false)
    }

    func testCheckpointFoldIsNotASecondPublicationAndOldFrameHasReason() {
        var inputs = (0..<20).map {
            Input(id: UInt64($0 + 1), timestamp: 100 + Double($0) / 60, detections: [detection()])
        }
        inputs.append(Input(id: 100, timestamp: 100, detections: [detection("9c")]))
        let on = run(inputs, traced: true, capacity: 13)
        let off = run(inputs, traced: false, capacity: 13)
        XCTAssertEqual(signature(on.updates), signature(off.updates))
        XCTAssertEqual(on.calls, off.calls)
        XCTAssertEqual(on.updates.flatMap(\.decisions).count, 1)
        XCTAssertEqual(on.entries.filter { $0["stage"] as? String == "timeline.published" }.count, 1)
        XCTAssertTrue(on.entries.contains { $0["replayMode"] as? String == "checkpointFold" })
        XCTAssertTrue(on.entries.contains { $0["reason"] as? String == "RESULT_BEFORE_CHECKPOINT" })
    }

    func testSanitizationAndUnconfirmedReasonsObserveShortCircuit() {
        let trace = RecognitionTrace()
        let coordinator = CardEventCoordinator()
        let updates = RecognitionTrace.withCurrent(trace) {
            [coordinator.processUpdate([detection(confidence: 0.1)], at: Date(timeIntervalSinceReferenceDate: 100)),
             coordinator.processUpdate([detection(supported: false)], at: Date(timeIntervalSinceReferenceDate: 101))]
        }
        XCTAssertTrue(updates.flatMap(\.records).isEmpty)
        XCTAssertTrue(trace.entries.contains { $0["reason"] as? String == "LOW_DETECTION_CONFIDENCE" })
        XCTAssertTrue(trace.entries.contains { $0["reason"] as? String == "SINGLE_FRAME_NO_INDEPENDENT_SUPPORT" })
        XCTAssertFalse(trace.entries.contains { $0["reason"] as? String == "SINGLE_FRAME_CONFIDENCE_TOO_LOW" })
        XCTAssertTrue(trace.entries.contains { $0["reason"] as? String == "TRACK_NOT_CONFIRMED" })
        XCTAssertTrue(trace.entries.contains { $0["remainingChecks"] as? String == "notEvaluated" })
    }

    func testTruncatedObserverCannotChangeTimelineDecisions() {
        let inputs = (0..<5).map {
            Input(id: UInt64($0 + 1), timestamp: 100 + Double($0) / 60, detections: [detection()])
        }
        let expected = run(inputs, traced: false)
        let timeline = CardResultTimeline()
        let trace = RecognitionTrace(maximumEntries: 0)
        let updates = RecognitionTrace.withCurrent(trace) {
            inputs.map { timeline.insert(frameID: $0.id, timestamp: $0.timestamp, detections: $0.detections) }
        }
        XCTAssertEqual(signature(updates), signature(expected.updates))
        XCTAssertGreaterThan(trace.truncatedEntries, 0)
        XCTAssertTrue(trace.entries.isEmpty)
    }

    func testTimelineRestoresCallerDiagnosticContext() {
        let trace = RecognitionTrace()
        trace.context = ["owner": "engine"]
        trace.candidateID = 7
        trace.componentID = "component-4"
        RecognitionTrace.withCurrent(trace) {
            _ = CardResultTimeline().insert(frameID: 1, timestamp: 100, detections: [detection()])
        }
        XCTAssertEqual(trace.context["owner"] as? String, "engine")
        XCTAssertEqual(trace.context.count, 1)
        XCTAssertEqual(trace.candidateID, 7)
        XCTAssertEqual(trace.componentID, "component-4")
        XCTAssertTrue(trace.entries.allSatisfy { $0["candidateID"] == nil && $0["componentID"] == nil })
    }
}
