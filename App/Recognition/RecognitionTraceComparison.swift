import CoreGraphics
import Foundation

enum RecognitionTraceComparison {
    private static let lock = NSLock()

    static func update(in root: URL) throws {
        lock.lock(); defer { lock.unlock() }
        let folders = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        let sessions = folders.compactMap { folder -> (URL, [String: Any])? in
            guard let manifest = try? object(at: folder.appendingPathComponent("session_manifest.json")) else { return nil }
            return (folder, manifest)
        }.sorted {
            let left = $0.1["finishedAt"] as? String ?? "", right = $1.1["finishedAt"] as? String ?? ""
            return left == right ? $0.0.lastPathComponent > $1.0.lastPathComponent : left > right
        }
        guard let full = sessions.first(where: { $0.1["testLabel"] as? String == "FULL 9C" }),
              let covered = sessions.first(where: { $0.1["testLabel"] as? String == "OCCLUDED 9C" }) else { return }
        let report = try report(full: full.0, covered: covered.0)
        let folder = root.appendingPathComponent("Comparisons", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // Imported manifest strings are data, not path components.
        let fullID = (full.1["runID"] as? String).flatMap(UUID.init(uuidString:))?.uuidString ?? "UNKNOWN_FULL"
        let coveredID = (covered.1["runID"] as? String).flatMap(UUID.init(uuidString:))?.uuidString ?? "UNKNOWN_OCCLUDED"
        let name = "FULL_9C_vs_OCCLUDED_9C_\(fullID)_\(coveredID).md"
        try report.write(to: folder.appendingPathComponent(name), atomically: true, encoding: .utf8)
        try report.write(to: folder.appendingPathComponent("FULL_9C_vs_OCCLUDED_9C_latest.md"), atomically: true, encoding: .utf8)
    }

    private static func object(at url: URL) throws -> [String: Any] {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let size = attributes[.size] as? NSNumber, size.int64Value <= 32 * 1024 * 1024 else {
            throw RecognitionTraceIOError.corruptArchive
        }
        guard let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any] else {
            throw RecognitionTraceIOError.corruptArchive
        }
        return object
    }

    static func loadSession(_ directory: URL) throws -> ([String: Any], [[String: Any]]) {
        let manifest = try object(at: directory.appendingPathComponent("session_manifest.json"))
        guard let records = manifest["recognitions"] as? [[String: Any]], records.count <= 10000 else {
            throw RecognitionTraceIOError.corruptArchive
        }
        let root = directory.standardizedFileURL.resolvingSymlinksInPath()
        let traces = try records.map { record -> [String: Any] in
            guard let path = record["traceFile"] as? String,
                  !path.isEmpty, !path.contains("\\"), !path.contains(":"), !path.hasPrefix("/"),
                  !path.split(separator: "/", omittingEmptySubsequences: false).contains(where: { $0 == ".." || $0.isEmpty }) else {
                throw RecognitionTraceIOError.corruptArchive
            }
            let file = root.appendingPathComponent(path).standardizedFileURL.resolvingSymlinksInPath()
            guard file.path.hasPrefix(root.path + "/") else { throw RecognitionTraceIOError.corruptArchive }
            let trace = try object(at: file)
            guard trace["entries"] is [[String: Any]], trace["recognitionID"] is String else {
                throw RecognitionTraceIOError.corruptArchive
            }
            return trace
        }
        return (manifest, traces)
    }

    static func report(full: URL, covered: URL) throws -> String {
        let a = try loadSession(full), b = try loadSession(covered)
        var lines = ["# FULL 9C vs OCCLUDED 9C", "",
            "FULL Session: \(full.lastPathComponent)", "OCCLUDED Session: \(covered.lastPathComponent)",
            "FULL complete: \(a.0["complete"] ?? false); OCCLUDED complete: \(b.0["complete"] ?? false)", "",
            "These are exported production observations. FULL/OCCLUDED 9C are user labels, not inferred identities.",
            "Different observations are not interchangeable physical tracks. No rank/suit evidence is fused by this report.",
            "First observed difference is not automatically the cause of rejection. OCR_NIL is an optional cue state.", ""]
        let comparable = sameMetadata(a.0, b.0)
        lines.append("Same known source revision/system metadata: \(comparable)")
        lines += ["", "## Session stage coverage (unpaired)",
                  "Counts describe each test duration; they do not imply one-to-one frame correspondence.", "",
                  "| Observed stage | FULL | OCCLUDED |", "| --- | ---: | ---: |"]
        let coverageA = coverage(a.1), coverageB = coverage(b.1)
        for key in ["recognitions", "candidate", "pip", "rank", "suit", "ocr", "fusion", "finalDetections", "published", "uiAccepted"] {
            lines.append("| \(key) | \(coverageA[key] ?? 0) | \(coverageB[key] ?? 0) |")
        }
        // Missing candidates must be visible even when ROI pairing is impossible.
        // This claim concerns stage availability, not correspondence of images.
        if let first = try firstCoverageDifference(a.1, b.1) {
            lines += ["", "First observed stage-availability difference: \(first) (unpaired sessions)."]
        } else {
            lines += ["", "No stage-availability difference was observed; compare matched values and terminal outcomes below."]
        }

        if let best = bestPair(a.1, b.1), comparable {
            let left = a.1[best.0], right = b.1[best.1]
            let pa = RecognitionTracePresentation.projection(left), pb = RecognitionTracePresentation.projection(right)
            lines += ["", "## Comparable observation pair", "FULL recognitionID: \(left["recognitionID"] ?? "")",
                "OCCLUDED recognitionID: \(right["recognitionID"] ?? "")",
                "Each observation has one processed ROI; ROI IoU: \(best.2). Input source/dimensions/orientation agree.",
                "Selected by ROI overlap, not by a favorable Rank/Suit outcome. This is geometric correspondence only.",
                "Absolute times, labels and generated IDs are excluded from equality; original JSON retains them.", "",
                "| Stage | Equal observed evidence |", "| --- | --- |"]
            for stage in RecognitionTracePresentation.comparisonStages {
                let equal = try RecognitionTracePresentation.comparisonData(pa[stage] ?? NSNull())
                    == RecognitionTracePresentation.comparisonData(pb[stage] ?? NSNull())
                lines.append("| \(stage) | \(equal) |")
            }
            lines += ["", "First observed difference: \(try RecognitionTracePresentation.firstDifference(left, right) ?? "none").",
                      "FULL final outcome: \(cell(RecognitionTracePresentation.outcome(left)))",
                      "OCCLUDED final outcome: \(cell(RecognitionTracePresentation.outcome(right)))"]
            for (title, trace) in [("FULL", left), ("OCCLUDED", right)] {
                lines += ["", "### \(title) terminal branch records",
                    "These are actual return/continue records. A rejected alternative is not a whole-engine failure when final detections exist.",
                    "```json", try json(RecognitionTracePresentation.terminalRejections(trace)), "```"]
            }
        } else {
            lines += ["", "## No unambiguous comparable candidate pair",
                "No forced candidate pairing. Missing candidates, multiple ROIs, input mismatch or unknown/different source metadata prevent a paired claim.",
                "Stage availability and every candidate's terminal outcome are still reported below."]
        }
        for (title, directory, traces) in [("FULL", full, a.1), ("OCCLUDED", covered, b.1)] {
            lines += ["", "## \(title): every Recognition and candidate"]
            if traces.isEmpty { lines.append("No exported Recognition observations. Inspect session_manifest.json for omitted/incomplete records.") }
            for trace in traces {
                let id = trace["recognitionID"] as? String ?? "unknown"
                lines += ["", "### Recognition \(id)", "Frame ID: \(trace["frameID"] ?? "null")",
                    "Full trace: \(directory.lastPathComponent)/Recognition-\(id)/recognition_trace.json",
                    "Metadata complete: \(cell(trace["metadataComplete"])); input saved: \(cell(trace["inputSaved"]))", ""]
                lines += observationLines(trace)
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    static func sameMetadata(_ a: [String: Any], _ b: [String: Any]) -> Bool {
        ["sourceRevision", "systemVersion"].allSatisfy { key in
            guard let lhs = a[key] as? String, let rhs = b[key] as? String,
                  !lhs.isEmpty, lhs != "unknown", !rhs.isEmpty, rhs != "unknown" else { return false }
            return lhs == rhs
        }
    }

    private static func sameInput(_ a: [String: Any], _ b: [String: Any]) -> Bool {
        let ia = RecognitionTracePresentation.last("recognitionSelected", in: RecognitionTracePresentation.entries(a))
        let ib = RecognitionTracePresentation.last("recognitionSelected", in: RecognitionTracePresentation.entries(b))
        guard let source = ia["source"] as? String, source == ib["source"] as? String,
              let width = ia["width"] as? Int, width > 0, width == ib["width"] as? Int,
              let height = ia["height"] as? Int, height > 0, height == ib["height"] as? Int,
              let orientation = ia["orientation"] as? Int, orientation == ib["orientation"] as? Int else { return false }
        return true
    }

    private static func box(_ value: Any?) -> CGRect? {
        guard let value = value as? [String: Any], let x = value["x"] as? Double, let y = value["y"] as? Double,
              let w = value["width"] as? Double, let h = value["height"] as? Double,
              x.isFinite, y.isFinite, w.isFinite, h.isFinite, w > 0, h > 0 else { return nil }
        return CGRect(x: x, y: y, width: w, height: h)
    }

    static func bestPair(_ a: [[String: Any]], _ b: [[String: Any]]) -> (Int, Int, Double)? {
        var best: (Int, Int, Double)?
        for (ai, left) in a.enumerated() {
            guard left["metadataComplete"] as? Bool == true else { continue }
            let ca = RecognitionTracePresentation.processedCandidates(left)
            guard ca.count == 1, let ra = box(ca[0]["boundingBox"]) else { continue }
            for (bi, right) in b.enumerated() {
                guard right["metadataComplete"] as? Bool == true else { continue }
                let cb = RecognitionTracePresentation.processedCandidates(right)
                guard cb.count == 1, let rb = box(cb[0]["boundingBox"]), sameInput(left, right) else { continue }
                let intersection = ra.intersection(rb)
                let area = intersection.isNull ? 0 : intersection.width * intersection.height
                let union = ra.width * ra.height + rb.width * rb.height - area
                let overlap = union > 0 ? Double(area / union) : 0
                // This is only an offline report association, never a production
                // Cardness, Track or recognition threshold.
                if overlap >= 0.60, overlap > (best?.2 ?? -1) { best = (ai, bi, overlap) }
            }
        }
        return best
    }

    static func coverage(_ traces: [[String: Any]]) -> [String: Int] {
        var result = ["recognitions": traces.count]
        for trace in traces {
            let entries = RecognitionTracePresentation.entries(trace)
            let tests: [(String, Bool)] = [
                ("candidate", !RecognitionTracePresentation.processedCandidates(trace).isEmpty),
                ("pip", entries.contains { $0["stage"] as? String == "pipSummary" && ["extracted", "completed"].contains($0["state"] as? String ?? "") }),
                ("rank", entries.contains { $0["stage"] as? String == "rank.candidate" }),
                ("suit", entries.contains { $0["stage"] as? String == "suit" }),
                ("ocr", entries.contains { $0["stage"] as? String == "ocr" && $0["state"] as? String == "completed" }),
                ("fusion", entries.contains { $0["stage"] as? String == "fusion.resolveInput" }),
                ("finalDetections", (RecognitionTracePresentation.last("engine.final", in: entries)["finalDetections"] as? [[String: Any]])?.isEmpty == false),
                ("published", entries.contains { $0["stage"] as? String == "timeline.published" }),
                ("uiAccepted", (trace["uiReceipts"] as? [[String: Any]] ?? []).contains { $0["recordAccepted"] as? Bool == true })
            ]
            for (key, observed) in tests where observed { result[key, default: 0] += 1 }
        }
        return result
    }

    static func firstCoverageDifference(_ a: [[String: Any]], _ b: [[String: Any]]) throws -> String? {
        guard !a.isEmpty, !b.isEmpty else { return a.isEmpty == b.isEmpty ? nil : "recognition" }
        func inputs(_ traces: [[String: Any]]) throws -> Set<Data> {
            try Set(traces.map { trace in
                try RecognitionTraceJSON.data(RecognitionTracePresentation.projection(trace)["input"] ?? NSNull())
            })
        }
        if try inputs(a) != inputs(b) { return "input" }
        let ca = coverage(a), cb = coverage(b)
        return ["candidate", "pip", "rank", "suit", "ocr", "fusion", "finalDetections", "published", "uiAccepted"].first {
            ((ca[$0] ?? 0) > 0) != ((cb[$0] ?? 0) > 0)
        }
    }

    private static func observationLines(_ trace: [String: Any]) -> [String] {
        let entries = RecognitionTracePresentation.entries(trace)
        let input = RecognitionTracePresentation.last("recognitionSelected", in: entries)
        let original = input["original"] as? [String: Any] ?? [:]
        let extractor = RecognitionTracePresentation.last("extractor", in: entries)
        let inputFields: [(String, Any?)] = [
            ("inputSource", input["source"]), ("inputWidth / inputHeight", [input["width"] ?? NSNull(), input["height"] ?? NSNull()]),
            ("originalWidth / originalHeight", [original["originalWidth"] ?? NSNull(), original["originalHeight"] ?? NSNull()]),
            ("snapshotWidth / snapshotHeight", [original["snapshotWidth"] ?? NSNull(), original["snapshotHeight"] ?? NSNull()]),
            ("scaleFactor / orientation", [original["scaleFactor"] ?? NSNull(), input["orientation"] ?? NSNull()]),
            ("candidateCount / featureCount", [extractor["candidateCount"] ?? NSNull(), extractor["featureCount"] ?? NSNull()]),
            ("final outcome", RecognitionTracePresentation.outcome(trace)),
            ("final detections", RecognitionTracePresentation.last("engine.final", in: entries)["finalDetections"]),
            ("coordinator", RecognitionTracePresentation.coordinatorOutcome(trace)), ("UI", trace["uiReceipts"])
        ]
        var lines = ["| Field | Observed value |", "| --- | --- |"]
        lines += inputFields.map { "| \($0.0) | \(cell($0.1)) |" }
        // Candidate proposals that never reached processing remain listed, along
        // with their actual failure. Do not silently discard them from the report.
        var ids: [Int] = []
        for entry in entries where entry["stage"] as? String == "candidate" {
            if let id = entry["candidateID"] as? Int, !ids.contains(id) { ids.append(id) }
        }
        for id in ids {
            let local = RecognitionTracePresentation.candidateEntries(id, in: trace)
            let processing = local.first { $0["stage"] as? String == "candidate" && $0["state"] as? String == "processing" }
            let detected = local.first { $0["stage"] as? String == "candidate" && $0["state"] as? String == "detected" } ?? [:]
            let candidate = processing ?? detected
            let pips = RecognitionTracePresentation.last("pipSummary", in: local)
            let rankInput = RecognitionTracePresentation.last("rank.input", in: local)
            let rank = RecognitionTracePresentation.last("rank.result", in: local)
            let fusionSuit = RecognitionTracePresentation.last("fusion.suit", in: local)
            let suit = fusionSuit.isEmpty ? RecognitionTracePresentation.last("suit", in: local) : fusionSuit
            let probabilities = suit["probabilities"] as? [String: Any] ?? [:]
            let ocr = RecognitionTracePresentation.last("ocr", in: local)
            let rankCandidates = local.filter { $0["stage"] as? String == "rank.candidate" }
            let rows: [(String, Any?)] = [
                ("candidate source / processing", [candidate["source"] ?? NSNull(), processing == nil ? "notRun" : "observed"]),
                ("localization confidence", candidate["localizationConfidence"]), ("boundingBox", candidate["boundingBox"]),
                ("candidate dimensions", candidate["extent"]), ("cardSurfaceScore", detected["cardSurfaceScore"]),
                ("surfaceOccupancy", detected["surfaceOccupancy"]), ("visibleRegion", candidate["visibleRegion"] ?? rankInput["visibleRegion"]),
                ("uncertainRegions", pips["uncertainRegions"] ?? rankInput["uncertainRegions"]),
                ("pip detected / retained / body", [RecognitionTracePresentation.detectedPipCount(in: local), pips["retainedCount"] ?? NSNull(), pips["bodyPipCount"] ?? NSNull()]),
                ("clipped pip centers", pips["clippedPipCandidates"]),
                ("estimator input centers", rankInput["points"] ?? pips["estimatorInput"]),
                ("normalized centers", RecognitionTracePresentation.last("rank.normalized", in: local)["normalizedPoints"]),
                ("Rank 9", rankCandidates.first { $0["rank"] as? String == "9" }),
                ("Rank 10", rankCandidates.first { $0["rank"] as? String == "10" }),
                ("Rank 8", rankCandidates.first { $0["rank"] as? String == "8" }),
                ("rank Top1 / Top2 / margin", [rank["top1"] ?? NSNull(), rank["top2"] ?? NSNull(), rank["margin"] ?? NSNull()]),
                ("finalRank / layout confidence", [rank["finalRank"] ?? NSNull(), rank["confidence"] ?? NSNull()]),
                ("club probability / suit confidence", [probabilities["club"] ?? NSNull(), suit["confidence"] ?? NSNull()]),
                ("suit distribution / margin / finalSuit", [probabilities.isEmpty ? NSNull() : probabilities as Any,
                    suit["margin"] ?? NSNull(), suit["finalSuit"] ?? NSNull()]),
                ("OCR parsed / confidence / status", [ocr["parsedRank"] ?? NSNull(), ocr["confidence"] ?? NSNull(), ocr["reason"] ?? ocr["state"] ?? NSNull()]),
                ("Fusion outcomes (each pass)", local.filter { ["fusion.resolve", "fusion.candidate"].contains($0["stage"] as? String ?? "") }),
                ("terminal branches", RecognitionTracePresentation.terminalRejections(trace).filter { $0["candidateID"] as? Int == id })
            ]
            lines += ["", "#### Candidate \(id)", "", "| Field | Observed value |", "| --- | --- |"]
            lines += rows.map { "| \($0.0) | \(cell($0.1)) |" }
        }
        return lines
    }

    private static func cell(_ value: Any?) -> String {
        RecognitionTracePresentation.value(value).replacingOccurrences(of: "|", with: "\\|")
            .replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\n", with: " ")
    }
    private static func json(_ value: Any) throws -> String {
        guard let text = String(data: try RecognitionTraceJSON.data(value), encoding: .utf8) else {
            throw RecognitionTraceIOError.corruptArchive
        }
        return text
    }
}
