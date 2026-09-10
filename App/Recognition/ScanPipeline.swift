import CoreVideo
import Foundation
import ImageIO

final class ScanPipeline {
    typealias SessionID = ScanSessionGate.SessionID
    typealias Recognizer = (CVPixelBuffer, CGImagePropertyOrientation) throws -> [CardDetection]
    var onRecords: ((SessionID, [CardRecord]) -> Void)?
    var onDetections: ((SessionID, [CardDetection]) -> Void)?
    var onError: ((SessionID, Error) -> Void)?
    var onDecisions: ((SessionID, [CardPassDecision]) -> Void)?
    /// Metadata only: observers cannot accidentally retain an event's pixels.
    var onCaptureEvent: ((SessionID, UInt64, Int, Bool) -> Void)?
    private let scheduler: EventFrameScheduler<CapturedImage>
    private let snapshotPool: CaptureSnapshotPool
    private let motion: ROIMotionTrigger
    private let sessionGate = ScanSessionGate()
    private let processingQueue = DispatchQueue(label: "com.cardscanmagic.recognition", qos: .userInitiated)
    private let debugQueue = DispatchQueue(label: "com.cardscanmagic.capture.debug", qos: .utility)
    private let timeline = CardResultTimeline()
    private let diagnostics = CaptureDiagnostics()
    private let injectedRecognizer: Recognizer?
    private var engine: RecognitionEngine?

    init(configuration: CaptureConfiguration = CaptureConfiguration(), recognizer: Recognizer? = nil) {
        scheduler = EventFrameScheduler(ringCapacity: configuration.historyCapacity,
            preFrameCount: configuration.preFrames, postFrameCount: configuration.postFrames,
            maximumEventFrames: configuration.maximumEventFrames,
            maximumPendingEventFrames: configuration.pendingEventCapacity)
        snapshotPool = CaptureSnapshotPool(maximumDimension: configuration.snapshotMaximumDimension,
            byteLimit: configuration.snapshotByteLimit,
            minimumBufferCount: configuration.historyCapacity + configuration.pendingEventCapacity
                + max(0, min(configuration.maximumEventFrames,
                             configuration.preFrames + 1 + configuration.postFrames) - configuration.historyCapacity) + 2)
        motion = ROIMotionTrigger(roi: configuration.motionROI, threshold: configuration.motionThreshold,
                                 releaseThreshold: configuration.motionReleaseThreshold)
        injectedRecognizer = recognizer
    }
    func prepare() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            processingQueue.async { [weak self] in
                guard let self else { continuation.resume(throwing: CancellationError()); return }
                do {
                    if self.engine == nil && self.injectedRecognizer == nil { self.engine = try RecognitionEngine() }
                    if let sessionID = self.sessionGate.activeSessionForSampling() { self.scheduleDrain(for: sessionID) }
                    continuation.resume(returning: ())
                } catch { continuation.resume(throwing: error) }
            }
        }
    }
    @discardableResult
    func start() -> SessionID {
        let sessionID = sessionGate.start()
        resetCapture(generation: sessionID)
        resetCoordinator(for: sessionID, clearsDetections: false)
        return sessionID
    }
    func stop() { sessionGate.stop(); resetCapture(generation: 0) }
    @discardableResult
    func resetRecordedState() -> SessionID? {
        guard let sessionID = sessionGate.resetRecordedState() else { return nil }
        resetCapture(generation: sessionID)
        resetCoordinator(for: sessionID, clearsDetections: true)
        return sessionID
    }
    private func resetCapture(generation: UInt64) {
        scheduler.reset(generation: generation)
        motion.reset(generation: generation)
        snapshotPool.reset()
    }
    func submit(pixelBuffer: CVPixelBuffer, timestamp: TimeInterval, orientation: CGImagePropertyOrientation) {
        let arrival = ProcessInfo.processInfo.systemUptime
        guard timestamp.isFinite, timestamp >= 0,
              let sessionID = sessionGate.activeSessionForSampling() else { return }
        let measurement = motion.measure(pixelBuffer, generation: sessionID)
        guard let image = snapshotPool.copy(pixelBuffer, orientation: orientation) else {
            diagnostics.snapshotFailed(); return
        }
        guard sessionGate.shouldDeliver(for: sessionID) else { return }
        let information = FrameInformationScorer.score(luma: measurement.sample, motionScore: measurement.score)
        let frame = CaptureFrame(id: timestamp.bitPattern, generation: sessionID, timestamp: timestamp,
            value: image, motionScore: measurement.score, informationScore: information, arrivalUptime: arrival)
        if let event = scheduler.ingest(frame, triggered: measurement.triggered) {
            let eventID = event.id, count = event.frames.count, complete = event.isComplete
            let missing = event.missingPreFrames, frameIDs = event.frames.map(\.id)
            diagnostics.eventCreatedOrUpdated(latency: ProcessInfo.processInfo.systemUptime - arrival)
            debugQueue.async { [weak self] in
                guard let self, self.sessionGate.shouldDeliver(for: sessionID) else { return }
                self.onCaptureEvent?(sessionID, eventID, count, complete)
                if count <= 7 || complete {
                    print("[CaptureEvent] session=\(sessionID) captureWindow=\(eventID) frames=\(frameIDs) complete=\(complete) missingPre=\(missing)")
                }
            }
        }
        // Only an immediately selected frame may retain its native camera sample.
        // All history/event/pending storage owns compact pool buffers instead.
        scheduleDrain(for: sessionID, nativeFrameID: frame.id, nativeBuffer: pixelBuffer, orientation: orientation)
        diagnostics.capture(timestamp: timestamp, duration: ProcessInfo.processInfo.systemUptime - arrival,
                            motionDuration: measurement.duration)
    }
    private func scheduleDrain(for sessionID: SessionID, nativeFrameID: UInt64? = nil,
                               nativeBuffer: CVPixelBuffer? = nil,
                               orientation: CGImagePropertyOrientation = .up) {
        guard scheduler.hasFrames, sessionGate.beginInference(for: sessionID) else { return }
        guard let frame = scheduler.take(generation: sessionID) else { sessionGate.finishInference(); return }
        let input = frame.id == nativeFrameID ? (nativeBuffer ?? frame.value.pixelBuffer) : frame.value.pixelBuffer
        let inputOrientation = frame.id == nativeFrameID ? orientation : frame.value.orientation
        processingQueue.async { [weak self] in
            guard let self else { return }
            defer {
                self.sessionGate.finishInference()
                if self.engine != nil || self.injectedRecognizer != nil,
                   let current = self.sessionGate.activeSessionForSampling() { self.scheduleDrain(for: current) }
            }
            guard self.sessionGate.shouldDeliver(for: sessionID) else { return }
            do {
                let started = ProcessInfo.processInfo.systemUptime
                let detections: [CardDetection] = try autoreleasepool {
                    if let recognize = self.injectedRecognizer { return try recognize(input, inputOrientation) }
                    guard let engine = self.engine else { throw RecognitionError.modelMissing }
                    return try engine.recognize(pixelBuffer: input, orientation: inputOrientation)
                }
                guard self.sessionGate.shouldDeliver(for: sessionID) else { return }
                let update = self.timeline.insert(frameID: frame.id, timestamp: frame.timestamp, detections: detections)
                guard self.sessionGate.shouldDeliver(for: sessionID) else { return }
                self.diagnostics.analysis(duration: ProcessInfo.processInfo.systemUptime - started,
                    resultLatency: ProcessInfo.processInfo.systemUptime - frame.arrivalUptime,
                    hasResult: !detections.isEmpty, confirmed: !update.records.isEmpty)
                self.onDetections?(sessionID, update.stableDetections)
                if !update.decisions.isEmpty {
                    self.onDecisions?(sessionID, update.decisions)
                    for decision in update.decisions {
                        print("[CardEventDecision] session=\(sessionID) event=\(decision.eventID) card=\(decision.record.card.code) duplicateCard=\(decision.duplicateCard) captures=\(decision.captureTimestamps.sorted())")
                    }
                }
                if !update.records.isEmpty { self.onRecords?(sessionID, update.records) }
                if let summary = self.diagnostics.summaryIfDue() {
                    let stats = self.scheduler.statistics, pixels = self.snapshotPool.statistics
                    print("[Phase1] \(summary) history=\(stats.retainedFrames) pendingEvent=\(stats.pendingEventFrames) eventDropped=\(stats.droppedEventFrames) snapshotFailures=\(pixels.failures) pixelBudgetBound=\(pixels.maximumPixelBytes) oldResults=\(self.timeline.rejectedOldResults)")
                }
            } catch {
                guard self.sessionGate.failCurrentSession(for: sessionID) else { return }
                self.scheduler.reset(generation: 0)
                self.onError?(sessionID, error)
            }
        }
    }
    private func resetCoordinator(for sessionID: SessionID, clearsDetections: Bool) {
        processingQueue.async { [weak self] in
            guard let self, self.sessionGate.shouldResetCoordinator(for: sessionID) else { return }
            self.timeline.reset(); self.diagnostics.reset()
            guard self.sessionGate.markCoordinatorReady(for: sessionID) else { return }
            self.scheduleDrain(for: sessionID)
            if clearsDetections { self.onDetections?(sessionID, []) }
        }
    }
    func cameraDroppedFrame() { diagnostics.cameraDropped() }
    func cameraCallbackCompleted(duration: TimeInterval) { diagnostics.cameraCallback(duration: duration) }
    // Test barrier only. The camera never waits on the processing queue.
    func whenReady(_ completion: @escaping () -> Void) { processingQueue.async(execute: completion) }
    var captureStatistics: EventFrameScheduler<CapturedImage>.Statistics { scheduler.statistics }
}
