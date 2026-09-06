import CoreVideo
import Foundation
import ImageIO

/// Owns all off-main-thread recognition state. At most one Core ML request runs
/// at once so camera frames cannot build an inference backlog.
final class ScanPipeline {
    typealias SessionID = ScanSessionGate.SessionID

    /// Every delivery is tagged with the scan session that produced it. UI
    /// consumers can therefore reject a queued main-actor update after a
    /// pause, clear, or restart.
    var onRecords: ((SessionID, [CardRecord]) -> Void)?
    var onDetections: ((SessionID, [CardDetection]) -> Void)?
    var onError: ((SessionID, Error) -> Void)?

    private let frameSampler = SharpFrameSampler()
    private let sessionGate = ScanSessionGate()
    private let processingQueue = DispatchQueue(label: "com.cardscanmagic.recognition", qos: .userInitiated)
    private var engine: RecognitionEngine?
    private var coordinator = CardEventCoordinator()

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
        frameSampler.reset()
        resetCoordinator(for: sessionID, clearsDetections: false)
        return sessionID
    }

    /// Invalidates the current generation immediately. An in-flight Vision
    /// request may still finish, but its result can no longer be delivered.
    func stop() {
        sessionGate.stop()
        frameSampler.reset()
    }

    /// Clears recorded cards without stopping the camera. It deliberately
    /// creates a new generation so an older inference cannot repopulate the
    /// just-cleared history or overlay.
    @discardableResult
    func resetRecordedState() -> SessionID? {
        guard let sessionID = sessionGate.resetRecordedState() else { return nil }
        frameSampler.reset()
        resetCoordinator(for: sessionID, clearsDetections: true)
        return sessionID
    }

    func submit(
        pixelBuffer: CVPixelBuffer,
        timestamp: TimeInterval,
        orientation: CGImagePropertyOrientation
    ) {
        guard let sessionID = sessionGate.activeSessionForSampling() else { return }
        let inferenceAvailable = sessionGate.canStartInference(for: sessionID)
        guard let selectedFrame = frameSampler.select(
            pixelBuffer: pixelBuffer,
            timestamp: timestamp,
            orientation: orientation,
            allowsInference: inferenceAvailable
        ), sessionGate.beginInference(for: sessionID) else {
            return
        }

        processingQueue.async { [weak self] in
            guard let self else { return }
            defer { self.sessionGate.finishInference() }

            guard self.sessionGate.shouldDeliver(for: sessionID), let engine = self.engine else {
                return
            }

            do {
                // RecognitionEngine normally performs one full-frame pass;
                // its bounded near-card ROI fallback is activated when that
                // pass has no result strong enough to survive the coordinator.
                // Keeping this call inside the single in-flight gate prevents
                // ROI passes from building a backlog behind later frames.
                let detections = try engine.recognize(
                    pixelBuffer: selectedFrame.0,
                    orientation: selectedFrame.2
                )
                guard self.sessionGate.shouldDeliver(for: sessionID) else { return }

                // Use the camera sample's monotonic timestamp rather than the
                // wall-clock time at which Vision happens to finish.  Model
                // latency can vary from frame to frame; using Date() here
                // makes a fast pass look stationary and breaks track timeout
                // and duplicate cooldown decisions.
                let captureDate = Date(timeIntervalSinceReferenceDate: selectedFrame.1)
                let update = self.coordinator.processUpdate(detections, at: captureDate)
                guard self.sessionGate.shouldDeliver(for: sessionID) else { return }

                // Never draw raw model output. The UI only receives tracks
                // whose label and geometry have survived confirmation.
                self.onDetections?(sessionID, update.stableDetections)
                guard !update.records.isEmpty else { return }
                self.onRecords?(sessionID, update.records)
            } catch {
                guard self.sessionGate.failCurrentSession(for: sessionID) else { return }
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
            guard self.sessionGate.markCoordinatorReady(for: sessionID) else { return }

            if clearsDetections, self.sessionGate.shouldDeliver(for: sessionID) {
                self.onDetections?(sessionID, [])
            }
        }
    }
}
