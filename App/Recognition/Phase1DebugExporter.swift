import Foundation

/// Metadata export only. Never called synchronously from a camera callback.
enum Phase1DebugExporter {
    struct Files {
        let json: URL
        let text: URL
    }
    private static let queue = DispatchQueue(label: "com.cardscanmagic.diagnostics.export", qos: .utility)
    private static let lock = NSLock()
    private static var latestStartedAt: [String: Date] = [:]

    static func enqueue(_ summary: Phase1DebugSummary) {
        queue.async {
            do {
                let documents = try FileManager.default.url(for: .documentDirectory,
                    in: .userDomainMask, appropriateFor: nil, create: true)
                let files = try write(summary, to: documents)
                print("[Phase1DebugSummary] session=\(summary.sessionID) JSON=\(files.json.path) TXT=\(files.text.path)")
            } catch {
                print("[Phase1DebugSummary] exportFailed session=\(summary.sessionID) error=\(error.localizedDescription)")
            }
        }
    }

    /// Tests use their own temporary directory; production calls via enqueue.
    @discardableResult
    static func write(_ summary: Phase1DebugSummary, to documents: URL) throws -> Files {
        lock.lock(); defer { lock.unlock() }
        let folder = documents.appendingPathComponent("Phase1Diagnostics", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let base = "Phase1-\(summary.runID.uuidString)"
        let files = Files(json: folder.appendingPathComponent(base + ".json"),
                          text: folder.appendingPathComponent(base + ".txt"))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let json = try encoder.encode(summary)
        let text = Data(summary.text.utf8)
        try json.write(to: files.json, options: .atomic)
        try text.write(to: files.text, options: .atomic)
        // A cancelled older inference may finish after the next run. Keep its
        // unique files, but do not replace the newest run's convenient copies.
        if summary.startedAt >= latestStartedAt[documents.path, default: .distantPast] {
            try json.write(to: documents.appendingPathComponent("Phase1DebugSummary.json"), options: .atomic)
            try text.write(to: documents.appendingPathComponent("Phase1DebugSummary.txt"), options: .atomic)
            latestStartedAt[documents.path] = summary.startedAt
        }
        return files
    }
}
