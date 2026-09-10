import CoreVideo
import Foundation
import ImageIO

final class ScanPipeline {
    typealias SessionID = ScanSessionGate.SessionID
    typealias Recognizer = (CVPixelBuffer, CGImagePropertyOrientation) throws -> [CardDetection]
    var onRecords: ((SessionID, [CardRecord]) -> Void)?
    var onRecordsWithDiagnostics: ((SessionID, [CardRecord], DiagnosticRecordReceipt) -> Void)?
    var onDetections: ((SessionID, [CardDetection]) -> Void)?
    var onError: ((SessionID, Error) -> Void)?
    var onDecisions: ((SessionID, [CardPassDecision]) -> Void)?
    /// Metadata only: observers cannot accidentally retain an event's pixels.
    var onCaptureEvent: ((SessionID, UInt64, Int, Bool) -> Void)?
    var onDebugSummary: ((Phase1DebugSummary) -> Void)?
    private let scheduler: EventFrameScheduler<CapturedImage>
    private let snapshotPool: CaptureSnapshotPool
    private let motion: ROIMotionTrigger
    private let sessionGate = ScanSessionGate()
    private let processingQueue = DispatchQueue(label: "com.cardscanmagic.recognition", qos: .userInitiated)
    private let debugQueue = DispatchQueue(label: "com.cardscanmagic.capture.debug", qos: .utility)
    private let timeline = CardResultTimeline()
    private let diagnosticsLock = NSLock()
    private var diagnosticRuns: [SessionID: CaptureDiagnostics] = [:]
    private var activeDiagnostics: CaptureDiagnostics?
    private var cameraOwners: [UInt64: SessionID] = [:]
    private let configuration: CaptureConfiguration
    private let injectedRecognizer: Recognizer?
    private var engine: RecognitionEngine?

    init(configuration: CaptureConfiguration = CaptureConfiguration(), recognizer: Recognizer? = nil) {
        self.configuration = configuration
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
        beginDiagnostics(sessionID: sessionID)
        resetCoordinator(for: sessionID, clearsDetections: false)
        return sessionID
    }
    func stop() {
        sessionGate.stop()
        resetCapture(generation: 0)
        finishDiagnostics(reason: "stopped")
    }
    @discardableResult
    func resetRecordedState() -> SessionID? {
        guard let sessionID = sessionGate.resetRecordedState() else { return nil }
        resetCapture(generation: sessionID)
        beginDiagnostics(sessionID: sessionID)
        resetCoordinator(for: sessionID, clearsDetections: true)
        return sessionID
    }
    private func resetCapture(generation: UInt64) {
        let previous = scheduler.reset(generation: generation)
        diagnosticRun(for: previous.generation)?.scheduler(previous)
        motion.reset(generation: generation)
        snapshotPool.reset()
    }
    func submit(pixelBuffer: CVPixelBuffer, timestamp: TimeInterval, orientation: CGImagePropertyOrientation,
                cameraCounted: Bool = false) {
        let arrival = ProcessInfo.processInfo.systemUptime
        guard timestamp.isFinite, timestamp >= 0,
              let sessionID = sessionGate.activeSessionForSampling() else { return }
        let candidate = diagnosticRun(for: sessionID)
        let diagnostics = candidate?.beginActivity() == true ? candidate : nil
        defer { diagnostics?.endActivity() }
        if !cameraCounted { diagnostics?.cameraFrame(timestamp: timestamp) }
        if cameraCounted {
            diagnosticsLock.lock()
            let cameraOwner = cameraOwners[timestamp.bitPattern]
            diagnosticsLock.unlock()
            if let cameraOwner, cameraOwner != sessionID {
                diagnostics?.cameraTransition(frameID: timestamp.bitPattern, sourceSessionID: cameraOwner)
            }
        }
        let measurement = motion.measure(pixelBuffer, generation: sessionID)
        diagnostics?.motion(duration: measurement.duration, triggered: measurement.triggered)
        guard let image = snapshotPool.copy(pixelBuffer, orientation: orientation,
            diagnostics: { diagnostics?.allocationFailures($0) }) else {
            diagnostics?.snapshotFailed(); return
        }
        guard sessionGate.shouldDeliver(for: sessionID) else { return }
        let information = FrameInformationScorer.score(luma: measurement.sample, motionScore: measurement.score)
        let frame = CaptureFrame(id: timestamp.bitPattern, generation: sessionID, timestamp: timestamp,
            value: image, motionScore: measurement.score, informationScore: information, arrivalUptime: arrival)
        diagnostics?.capture(frame, width: CVPixelBufferGetWidth(image.pixelBuffer),
                             height: CVPixelBufferGetHeight(image.pixelBuffer))
        if let event = scheduler.ingest(frame, triggered: measurement.triggered) {
            let eventID = event.id, count = event.frames.count, complete = event.isComplete
            let missing = event.missingPreFrames, frameIDs = event.frames.map(\.id)
            diagnostics?.event(event, latency: ProcessInfo.processInfo.systemUptime - arrival)
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
        diagnostics?.scheduler(scheduler.statistics)
    }
    private func scheduleDrain(for sessionID: SessionID, nativeFrameID: UInt64? = nil,
                               nativeBuffer: CVPixelBuffer? = nil,
                               orientation: CGImagePropertyOrientation = .up) {
        guard scheduler.hasFrames, sessionGate.beginInference(for: sessionID) else { return }
        guard let frame = scheduler.take(generation: sessionID) else { sessionGate.finishInference(); return }
        let input = frame.id == nativeFrameID ? (nativeBuffer ?? frame.value.pixelBuffer) : frame.value.pixelBuffer
        let inputOrientation = frame.id == nativeFrameID ? orientation : frame.value.orientation
        let candidate = diagnosticRun(for: sessionID)
        let diagnostics = candidate?.beginActivity() == true ? candidate : nil
        diagnostics?.selected(frame, source: frame.id == nativeFrameID && nativeBuffer != nil ? "native" : "snapshot",
                              width: CVPixelBufferGetWidth(input), height: CVPixelBufferGetHeight(input))
        processingQueue.async { [weak self] in
            defer { diagnostics?.endActivity() }
            guard let self else { return }
            defer {
                self.sessionGate.finishInference()
                if self.engine != nil || self.injectedRecognizer != nil,
                   let current = self.sessionGate.activeSessionForSampling() { self.scheduleDrain(for: current) }
            }
            guard self.sessionGate.shouldDeliver(for: sessionID) else {
                diagnostics?.recognitionCancelled(frameID: frame.id)
                return
            }
            do {
                let started = ProcessInfo.processInfo.systemUptime
                diagnostics?.recognitionStarted(frameID: frame.id, at: started)
                let detections: [CardDetection] = try autoreleasepool {
                    if let recognize = self.injectedRecognizer { return try recognize(input, inputOrientation) }
                    guard let engine = self.engine else { throw RecognitionError.modelMissing }
                    return try engine.recognize(pixelBuffer: input, orientation: inputOrientation)
                }
                diagnostics?.recognitionCompleted(frameID: frame.id, at: ProcessInfo.processInfo.systemUptime,
                    detections: detections, acceptedBySession: self.sessionGate.shouldDeliver(for: sessionID))
                guard self.sessionGate.shouldDeliver(for: sessionID) else { return }
                let update = self.timeline.insert(frameID: frame.id, timestamp: frame.timestamp, detections: detections)
                guard self.sessionGate.shouldDeliver(for: sessionID) else { return }
                diagnostics?.decisions(update.decisions, at: ProcessInfo.processInfo.systemUptime)
                self.onDetections?(sessionID, update.stableDetections)
                if !update.decisions.isEmpty {
                    self.onDecisions?(sessionID, update.decisions)
                    for decision in update.decisions {
                        print("[CardEventDecision] session=\(sessionID) event=\(decision.eventID) card=\(decision.record.card.code) duplicateCard=\(decision.duplicateCard) captures=\(decision.captureTimestamps.sorted())")
                    }
                }
                if !update.records.isEmpty {
                    if let deliver = self.onRecordsWithDiagnostics {
                        deliver(sessionID, update.records, DiagnosticRecordReceipt(diagnostics))
                    } else {
                        self.onRecords?(sessionID, update.records)
                    }
                }
            } catch {
                diagnostics?.recognitionFailed(frameID: frame.id, at: ProcessInfo.processInfo.systemUptime,
                                               error: error.localizedDescription)
                guard self.sessionGate.failCurrentSession(for: sessionID) else { return }
                let previous = self.scheduler.reset(generation: 0)
                diagnostics?.scheduler(previous)
                self.finishDiagnostics(reason: "recognitionError", sessionID: sessionID)
                self.onError?(sessionID, error)
            }
        }
    }
    private func resetCoordinator(for sessionID: SessionID, clearsDetections: Bool) {
        processingQueue.async { [weak self] in
            guard let self, self.sessionGate.shouldResetCoordinator(for: sessionID) else { return }
            self.timeline.reset()
            guard self.sessionGate.markCoordinatorReady(for: sessionID) else { return }
            self.scheduleDrain(for: sessionID)
            if clearsDetections { self.onDetections?(sessionID, []) }
        }
    }
    /// The returned token keeps this callback attached to its original run,
    /// even if stop/111/start happens before the callback returns.
    func cameraCallbackBegan(timestamp: TimeInterval) -> ((TimeInterval) -> Void)? {
        diagnosticsLock.lock()
        let run = activeDiagnostics
        let accepted = run?.beginActivity() == true
        if accepted, let run { cameraOwners[timestamp.bitPattern] = run.sessionID }
        diagnosticsLock.unlock()
        guard accepted, let run else { return nil }
        run.cameraFrame(timestamp: timestamp)
        return { [weak self] duration in
            run.cameraCallback(duration: duration)
            if let self {
                self.diagnosticsLock.lock()
                if self.cameraOwners[timestamp.bitPattern] == run.sessionID {
                    self.cameraOwners.removeValue(forKey: timestamp.bitPattern)
                }
                self.diagnosticsLock.unlock()
            }
            run.endActivity()
        }
    }
    func cameraDroppedFrame() {
        diagnosticsLock.lock()
        activeDiagnostics?.cameraDropped()
        diagnosticsLock.unlock()
    }
    func recordFormalRecords(_ records: [CardRecord], sessionID: SessionID) {
        diagnosticRun(for: sessionID)?.formalRecords(records)
    }
    private func diagnosticRun(for sessionID: SessionID) -> CaptureDiagnostics? {
        diagnosticsLock.lock(); defer { diagnosticsLock.unlock() }
        return diagnosticRuns[sessionID]
    }
    private func beginDiagnostics(sessionID: SessionID) {
        finishDiagnostics(reason: "newSession")
        let run = CaptureDiagnostics(sessionID: sessionID, configuration: configuration)
        diagnosticsLock.lock()
        diagnosticRuns[sessionID] = run
        activeDiagnostics = run
        diagnosticsLock.unlock()
    }
    private func finishDiagnostics(reason: String, sessionID: SessionID? = nil) {
        diagnosticsLock.lock()
        let run: CaptureDiagnostics?
        if let sessionID { run = diagnosticRuns[sessionID] }
        else { run = activeDiagnostics }
        if activeDiagnostics === run { activeDiagnostics = nil }
        diagnosticsLock.unlock()
        run?.close(reason: reason) { [weak self] summary in
            // Encoding and disk I/O happen after camera/recognition activities
            // finish, on a utility queue, without holding their pixel buffers.
            Phase1DebugExporter.enqueue(summary)
            guard let self else { return }
            self.onDebugSummary?(summary)
            self.diagnosticsLock.lock()
            self.diagnosticRuns.removeValue(forKey: summary.sessionID)
            self.diagnosticsLock.unlock()
        }
    }
    // Test barrier only. The camera never waits on the processing queue.
    func whenReady(_ completion: @escaping () -> Void) { processingQueue.async(execute: completion) }
    var captureStatistics: EventFrameScheduler<CapturedImage>.Statistics { scheduler.statistics }
}
