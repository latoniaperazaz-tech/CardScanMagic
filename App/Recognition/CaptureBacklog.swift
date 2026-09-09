import CoreVideo
import Foundation
import ImageIO

/// A bounded reservoir: keep transient motion while dropping low-information
/// background frames first. Dequeue is always in capture-time order.
final class CaptureBacklog<Value> {
    struct Entry {
        let value: Value
        let timestamp: TimeInterval
        let priority: Double
        let bytes: Int
    }

    private let lock = NSLock()
    private let capacity: Int
    private let byteLimit: Int
    private let maximumAge: TimeInterval
    private var generation: UInt64 = 0
    private var entries: [Entry] = []
    private var byteCount = 0
    private var latestTimestamp: TimeInterval?
    private var dropped = 0

    init(capacity: Int = 24, byteLimit: Int = 96 * 1_024 * 1_024, maximumAge: TimeInterval = 0.85) {
        self.capacity = max(1, capacity)
        self.byteLimit = max(1, byteLimit)
        self.maximumAge = maximumAge.isFinite ? max(0, maximumAge) : 0.85
    }

    func reset(generation: UInt64) {
        lock.lock()
        defer { lock.unlock() }
        self.generation = generation
        entries.removeAll(keepingCapacity: true)
        byteCount = 0
        latestTimestamp = nil
        dropped = 0
    }

    func discard(generation: UInt64) {
        lock.lock()
        defer { lock.unlock() }
        guard generation == self.generation else { return }
        dropped += entries.count
        entries.removeAll(keepingCapacity: true)
        byteCount = 0
    }

    @discardableResult
    func insert(_ value: Value, timestamp: TimeInterval, priority: Double, bytes: Int, generation: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard generation == self.generation, timestamp.isFinite, priority.isFinite,
              bytes > 0, bytes <= byteLimit,
              latestTimestamp.map({ timestamp > $0 }) ?? true else { return false }
        latestTimestamp = timestamp
        while let first = entries.first, timestamp - first.timestamp > maximumAge {
            remove(at: 0)
        }
        // Evict before adding bytes, so even a caller-supplied Int.max limit
        // cannot overflow the running allocation count.
        while entries.count >= capacity || byteCount > byteLimit - bytes {
            let index = entries.indices.min {
                entries[$0].priority == entries[$1].priority
                    ? entries[$0].timestamp < entries[$1].timestamp
                    : entries[$0].priority < entries[$1].priority
            }!
            guard entries[index].priority <= priority else {
                dropped += 1
                return false
            }
            remove(at: index)
        }
        entries.append(Entry(value: value, timestamp: timestamp, priority: priority, bytes: bytes))
        byteCount += bytes
        return true
    }

    func take(generation: UInt64) -> Entry? {
        lock.lock()
        defer { lock.unlock() }
        guard generation == self.generation, !entries.isEmpty else { return nil }
        let entry = entries.removeFirst()
        byteCount -= entry.bytes
        return entry
    }

    func hasFrames(generation: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return generation == self.generation && !entries.isEmpty
    }

    var statistics: (pending: Int, bytes: Int, dropped: Int) {
        lock.lock()
        defer { lock.unlock() }
        return (entries.count, byteCount, dropped)
    }

    private func remove(at index: Int) {
        byteCount -= entries.remove(at: index).bytes
        dropped += 1
    }
}

struct CapturedImage {
    let pixelBuffer: CVPixelBuffer
    let orientation: CGImagePropertyOrientation
    let bytes: Int

    /// Own a copy so retaining a burst cannot exhaust AVFoundation's buffers.
    static func copy(_ source: CVPixelBuffer, orientation: CGImagePropertyOrientation) -> CapturedImage? {
        let width = CVPixelBufferGetWidth(source)
        let height = CVPixelBufferGetHeight(source)
        guard width > 0, height > 0 else { return nil }
        var copied: CVPixelBuffer?
        let result = CVPixelBufferCreate(
            kCFAllocatorDefault, width, height, CVPixelBufferGetPixelFormatType(source),
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &copied
        )
        guard result == kCVReturnSuccess, let target = copied,
              CVPixelBufferLockBaseAddress(source, .readOnly) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(source, .readOnly) }
        guard CVPixelBufferLockBaseAddress(target, []) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(target, []) }

        let planes = CVPixelBufferGetPlaneCount(source)
        var bytes = 0
        if planes == 0 {
            guard let input = CVPixelBufferGetBaseAddress(source),
                  let output = CVPixelBufferGetBaseAddress(target) else { return nil }
            let inputStride = CVPixelBufferGetBytesPerRow(source)
            let outputStride = CVPixelBufferGetBytesPerRow(target)
            for row in 0..<height {
                memcpy(output.advanced(by: row * outputStride), input.advanced(by: row * inputStride), min(inputStride, outputStride))
            }
            bytes = outputStride * height
        } else {
            guard CVPixelBufferGetPlaneCount(target) == planes else { return nil }
            for plane in 0..<planes {
                guard let input = CVPixelBufferGetBaseAddressOfPlane(source, plane),
                      let output = CVPixelBufferGetBaseAddressOfPlane(target, plane),
                      CVPixelBufferGetHeightOfPlane(target, plane) == CVPixelBufferGetHeightOfPlane(source, plane) else {
                    return nil
                }
                let rows = CVPixelBufferGetHeightOfPlane(source, plane)
                let inputStride = CVPixelBufferGetBytesPerRowOfPlane(source, plane)
                let outputStride = CVPixelBufferGetBytesPerRowOfPlane(target, plane)
                for row in 0..<rows {
                    memcpy(output.advanced(by: row * outputStride), input.advanced(by: row * inputStride), min(inputStride, outputStride))
                }
                bytes += outputStride * rows
            }
        }
        CVBufferPropagateAttachments(source, target)
        return CapturedImage(
            pixelBuffer: target,
            orientation: orientation,
            bytes: max(bytes, CVPixelBufferGetDataSize(target))
        )
    }
}

/// Cheap motion evidence, not whole-frame sharpness: a blurred moving card
/// must not lose its only frame to a perfectly sharp but empty tabletop.
final class CaptureActivityMeter {
    private let lock = NSLock()
    private var previous: [Int] = []
    private var generation: UInt64 = 0

    func measure(_ buffer: CVPixelBuffer, generation: UInt64 = 0) -> Double {
        guard CVPixelBufferGetPlaneCount(buffer) > 0,
              CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else { return 0 }
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddressOfPlane(buffer, 0) else { return 0 }
        let pixels = base.assumingMemoryBound(to: UInt8.self)
        let width = CVPixelBufferGetWidthOfPlane(buffer, 0)
        let height = CVPixelBufferGetHeightOfPlane(buffer, 0)
        let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        guard width > 0, height > 0 else { return 0 }
        var sample: [Int] = []
        sample.reserveCapacity(32 * 32)
        for y in 0..<32 {
            for x in 0..<32 {
                sample.append(Int(pixels[min(height - 1, (2 * y + 1) * height / 64) * stride
                    + min(width - 1, (2 * x + 1) * width / 64)]))
            }
        }
        lock.lock()
        defer { lock.unlock() }
        guard generation == self.generation else { return 0 }
        defer { previous = sample }
        guard previous.count == sample.count else { return 0 }
        let changes = zip(sample, previous).map { abs($0 - $1) }.sorted(by: >)
        return Double(changes.prefix(128).reduce(0, +)) / (128 * 255)
    }

    func reset(generation: UInt64 = 0) {
        lock.lock()
        self.generation = generation
        previous.removeAll(keepingCapacity: true)
        lock.unlock()
    }
}
