import CoreFoundation
import Foundation

/// Formats already observed values. This file never invokes recognition or a
/// recognition predicate, including when explaining an unsuccessful branch.
enum RecognitionTracePresentation {
    static let comparisonStages = ["input", "candidate", "pip", "rank", "suit", "ocr", "fusion", "final", "coordinator", "ui"]

    static func entries(_ trace: [String: Any]) -> [[String: Any]] { trace["entries"] as? [[String: Any]] ?? [] }
    static func last(_ stage: String, in entries: [[String: Any]]) -> [String: Any] {
        entries.last { $0["stage"] as? String == stage } ?? [:]
    }
    static func value(_ value: Any?) -> String {
        guard let value, !(value is NSNull) else { return "notRun / null" }
        if let string = value as? String { return string }
        if let number = value as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return number.boolValue ? "true" : "false" }
            return String(format: "%.4g", number.doubleValue)
        }
        if let data = try? RecognitionTraceJSON.data(value), let text = String(data: data, encoding: .utf8) {
            return text.replacingOccurrences(of: "\n", with: " ")
        }
        return String(describing: value)
    }

    static func processedCandidates(_ trace: [String: Any]) -> [[String: Any]] {
        entries(trace).filter { $0["stage"] as? String == "candidate" && $0["state"] as? String == "processing" }
    }

    static func candidateEntries(_ id: Int, in trace: [String: Any]) -> [[String: Any]] {
        entries(trace).filter { $0["candidateID"] as? Int == id }
    }

    /// Do not turn absent telemetry into a measured zero. A completed component
    /// pass can measure zero; a failed brightness guard has never run that pass.
    static func detectedPipCount(in local: [[String: Any]]) -> Any {
        let detected = local.filter { $0["stage"] as? String == "componentDetected"
            && ($0["purpose"] as? String ?? "").hasPrefix("pip") }
        if !detected.isEmpty { return detected.count }
        let summaries = local.filter { $0["stage"] as? String == "pipSummary" }
        if let explicit = summaries.last(where: { $0["detectedCount"] != nil }) {
            return explicit["detectedCount"] ?? NSNull()
        }
        if summaries.contains(where: { ["extracted", "completed"].contains($0["state"] as? String ?? "") }) { return 0 }
        return NSNull()
    }

    /// Only terminal records from actual return/continue sites qualify. A false
    /// optional OCR or Pip support check is not a terminal Fusion rejection.
    static func terminalRejections(_ trace: [String: Any]) -> [[String: Any]] {
        let all = entries(trace)
        return all.enumerated().compactMap { index, entry in
            let stage = entry["stage"] as? String ?? ""
            let terminal = (["fusion.resolve", "fusion.candidate"].contains(stage) && entry["accepted"] as? Bool == false)
                || (["candidate", "extractor", "pipSummary"].contains(stage) && entry["state"] as? String == "rejected")
                || ["timeline.rejected", "engine.error", "pipelineError", "pipelineRejected"].contains(stage)
            guard terminal else { return nil }
            var result = entry
            if entry["reason"] as? String == "FAILED_PRECEDING_CHECK" {
                // The actual failed check is adjacent to this terminal branch.
                // Limit the lookup to its candidate and Fusion pass; never use
                // a rejected optional cue from another candidate/pass.
                let previous = all[..<index].last { prior in
                    prior["stage"] as? String == "fusion.check"
                        && prior["passed"] as? Bool == false
                        && prior["candidateID"] as? Int == entry["candidateID"] as? Int
                        && prior["fusionPass"] as? String == entry["fusionPass"] as? String
                }
                result["actualFailedCheck"] = previous ?? ["status": "notObserved", "reason": NSNull()]
                if let reason = previous?["reason"] { result["reason"] = reason }
            }
            return result
        }
    }

    /// Summarize the final observed outcome separately from failed alternatives.
    /// This is a description of the trace, not a diagnosis of an unseen image.
    static func outcome(_ trace: [String: Any]) -> [String: Any] {
        let all = entries(trace)
        let final = last("engine.final", in: all)
        if let error = all.last(where: { ["engine.error", "pipelineError"].contains($0["stage"] as? String ?? "") }) {
            return ["status": "error", "stage": "engine", "reason": error["reason"] ?? error["error"] ?? "ENGINE_ERROR"]
        }
        guard let detections = final["finalDetections"] as? [[String: Any]] else {
            return ["status": "notRun", "stage": "engine", "reason": NSNull()]
        }
        if !detections.isEmpty {
            return ["status": "detectionsReturned", "stage": "engine", "reason": NSNull(), "detections": detections]
        }
        let extractor = last("extractor", in: all)
        if extractor["candidateCount"] as? Int == 0 {
            return ["status": "empty", "stage": "candidate", "reason": "NO_PARTIAL_CANDIDATE"]
        }
        let rejections = terminalRejections(trace)
        let finalPass = all.last { $0["stage"] as? String == "fusion.input" }?["fusionPass"] as? String
        let fusion = rejections.first { ($0["stage"] as? String ?? "").hasPrefix("fusion.")
            && $0["fusionPass"] as? String == finalPass }
        if let fusion {
            return ["status": "empty", "stage": "fusion", "reason": fusion["reason"] ?? NSNull(),
                    "candidateID": fusion["candidateID"] ?? NSNull(),
                    "scope": "first rejected local candidate in final Fusion pass; other candidates remain in trace"]
        }
        let processedIDs = Set(processedCandidates(trace).compactMap { $0["candidateID"] as? Int })
        if let candidate = rejections.first(where: {
            $0["stage"] as? String == "candidate" && processedIDs.contains($0["candidateID"] as? Int ?? -1)
        }) {
            return ["status": "empty", "stage": "candidate", "reason": candidate["reason"] ?? NSNull(),
                    "candidateID": candidate["candidateID"] ?? NSNull()]
        }
        return ["status": "empty", "stage": "engine", "reason": "NO_FINAL_DETECTION",
                "detail": "No terminal local rejection was observed; inspect model output and metadata completeness."]
    }

    static func coordinatorOutcome(_ trace: [String: Any]) -> [String: Any] {
        let all = entries(trace)
        if let rejected = all.last(where: { $0["stage"] as? String == "pipelineRejected" }) { return rejected }
        let published = all.filter { $0["stage"] as? String == "timeline.published" }
        if !published.isEmpty { return ["status": "published", "decisions": published] }
        if let rejected = all.last(where: { $0["stage"] as? String == "timeline.rejected" }) { return rejected }
        let output = last("timeline.output", in: all)
        guard !output.isEmpty else { return ["status": "notRun", "reason": NSNull()] }
        let suppressed = all.filter { $0["stage"] as? String == "timeline.decisionSuppressed" }
        if !suppressed.isEmpty { return ["status": "suppressed", "decisions": suppressed] }
        // Coordinator history replay may contain failed consensus checks from
        // prior frames or optional conflict lookups. Present only explicit
        // current-frame Track decision failures as reasons.
        let current = currentFrameEntries(trace)
        let decisions = current.filter { $0["stage"] as? String == "track.decision"
            && ($0["accepted"] as? Bool == false || $0["reason"] as? String == "TRACK_NOT_CONFIRMED") }
        return ["status": "noPublication", "publishedDecisionCount": output["publishedDecisionCount"] ?? NSNull(),
                "recordCount": output["recordCount"] ?? NSNull(), "decisionFailures": decisions,
                "reason": decisions.first?["reason"] ?? NSNull()]
    }

    static func currentFrameEntries(_ trace: [String: Any]) -> [[String: Any]] {
        let frame = value(trace["frameID"])
        return entries(trace).filter {
            guard let evidenceFrame = $0["evidenceFrameID"] else { return true }
            return value(evidenceFrame) == frame && $0["replayMode"] as? String != "checkpointFold"
        }
    }

    static func text(_ trace: [String: Any]) -> String {
        let all = entries(trace)
        let input = last("recognitionSelected", in: all)
        let extractor = last("extractor", in: all)
        let candidates = processedCandidates(trace)
        var lines = [
            "Recognition \((trace["recognitionID"] as? String ?? "").prefix(8)) · completed",
            "\(value(input["source"])) \(value(input["width"]))×\(value(input["height"]))",
            "Candidates: \(value(extractor["candidateCount"])) · features \(value(extractor["featureCount"]))"
        ]
        // Keep candidate evidence together; never show Rank from one candidate
        // next to Suit from another. All processed ROIs are visible in the panel.
        for candidate in candidates {
            guard let id = candidate["candidateID"] as? Int else { continue }
            let local = candidateEntries(id, in: trace)
            let pips = last("pipSummary", in: local)
            let rank = last("rank.result", in: local)
            let fusionSuit = last("fusion.suit", in: local)
            let suit = fusionSuit.isEmpty ? last("suit", in: local) : fusionSuit
            let ocr = last("ocr", in: local)
            let fusion = last("fusion.candidate", in: local)
            lines += [
                "Candidate \(id) · \(value(candidate["source"]))",
                "  Pips detected \(value(detectedPipCount(in: local))) / retained \(value(pips["retainedCount"])) / body \(value(pips["bodyPipCount"]))",
                "  Rank \(value(rank["finalRank"])) · \(value(rank["top1"])) / \(value(rank["top2"])) · margin \(value(rank["margin"]))",
                "  Suit \(value(suit["top1"])) · confidence \(value(suit["confidence"])) · margin \(value(suit["margin"]))",
                "  OCR \(value(ocr["parsedRank"])) · \(value(ocr["reason"])) (optional cue)",
                "  Fusion accepted \(value(fusion["accepted"])) · card \(value(fusion["finalCard"]))"
            ]
        }
        let result = outcome(trace)
        lines += ["Engine: \(value(result["status"])) · \(value(result["reason"]))",
                  "Final: \(value(last("engine.final", in: all)["finalDetections"]))",
                  "Track: \(value(coordinatorOutcome(trace)))",
                  "UI: \(value(trace["uiReceipts"]))",
                  "每个候选的终止分支及未执行字段见导出 JSON"]
        if trace["metadataComplete"] as? Bool == false { lines.append("TRACE INCOMPLETE: 中间记录已截断") }
        return lines.joined(separator: "\n")
    }

    /// Observations used for semantic comparison. IDs, user labels and absolute
    /// capture times differ by definition between A/B and are not evidence.
    /// The original exported trace remains untouched and retains every ID.
    static func projection(_ trace: [String: Any]) -> [String: Any] {
        let all = entries(trace)
        let groups: [(String, [String])] = [
            ("input", ["recognitionSelected", "losslessInput"]),
            ("candidate", ["extractor", "candidate"]),
            ("pip", ["componentDetected", "componentFiltered", "componentRetained", "pipSummary"]),
            ("rank", ["rank.input", "rank.normalized", "rank.candidate", "rank.result", "rank.check"]),
            ("suit", ["suit", "fusion.suit"]), ("ocr", ["ocr"]),
            ("fusion", ["fusion.input", "fusion.check", "fusion.resolveInput", "fusion.resolve", "fusion.candidate", "fusion.result", "fusion.conflict", "fusion.pipSupport"]),
            ("final", ["engine.final", "engine.error", "pipelineError"])
        ]
        var result: [String: Any] = [:]
        for (key, stages) in groups {
            result[key] = semanticValue(all.filter { stages.contains($0["stage"] as? String ?? "") })
        }
        result["coordinator"] = semanticValue(coordinatorOutcome(trace))
        result["ui"] = semanticValue(trace["uiReceipts"] ?? NSNull())
        return result
    }

    private static let identityFields: Set<String> = [
        "uptime", "timestamp", "evidenceTimestamp", "lastTimestamp", "checkpointTimestamp", "lastSeen",
        "captureTimestamps", "proposalTimestamp", "observationTimestamps", "selectedUptime", "startUptime", "completedUptime",
        "processingRecognitionID", "evidenceRecognitionID", "replayPassID", "traceTrackID", "temporaryTrackID",
        "publishedTrackID", "selectedTrackID", "recentTrackID", "trackID", "recognitionID", "candidateID",
        "componentID", "estimatorComponentIDs", "inputComponentIDs", "sourceComponentID", "frameID", "evidenceFrameID",
        "runID", "sessionID", "testLabel", "captureWindowIDs", "preRectificationImage"
    ]

    static func semanticValue(_ value: Any) -> Any {
        if let dictionary = value as? [String: Any] {
            return dictionary.reduce(into: [String: Any]()) { result, pair in
                if !identityFields.contains(pair.key) { result[pair.key] = semanticValue(pair.value) }
            }
        }
        if let array = value as? [Any] { return array.map(semanticValue) }
        return value
    }

    static func firstDifference(_ a: [String: Any], _ b: [String: Any]) throws -> String? {
        let lhs = projection(a), rhs = projection(b)
        return try comparisonStages.first { stage in
            try comparisonData(lhs[stage] ?? NSNull()) != comparisonData(rhs[stage] ?? NSNull())
        }
    }

    /// JSONSerialization accepts an object/array at the root without fragment
    /// options. Wrapping permits an actual null or scalar stage safely.
    static func comparisonData(_ value: Any) throws -> Data {
        try RecognitionTraceJSON.data(["observed": value])
    }
}
