import CoreGraphics
import CoreImage
import Foundation

/// A thread-scoped observer. Production never reads its output to make decisions.
final class RecognitionTrace {
    private static let key = "com.cardscanmagic.recognition.trace"
    static var current: RecognitionTrace? { Thread.current.threadDictionary[key] as? RecognitionTrace }
    let recognitionID: String
    let frameID: UInt64
    let sessionID: UInt64
    let runID: String
    var candidateID: Int?
    var componentID: String?
    var context: [String: Any] = [:]
    private(set) var entries: [[String: Any]] = []
    private(set) var callCounts: [String: Int] = [:]
    private(set) var truncatedEntries = 0
    private var nextCandidateID = 0
    let maximumEntries: Int
    var imageSink: ((String, CIImage) -> Void)?
    var overlaySink: ((String, CIImage, [[String: Any]], [CGRect]) -> Void)?

    init(recognitionID: String = UUID().uuidString, frameID: UInt64 = 0,
         sessionID: UInt64 = 0, runID: String = UUID().uuidString, maximumEntries: Int = 12000) {
        self.recognitionID = recognitionID; self.frameID = frameID
        self.sessionID = sessionID; self.runID = runID; self.maximumEntries = maximumEntries
    }

    static func withCurrent<T>(_ trace: RecognitionTrace?, _ body: () throws -> T) rethrows -> T {
        let previous = Thread.current.threadDictionary[key]
        if let trace { Thread.current.threadDictionary[key] = trace }
        else { Thread.current.threadDictionary.removeObject(forKey: key) }
        defer {
            if let previous { Thread.current.threadDictionary[key] = previous }
            else { Thread.current.threadDictionary.removeObject(forKey: key) }
        }
        return try body()
    }

    static func call(_ name: String) {
        RecognitionCallProbe.current?.increment(name)
        current?.callCounts[name, default: 0] += 1
    }

    func event(_ stage: String, _ fields: [String: Any] = [:]) {
        guard entries.count < maximumEntries else { truncatedEntries += 1; return }
        var entry = context
        entry["stage"] = stage
        entry["uptime"] = ProcessInfo.processInfo.systemUptime
        if let candidateID { entry["candidateID"] = candidateID }
        if let componentID { entry["componentID"] = componentID }
        fields.forEach { entry[$0.key] = $0.value }
        entries.append(entry)
    }

    @discardableResult
    func beginCandidate(_ fields: [String: Any] = [:]) -> Int {
        let id = nextCandidateID; nextCandidateID += 1; candidateID = id
        event("candidate", fields); return id
    }

    func image(_ name: String, image: CIImage) { imageSink?(name, image) }

    func overlay(_ name: String, image: CIImage, components: [[String: Any]], uncertainRegions: [CGRect]) {
        overlaySink?(name, image, components, uncertainRegions)
    }

    func snapshot() -> [String: Any] {
        ["schemaVersion": 1, "runID": runID, "sessionID": String(sessionID),
         "frameID": String(frameID), "recognitionID": recognitionID,
         "candidateProposalCount": nextCandidateID, "entries": entries, "callCounts": callCounts,
         "truncatedEntries": truncatedEntries, "metadataComplete": truncatedEntries == 0]
    }

    static func rect(_ value: CGRect) -> [String: Double] {
        ["x": Double(value.minX), "y": Double(value.minY),
         "width": Double(value.width), "height": Double(value.height)]
    }
    static func points(_ values: [CGPoint]) -> [[String: Double]] {
        values.map { ["x": Double($0.x), "y": Double($0.y)] }
    }
    static func detections(_ values: [CardDetection]) -> [[String: Any]] {
        values.map {
            ["card": $0.card.code, "confidence": $0.confidence,
             "boundingBox": rect($0.boundingBox),
             "width": Double($0.orientedImageSize.width), "height": Double($0.orientedImageSize.height),
             "hasIndependentSupport": $0.hasIndependentSupport]
        }
    }
}

/// Separately enabled in equivalence tests, including when Trace is OFF.
final class RecognitionCallProbe {
    private static let key = "com.cardscanmagic.recognition.callprobe"
    static var current: RecognitionCallProbe? { Thread.current.threadDictionary[key] as? RecognitionCallProbe }
    private(set) var counts: [String: Int] = [:]
    func increment(_ name: String) { counts[name, default: 0] += 1 }
    static func measure<T>(_ body: () throws -> T) rethrows -> (T, [String: Int]) {
        let probe = RecognitionCallProbe()
        let previous = Thread.current.threadDictionary[key]
        Thread.current.threadDictionary[key] = probe
        defer {
            if let previous { Thread.current.threadDictionary[key] = previous }
            else { Thread.current.threadDictionary.removeObject(forKey: key) }
        }
        let value = try body()
        return (value, probe.counts)
    }
}
