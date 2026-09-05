import CoreVideo
import Foundation

/// Owns all off-main-thread recognition state. At most one Core ML request runs
/// at once so camera frames cannot build an inference backlog.
final class ScanPipeline {
    var onRecords: (([CardRecord]) -> Void)?
    var onError: ((Error) -> Void)?

    private let frameSampler = SharpFrameSampler()
    private let processingQueue = DispatchQueue(label: "com.cardscanmagic.recognition", qos: .userInitiated)
    private let stateLock = NSLock()
    private var engine: RecognitionEngine?
    private var coordinator = CardEventCoordinator()
    private var isRunning = false
    private var workInFlight = false

    func prepare() throws {
        try processingQueue.sync {
            if engine == nil {
                engine = try RecognitionEngine()
            }
        }
    }

    func start() {
        processingQueue.sync { coordinator.reset() }
        frameSampler.reset()
        stateLock.lock()
        isRunning = true
        stateLock.unlock()
    }

    func stop() {
        stateLock.lock()
        isRunning = false
        stateLock.unlock()
        frameSampler.reset()
    }

    func resetRecordedState() {
        processingQueue.sync { coordinator.reset() }
        frameSampler.reset()
    }

    func submit(pixelBuffer: CVPixelBuffer, timestamp: TimeInterval) {
        guard let selectedFrame = frameSampler.select(pixelBuffer: pixelBuffer, timestamp: timestamp) else {
            return
        }

        stateLock.lock()
        guard isRunning, !workInFlight else {
            stateLock.unlock()
            return
        }
        workInFlight = true
        stateLock.unlock()

        processingQueue.async { [weak self] in
            guard let self else { return }
            defer {
                self.stateLock.lock()
                self.workInFlight = false
                self.stateLock.unlock()
            }

            do {
                guard self.currentlyRunning(), let engine = self.engine else { return }
                let detections = try engine.recognize(pixelBuffer: selectedFrame.0)
                guard self.currentlyRunning() else { return }
                let records = self.coordinator.process(detections, at: Date())
                guard !records.isEmpty else { return }
                self.onRecords?(records)
            } catch {
                self.stateLock.lock()
                self.isRunning = false
                self.stateLock.unlock()
                self.onError?(error)
            }
        }
    }

    private func currentlyRunning() -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return isRunning
    }
}
