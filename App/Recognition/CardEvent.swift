import Foundation

/// One immutable capture identity. Snapshots share this object and its owned
/// image value; they never copy camera pixels while an event is assembled.
final class CaptureFrame<Value> {
    let id: UInt64
    let generation: UInt64
    let timestamp: TimeInterval
    let value: Value
    let motionScore: Double
    let informationScore: Double
    let arrivalUptime: TimeInterval

    init(id: UInt64, generation: UInt64, timestamp: TimeInterval, value: Value,
         motionScore: Double, informationScore: Double,
         arrivalUptime: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        self.id = id
        self.generation = generation
        self.timestamp = timestamp
        self.value = value
        self.motionScore = motionScore
        self.informationScore = informationScore
        self.arrivalUptime = arrivalUptime
    }
}

/// Capture bookkeeping only. Motion and information scores are scheduling
/// evidence, never a card classification or classification confidence.
struct CardEvent<Value> {
    let id: UInt64
    let generation: UInt64
    let triggerTimestamp: TimeInterval
    let frames: [CaptureFrame<Value>]
    let isComplete: Bool
    let missingPreFrames: Int
}
