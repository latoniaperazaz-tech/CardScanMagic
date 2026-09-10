import Foundation

enum RecognitionTraceComparison {
    private static let lock = NSLock()
    private static let stages = ["input", "candidate", "pip", "rank", "suit", "ocr", "fusion", "final", "coordinator", "ui"]

    static func update(in root: URL) throws {
        lock.lock(); defer { lock.unlock() }
        let folders = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        let sessions = folders.compactMap { folder -> (URL, [String: Any])? in
            guard let data = try? Data(contentsOf: folder.appendingPathComponent("session_manifest.json")),
                  let manifest = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
            return (folder, manifest)
        }.sorted { ($0.1["finishedAt"] as? String ?? "") > ($1.1["finishedAt"] as? String ?? "") }
        guard let full = sessions.first(where: { $0.1["testLabel"] as? String == "FULL 9C" }),
              let covered = sessions.first(where: { $0.1["testLabel"] as? String == "OCCLUDED 9C" }) else { return }
        let text = try report(full: full.0, covered: covered.0)
        let folder = root.appendingPathComponent("Comparisons", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let name = "FULL_9C_vs_OCCLUDED_9C_\(full.1["runID"] ?? "A")_\(covered.1["runID"] ?? "B").md"
        try text.write(to: folder.appendingPathComponent(name), atomically: true, encoding: .utf8)
        try text.write(to: folder.appendingPathComponent("FULL_9C_vs_OCCLUDED_9C_latest.md"), atomically: true, encoding: .utf8)
    }

    static func loadSession(_ directory: URL) throws -> ([String: Any], [[String: Any]]) {
        let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent("session_manifest.json"))) as! [String: Any]
        let traces = try (manifest["recognitions"] as? [[String: Any]] ?? []).map { record -> [String: Any] in
            guard let path = record["traceFile"] as? String, !path.contains(".."), !path.hasPrefix("/") else {
                throw RecognitionTraceIOError.corruptArchive
            }
            return try JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent(path))) as! [String: Any]
        }
        return (manifest, traces)
    }

    static func report(full: URL, covered: URL) throws -> String {
        let a = try loadSession(full), b = try loadSession(covered)
        var lines = ["# FULL 9C vs OCCLUDED 9C", "",
            "FULL Session: \(full.lastPathComponent)", "OCCLUDED Session: \(covered.lastPathComponent)",
            "FULL complete: \(a.0["complete"] ?? false); OCCLUDED complete: \(b.0["complete"] ?? false)", "",
            "This compares exported production observations. Labels describe the user's test, not inferred identity.",
            "Candidate correspondence requires one processed candidate on each side and matching ROI geometry.",
            "OCR differences alone are not proof of the terminating rejection.", ""]
        let comparable = a.0["sourceRevision"] as? String == b.0["sourceRevision"] as? String
            && a.0["systemVersion"] as? String == b.0["systemVersion"] as? String
        lines.append("Same source/system metadata: \(comparable)")
        func candidate(_ trace: [String: Any]) -> [String: Any]? {
            let candidates = RecognitionTracePresentation.entries(trace).filter {
                $0["stage"] as? String == "candidate" && $0["state"] as? String == "processing"
            }
            return candidates.count == 1 ? candidates.first : nil
        }
        func box(_ value: Any?) -> CGRect? {
            guard let value = value as? [String: Double],
                  let x = value["x"], let y = value["y"], let w = value["width"], let h = value["height"] else { return nil }
            return CGRect(x: x, y: y, width: w, height: h)
        }
        var best: (Int, Int, Double)?
        for (ai, left) in a.1.enumerated() {
            guard let ca = candidate(left), let ra = box(ca["boundingBox"]) else { continue }
            let ia = RecognitionTracePresentation.last("recognitionSelected", in: RecognitionTracePresentation.entries(left))
            for (bi, right) in b.1.enumerated() {
                guard let cb = candidate(right), let rb = box(cb["boundingBox"]) else { continue }
                let ib = RecognitionTracePresentation.last("recognitionSelected", in: RecognitionTracePresentation.entries(right))
                guard ia["source"] as? String == ib["source"] as? String,
                      ia["width"] as? Int == ib["width"] as? Int, ia["height"] as? Int == ib["height"] as? Int else { continue }
                let intersection = ra.intersection(rb)
                let area = intersection.isNull ? 0 : intersection.width * intersection.height
                let union = ra.width * ra.height + rb.width * rb.height - area
                let overlap = union > 0 ? Double(area / union) : 0
                if overlap >= 0.60, best == nil || overlap > best!.2 { best = (ai, bi, overlap) }
            }
        }
        if let best, comparable {
            let left = a.1[best.0], right = b.1[best.1]
            let pa = RecognitionTracePresentation.projection(left), pb = RecognitionTracePresentation.projection(right)
            lines += ["", "## Matched observation pair",
                "FULL recognitionID: \(left["recognitionID"] ?? "")",
                "OCCLUDED recognitionID: \(right["recognitionID"] ?? "")",
                "Unique processed ROI IoU: \(best.2); equal input source and dimensions.",
                "Chosen by ROI overlap, not by Rank/Suit score; all other observations remain below.", ""]
            var first: String?
            lines += ["| Stage | Equal exported values |", "| --- | --- |"]
            for stage in stages {
                let equal = try RecognitionTraceJSON.data(pa[stage] ?? NSNull()) == RecognitionTraceJSON.data(pb[stage] ?? NSNull())
                if !equal && first == nil { first = stage }
                lines.append("| \(stage) | \(equal) |")
            }
            lines += ["", "First observed difference: \(first ?? "none").",
                "Inspect the actual failed checks below to distinguish differences from rejection causes.", ""]
            for (title, trace) in [("FULL", left), ("OCCLUDED", right)] {
                let checks = RecognitionTracePresentation.entries(trace).filter {
                    $0["passed"] as? Bool == false || $0["state"] as? String == "rejected"
                }
                lines += ["### \(title) actual failed branches", "Not every false check is terminal; alternatives may still succeed.",
                    "```json", String(data: try RecognitionTraceJSON.data(checks), encoding: .utf8)!, "```"]
            }
        } else {
            lines += ["", "## No unambiguous comparable candidate pair",
                "No forced candidate pairing. Check source, dimensions, missing candidates, multiple ROIs or build/system mismatch in the observations below."]
        }
        for (title, traces) in [("FULL", a.1), ("OCCLUDED", b.1)] {
            lines += ["", "## \(title): all Recognition observations"]
            for trace in traces {
                lines += ["", "### Recognition \(trace["recognitionID"] ?? "")",
                    "```json", String(data: try RecognitionTraceJSON.data(RecognitionTracePresentation.projection(trace)), encoding: .utf8)!, "```"]
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }
}

