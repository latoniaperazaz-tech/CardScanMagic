import CoreVideo
import Foundation

/// Samples a high-frame-rate camera stream without making Core ML compete for
/// every frame. The most recent sufficiently sharp frame wins a short window.
final class SharpFrameSampler {
    private struct CandidateBuffer {
        let pixelBuffer: CVPixelBuffer
        let timestamp: TimeInterval
    }

    private let inferenceInterval: TimeInterval
    private let qualityInterval: TimeInterval
    private let stateLock = NSLock()
    private var nextInferenceTime: TimeInterval = 0
    private var nextQualityTime: TimeInterval = 0
    private var candidateWindow = FrameCandidateWindow()
    private var candidateBuffer: CandidateBuffer?
    private var revision: UInt64 = 0

    init(
        maximumInferencesPerSecond: Double = 18,
        maximumQualitySamplesPerSecond: Double = 80
    ) {
        inferenceInterval = 1 / maximumInferencesPerSecond
        qualityInterval = 1 / maximumQualitySamplesPerSecond
    }

    /// Returns at most one recent frame at the requested inference rate. Frame
    /// sharpness is calculated outside the lock so a reset can immediately
    /// discard a measurement that is still being calculated.
    func select(
        pixelBuffer: CVPixelBuffer,
        timestamp: TimeInterval,
        allowsInference: Bool
    ) -> (CVPixelBuffer, TimeInterval)? {
        guard timestamp.isFinite else { return nil }

        stateLock.lock()
        let currentRevision = revision
        let shouldMeasureQuality = timestamp >= nextQualityTime
        if shouldMeasureQuality {
            nextQualityTime = timestamp + qualityInterval
        }
        stateLock.unlock()

        if shouldMeasureQuality {
            let sharpness = FrameQuality.sharpness(of: pixelBuffer)

            stateLock.lock()
            guard revision == currentRevision else {
                stateLock.unlock()
                return nil
            }

            if candidateWindow.insert(timestamp: timestamp, sharpness: sharpness) {
                candidateBuffer = CandidateBuffer(pixelBuffer: pixelBuffer, timestamp: timestamp)
            }
            let selected = takeCandidateIfReady(at: timestamp, allowsInference: allowsInference)
            stateLock.unlock()
            return selected
        }

        stateLock.lock()
        let selected = takeCandidateIfReady(at: timestamp, allowsInference: allowsInference)
        stateLock.unlock()
        return selected
    }

    func reset() {
        stateLock.lock()
        revision &+= 1
        nextInferenceTime = 0
        nextQualityTime = 0
        candidateWindow.reset()
        candidateBuffer = nil
        stateLock.unlock()
    }

    private func takeCandidateIfReady(
        at timestamp: TimeInterval,
        allowsInference: Bool
    ) -> (CVPixelBuffer, TimeInterval)? {
        guard allowsInference, timestamp >= nextInferenceTime,
              let metadata = candidateWindow.take(at: timestamp),
              let buffer = candidateBuffer,
              buffer.timestamp == metadata.timestamp else {
            return nil
        }

        candidateBuffer = nil
        nextInferenceTime = timestamp + inferenceInterval
        return (buffer.pixelBuffer, metadata.timestamp)
    }
}

private enum FrameQuality {
    static func sharpness(of pixelBuffer: CVPixelBuffer) -> Double {
        guard CVPixelBufferGetPlaneCount(pixelBuffer) > 0,
              CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly) == kCVReturnSuccess else {
            return 0
        }
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        guard let baseAddress = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0) else { return 0 }
        let pointer = baseAddress.assumingMemoryBound(to: UInt8.self)
        let width = CVPixelBufferGetWidthOfPlane(pixelBuffer, 0)
        let height = CVPixelBufferGetHeightOfPlane(pixelBuffer, 0)
        let bytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
        guard width > 16, height > 16 else { return 0 }

        // A coarse luma grid is enough to reject motion blur and avoids doing
        // 240 full-frame quality passes per second on the camera queue.
        let step = max(8, min(width, height) / 42)
        var total: Double = 0
        var samples = 0
        for y in stride(from: step, to: height - step, by: step) {
            for x in stride(from: step, to: width - step, by: step) {
                let center = Int(pointer[y * bytesPerRow + x])
                let horizontal = Int(pointer[y * bytesPerRow + x - step]) + Int(pointer[y * bytesPerRow + x + step])
                let vertical = Int(pointer[(y - step) * bytesPerRow + x]) + Int(pointer[(y + step) * bytesPerRow + x])
                total += Double(abs((4 * center) - horizontal - vertical))
                samples += 1
            }
        }
        return samples > 0 ? total / Double(samples) : 0
    }
}
