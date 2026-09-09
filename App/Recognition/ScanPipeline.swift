import CoreVideo
import Foundation
import ImageIO

/// Owns all off-main-thread recognition state. At most one Core ML request runs
/// at once; pending captures have a separate bounded, priority-aware reservoir.
final class ScanPipeline {
    typealias SessionID = ScanSessionGate.SessionID

    /// Every delivery is tagged with the scan session that produced it. UI
    /// consumers can therefore reject a queued main-actor update after a
    /// pause, clear, or restart.
    var onRecords: ((SessionID, [CardRecord]) -> Void)?
    var onDetections: ((SessionID, [CardDetection]) -> Void)?
    var onError: ((SessionID, Error) -> Void)?

    private let backlog = CaptureBacklog<CapturedImage>()
    private let activityMeter = CaptureActivityMeter()
    private let sessionGate = ScanSessionGate()
    private let processingQueue = DispatchQueue(label: "com.cardscanmagic.recognition", qos: .userInitiated)
    private var engine: RecognitionEngine?
    private var coordinator = CardEventCoordinator()
    private var diagnosticsStart: TimeInterval = 0
    private var analyzedFrames = 0
    private var analysisSeconds: TimeInterval = 0

    /// Loads the Core ML model away from the main actor. Calls are serialized
    /// with inference and are idempotent, so multiple start requests cannot
    /// create multiple engines.
    func prepare() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            processingQueue.async { [weak self] in
                guard let self else {
                    continuation.resume(throwing: CancellationError())
                    return
                }

                do {
                    if self.engine == nil {
                        self.engine = try RecognitionEngine()
                    }
                    if let sessionID = self.sessionGate.activeSessionForSampling() {
                        self.scheduleDrain(for: sessionID)
                    }
                    continuation.resume(returning: ())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Starts a new recognition generation. The coordinator is reset on its
    /// owning queue before frames for this generation are accepted.
    @discardableResult
    func start() -> SessionID {
        let sessionID = sessionGate.start()
        backlog.reset(generation: sessionID)
        activityMeter.reset(generation: sessionID)
        resetCoordinator(for: sessionID, clearsDetections: false)
        return sessionID
    }

    /// Invalidates the current generation immediately. An in-flight Vision
    /// request may still finish, but its result can no longer be delivered.
    func stop() {
        sessionGate.stop()
        backlog.reset(generation: 0)
        activityMeter.reset(generation: 0)
    }

    /// Clears recorded cards without stopping the camera. It deliberately
    /// creates a new generation so an older inference cannot repopulate the
    /// just-cleared history or overlay.
    @discardableResult
    func resetRecordedState() -> SessionID? {
        guard let sessionID = sessionGate.resetRecordedState() else { return nil }
        backlog.reset(generation: sessionID)
        activityMeter.reset(generation: sessionID)
        resetCoordinator(for: sessionID, clearsDetections: true)
        return sessionID
    }

    func submit(
        pixelBuffer: CVPixelBuffer,
        timestamp: TimeInterval,
        orientation: CGImagePropertyOrientation
    ) {
        guard timestamp.isFinite,
              let sessionID = sessionGate.activeSessionForSampling() else { return }
        let activity = activityMeter.measure(pixelBuffer, generation: sessionID)
        guard let image = CapturedImage.copy(pixelBuffer, orientation: orientation) else { return }
        guard sessionGate.shouldDeliver(for: sessionID) else { return }
        backlog.insert(image, timestamp: timestamp, priority: activity, bytes: image.bytes, generation: sessionID)
        scheduleDrain(for: sessionID)
    }

    private func scheduleDrain(for sessionID: SessionID) {
        guard backlog.hasFrames(generation: sessionID), sessionGate.beginInference(for: sessionID) else { return }
        processingQueue.async { [weak self] in
            guard let self else { return }
            defer {
                self.sessionGate.finishInference()
                // A start before prepare must not reschedule an empty-engine
                // drain forever. Successful prepare wakes pending captures.
                if self.engine != nil, let current = self.sessionGate.activeSessionForSampling() {
                    self.scheduleDrain(for: current)
                }
            }

            guard self.sessionGate.shouldDeliver(for: sessionID), let engine = self.engine,
                  let frame = self.backlog.take(generation: sessionID) else {
                return
            }

            do {
                let analysisStart = ProcessInfo.processInfo.systemUptime
                let detections = try autoreleasepool {
                    try engine.recognize(pixelBuffer: frame.value.pixelBuffer, orientation: frame.value.orientation)
                }
                guard self.sessionGate.shouldDeliver(for: sessionID) else { return }
                self.recordDiagnostics(elapsed: ProcessInfo.processInfo.systemUptime - analysisStart)

                // Use the camera sample's monotonic timestamp rather than the
                // wall-clock time at which Vision happens to finish.  Model
                // latency can vary from frame to frame; using Date() here
                // makes a fast pass look stationary and breaks track timeout
                // and duplicate cooldown decisions.
                let captureDate = Date(timeIntervalSinceReferenceDate: frame.timestamp)
                let update = self.coordinator.processUpdate(detections, at: captureDate)
                guard self.sessionGate.shouldDeliver(for: sessionID) else { return }

                // Never draw raw model output. The UI only receives tracks
                // whose label and geometry have survived confirmation.
                self.onDetections?(sessionID, update.stableDetections)
                guard !update.records.isEmpty else { return }
                self.onRecords?(sessionID, update.records)
            } catch {
                guard self.sessionGate.failCurrentSession(for: sessionID) else { return }
                self.backlog.discard(generation: sessionID)
                self.onError?(sessionID, error)
            }
        }
    }

    private func resetCoordinator(for sessionID: SessionID, clearsDetections: Bool) {
        processingQueue.async { [weak self] in
            guard let self,
                  self.sessionGate.shouldResetCoordinator(for: sessionID) else {
                return
            }

            self.coordinator.reset()
            self.diagnosticsStart = ProcessInfo.processInfo.systemUptime
            self.analyzedFrames = 0
            self.analysisSeconds = 0
            guard self.sessionGate.markCoordinatorReady(for: sessionID) else { return }
            self.scheduleDrain(for: sessionID)

            if clearsDetections, self.sessionGate.shouldDeliver(for: sessionID) {
                self.onDetections?(sessionID, [])
            }
        }
    }

    private func recordDiagnostics(elapsed: TimeInterval) {
        analyzedFrames += 1
        analysisSeconds += elapsed
        let now = ProcessInfo.processInfo.systemUptime
        let window = now - diagnosticsStart
        guard window >= 2 else { return }
        let stats = backlog.statistics
        print("[ScanPipeline] analyzedFPS=\(Double(analyzedFrames) / window) "
            + "meanAnalysisMs=\(1000 * analysisSeconds / Double(analyzedFrames)) "
            + "pending=\(stats.pending) retainedBytes=\(stats.bytes) dropped=\(stats.dropped)")
        diagnosticsStart = now
        analyzedFrames = 0
        analysisSeconds = 0
    }
}
