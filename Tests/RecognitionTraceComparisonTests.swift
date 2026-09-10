import Foundation
import XCTest
@testable import CardScanMagic

/// JSON fixtures exercise presentation, not recognition. The production Engine
/// ON/OFF tests live in RecognitionEvidenceTraceTests and use actual images.
final class RecognitionTraceComparisonTests: XCTestCase {
    func testComparisonIgnoresDifferentIDsLabelsAndAbsoluteTimestampsRecursively() throws {
        let a = observation(id: "full", frame: "2", candidateID: 7, timestamp: 100, label: "FULL 9C")
        let b = observation(id: "covered", frame: "900", candidateID: 81, timestamp: 9800, label: "OCCLUDED 9C")
        XCTAssertNil(try RecognitionTracePresentation.firstDifference(a, b))
        XCTAssertNil(try RecognitionTraceComparison.firstCoverageDifference([a], [b]))
        let projection = try RecognitionTraceJSON.data(RecognitionTracePresentation.projection(a))
        let json = try XCTUnwrap(String(data: projection, encoding: .utf8))
        XCTAssertFalse(json.contains("candidateID"))
        XCTAssertFalse(json.contains("timestamp"))
        XCTAssertFalse(json.contains("testLabel"))
        // Actual exported observations keep their trace identity.
        XCTAssertEqual(RecognitionTracePresentation.processedCandidates(a).first?["candidateID"] as? Int, 7)
    }

    func testMissingCandidateReportsCandidateAsFirstDivergenceWithoutPairing() throws {
        let full = observation()
        var covered = observation(id: "covered")
        var entries = RecognitionTracePresentation.entries(covered)
        entries.removeAll { $0["candidateID"] != nil }
        if let index = entries.firstIndex(where: { $0["stage"] as? String == "extractor" }) {
            entries[index]["candidateCount"] = 0
            entries[index]["featureCount"] = 0
            entries[index]["reason"] = "NO_PARTIAL_CANDIDATE"
        }
        entries[entries.count - 1]["finalDetections"] = [[String: Any]]()
        covered["entries"] = entries
        XCTAssertEqual(try RecognitionTracePresentation.firstDifference(full, covered), "candidate")
        XCTAssertEqual(try RecognitionTraceComparison.firstCoverageDifference([full], [covered]), "candidate")
        XCTAssertNil(RecognitionTraceComparison.bestPair([full], [covered]))
        XCTAssertEqual(RecognitionTracePresentation.outcome(covered)["reason"] as? String, "NO_PARTIAL_CANDIDATE")
    }

    func testFeatureLossAfterPipFailureDoesNotFalselyBlameCandidateLocalization() throws {
        let full = observation()
        var covered = observation(id: "covered")
        var entries = RecognitionTracePresentation.entries(covered)
        let extractor = entries.firstIndex { $0["stage"] as? String == "extractor" }!
        entries[extractor]["featureCount"] = 0
        entries.removeAll { ["componentDetected", "pipSummary", "rank.input", "rank.normalized", "rank.candidate", "rank.result", "suit", "fusion.resolveInput", "fusion.candidate"]
            .contains($0["stage"] as? String ?? "") }
        entries += [["stage": "pipSummary", "candidateID": 1, "state": "rejected", "reason": "PIP_WHITE_LEVEL", "detectedCount": NSNull()],
                    ["stage": "candidate", "candidateID": 1, "state": "rejected", "reason": "NO_PIPS_AND_OCR_NIL", "featureProduced": false]]
        covered["entries"] = entries
        XCTAssertEqual(try RecognitionTracePresentation.firstDifference(full, covered), "pip")
    }

    func testMultipleCandidatesAreNotForcePairedAndLiveKeepsTheirEvidenceSeparate() {
        let full = observation()
        var covered = observation()
        var entries = RecognitionTracePresentation.entries(covered)
        entries.append(["stage": "candidate", "state": "processing", "candidateID": 2,
                        "source": "surfaceFallback", "boundingBox": box])
        entries.append(["stage": "rank.result", "candidateID": 2, "finalRank": "8", "top1": "8", "margin": 0.11])
        covered["entries"] = entries
        XCTAssertNil(RecognitionTraceComparison.bestPair([full], [covered]))
        let live = RecognitionTracePresentation.text(covered)
        XCTAssertTrue(live.contains("Candidate 1"))
        XCTAssertTrue(live.contains("Candidate 2"))
        XCTAssertTrue(live.contains("Rank 9"))
        XCTAssertTrue(live.contains("Rank 8"))
    }

    func testIdenticalSingleROIsCanBeComparedWithoutUsingRankOrSuit() {
        let full = observation()
        var covered = observation(id: "covered", candidateID: 20)
        var entries = RecognitionTracePresentation.entries(covered)
        let index = entries.firstIndex { $0["stage"] as? String == "rank.result" }!
        entries[index]["finalRank"] = NSNull()
        covered["entries"] = entries
        XCTAssertNotNil(RecognitionTraceComparison.bestPair([full], [covered]))
    }

    func testUnknownBuildMetadataCannotBeCalledComparable() {
        XCTAssertFalse(RecognitionTraceComparison.sameMetadata([:], [:]))
        XCTAssertFalse(RecognitionTraceComparison.sameMetadata(["sourceRevision": "unknown", "systemVersion": "iOS"],
                                                               ["sourceRevision": "unknown", "systemVersion": "iOS"]))
        XCTAssertTrue(RecognitionTraceComparison.sameMetadata(["sourceRevision": "abc", "systemVersion": "iOS"],
                                                              ["sourceRevision": "abc", "systemVersion": "iOS"]))
    }

    func testOptionalOCRFailureIsNotDisplayedAsTerminalEngineFailure() {
        var trace = observation()
        var entries = RecognitionTracePresentation.entries(trace)
        entries.insert(["stage": "fusion.check", "candidateID": 1, "fusionPass": "final", "passed": false,
                        "reason": "FUSION_OCR_CONFIDENCE_LOW"], at: entries.count - 1)
        trace["entries"] = entries
        XCTAssertTrue(RecognitionTracePresentation.terminalRejections(trace).isEmpty)
        XCTAssertEqual(RecognitionTracePresentation.outcome(trace)["status"] as? String, "detectionsReturned")
        let live = RecognitionTracePresentation.text(trace)
        XCTAssertFalse(live.contains("FUSION_OCR_CONFIDENCE_LOW"))
        XCTAssertTrue(live.contains("OCR_NIL"))
        XCTAssertTrue(live.contains("optional cue"))
    }

    func testTerminalFusionReasonUsesRealGuardFromCorrectCandidateAndPass() throws {
        var trace = observation()
        var entries = RecognitionTracePresentation.entries(trace)
        entries.removeAll { ["engine.final", "fusion.candidate"].contains($0["stage"] as? String ?? "") }
        entries += [
            ["stage": "fusion.input", "fusionPass": "final", "modelDetections": []],
            ["stage": "fusion.check", "candidateID": 1, "fusionPass": "final", "passed": false, "reason": "LOCALIZATION_CONFIDENCE_LOW"],
            ["stage": "fusion.check", "candidateID": 2, "fusionPass": "final", "passed": false, "reason": "FUSION_OCR_CONFIDENCE_LOW"],
            ["stage": "fusion.check", "candidateID": 1, "fusionPass": "first", "passed": false, "reason": "SUIT_CONFIDENCE_LOW"],
            ["stage": "fusion.resolve", "candidateID": 1, "fusionPass": "final", "accepted": false, "reason": "FAILED_PRECEDING_CHECK"],
            ["stage": "engine.final", "finalDetections": []]
        ]
        trace["entries"] = entries
        let terminal = try XCTUnwrap(RecognitionTracePresentation.terminalRejections(trace).first)
        XCTAssertEqual(terminal["reason"] as? String, "LOCALIZATION_CONFIDENCE_LOW")
        XCTAssertEqual(RecognitionTracePresentation.outcome(trace)["reason"] as? String, "LOCALIZATION_CONFIDENCE_LOW")
    }

    func testCandidateRejectionIsRetainedWhenNoFeatureWasProduced() {
        var trace = observation()
        trace["entries"] = [
            ["stage": "candidate", "state": "processing", "candidateID": 1, "source": "surfaceFallback", "boundingBox": box],
            ["stage": "pipSummary", "candidateID": 1, "state": "rejected", "reason": "PIP_WHITE_LEVEL", "componentState": "notRun", "detectedCount": NSNull(), "retainedCount": NSNull()],
            ["stage": "candidate", "candidateID": 1, "state": "rejected", "reason": "NO_PIPS_AND_OCR_NIL", "featureProduced": false],
            ["stage": "extractor", "state": "completed", "candidateCount": 1, "featureCount": 0],
            ["stage": "engine.final", "finalDetections": []]
        ]
        let local = RecognitionTracePresentation.candidateEntries(1, in: trace)
        XCTAssertTrue(RecognitionTracePresentation.detectedPipCount(in: local) is NSNull)
        let live = RecognitionTracePresentation.text(trace)
        XCTAssertFalse(live.contains("Pips detected 0"))
        XCTAssertTrue(live.contains("NO_PIPS_AND_OCR_NIL"))
        XCTAssertEqual(RecognitionTracePresentation.terminalRejections(trace).count, 2)
    }

    func testMeasuredZeroPipCountRemainsZeroAfterCompletedExtraction() {
        let local: [[String: Any]] = [["stage": "pipSummary", "state": "extracted", "retainedCount": 0]]
        XCTAssertEqual(RecognitionTracePresentation.detectedPipCount(in: local) as? Int, 0)
        XCTAssertTrue(RecognitionTracePresentation.detectedPipCount(in: []) is NSNull)
    }

    func testUIReceiptRecordIDsDoNotCountAsEvidenceDifferences() throws {
        var a = observation(), b = observation(id: "covered")
        a["uiReceipts"] = [["recordID": "record-A", "card": "9C", "recordAccepted": true]]
        b["uiReceipts"] = [["recordID": "record-B", "card": "9C", "recordAccepted": true]]
        XCTAssertNil(try RecognitionTracePresentation.firstDifference(a, b))
    }

    func testMissingStagesCompareAsNullAndPipelineErrorIsVisible() throws {
        let empty: [String: Any] = ["recognitionID": "empty", "entries": [[String: Any]]()]
        XCTAssertNil(try RecognitionTracePresentation.firstDifference(empty, empty))
        XCTAssertEqual(RecognitionTracePresentation.outcome(empty)["status"] as? String, "notRun")
        let failure: [String: Any] = ["entries": [["stage": "pipelineError", "reason": "RECOGNITION_ERROR", "error": "model execution failed"]]]
        XCTAssertEqual(RecognitionTracePresentation.outcome(failure)["reason"] as? String, "RECOGNITION_ERROR")
    }

    func testCurrentFrameTrackReasonIgnoresPriorReplayAndOptionalStabilityFailures() {
        var trace = observation(frame: "9")
        var entries = RecognitionTracePresentation.entries(trace)
        entries += [
            ["stage": "track.decision", "evidenceFrameID": "8", "reason": "OLD_FRAME_REJECTION", "accepted": false, "replayMode": "history"],
            ["stage": "track.stability", "evidenceFrameID": "9", "reason": "OPTIONAL_CONFLICT_PROBE", "accepted": false, "replayMode": "history"],
            ["stage": "track.decision", "evidenceFrameID": "9", "reason": "TRACK_NOT_CONFIRMED", "decisionPublished": false, "replayMode": "history"],
            ["stage": "timeline.output", "publishedDecisionCount": 0, "recordCount": 0]
        ]
        trace["entries"] = entries
        let result = RecognitionTracePresentation.coordinatorOutcome(trace)
        XCTAssertEqual(result["reason"] as? String, "TRACK_NOT_CONFIRMED")
        XCTAssertEqual((result["decisionFailures"] as? [[String: Any]])?.count, 1)
    }

    func testMalformedSessionAndTraceJSONThrowInsteadOfForceCasting() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let manifest = root.appendingPathComponent("session_manifest.json")
        try Data("[]".utf8).write(to: manifest)
        XCTAssertThrowsError(try RecognitionTraceComparison.loadSession(root))
        try RecognitionTraceJSON.data(["recognitions": ["incorrect record"]]).write(to: manifest)
        XCTAssertThrowsError(try RecognitionTraceComparison.loadSession(root))
        try RecognitionTraceJSON.data(["recognitions": [["traceFile": "trace.json"]]]).write(to: manifest)
        try Data("[]".utf8).write(to: root.appendingPathComponent("trace.json"))
        XCTAssertThrowsError(try RecognitionTraceComparison.loadSession(root))
        try RecognitionTraceJSON.data(["recognitionID": "x", "entries": "incorrect entries"]).write(to: root.appendingPathComponent("trace.json"))
        XCTAssertThrowsError(try RecognitionTraceComparison.loadSession(root))
    }

    func testImportRejectsPathTraversalAndAbsolutePaths() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        for path in ["../trace.json", "/trace.json", "C:\\trace.json", "\\server\\trace.json", "a//trace.json", ""] {
            try RecognitionTraceJSON.data(["recognitions": [["traceFile": path]]])
                .write(to: root.appendingPathComponent("session_manifest.json"))
            XCTAssertThrowsError(try RecognitionTraceComparison.loadSession(root), path)
        }
    }

    func testReportIncludesRequestedMetricsAndBothTerminalOutcomes() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let full = try writeSession(root, label: "FULL 9C", trace: observation())
        let covered = try writeSession(root, label: "OCCLUDED 9C", trace: observation(id: "covered", candidateID: 21))
        let report = try RecognitionTraceComparison.report(full: full, covered: covered)
        for name in ["originalWidth", "snapshotWidth", "scaleFactor", "localization confidence", "pip detected",
                     "estimator input centers", "normalized centers", "Rank 9", "Rank 10", "Rank 8",
                     "rank Top1 / Top2 / margin", "club probability", "OCR parsed", "Fusion outcomes", "final detections", "coordinator"] {
            XCTAssertTrue(report.contains(name), name)
        }
        XCTAssertTrue(report.contains("First observed difference: none."))
        XCTAssertTrue(report.contains("Candidate 1"))
        XCTAssertTrue(report.contains("Candidate 21"))
        try RecognitionTraceComparison.update(in: root)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("Comparisons/FULL_9C_vs_OCCLUDED_9C_latest.md").path))
    }

    func testInputResolutionDifferenceRemainsVisibleInsteadOfForcingPair() throws {
        let full = observation()
        var covered = observation()
        var entries = RecognitionTracePresentation.entries(covered)
        entries[0]["width"] = 1280
        covered["entries"] = entries
        XCTAssertEqual(try RecognitionTracePresentation.firstDifference(full, covered), "input")
        XCTAssertEqual(try RecognitionTraceComparison.firstCoverageDifference([full], [covered]), "input")
        XCTAssertNil(RecognitionTraceComparison.bestPair([full], [covered]))
    }

    private var box: [String: Double] { ["x": 0.2, "y": 0.1, "width": 0.5, "height": 0.7] }

    private func observation(id: String = "full", frame: String = "1", candidateID: Int = 1,
                             timestamp: Double = 100, label: String = "FULL 9C") -> [String: Any] {
        let final: [[String: Any]] = [["card": "9C", "confidence": 0.96, "boundingBox": box]]
        var local: [[String: Any]] = [
            ["stage": "candidate", "state": "detected", "source": "visionRectangle", "boundingBox": box, "localizationConfidence": 0.9],
            ["stage": "candidate", "state": "processing", "source": "visionRectangle", "boundingBox": box, "localizationConfidence": 0.9,
             "extent": ["width": 320, "height": 448]],
            ["stage": "componentDetected", "purpose": "pipBlack", "componentID": "\(id)-component", "area": 120],
            ["stage": "pipSummary", "state": "completed", "retainedCount": 9, "bodyPipCount": 9, "estimatorComponentIDs": ["\(id)-component"]],
            ["stage": "rank.input", "points": [["x": 0.3, "y": 0.15]]],
            ["stage": "rank.normalized", "normalizedPoints": [["x": 0.214, "y": 0.15]]],
            ["stage": "rank.candidate", "rank": "9", "probability": 0.94, "score": 0.96, "matchedCount": 9],
            ["stage": "rank.candidate", "rank": "10", "probability": 0.03, "score": 0.75, "matchedCount": 9],
            ["stage": "rank.candidate", "rank": "8", "probability": 0.02, "score": 0.70, "matchedCount": 8],
            ["stage": "rank.result", "finalRank": "9", "top1": "9", "top2": "10", "margin": 0.91, "confidence": 0.95],
            ["stage": "suit", "state": "evaluated", "probabilities": ["club": 0.96, "spade": 0.02, "heart": 0.01, "diamond": 0.01],
             "top1": "club", "confidence": 0.96, "margin": 0.94],
            ["stage": "ocr", "state": "completed", "parsedRank": NSNull(), "reason": "OCR_NIL", "confidence": 0],
            ["stage": "fusion.resolveInput", "fusionPass": "final", "layoutRank": "9"],
            ["stage": "fusion.candidate", "fusionPass": "final", "accepted": true, "finalCard": "9C", "confidence": 0.95]
        ]
        for index in local.indices { local[index]["candidateID"] = candidateID; local[index]["uptime"] = timestamp }
        let entries: [[String: Any]] = [
            ["stage": "recognitionSelected", "source": "snapshot", "width": 720, "height": 1280, "orientation": 1,
             "timestamp": timestamp, "testLabel": label, "original": ["timestamp": timestamp, "originalWidth": 1080, "originalHeight": 1920,
                 "snapshotWidth": 720, "snapshotHeight": 1280, "scaleFactor": 2.0 / 3.0]],
            ["stage": "extractor", "state": "completed", "candidateCount": 1, "featureCount": 1]
        ] + local + [["stage": "engine.final", "finalDetections": final]]
        return ["recognitionID": id, "frameID": frame, "runID": id, "sessionID": frame, "metadataComplete": true,
                "entries": entries, "uiReceipts": [[String: Any]]()]
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("TraceComparison-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func writeSession(_ root: URL, label: String, trace: [String: Any]) throws -> URL {
        let folder = root.appendingPathComponent(label.replacingOccurrences(of: " ", with: "_"))
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try RecognitionTraceJSON.data(trace).write(to: folder.appendingPathComponent("trace.json"))
        try RecognitionTraceJSON.data(["runID": UUID().uuidString, "testLabel": label, "complete": true,
            "sourceRevision": "abc", "systemVersion": "iOS", "finishedAt": "2026-09-11T00:00:00Z",
            "recognitions": [["traceFile": "trace.json"]]]).write(to: folder.appendingPathComponent("session_manifest.json"))
        return folder
    }
}
