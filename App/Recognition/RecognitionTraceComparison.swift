import CoreGraphics
import Foundation

enum RecognitionTraceComparison {
    private static let lock = NSLock()
    // Report-only limits. They do not limit production Trace recording. Read at
    // most one full Trace at a time and retain only compact metrics. Large or
    // excess observations remain in their original exported files and are
    // explicitly listed as omitted from this bounded convenience report.
    static let maximumReportTraceBytes = 4 * 1024 * 1024
    static let maximumReportParsedBytes = 32 * 1024 * 1024
    static let maximumReportSummaryBytes = 2 * 1024 * 1024
    static let maximumReportObservationBytes = 96 * 1024
    static let maximumReportObservations = 80

    struct ReportSession {
        let manifest: [String: Any]
        let traces: [[String: Any]]
        let omissions: [[String: String]]
        let sourceObservationCount: Int
    }

    static func update(in root: URL) throws {
        lock.lock(); defer { lock.unlock() }
        let folders = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        let sessions = folders.compactMap { folder -> (URL, [String: Any])? in
            guard let manifest = try? object(at: folder.appendingPathComponent("session_manifest.json"), maximumBytes: 1024 * 1024) else { return nil }
            // Session discovery needs only these three fields. Do not retain
            // every historical Session's full Recognition index in memory.
            return (folder, manifest.filter { ["testLabel", "finishedAt", "runID"].contains($0.key) })
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

    private static func object(at url: URL, maximumBytes: Int = 32 * 1024 * 1024) throws -> [String: Any] {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let size = attributes[.size] as? NSNumber, size.int64Value >= 0, size.int64Value <= Int64(maximumBytes) else {
            throw RecognitionTraceIOError.corruptArchive
        }
        guard let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any] else {
            throw RecognitionTraceIOError.corruptArchive
        }
        return object
    }

    static func loadSession(_ directory: URL) throws -> ([String: Any], [[String: Any]]) {
        // Full-object loading is used by small archive tests/tools. Refuse a
        // large archive rather than exposing another unbounded load path.
        // Device reports use loadReportSession's sequential compact reader.
        let manifest = try object(at: directory.appendingPathComponent("session_manifest.json"), maximumBytes: 1024 * 1024)
        guard let records = manifest["recognitions"] as? [[String: Any]], records.count <= maximumReportObservations else {
            throw RecognitionTraceIOError.corruptArchive
        }
        var loadedBytes = 0
        let traces = try records.map { record -> [String: Any] in
            let file = try traceFile(record, in: directory)
            let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
            guard let size = attributes[.size] as? NSNumber,
                  size.int64Value >= 0, size.int64Value <= Int64(8 * 1024 * 1024 - loadedBytes) else {
                throw RecognitionTraceIOError.corruptArchive
            }
            loadedBytes += size.intValue
            let trace = try object(at: file, maximumBytes: maximumReportTraceBytes)
            guard trace["entries"] is [[String: Any]], trace["recognitionID"] is String else {
                throw RecognitionTraceIOError.corruptArchive
            }
            return trace
        }
        return (manifest, traces)
    }

    private static func traceFile(_ record: [String: Any], in directory: URL) throws -> URL {
        guard let path = record["traceFile"] as? String,
              !path.isEmpty, !path.contains("\\"), !path.contains(":"), !path.hasPrefix("/"),
              !path.split(separator: "/", omittingEmptySubsequences: false).contains(where: { $0 == ".." || $0.isEmpty }) else {
            throw RecognitionTraceIOError.corruptArchive
        }
        let root = directory.standardizedFileURL.resolvingSymlinksInPath()
        let file = root.appendingPathComponent(path).standardizedFileURL.resolvingSymlinksInPath()
        guard file.path.hasPrefix(root.path + "/") else { throw RecognitionTraceIOError.corruptArchive }
        return file
    }

    static func loadReportSession(_ directory: URL) throws -> ReportSession {
        let manifest = try object(at: directory.appendingPathComponent("session_manifest.json"), maximumBytes: 1024 * 1024)
        guard let records = manifest["recognitions"] as? [[String: Any]], records.count <= 10000 else {
            throw RecognitionTraceIOError.corruptArchive
        }
        var traces: [[String: Any]] = [], omissions: [[String: String]] = []
        var parsedBytes = 0, summaryBytes = 0
        for record in records {
            var reason: String?
            let path = record["traceFile"] as? String ?? "notRecorded"
            do {
                // Validate every reference, including those beyond the report's
                // count budget, without opening the omitted full JSON files.
                let file = try traceFile(record, in: directory)
                if traces.count >= maximumReportObservations { reason = "REPORT_OBSERVATION_LIMIT" }
                else if parsedBytes >= maximumReportParsedBytes { reason = "REPORT_PARSE_BYTE_LIMIT" }
                else if summaryBytes >= maximumReportSummaryBytes { reason = "REPORT_SUMMARY_BYTE_LIMIT" }
                else {
                    let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
                    guard let size = attributes[.size] as? NSNumber else { throw RecognitionTraceIOError.corruptArchive }
                    let count = size.intValue
                    if count > maximumReportTraceBytes { reason = "REPORT_SINGLE_TRACE_BYTE_LIMIT" }
                    else if count > maximumReportParsedBytes - parsedBytes { reason = "REPORT_PARSE_BYTE_LIMIT" }
                    else {
                        parsedBytes += count
                        // Foundation JSON bridges allocate autoreleased objects.
                        // Drain them per source file, not after all 500 files.
                        let result: ([String: Any], Int) = try autoreleasepool {
                            let full = try object(at: file, maximumBytes: maximumReportTraceBytes)
                            guard full["entries"] is [[String: Any]], full["recognitionID"] is String else {
                                throw RecognitionTraceIOError.corruptArchive
                            }
                            let compact = compactObservation(full)
                            return (compact, try RecognitionTraceJSON.data(compact).count)
                        }
                        if result.1 > maximumReportObservationBytes { reason = "REPORT_SINGLE_SUMMARY_BYTE_LIMIT" }
                        else if result.1 > maximumReportSummaryBytes - summaryBytes { reason = "REPORT_SUMMARY_BYTE_LIMIT" }
                        else { traces.append(result.0); summaryBytes += result.1 }
                    }
                }
            } catch { reason = "REPORT_TRACE_UNREADABLE: \(error)" }
            if let reason { omissions.append(["traceFile": path, "reason": reason]) }
        }
        return ReportSession(manifest: manifest, traces: traces, omissions: omissions, sourceObservationCount: records.count)
    }

    private static func compactObservation(_ trace: [String: Any]) -> [String: Any] {
        let all = RecognitionTracePresentation.entries(trace)
        let current = RecognitionTracePresentation.currentFrameEntries(trace)
        let scalarStages: Set<String> = ["recognitionSelected", "losslessInput", "extractor", "candidate", "pipSummary",
            "rank.input", "rank.normalized", "rank.candidate", "rank.result", "rank.check", "suit",
            "fusion.input", "fusion.resolveInput", "fusion.resolve", "fusion.candidate", "fusion.result", "fusion.suit",
            "fusion.conflict", "fusion.pipSupport", "engine.final", "engine.error", "pipelineError", "pipelineRejected",
            "timeline.output", "timeline.published", "timeline.rejected", "timeline.decisionSuppressed"]
        var selected = all.filter { entry in
            let stage = entry["stage"] as? String ?? ""
            return scalarStages.contains(stage)
                || (stage == "fusion.check" && entry["passed"] as? Bool == false)
                || (stage == "ocr" && ["completed", "notRun", "error"].contains(entry["state"] as? String ?? ""))
        }
        selected += current.filter { $0["stage"] as? String == "track.decision" }
        // Older traces did not yet contain the explicit production total. Keep
        // the count of observed entries separately, without inventing a value
        // named detectedCount that production never emitted.
        for candidate in RecognitionTracePresentation.processedCandidates(trace) {
            guard let id = candidate["candidateID"] as? Int else { continue }
            let local = RecognitionTracePresentation.candidateEntries(id, in: trace)
            let count = RecognitionTracePresentation.detectedPipCount(in: local)
            if let index = selected.lastIndex(where: { $0["stage"] as? String == "pipSummary" && $0["candidateID"] as? Int == id }) {
                selected[index]["comparisonObservedComponentCount"] = count
            }
        }
        var result = trace.filter { ["recognitionID", "frameID", "metadataComplete", "inputSaved", "uiReceipts", "captureWindowIDs", "testLabel"].contains($0.key) }
        result["entries"] = selected
        result["comparisonCompacted"] = true
        result["sourceEntryCount"] = all.count
        result["omittedDetailEntryCount"] = all.count - selected.count
        return result
    }

    static func report(full: URL, covered: URL) throws -> String {
        let fullSession = try loadReportSession(full), coveredSession = try loadReportSession(covered)
        let a = (fullSession.manifest, fullSession.traces), b = (coveredSession.manifest, coveredSession.traces)
        var lines = ["# FULL 9C vs OCCLUDED 9C", "",
            "FULL Session: \(full.lastPathComponent)", "OCCLUDED Session: \(covered.lastPathComponent)",
            "FULL complete: \(a.0["complete"] ?? false); OCCLUDED complete: \(b.0["complete"] ?? false)", "",
            "These are exported production observations. FULL/OCCLUDED 9C are user labels, not inferred identities.",
            "Different observations are not interchangeable physical tracks. No rank/suit evidence is fused by this report.",
            "First observed difference is not automatically the cause of rejection. OCR_NIL is an optional cue state.",
            "This bounded report compares compact production metrics. Component-by-component lifecycles, OCR observations and replay history remain in each original Trace JSON.",
            "Report limits per session: \(maximumReportObservations) observations, \(maximumReportTraceBytes) bytes per input Trace, \(maximumReportParsedBytes) parsed bytes, \(maximumReportSummaryBytes) compact summary bytes.",
            "FULL report observations: \(fullSession.traces.count)/\(fullSession.sourceObservationCount); omitted: \(fullSession.omissions.count).",
            "OCCLUDED report observations: \(coveredSession.traces.count)/\(coveredSession.sourceObservationCount); omitted: \(coveredSession.omissions.count).", ""]
        if !fullSession.omissions.isEmpty || !coveredSession.omissions.isEmpty {
            lines += ["PARTIAL COMPARISON: omitted observations can contain earlier differences or successful results. No whole-session conclusion is made from this subset.", ""]
        }
        let comparable = sameMetadata(a.0, b.0)
        lines.append("Same known source revision/system/model SHA-256: \(comparable)")
        lines += ["", "## Included observation stage coverage (unpaired)",
                  "Counts describe included observations; they do not imply one-to-one frame correspondence.", "",
                  "| Observed stage | FULL | OCCLUDED |", "| --- | ---: | ---: |"]
        let coverageA = coverage(a.1), coverageB = coverage(b.1)
        for key in ["recognitions", "candidate", "pip", "rank", "suit", "ocr", "fusion", "finalDetections", "published", "uiAccepted"] {
            lines.append("| \(key) | \(coverageA[key] ?? 0) | \(coverageB[key] ?? 0) |")
        }
        // Missing candidates must be visible even when ROI pairing is impossible.
        // This claim concerns stage availability, not correspondence of images.
        if let first = try firstCoverageDifference(a.1, b.1) {
            lines += ["", "First observed stage-availability difference: \(first) (included, unpaired observations)."]
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
                "| Stage | Equal compared metrics |", "| --- | --- |"]
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
            lines += ["", "## \(title): included Recognition observations and candidates"]
            if traces.isEmpty { lines.append("No exported Recognition observations. Inspect session_manifest.json for omitted/incomplete records.") }
            for trace in traces {
                let id = trace["recognitionID"] as? String ?? "unknown"
                lines += ["", "### Recognition \(id)", "Frame ID: \(trace["frameID"] ?? "null")",
                    "Full trace: \(directory.lastPathComponent)/Recognition-\(id)/recognition_trace.json",
                    "Metadata complete: \(cell(trace["metadataComplete"])); input saved: \(cell(trace["inputSaved"]))",
                    "Source entries: \(cell(trace["sourceEntryCount"])); low-level detail entries retained only in source JSON: \(cell(trace["omittedDetailEntryCount"])).", ""]
                lines += observationLines(trace)
            }
        }
        for (title, session) in [("FULL", fullSession), ("OCCLUDED", coveredSession)] where !session.omissions.isEmpty {
            lines += ["", "## \(title): observations omitted from this report", "Original exported files are not deleted or modified.", "",
                      "| Original Trace reference | Report omission reason |", "| --- | --- |"]
            for omitted in session.omissions { lines.append("| \(cell(omitted["traceFile"])) | \(cell(omitted["reason"])) |") }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    static func sameMetadata(_ a: [String: Any], _ b: [String: Any]) -> Bool {
        ["sourceRevision", "systemVersion", "modelSHA256"].allSatisfy { key in
            guard let lhs = a[key] as? String, let rhs = b[key] as? String,
                  !lhs.isEmpty, lhs != "unknown", !rhs.isEmpty, rhs != "unknown" else { return false }
            if key == "modelSHA256" {
                guard lhs.count == 64, rhs.count == 64,
                      lhs.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "0123456789abcdefABCDEF").contains($0) }),
                      rhs.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "0123456789abcdefABCDEF").contains($0) }) else { return false }
                return lhs.lowercased() == rhs.lowercased()
            }
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
