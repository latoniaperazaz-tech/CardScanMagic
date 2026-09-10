import Foundation

/// Produces a snapshot immediately at the trigger and after every post frame.
/// Repeated motion cannot extend a window; the next capture can start a new
/// event once the current window closes. Its owner supplies synchronization.
final class CardEventBuilder<Value> {
    let preFrameCount: Int
    let postFrameCount: Int
    let maximumFrameCount: Int
    private(set) var activeEvent: CardEvent<Value>?
    private var generation: UInt64 = 0
    private var nextEventID: UInt64 = 0
    private var remainingPostFrames = 0
    private var lastFrameID: UInt64?
    private var lastTimestamp: TimeInterval?

    init(preFrameCount: Int = 6, postFrameCount: Int = 6, maximumFrameCount: Int = 25) {
        self.preFrameCount = max(0, preFrameCount)
        self.postFrameCount = max(0, postFrameCount)
        self.maximumFrameCount = max(1, maximumFrameCount)
    }

    func reset(generation: UInt64) {
        self.generation = generation
        activeEvent = nil
        nextEventID = 0
        remainingPostFrames = 0
        lastFrameID = nil
        lastTimestamp = nil
    }

    func ingest(_ frame: CaptureFrame<Value>, triggered: Bool,
                previousFrames: [CaptureFrame<Value>]) -> CardEvent<Value>? {
        guard frame.generation == generation, frame.timestamp.isFinite,
              lastFrameID.map({ frame.id > $0 }) ?? true,
              lastTimestamp.map({ frame.timestamp > $0 }) ?? true else { return nil }
        lastFrameID = frame.id
        lastTimestamp = frame.timestamp

        if let current = activeEvent {
            remainingPostFrames -= 1
            let frames = current.frames + [frame]
            let complete = remainingPostFrames <= 0 || frames.count >= maximumFrameCount
            let update = CardEvent(id: current.id, generation: generation,
                                  triggerTimestamp: current.triggerTimestamp, frames: frames,
                                  isComplete: complete, missingPreFrames: current.missingPreFrames)
            activeEvent = complete ? nil : update
            return update
        }

        guard triggered else { return nil }
        let allowedPreFrames = min(preFrameCount, maximumFrameCount - 1)
        let candidates = previousFrames.filter {
            $0.generation == generation && $0.id < frame.id && $0.timestamp < frame.timestamp
        }
        let preceding = Array(candidates.suffix(allowedPreFrames))
        let frames = preceding + [frame]
        nextEventID &+= 1
        remainingPostFrames = min(postFrameCount, maximumFrameCount - frames.count)
        let event = CardEvent(id: nextEventID, generation: generation,
                             triggerTimestamp: frame.timestamp, frames: frames,
                             isComplete: remainingPostFrames == 0,
                             missingPreFrames: preFrameCount - preceding.count)
        activeEvent = event.isComplete ? nil : event
        return event
    }
}
