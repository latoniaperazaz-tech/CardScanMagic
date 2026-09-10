import Foundation

/// Formats already observed scalar values. Never invokes recognition.
enum RecognitionTracePresentation {
    static func entries(_ trace: [String: Any]) -> [[String: Any]] { trace["entries"] as? [[String: Any]] ?? [] }
    static func last(_ stage: String, in entries: [[String: Any]]) -> [String: Any] {
        entries.last { $0["stage"] as? String == stage } ?? [:]
    }
    static func value(_ value: Any?) -> String {
        guard let value, !(value is NSNull) else { return "notRun / null" }
        if let number = value as? NSNumber { return String(format: "%.4g", number.doubleValue) }
        if let string = value as? String { return string }
        if let data = try? RecognitionTraceJSON.data(value), let text = String(data: data, encoding: .utf8) {
            return text.replacingOccurrences(of: "\n", with: " ")
        }
        return String(describing: value)
    }
    static func text(_ trace: [String: Any]) -> String {
        let all = entries(trace)
        let input = last("recognitionSelected", in: all)
        let extractor = last("extractor", in: all)
        let processing = all.last { $0["stage"] as? String == "candidate" && $0["state"] as? String == "processing" }
        let id = processing?["candidateID"] as? Int
        let local = all.filter { id == nil || $0["candidateID"] as? Int == id }
        let pips = last("pipSummary", in: local)
        let rank = last("rank.result", in: local)
        let suit = last("fusion.suit", in: local).isEmpty ? last("suit", in: local) : last("fusion.suit", in: local)
        let ocr = last("ocr", in: local)
        let final = last("engine.final", in: all)
        let failure = local.last { ($0["passed"] as? Bool) == false || $0["state"] as? String == "rejected" }
        let detected = local.filter { $0["stage"] as? String == "componentDetected"
            && ($0["purpose"] as? String ?? "").hasPrefix("pip") }.count
        return [
            "Recognition \((trace["recognitionID"] as? String ?? "").prefix(8)) · completed",
            "\(value(input["source"])) \(value(input["width"]))×\(value(input["height"]))",
            "Candidate: \(value(extractor["candidateCount"])) · shown \(value(id))",
            "Pips detected \(detected) / retained \(value(pips["retainedCount"])) / body \(value(pips["bodyPipCount"]))",
            "Rank: \(value(rank["finalRank"])) · top1 \(value(rank["top1"])) / top2 \(value(rank["top2"]))",
            "Rank margin \(value(rank["margin"])) · confidence \(value(rank["confidence"]))",
            "Suit: \(value(suit["top1"])) · \(value(suit["confidence"]))",
            "OCR: \(value(ocr["parsedRank"] ?? ocr["rank"] ?? ocr["reason"]))",
            "Fusion: \(value(last("fusion.candidate", in: local)["accepted"]))",
            "Final: \(value(final["finalDetections"]))",
            "Track: \(value(last("timeline.output", in: all)))",
            "Branch: \(value(failure?["reason"]))",
            "Details: every candidate and Track/UI receipt in exported JSON"
        ].joined(separator: "\n")
    }

    static func projection(_ trace: [String: Any]) -> [String: Any] {
        let all = entries(trace)
        let input = last("recognitionSelected", in: all)
        let groups: [(String, [String])] = [
            ("input", ["recognitionSelected"]),
            ("candidate", ["extractor", "candidate"]),
            ("pip", ["componentDetected", "componentFiltered", "componentRetained", "pipSummary"]),
            ("rank", ["rank.input", "rank.normalized", "rank.candidate", "rank.result", "rank.check"]),
            ("suit", ["suit", "fusion.suit"]), ("ocr", ["ocr"]),
            ("fusion", ["fusion.check", "fusion.resolve", "fusion.candidate", "fusion.result"]),
            ("final", ["engine.final"]), ("coordinator", ["timeline.published", "timeline.output"])
        ]
        var result: [String: Any] = ["recognitionID": trace["recognitionID"] ?? NSNull(),
            "frameID": trace["frameID"] ?? NSNull(), "inputSource": input["source"] ?? NSNull()]
        for (key, stages) in groups {
            result[key] = all.filter { stages.contains($0["stage"] as? String ?? "") }.map { entry in
                entry.filter { !["uptime", "processingRecognitionID", "replayPassID", "traceTrackID",
                    "publishedTrackID", "trackID", "recognitionID"].contains($0.key) }
            }
        }
        result["ui"] = trace["uiReceipts"] ?? []
        return result
    }
}
