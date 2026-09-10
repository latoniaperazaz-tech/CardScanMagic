import Foundation

struct Phase1DebugLimits: Codable {
    var frames = 20_000
    var events = 5_000
    var recognitions = 10_000
    var decisions = 1_000
    var identitiesPerCounter = 200_000
    var detectionsPerRecognition = 128
}

struct Phase1DebugTruncation: Codable {
    var frames = 0
    var events = 0
    var recognitions = 0
    var decisions = 0
    var detections = 0
    var identityOverflowOperations = 0
    var hasTruncation: Bool {
        frames + events + recognitions + decisions + detections + identityOverflowOperations > 0
    }
}

/// Full-session logarithmic histogram. Counts and maximum are exact; quantiles
/// are upper bucket bounds (1% bucket spacing, floor 0.001 ms).
struct Phase1DebugMetric: Codable {
    var count = 0
    var p50Ms: Double?
    var p95Ms: Double?
    var maxMs: Double?
}

struct Phase1DebugFrame: Codable {
    let frameID: UInt64
    let timestamp: Double
    let arrivalUptime: Double
    let informationScore: Double
    let motionScore: Double
    var snapshotWidth: Int
    var snapshotHeight: Int
}

struct Phase1DebugRecognition: Codable {
    let frameID: UInt64
    let timestamp: Double
    let arrivalUptime: Double
    let informationScore: Double
    let source: String
    let width: Int
    let height: Int
    let selectedUptime: Double
    var startUptime: Double?
    var completedUptime: Double?
    var status = "selected"
    var resultCodes: [String] = []
    var resultConfidences: [Float] = []
    var resultCount = 0
    var acceptedBySession: Bool?
    var error: String?
}

struct Phase1DebugDecision: Codable {
    let trackID: String
    let card: String
    let confidence: Float
    let duplicateCard: Bool
    let captureTimestamps: [Double]
    let publishedUptime: Double
    let captureToConfirmedMs: Double?
    let captureTimingComplete: Bool
    var formallyRecorded: Bool
}

struct Phase1DebugEvent: Codable {
    let eventID: UInt64
    let triggerFrameID: UInt64?
    let triggerTimestamp: Double
    let frameIDs: [UInt64]
    let selectedFrameIDs: [UInt64]
    let timestamps: [Double]
    let informationScores: [Double]
    let frames: [Phase1DebugFrame]
    let missingPreFrames: Int
    let preFramesReceived: Int
    let postFramesReceived: Int
    let missingPostFrames: Int
    let obtainedRequestedPreFrames: Bool
    let obtainedRequestedPostFrames: Bool
    let complete: Bool
    let recognitionAttempts: [Phase1DebugRecognition]
    let recognitionResults: [Phase1DebugRecognition]
    /// A capture window can intersect several physical tracks. This association
    /// reports shared capture timestamps and is not identity evidence or fusion.
    let finalDecision: [Phase1DebugDecision]
    let hasRecognitionResult: Bool
    let hasConcreteCardValue: Bool
    let hasUsableFrame: Bool
    let wasSentToRecognition: Bool
    let outcome: String
}

/// Scalar-only immutable export value. No image buffers or model objects.
struct Phase1DebugSummary: Codable {
    var schemaVersion = 3
    var runID: UUID
    var sessionID: UInt64
    var startedAt: Date
    var finishedAt: Date
    var reason: String
    var cameraFrames = 0
    var invalidCameraTimestamps = 0
    var averageFPS: Double = 0
    var firstCameraTimestamp: Double?
    var lastCameraTimestamp: Double?
    var droppedFrames = 0
    var motionTriggers = 0
    var motionActiveSamples = 0
    var captureEvents = 0
    var eventsWithUsableFrames = 0
    var eventsSentToRecognition = 0
    var recognitionFramesSent = 0
    var recognitionCompletions = 0
    var recognitionResults = 0
    var recognitionResultDetections = 0
    var recognitionErrors = 0
    var recognitionCancelled = 0
    var recognitionRejectedBySession = 0
    var trackDecisions = 0
    var confirmedCards = 0
    var formalRecords = 0
    var sessionUniqueCards = 0
    var duplicateDecisions = 0
    var captureToConfirmedMissingTiming = 0
    var captureToResultMissingTiming = 0
    var snapshotFailures = 0
    var snapshotAllocationFailures = 0
    var successfulSnapshots = 0
    var ringOverwrites = 0
    /// Number of pending frame evictions, not number of whole windows lost.
    var eventOverflows = 0
    var schedulerDispatchedFrames = 0
    var residentMemoryPeakBytes: UInt64 = 0
    var residentMemoryPeakMB: Double = 0
    var residentMemorySamples = 0
    var residentMemorySamplingFailures = 0
    var residentMemorySampleIntervalMs = 250
    var snapshotMaximumDimension = 1280
    var snapshotByteLimit = 0
    var requiredPreFrames = 6
    var requiredPostFrames = 6
    var eventsWithNoRecognitionResult = 0
    var metrics: [String: Phase1DebugMetric] = [:]
    var limits = Phase1DebugLimits()
    var truncation = Phase1DebugTruncation()
    var metadataComplete = true
    var uniqueCountersExact = true
    var eventOutcomeCountsScope = "retained events; complete when event/recognition metadata is not truncated"
    var notes = [
        "Camera PTS identifies captures; arrival/start/end/publish use monotonic system uptime in seconds.",
        "FPS = (delivered frames with valid PTS - 1) / (last camera PTS - first camera PTS), including snapshot failures. Invalid PTS frames are counted separately.",
        "Latency quantiles cover the full session using 4096 logarithmic buckets, 1% spacing from 0.001 ms. Count and max are exact; p50/p95 are upper bucket approximations.",
        "recognitionResults counts completed frames with at least one raw detection; recognitionCompletions also includes empty results. Rejected session results are retained for diagnostics.",
        "confirmedCards/formalRecords count UI-accepted records; trackDecisions includes duplicate-card and other decisions not formally recorded.",
        "captureToResult measures arrival of the recognized frame to engine completion, only for nonempty results. captureToConfirmed measures earliest observed capture arrival in a track to decision publication; missing capture timing is excluded and counted.",
        "residentMemoryPeak is a 250 ms sampled resident peak, not an operating-system high-water mark; shorter spikes may be missed.",
        "eventOverflows counts pending frame evictions. motionTriggers counts rising edges of the existing motion-active flag; motionActiveSamples counts all active samples.",
        "eventsWithUsableFrames means at least one captured snapshot in a retained window; it is not a claim that the card identity is visually recoverable.",
        "captureWindow IDs and physical track UUIDs are different. A window may associate with multiple decisions and one decision may associate with overlapping windows. Association is timestamp intersection, not evidence fusion.",
        "Snapshot dimensions may shrink further to meet the existing pool budget. Each recognition attempt records actual input dimensions and native/snapshot source.",
        "Metadata is bounded. Truncation counters expose omitted detail; unique counters continue independently until their separate identity cap. If identity capacity is exceeded, uniqueCountersExact is false and overflow callbacks may overcount."
    ]
    var frames: [Phase1DebugFrame] = []
    var recognitionAttempts: [Phase1DebugRecognition] = []
    var decisions: [Phase1DebugDecision] = []
    var events: [Phase1DebugEvent] = []

    var text: String {
        var lines = ["## TEST SESSION", "runID = \(runID.uuidString)", "sessionID = \(sessionID)",
                     "reason = \(reason)", "cameraFrames = \(cameraFrames)",
                     String(format: "averageFPS = %.2f", averageFPS), "droppedFrames = \(droppedFrames)", "",
                     "motionTriggers = \(motionTriggers)", "motionActiveSamples = \(motionActiveSamples)",
                     "captureEvents = \(captureEvents)", "eventsWithUsableFrames = \(eventsWithUsableFrames)",
                     "eventsSentToRecognition = \(eventsSentToRecognition)", "",
                     "recognitionFramesSent = \(recognitionFramesSent)", "recognitionCompletions = \(recognitionCompletions)",
                     "recognitionResults = \(recognitionResults)", "recognitionErrors = \(recognitionErrors)",
                     "recognitionCancelled = \(recognitionCancelled)", "trackDecisions = \(trackDecisions)",
                     "confirmedCards = \(confirmedCards)", "duplicateDecisions = \(duplicateDecisions)", ""]
        for key in metrics.keys.sorted() {
            let metric = metrics[key]!
            lines.append("\(key)P50 = \(milliseconds(metric.p50Ms))")
            lines.append("\(key)P95 = \(milliseconds(metric.p95Ms))")
            lines.append("\(key)Max = \(milliseconds(metric.maxMs)) count = \(metric.count)")
        }
        lines += ["", "snapshotFailures = \(snapshotFailures)", "snapshotAllocationFailures = \(snapshotAllocationFailures)",
                  "ringOverwrites = \(ringOverwrites)", "eventOverflows = \(eventOverflows) pending frames",
                  String(format: "memoryPeak = %.2f MB (sampled)", residentMemoryPeakMB),
                  "snapshotMaximumDimension = \(snapshotMaximumDimension)",
                  "eventsWithNoRecognitionResult = \(eventsWithNoRecognitionResult)",
                  "captureToConfirmedMissingTiming = \(captureToConfirmedMissingTiming)",
                  "metadataComplete = \(metadataComplete) uniqueCountersExact = \(uniqueCountersExact)",
                  "truncated frames=\(truncation.frames) events=\(truncation.events) recognitions=\(truncation.recognitions) decisions=\(truncation.decisions) detections=\(truncation.detections) identityOverflowOperations=\(truncation.identityOverflowOperations)",
                  "", "## DEFINITIONS"]
        lines += notes
        lines += ["", "## EVENTS"]
        for event in events {
            let trigger = event.triggerFrameID.map { String($0) } ?? "nil"
            lines += ["eventID = \(event.eventID)", "triggerFrameID = \(trigger)",
                      "frameIDs = \(event.frameIDs)", "selectedFrameIDs = \(event.selectedFrameIDs)",
                      "timestamps = \(event.timestamps)", "informationScores = \(event.informationScores)",
                      "preFramesReceived = \(event.preFramesReceived) missingPreFrames = \(event.missingPreFrames)",
                      "postFramesReceived = \(event.postFramesReceived) missingPostFrames = \(event.missingPostFrames)",
                      "complete = \(event.complete) outcome = \(event.outcome)"]
            for attempt in event.recognitionAttempts {
                let start = attempt.startUptime.map { String($0) } ?? "nil"
                let end = attempt.completedUptime.map { String($0) } ?? "nil"
                lines.append("recognition frame=\(attempt.frameID) source=\(attempt.source) size=\(attempt.width)x\(attempt.height) score=\(attempt.informationScore) start=\(start) end=\(end) status=\(attempt.status) codes=\(attempt.resultCodes) error=\(attempt.error ?? "none")")
            }
            if event.finalDecision.isEmpty { lines.append("finalDecision = []") }
            for decision in event.finalDecision {
                lines.append("finalDecision = \(decision.card) track=\(decision.trackID) confidence=\(decision.confidence) duplicateCard=\(decision.duplicateCard) formallyRecorded=\(decision.formallyRecorded)")
            }
            lines.append("")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private func milliseconds(_ value: Double?) -> String {
        guard let value else { return "n/a" }
        return String(format: "%.3f ms", value)
    }
}
