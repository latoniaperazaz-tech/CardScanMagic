import Foundation

/// Separates continuous capture history from protected event work. All mutable
/// state is under this lock; callers receive snapshots and invoke callbacks
/// after ingest/take return. The generic value is normally a compact owned image.
final class EventFrameScheduler<Value> {
    struct Statistics {
        let generation: UInt64
        let retainedFrames: Int
        let pendingEventFrames: Int
        let pendingBaselineFrames: Int
        let triggeredEvents: Int
        let completedEvents: Int
        let missingPreFrames: Int
        /// Pending-frame evictions caused by capacity overflow. This counts
        /// frames, not whole capture windows; a trim can evict several frames.
        let droppedEventFrames: Int
        let ringOverwrites: Int
        let replacedBaselineFrames: Int
        let dispatchedFrames: Int
        let rejectedFrames: Int

        var pendingFrames: Int { pendingEventFrames + pendingBaselineFrames }
    }

    private let lock = NSLock()
    private let ring: RingFrameBuffer<Value>
    private let builder: CardEventBuilder<Value>
    private let maximumPendingEventFrames: Int
    private var generation: UInt64 = 0
    private var pendingEventFrames: [UInt64: CaptureFrame<Value>] = [:]
    private var baseline: CaptureFrame<Value>?
    private var dispatchedIDs = Set<UInt64>()
    private var triggeredEvents = 0
    private var completedEvents = 0
    private var missingPreFrames = 0
    private var droppedEventFrames = 0
    private var ringOverwrites = 0
    private var replacedBaselineFrames = 0
    private var dispatchedFrames = 0
    private var rejectedFrames = 0

    init(ringCapacity: Int = 30, preFrameCount: Int = 6, postFrameCount: Int = 6,
         maximumEventFrames: Int = 25, maximumPendingEventFrames: Int = 26) {
        ring = RingFrameBuffer(capacity: ringCapacity)
        builder = CardEventBuilder(preFrameCount: preFrameCount, postFrameCount: postFrameCount,
                                   maximumFrameCount: maximumEventFrames)
        self.maximumPendingEventFrames = max(1, maximumPendingEventFrames)
    }

    /// Returns the previous generation's final counters atomically with reset.
    @discardableResult
    func reset(generation: UInt64) -> Statistics {
        lock.lock()
        defer { lock.unlock() }
        let previousStatistics = makeStatistics()
        self.generation = generation
        ring.reset()
        builder.reset(generation: generation)
        pendingEventFrames.removeAll(keepingCapacity: true)
        baseline = nil
        dispatchedIDs.removeAll(keepingCapacity: true)
        triggeredEvents = 0
        completedEvents = 0
        missingPreFrames = 0
        droppedEventFrames = 0
        ringOverwrites = 0
        replacedBaselineFrames = 0
        dispatchedFrames = 0
        rejectedFrames = 0
        return previousStatistics
    }

    @discardableResult
    func ingest(_ frame: CaptureFrame<Value>, triggered: Bool) -> CardEvent<Value>? {
        lock.lock()
        defer { lock.unlock() }
        guard frame.generation == generation, frame.timestamp.isFinite,
              frame.motionScore.isFinite, frame.informationScore.isFinite,
              ring.latest.map({ frame.id > $0.id && frame.timestamp > $0.timestamp }) ?? true else {
            rejectedFrames += 1
            return nil
        }

        // Read before append, so a ring exactly six frames wide still supplies
        // six pre-trigger captures without losing one to the trigger itself.
        let previous = ring.history(before: frame.id, limit: builder.preFrameCount)
        if ring.append(frame) != nil { ringOverwrites += 1 }
        let wasActive = builder.activeEvent != nil
        let update = builder.ingest(frame, triggered: triggered, previousFrames: previous)
        if let event = update {
            if !wasActive {
                triggeredEvents += 1
                missingPreFrames += event.missingPreFrames
            }
            if event.isComplete { completedEvents += 1 }
            for capture in event.frames where !dispatchedIDs.contains(capture.id) {
                pendingEventFrames[capture.id] = capture
                if baseline?.id == capture.id { baseline = nil }
            }
            trimEventQueue()
        } else {
            if baseline != nil { replacedBaselineFrames += 1 }
            baseline = frame
        }
        pruneDispatchedIDs()
        return update
    }

    /// Event candidates are selected by information score, then capture order.
    /// Motion is deliberately absent from this comparator and never changes
    /// a recognition result's confidence.
    func take(generation expectedGeneration: UInt64? = nil) -> CaptureFrame<Value>? {
        lock.lock()
        defer { lock.unlock() }
        guard expectedGeneration == nil || expectedGeneration == generation else { return nil }
        let frame: CaptureFrame<Value>?
        if let selected = pendingEventFrames.values.max(by: isLowerPriority) {
            pendingEventFrames.removeValue(forKey: selected.id)
            frame = selected
        } else {
            frame = baseline
            baseline = nil
        }
        guard let selected = frame else { return nil }
        dispatchedIDs.insert(selected.id)
        dispatchedFrames += 1
        pruneDispatchedIDs()
        return selected
    }

    var hasFrames: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !pendingEventFrames.isEmpty || baseline != nil
    }

    var statistics: Statistics {
        lock.lock()
        defer { lock.unlock() }
        return makeStatistics()
    }

    /// Caller holds lock, including when atomically taking pre-reset counters.
    private func makeStatistics() -> Statistics {
        return Statistics(generation: generation,
                          retainedFrames: ring.count, pendingEventFrames: pendingEventFrames.count,
                          pendingBaselineFrames: baseline == nil ? 0 : 1,
                          triggeredEvents: triggeredEvents, completedEvents: completedEvents,
                          missingPreFrames: missingPreFrames, droppedEventFrames: droppedEventFrames,
                          ringOverwrites: ringOverwrites,
                          replacedBaselineFrames: replacedBaselineFrames, dispatchedFrames: dispatchedFrames,
                          rejectedFrames: rejectedFrames)
    }

    private func isLowerPriority(_ lhs: CaptureFrame<Value>, _ rhs: CaptureFrame<Value>) -> Bool {
        if lhs.informationScore != rhs.informationScore {
            return lhs.informationScore < rhs.informationScore
        }
        return lhs.id > rhs.id
    }

    private func trimEventQueue() {
        while pendingEventFrames.count > maximumPendingEventFrames {
            guard let leastUseful = pendingEventFrames.values.min(by: isLowerPriority) else { break }
            pendingEventFrames.removeValue(forKey: leastUseful.id)
            droppedEventFrames += 1
        }
    }

    /// A dispatched ID only needs protection while its frame could be offered
    /// again by history or an active event. This keeps dedup memory bounded.
    private func pruneDispatchedIDs() {
        var reachable = Set(ring.snapshot().map(\.id))
        if let event = builder.activeEvent { reachable.formUnion(event.frames.map(\.id)) }
        reachable.formUnion(pendingEventFrames.keys)
        if let baseline { reachable.insert(baseline.id) }
        dispatchedIDs.formIntersection(reachable)
    }
}
