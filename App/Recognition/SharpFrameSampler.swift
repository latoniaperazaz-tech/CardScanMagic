import CoreVideo
import Foundation

/// Keeps the clearest luma frame in each short time window before Core ML runs.
final class SharpFrameSampler {
    private struct Candidate {
        let pixelBuffer: CVPixelBuffer
        let timestamp: TimeInterval
        let sharpness: Double
    }

    private let interval: TimeInterval
    private let stateLock = NSLock()
    private var nextInferenceTime: TimeInterval = 0
    private var bestCandidate: Candidate?

    init(maximumInferencesPerSecond: Double = 14) {
        interval = 1 / maximumInferencesPerSecond
    }

    func select(pixelBuffer: CVPixelBuffer, timestamp: TimeInterval) -> (CVPixelBuffer, TimeInterval)? {
        stateLock.lock()
        defer { stateLock.unlock() }

        let sharpness = FrameQuality.sharpness(of: pixelBuffer)
        if timestamp < nextInferenceTime {
            if bestCandidate == nil || sharpness > bestCandidate!.sharpness {
                bestCandidate = Candidate(pixelBuffer: pixelBuffer, timestamp: timestamp, sharpness: sharpness)
            }
            return nil
        }

        let selected = bestCandidate ?? Candidate(
            pixelBuffer: pixelBuffer,
            timestamp: timestamp,
            sharpness: sharpness
        )
        bestCandidate = nil
        nextInferenceTime = timestamp + interval
        return (selected.pixelBuffer, selected.timestamp)
    }

    func reset() {
        stateLock.lock()
        nextInferenceTime = 0
        bestCandidate = nil
        stateLock.unlock()
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

        let step = max(8, min(width, height) / 64)
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
