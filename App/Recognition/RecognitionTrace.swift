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
    private(set) var estimatedBytes = 0
    private var nextCandidateID = 0
    let maximumEntries: Int
    let maximumBytes: Int
    var imageSink: ((String, CIImage) -> Void)?
    var overlaySink: ((String, CIImage, [[String: Any]], [CGRect]) -> Void)?

    init(recognitionID: String = UUID().uuidString, frameID: UInt64 = 0,
         sessionID: UInt64 = 0, runID: String = UUID().uuidString, maximumEntries: Int = 12000,
         maximumBytes: Int = 8 * 1024 * 1024) {
        self.recognitionID = recognitionID; self.frameID = frameID
        self.sessionID = sessionID; self.runID = runID; self.maximumEntries = maximumEntries
        self.maximumBytes = maximumBytes
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
        if let code = Self.reasonCode(stage, entry) { entry["reasonCode"] = code }
        let cost = Self.storageCost(entry)
        guard cost <= maximumBytes - estimatedBytes else { truncatedEntries += 1; return }
        estimatedBytes += cost
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
        let value: [String: Any] = ["schemaVersion": 1, "runID": runID, "sessionID": String(sessionID),
         "frameID": String(frameID), "recognitionID": recognitionID,
         "candidateProposalCount": nextCandidateID, "entries": entries, "callCounts": callCounts,
         "truncatedEntries": truncatedEntries, "metadataComplete": truncatedEntries == 0,
         "estimatedMetadataBytes": estimatedBytes, "metadataByteLimit": maximumBytes]
        return RecognitionTraceJSON.safe(value) as? [String: Any] ?? [:]
    }

    /// Conservative recursive accounting bounds nested arrays as well as entry count.
    /// Diagnostic allocation units, not a claim about resident memory measurements.
    static func storageCost(_ value: Any) -> Int {
        if let map = value as? [String: Any] {
            return 128 + map.reduce(0) { $0 + 128 + $1.key.utf8.count * 6 + storageCost($1.value) }
        }
        if let list = value as? [Any] { return 64 + list.reduce(0) { $0 + 32 + storageCost($1) } }
        if let string = value as? String { return 64 + string.utf8.count * 6 }
        return 64
    }

    /// Categories only: preserve the detailed branch reason and never affect its result.
    private static func reasonCode(_ stage: String, _ fields: [String: Any]) -> String? {
        if stage == "engine.final", let output = fields["finalDetections"] as? [Any], output.isEmpty { return "NO_FINAL_DETECTION" }
        if stage == "fusion.conflict", fields["vetoed"] as? Bool == true {
            return fields["rankConflict"] as? Bool == true ? "OCR_CONFLICT" : "RANK_SUIT_CONFLICT"
        }
        guard fields["passed"] as? Bool != true, let reason = fields["reason"] as? String else { return nil }
        switch reason {
        case "LOCALIZATION_CONFIDENCE_LOW": return "LOW_LOCALIZATION"
        case "NO_SUIT_ELIGIBLE_PIP": return "SUIT_NOT_FOUND"
        case "SUIT_MARGIN_LOW", "SUIT_CONFIDENCE_LOW", "FUSION_SUIT_UNRESOLVED": return "SUIT_AMBIGUOUS"
        case "NO_VALID_ESTIMATOR_PIPS", "PIP_INPUT_EMPTY", "PIP_ABSOLUTE_SUPPORT_INSUFFICIENT",
             "PIP_VISIBLE_SUPPORT_INSUFFICIENT", "PIP_PARTIAL_COUNT_LOW": return "INSUFFICIENT_PIP_CENTERS"
        case "PIP_LAYOUT_SCORE_LOW", "PIP_LAYOUT_CONFIDENCE_LOW", "FUSION_LAYOUT_CONFIDENCE_LOW": return "PIP_LAYOUT_LOW_SCORE"
        case "PIP_LAYOUT_MARGIN_LOW", "PIP_OCCLUSION_AMBIGUOUS", "PIP_LAYOUT_RANK_UNRESOLVED",
             "FUSION_RANK_UNRESOLVED": return "PIP_LAYOUT_AMBIGUOUS"
        case "FUSION_NO_QUALIFIED_RANK_SUPPORT", "FUSION_CONFLICT_VETO": return "FUSION_REJECTED"
        default:
            if stage == "componentFiltered", fields["purpose"] as? String == "pip" { return "PIP_COMPONENTS_FILTERED" }
            return reason
        }
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
