import CoreGraphics
import CoreVideo
import Foundation

/// Capture scheduling only. Motion is never evidence for a card or its value.
final class ROIMotionTrigger {
    struct Measurement {
        let score: Double
        /// True on every active-motion sample, not just the rising edge.
        let triggered: Bool
        let sample: [UInt8]
        let duration: TimeInterval
    }

    private let roi: CGRect
    private let threshold: Double
    private let releaseThreshold: Double
    private let lock = NSLock()
    private var generation: UInt64 = 0
    private var previous: [UInt8] = []
    private var active = false

    init(roi: CGRect = CGRect(x: 0, y: 0, width: 1, height: 1), threshold: Double = 0.08, releaseThreshold: Double = 0.035) {
        self.roi = roi
        self.threshold = threshold.isFinite ? min(1, max(0.001, threshold)) : 0.08
        self.releaseThreshold = releaseThreshold.isFinite ? min(self.threshold, max(0, releaseThreshold)) : min(self.threshold, 0.035)
    }

    func reset(generation: UInt64) {
        lock.lock()
        defer { lock.unlock() }
        self.generation = generation
        previous.removeAll(keepingCapacity: true)
        active = false
    }

    func measure(_ buffer: CVPixelBuffer, generation: UInt64) -> Measurement {
        let started = ProcessInfo.processInfo.systemUptime
        let sample = sampleLuma(buffer)
        lock.lock()
        defer { lock.unlock() }
        guard generation == self.generation, sample.count == 1024 else {
            return Measurement(score: 0, triggered: false, sample: [], duration: ProcessInfo.processInfo.systemUptime - started)
        }
        defer { previous = sample }
        guard previous.count == sample.count else {
            return Measurement(score: 0, triggered: false, sample: sample, duration: ProcessInfo.processInfo.systemUptime - started)
        }
        // Top 1/8 of changes catches a small fast foreground target without
        // sorting the grid or depending on the unchanging background area.
        var histogram = [Int](repeating: 0, count: 256)
        for index in sample.indices {
            histogram[abs(Int(sample[index]) - Int(previous[index]))] += 1
        }
        var remaining = 128
        var total = 0
        for delta in stride(from: 255, through: 0, by: -1) {
            let count = min(remaining, histogram[delta])
            total += count * delta
            remaining -= count
            if remaining == 0 { break }
        }
        let score = Double(total) / (128 * 255)
        if active {
            if score <= releaseThreshold { active = false }
        } else if score >= threshold {
            active = true
        }
        return Measurement(score: score, triggered: active, sample: sample, duration: ProcessInfo.processInfo.systemUptime - started)
    }

    private func sampleLuma(_ buffer: CVPixelBuffer) -> [UInt8] {
        guard roi.minX.isFinite, roi.minY.isFinite, roi.width.isFinite, roi.height.isFinite,
              roi.width > 0, roi.height > 0 else { return [] }
        let clipped = roi.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        guard !clipped.isNull, !clipped.isEmpty else { return [] }
        let pixelFormat = CVPixelBufferGetPixelFormatType(buffer)
        let bgra = pixelFormat == kCVPixelFormatType_32BGRA
        let planar = pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange || pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        guard bgra || planar,
              CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else { return [] }
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let rowBytes = bgra ? CVPixelBufferGetBytesPerRow(buffer) : CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        let base = bgra ? CVPixelBufferGetBaseAddress(buffer) : CVPixelBufferGetBaseAddressOfPlane(buffer, 0)
        guard width > 0, height > 0, let base else { return [] }
        let pixels = base.assumingMemoryBound(to: UInt8.self)
        var result: [UInt8] = []
        result.reserveCapacity(1024)
        for y in 0..<32 {
            let normalizedY = clipped.minY + (CGFloat(y) + 0.5) * clipped.height / 32
            let row = min(height - 1, max(0, Int(normalizedY * CGFloat(height))))
            for x in 0..<32 {
                let normalizedX = clipped.minX + (CGFloat(x) + 0.5) * clipped.width / 32
                let column = min(width - 1, max(0, Int(normalizedX * CGFloat(width))))
                let offset = row * rowBytes + column * (bgra ? 4 : 1)
                if bgra {
                    let luma = 29 * Int(pixels[offset]) + 150 * Int(pixels[offset + 1]) + 77 * Int(pixels[offset + 2])
                    result.append(UInt8(luma >> 8))
                } else {
                    result.append(pixels[offset])
                }
            }
        }
        return result
    }
}
