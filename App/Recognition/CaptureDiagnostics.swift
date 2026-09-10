import Darwin
import Foundation

/// Diagnostic scalar collection only. A recorder is owned by one camera run;
/// it never retains CaptureFrame.value, waits on recognition, or writes files.
final class CaptureDiagnostics {
    private struct Histogram {
        private static let floorMs = 0.001
        private static let logFactor = log(1.01)
        private var buckets = [Int](repeating: 0, count: 4096)
        private var count = 0
        private var maximum: Double = 0

        mutating func append(seconds: Double) {
            let ms = seconds * 1000
            guard ms.isFinite, ms >= 0 else { return }
            let raw = ms <= Self.floorMs ? 0 : Int(ceil(log(ms / Self.floorMs) / Self.logFactor))
            buckets[min(buckets.count - 1, max(0, raw))] += 1
            count += 1
            maximum = max(maximum, ms)
        }

        var summary: Phase1DebugMetric {
            Phase1DebugMetric(count: count, p50Ms: quantile(0.50), p95Ms: quantile(0.95),
                              maxMs: count == 0 ? nil : maximum)
        }

        private func quantile(_ fraction: Double) -> Double? {
            guard count > 0 else { return nil }
            let required = max(1, Int(ceil(Double(count) * fraction)))
            var cumulative = 0
            for (index, value) in buckets.enumerated() {
                cumulative += value
                if cumulative >= required {
                    // The last bucket includes arbitrarily large values. Its
                    // exact full-session maximum remains a valid upper bound.
                    if index == buckets.count - 1 { return maximum }
                    return min(maximum, Self.floorMs * exp(Double(index) * Self.logFactor))
                }
            }
            return maximum
        }
    }

    private struct Window {
        let id: UInt64
        let triggerTimestamp: Double
        var frames: [Phase1DebugFrame]
        var complete: Bool
        var missingPreFrames: Int
    }

    let sessionID: UInt64
    let runID = UUID()
    private let configuration: CaptureConfiguration
    private let limits: Phase1DebugLimits
    private let startedAt = Date()
    private let lock = NSLock()
    private let activities = DispatchGroup()
    private var closing = false
    private var finalized = false
    private var timer: DispatchSourceTimer?
    private var frames: [UInt64: Phase1DebugFrame] = [:]
    private var retainedArrivalTimes: [Double: Double] = [:]
    private var windows: [UInt64: Window] = [:]
    private var attempts: [UInt64: Phase1DebugRecognition] = [:]
    private var decisionValues: [UUID: Phase1DebugDecision] = [:]
    private var histograms: [String: Histogram] = [:]
    private var truncation = Phase1DebugTruncation()
    private var selectedIDs = Set<UInt64>()
    private var terminalIDs = Set<UInt64>()
    private var windowIDs = Set<UInt64>()
    private var decisionIDs = Set<UUID>()
    private var formalIDs = Set<UUID>()
    private var cardCodes = Set<String>()
    // Active attempt timing survives the detail cap. It is bounded separately
    // from history and released on completion; the pipeline has one in flight.
    private var inFlightArrivals: [UInt64: Double] = [:]
    private var inFlightStarts: [UInt64: Double] = [:]
    private var recentArrivals: [Double: Double] = [:]
    private var recentArrivalKeys = [Double]()
    private var recentArrivalIndex = 0
    private let recentArrivalCapacity = 512
    private var cameraFrames = 0
    private var validCameraTimestamps = 0
    private var cameraFramesFromOtherSessions = 0
    private var cameraTransitions: [Phase1CameraTransition] = []
    private var firstPTS: Double?
    private var lastPTS: Double?
    private var droppedFrames = 0
    private var motionWasActive = false
    private var motionTriggers = 0
    private var motionActiveSamples = 0
    private var captureEvents = 0
    private var schedulerCaptureEvents = 0
    private var recognitionFramesSent = 0
    private var recognitionCompletions = 0
    private var recognitionResults = 0
    private var recognitionResultDetections = 0
    private var recognitionErrors = 0
    private var cancelledRecognitions = 0
    private var recognitionRejectedBySession = 0
    private var trackDecisions = 0
    private var duplicateDecisions = 0
    private var formalRecordCount = 0
    private var confirmedMissingTiming = 0
    private var resultMissingTiming = 0
    private var snapshotFailures = 0
    private var allocationFailureCount = 0
    private var successfulSnapshots = 0
    private var ringOverwrites = 0
    private var eventOverflows = 0
    private var schedulerDispatchedFrames = 0
    private var residentPeak: UInt64 = 0
    private var residentSamples = 0
    private var residentSamplingFailures = 0

    init(sessionID: UInt64, configuration: CaptureConfiguration,
         limits: Phase1DebugLimits = Phase1DebugLimits()) {
        self.sessionID = sessionID
        self.configuration = configuration
        self.limits = limits
        for key in ["cameraCallback", "motionMeasure", "eventCreation", "eventUpdate", "recognitionDuration", "captureToResult", "captureToConfirmed"] {
            histograms[key] = Histogram()
        }
        let sampler = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        sampler.schedule(deadline: .now(), repeating: .milliseconds(250))
        sampler.setEventHandler { [weak self] in self?.sampleMemory() }
        timer = sampler
        sampler.resume()
    }

    deinit { timer?.cancel() }

    /// Admission and group.enter are atomic with close. No new work can enter
    /// after sealing, while previously admitted work can finish bookkeeping.
    @discardableResult
    func beginActivity() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !closing else { return false }
        activities.enter()
        return true
    }

    func endActivity() { activities.leave() }

    func close(reason: String, completion: @escaping (Phase1DebugSummary) -> Void) {
        lock.lock()
        guard !closing else { lock.unlock(); return }
        closing = true
        lock.unlock()
        activities.notify(queue: DispatchQueue.global(qos: .utility)) { [self] in
            sampleMemory()
            lock.lock()
            finalized = true
            timer?.cancel()
            timer = nil
            lock.unlock()
            // All mutations reject finalized recorders. Expensive joins and
            // formatting now run outside locks and off capture/recognition.
            completion(makeSummary(reason: reason))
        }
    }

    func cameraFrame(timestamp: Double) {
        mutate {
            cameraFrames += 1
            if timestamp.isFinite && timestamp >= 0 {
                validCameraTimestamps += 1
                firstPTS = firstPTS ?? timestamp
                lastPTS = timestamp
            }
        }
    }

    func cameraCallback(duration: Double) { mutate { measure("cameraCallback", duration) } }
    func cameraTransition(frameID: UInt64, sourceSessionID: UInt64) {
        mutate {
            cameraFramesFromOtherSessions += 1
            if cameraTransitions.count < max(0, limits.frames) {
                cameraTransitions.append(Phase1CameraTransition(frameID: frameID, sourceSessionID: sourceSessionID))
            } else { truncation.frames += 1 }
        }
    }
    func cameraDropped() { mutate { droppedFrames += 1 } }
    func snapshotFailed() { mutate { snapshotFailures += 1 } }
    /// Delta for the current copy attempt, not a pool lifetime total.
    func allocationFailures(_ count: Int) { mutate { allocationFailureCount += max(0, count) } }

    func motion(duration: Double, triggered: Bool) {
        mutate {
            measure("motionMeasure", duration)
            if triggered { motionActiveSamples += 1 }
            if triggered && !motionWasActive { motionTriggers += 1 }
            motionWasActive = triggered
        }
    }

    func capture<Value>(_ frame: CaptureFrame<Value>, width: Int, height: Int) {
        guard frame.generation == sessionID else { return }
        mutate {
            successfulSnapshots += 1
            let value = metadata(frame, width: width, height: height)
            if frames[frame.id] != nil || frames.count < max(0, limits.frames) {
                frames[frame.id] = value
                retainedArrivalTimes[frame.timestamp] = frame.arrivalUptime
            } else {
                truncation.frames += 1
            }
            rememberArrival(timestamp: frame.timestamp, uptime: frame.arrivalUptime)
        }
    }

    func event<Value>(_ event: CardEvent<Value>, latency: Double) {
        guard event.generation == sessionID else { return }
        mutate {
            let isNew = remember(event.id, in: &windowIDs)
            if isNew { captureEvents += 1; measure("eventCreation", latency) }
            measure("eventUpdate", latency)
            guard windows[event.id] != nil || windows.count < max(0, limits.events) else {
                if isNew { truncation.events += 1 }
                return
            }
            // Copy scalar metadata, not frame.value. A window remains reviewable
            // after the ring or global diagnostic history has been overwritten.
            let values = event.frames.map { frame -> Phase1DebugFrame in
                frames[frame.id] ?? metadata(frame, width: 0, height: 0)
            }
            windows[event.id] = Window(id: event.id, triggerTimestamp: event.triggerTimestamp,
                                      frames: values, complete: event.isComplete,
                                      missingPreFrames: event.missingPreFrames)
        }
    }

    func scheduler(_ stats: EventFrameScheduler<CapturedImage>.Statistics) {
        guard stats.generation == sessionID else { return }
        mutate {
            schedulerCaptureEvents = max(schedulerCaptureEvents, stats.triggeredEvents)
            ringOverwrites = max(ringOverwrites, stats.ringOverwrites)
            eventOverflows = max(eventOverflows, stats.droppedEventFrames)
            schedulerDispatchedFrames = max(schedulerDispatchedFrames, stats.dispatchedFrames)
        }
    }

    func selected<Value>(_ frame: CaptureFrame<Value>, source: String, width: Int, height: Int) {
        guard frame.generation == sessionID else { return }
        mutate {
            guard remember(frame.id, in: &selectedIDs) else { return }
            recognitionFramesSent += 1
            if inFlightArrivals.count < 256 { inFlightArrivals[frame.id] = frame.arrivalUptime }
            guard attempts.count < max(0, limits.recognitions) else {
                truncation.recognitions += 1
                return
            }
            attempts[frame.id] = Phase1DebugRecognition(frameID: frame.id, timestamp: frame.timestamp,
                arrivalUptime: frame.arrivalUptime, informationScore: frame.informationScore,
                source: source, width: width, height: height,
                selectedUptime: ProcessInfo.processInfo.systemUptime)
        }
    }

    func recognitionStarted(frameID: UInt64, at: Double) {
        mutate {
            guard !terminalIDs.contains(frameID) else { return }
            if inFlightStarts[frameID] == nil && inFlightStarts.count < 256 { inFlightStarts[frameID] = at }
            if attempts[frameID]?.startUptime == nil { attempts[frameID]?.startUptime = at }
            attempts[frameID]?.status = "running"
        }
    }

    func recognitionCompleted(frameID: UInt64, at: Double, detections: [CardDetection], acceptedBySession: Bool) {
        mutate {
            guard remember(frameID, in: &terminalIDs) else { return }
            recognitionCompletions += 1
            if !acceptedBySession { recognitionRejectedBySession += 1 }
            if !detections.isEmpty {
                recognitionResults += 1
                recognitionResultDetections += detections.count
                if let arrival = inFlightArrivals[frameID] ?? attempts[frameID]?.arrivalUptime ?? frames[frameID]?.arrivalUptime {
                    measure("captureToResult", at - arrival)
                } else { resultMissingTiming += 1 }
            }
            if let start = inFlightStarts.removeValue(forKey: frameID) ?? attempts[frameID]?.startUptime {
                measure("recognitionDuration", at - start)
            }
            inFlightArrivals.removeValue(forKey: frameID)
            let retained = detections.prefix(max(0, limits.detectionsPerRecognition))
            truncation.detections += max(0, detections.count - retained.count)
            attempts[frameID]?.completedUptime = at
            attempts[frameID]?.status = "completed"
            attempts[frameID]?.acceptedBySession = acceptedBySession
            attempts[frameID]?.resultCount = detections.count
            attempts[frameID]?.resultCodes = retained.map { $0.card.code }
            attempts[frameID]?.resultConfidences = retained.map { $0.confidence.isFinite ? $0.confidence : 0 }
        }
    }

    func recognitionCancelled(frameID: UInt64) {
        mutate {
            guard remember(frameID, in: &terminalIDs) else { return }
            cancelledRecognitions += 1
            inFlightStarts.removeValue(forKey: frameID)
            inFlightArrivals.removeValue(forKey: frameID)
            attempts[frameID]?.completedUptime = ProcessInfo.processInfo.systemUptime
            attempts[frameID]?.status = "cancelled"
        }
    }

    func recognitionFailed(frameID: UInt64, at: Double, error: String) {
        mutate {
            guard remember(frameID, in: &terminalIDs) else { return }
            recognitionErrors += 1
            if let start = inFlightStarts.removeValue(forKey: frameID) ?? attempts[frameID]?.startUptime {
                measure("recognitionDuration", at - start)
            }
            inFlightArrivals.removeValue(forKey: frameID)
            attempts[frameID]?.completedUptime = at
            attempts[frameID]?.status = "error"
            attempts[frameID]?.error = String(error.prefix(1024))
        }
    }

    func decisions(_ values: [CardPassDecision], at: Double) {
        mutate {
            for value in values {
                guard remember(value.eventID, in: &decisionIDs) else { continue }
                trackDecisions += 1
                if value.duplicateCard { duplicateDecisions += 1 }
                let timestamps = value.captureTimestamps.sorted()
                let arrivals = timestamps.compactMap { timestamp -> Double? in
                    // Recent identity timing remains bounded independently of
                    // full-session frame metadata; normal tracks live < 4 s.
                    if let recent = recentArrivals[timestamp] { return recent }
                    return retainedArrivalTimes[timestamp]
                }
                let timingComplete = !timestamps.isEmpty && arrivals.count == timestamps.count
                let latency = timingComplete ? arrivals.min().map { max(0, at - $0) * 1000 } : nil
                if let latency { measure("captureToConfirmed", latency / 1000) }
                else { confirmedMissingTiming += 1 }
                guard decisionValues.count < max(0, limits.decisions) else {
                    truncation.decisions += 1
                    continue
                }
                decisionValues[value.eventID] = Phase1DebugDecision(trackID: value.eventID.uuidString,
                    card: value.record.card.code, confidence: value.record.confidence,
                    duplicateCard: value.duplicateCard, captureTimestamps: timestamps,
                    publishedUptime: at, captureToConfirmedMs: latency,
                    captureTimingComplete: timingComplete, formallyRecorded: formalIDs.contains(value.record.id))
            }
        }
    }

    func formalRecords(_ records: [CardRecord]) {
        mutate {
            for record in records {
                guard remember(record.id, in: &formalIDs) else { continue }
                formalRecordCount += 1
                cardCodes.insert(record.card.code)
                decisionValues[record.id]?.formallyRecorded = true
            }
        }
    }

    private func mutate(_ body: () -> Void) {
        lock.lock(); defer { lock.unlock() }
        guard !finalized else { return }
        body()
    }

    private func measure(_ name: String, _ duration: Double) { histograms[name]?.append(seconds: duration) }

    /// Identity storage has its own cap, independent of detailed metadata.
    /// Saturation is explicit; callbacks outside coverage may overcount.
    private func remember<Key: Hashable>(_ key: Key, in identities: inout Set<Key>) -> Bool {
        if identities.contains(key) { return false }
        guard identities.count < max(0, limits.identitiesPerCounter) else {
            truncation.identityOverflowOperations += 1
            return true
        }
        identities.insert(key)
        return true
    }

    private func metadata<Value>(_ frame: CaptureFrame<Value>, width: Int, height: Int) -> Phase1DebugFrame {
        Phase1DebugFrame(frameID: frame.id, timestamp: frame.timestamp,
            arrivalUptime: frame.arrivalUptime, informationScore: frame.informationScore,
            motionScore: frame.motionScore, snapshotWidth: width, snapshotHeight: height)
    }

    private func rememberArrival(timestamp: Double, uptime: Double) {
        if recentArrivalKeys.count < recentArrivalCapacity {
            recentArrivalKeys.append(timestamp)
        } else {
            recentArrivals.removeValue(forKey: recentArrivalKeys[recentArrivalIndex])
            recentArrivalKeys[recentArrivalIndex] = timestamp
            recentArrivalIndex = (recentArrivalIndex + 1) % recentArrivalCapacity
        }
        recentArrivals[timestamp] = uptime
    }

    private func sampleMemory() {
        let bytes = Self.residentBytes()
        mutate {
            if let bytes { residentPeak = max(residentPeak, bytes); residentSamples += 1 }
            else { residentSamplingFailures += 1 }
        }
    }

    private static func residentBytes() -> UInt64? {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return status == KERN_SUCCESS ? UInt64(info.resident_size) : nil
    }

    private func makeSummary(reason: String) -> Phase1DebugSummary {
        var result = Phase1DebugSummary(runID: runID, sessionID: sessionID, startedAt: startedAt,
                                       finishedAt: Date(), reason: reason)
        result.cameraFrames = cameraFrames
        result.invalidCameraTimestamps = cameraFrames - validCameraTimestamps
        result.cameraFramesFromOtherSessions = cameraFramesFromOtherSessions
        result.cameraTransitions = cameraTransitions
        result.firstCameraTimestamp = firstPTS
        result.lastCameraTimestamp = lastPTS
        if let firstPTS, let lastPTS, lastPTS > firstPTS {
            result.averageFPS = Double(max(0, validCameraTimestamps - 1)) / (lastPTS - firstPTS)
        }
        result.droppedFrames = droppedFrames
        result.motionTriggers = motionTriggers
        result.motionActiveSamples = motionActiveSamples
        result.captureEvents = max(captureEvents, schedulerCaptureEvents)
        result.recognitionFramesSent = recognitionFramesSent
        result.recognitionCompletions = recognitionCompletions
        result.recognitionResults = recognitionResults
        result.recognitionResultDetections = recognitionResultDetections
        result.recognitionErrors = recognitionErrors
        result.recognitionCancelled = cancelledRecognitions
        result.recognitionRejectedBySession = recognitionRejectedBySession
        result.trackDecisions = trackDecisions
        result.confirmedCards = formalRecordCount
        result.formalRecords = formalRecordCount
        result.sessionUniqueCards = cardCodes.count
        result.duplicateDecisions = duplicateDecisions
        result.captureToConfirmedMissingTiming = confirmedMissingTiming
        result.captureToResultMissingTiming = resultMissingTiming
        result.snapshotFailures = snapshotFailures
        result.snapshotAllocationFailures = allocationFailureCount
        result.successfulSnapshots = successfulSnapshots
        result.ringOverwrites = ringOverwrites
        result.eventOverflows = eventOverflows
        result.schedulerDispatchedFrames = schedulerDispatchedFrames
        result.residentMemoryPeakBytes = residentPeak
        result.residentMemoryPeakMB = Double(residentPeak) / (1024 * 1024)
        result.residentMemorySamples = residentSamples
        result.residentMemorySamplingFailures = residentSamplingFailures
        result.snapshotMaximumDimension = configuration.snapshotMaximumDimension
        result.snapshotByteLimit = configuration.snapshotByteLimit
        result.requiredPreFrames = configuration.preFrames
        result.requiredPostFrames = configuration.postFrames
        result.metrics = histograms.mapValues { $0.summary }
        result.limits = limits
        result.truncation = truncation
        result.metadataComplete = !truncation.hasTruncation
        result.uniqueCountersExact = truncation.identityOverflowOperations == 0
        result.frames = frames.values.sorted { $0.frameID < $1.frameID }
        result.recognitionAttempts = attempts.values.sorted { $0.frameID < $1.frameID }
        result.decisions = decisionValues.values.sorted {
            $0.publishedUptime == $1.publishedUptime ? $0.trackID < $1.trackID : $0.publishedUptime < $1.publishedUptime
        }
        let orderedDecisions = result.decisions
        var decisionsByTimestamp: [Double: [Int]] = [:]
        for (index, decision) in orderedDecisions.enumerated() {
            for timestamp in decision.captureTimestamps { decisionsByTimestamp[timestamp, default: []].append(index) }
        }
        result.events = windows.values.sorted { $0.id < $1.id }.map { window in
            let ordered = window.frames.sorted { $0.frameID < $1.frameID }
            let selected = ordered.compactMap { attempts[$0.frameID] }
            let completed = selected.filter { $0.status == "completed" && $0.resultCount > 0 }
            var linkedIndices = Set<Int>()
            for frame in ordered { linkedIndices.formUnion(decisionsByTimestamp[frame.timestamp] ?? []) }
            let linked = linkedIndices.sorted().map { orderedDecisions[$0] }
            let pre = ordered.filter { $0.timestamp < window.triggerTimestamp }.count
            let post = ordered.filter { $0.timestamp > window.triggerTimestamp }.count
            let outcome: String
            if !linked.isEmpty { outcome = "decision" }
            else if !completed.isEmpty { outcome = "detectionsWithoutDecision" }
            else if selected.isEmpty { outcome = "neverSelected" }
            else if selected.contains(where: { $0.status == "completed" }) { outcome = "completedEmpty" }
            else if selected.contains(where: { $0.status == "error" }) { outcome = "error" }
            else if selected.allSatisfy({ $0.status == "cancelled" }) { outcome = "cancelled" }
            else { outcome = "unfinished" }
            return Phase1DebugEvent(eventID: window.id,
                triggerFrameID: ordered.first(where: { $0.timestamp == window.triggerTimestamp })?.frameID,
                triggerTimestamp: window.triggerTimestamp, frameIDs: ordered.map(\.frameID),
                selectedFrameIDs: selected.map(\.frameID), timestamps: ordered.map(\.timestamp),
                informationScores: ordered.map(\.informationScore), frames: ordered,
                missingPreFrames: window.missingPreFrames, preFramesReceived: pre, postFramesReceived: post,
                missingPostFrames: max(0, configuration.postFrames - post),
                obtainedRequestedPreFrames: pre >= configuration.preFrames,
                obtainedRequestedPostFrames: post >= configuration.postFrames,
                complete: window.complete, recognitionAttempts: selected, recognitionResults: completed,
                finalDecision: linked, hasRecognitionResult: !completed.isEmpty,
                hasConcreteCardValue: !linked.isEmpty, hasUsableFrame: !ordered.isEmpty,
                wasSentToRecognition: !selected.isEmpty, outcome: outcome)
        }
        result.eventsWithUsableFrames = result.events.filter(\.hasUsableFrame).count
        result.eventsSentToRecognition = result.events.filter(\.wasSentToRecognition).count
        result.eventsWithNoRecognitionResult = result.events.filter { !$0.hasRecognitionResult }.count
        if resultMissingTiming > 0 { result.notes.append("captureToResult missing arrival timing: \(resultMissingTiming) nonempty completions excluded from latency.") }
        return result
    }
}
