import CoreVideo
import Foundation
import ImageIO

/// Owned, reusable snapshots. AVFoundation buffers are never retained by the
/// history/event queues. Ring and event entries share the same pool buffer.
final class CaptureSnapshotPool {
    struct Statistics {
        /// Upper bound for the pool's pixel storage, including retained events.
        let maximumPixelBytes: Int
        let bytesPerBuffer: Int
        let allocationThreshold: Int
        let failures: Int
        let formatChangeRejections: Int
    }

    private struct Format: Equatable {
        let width: Int
        let height: Int
        let pixelFormat: OSType
    }

    private let lock = NSLock()
    private let maximumDimension: Int
    private let byteLimit: Int
    private var pool: CVPixelBufferPool?
    private var format: Format?
    private var bytesPerBuffer = 0
    private var allocationThreshold = 0
    private var failures = 0
    private var formatChangeRejections = 0

    init(maximumDimension: Int = 1280, byteLimit: Int = 72 * 1_024 * 1_024) {
        self.maximumDimension = max(2, min(4096, maximumDimension))
        self.byteLimit = max(0, byteLimit)
    }

    func copy(_ source: CVPixelBuffer, orientation: CGImagePropertyOrientation) -> CapturedImage? {
        lock.lock()
        defer { lock.unlock() }
        guard let requested = destinationFormat(source) else {
            failures += 1
            return nil
        }
        // Do not create a second pool while old ring/event snapshots may still
        // exist. Fixed output format also prevents mixed geometry in an event.
        if let format, format != requested {
            formatChangeRejections += 1
            failures += 1
            return nil
        }
        let target: CVPixelBuffer
        if pool == nil {
            guard let first = configure(requested) else {
                failures += 1
                return nil
            }
            target = first
        } else {
            var next: CVPixelBuffer?
            let options = [kCVPixelBufferPoolAllocationThresholdKey: allocationThreshold] as CFDictionary
            guard let pool,
                  CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(kCFAllocatorDefault, pool, options, &next) == kCVReturnSuccess,
                  let next else {
                failures += 1
                return nil
            }
            target = next
        }
        guard Self.allocatedBytes(target) <= bytesPerBuffer, scale(source, into: target) else {
            failures += 1
            return nil
        }
        CVBufferPropagateAttachments(source, target)
        return CapturedImage(pixelBuffer: target, orientation: orientation, bytes: bytesPerBuffer)
    }

    /// A session reset never replaces the pool: previous-generation inference
    /// can still own a buffer, and must continue to count against this budget.
    func reset() {
        lock.lock()
        defer { lock.unlock() }
        failures = 0
        formatChangeRejections = 0
        if let pool { CVPixelBufferPoolFlush(pool, .excessBuffers) }
    }

    var statistics: Statistics {
        lock.lock()
        defer { lock.unlock() }
        return Statistics(
            maximumPixelBytes: bytesPerBuffer * allocationThreshold,
            bytesPerBuffer: bytesPerBuffer,
            allocationThreshold: allocationThreshold,
            failures: failures,
            formatChangeRejections: formatChangeRejections
        )
    }

    private func destinationFormat(_ source: CVPixelBuffer) -> Format? {
        let pixelFormat = CVPixelBufferGetPixelFormatType(source)
        guard pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
            || pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            || pixelFormat == kCVPixelFormatType_32BGRA else { return nil }
        let width = CVPixelBufferGetWidth(source)
        let height = CVPixelBufferGetHeight(source)
        guard width >= 2, height >= 2 else { return nil }
        let ratio = min(1, Double(maximumDimension) / Double(max(width, height)))
        let outputWidth = max(2, Int(Double(width) * ratio) / 2 * 2)
        let outputHeight = max(2, Int(Double(height) * ratio) / 2 * 2)
        return Format(width: outputWidth, height: outputHeight, pixelFormat: pixelFormat)
    }

    private func configure(_ requested: Format) -> CVPixelBuffer? {
        // Refuse undersized budgets before asking CoreVideo to allocate the
        // first surface. This conservative bound covers row/plane padding;
        // subsequent thresholds use the measured pixel-buffer storage size.
        let channels = requested.pixelFormat == kCVPixelFormatType_32BGRA ? 4 : 1
        let paddedStride = ((requested.width * channels + 255) / 256) * 256
        let paddedHeight = ((requested.height + 63) / 64) * 64
        let conservativeBytes = paddedStride * paddedHeight * (channels == 1 ? 2 : 1) + 16_384
        guard conservativeBytes <= byteLimit else { return nil }
        let attributes: [CFString: Any] = [
            kCVPixelBufferWidthKey: requested.width,
            kCVPixelBufferHeightKey: requested.height,
            kCVPixelBufferPixelFormatTypeKey: requested.pixelFormat,
            kCVPixelBufferBytesPerRowAlignmentKey: 64,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as [String: Any]
        ]
        var createdPool: CVPixelBufferPool?
        guard CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attributes as CFDictionary, &createdPool) == kCVReturnSuccess,
              let createdPool else { return nil }
        var first: CVPixelBuffer?
        let probeOptions = [kCVPixelBufferPoolAllocationThresholdKey: 1] as CFDictionary
        guard CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(kCFAllocatorDefault, createdPool, probeOptions, &first) == kCVReturnSuccess,
              let first else { return nil }
        let bytes = Self.allocatedBytes(first)
        guard bytes > 0, bytes <= byteLimit else { return nil }
        pool = createdPool
        format = requested
        bytesPerBuffer = bytes
        allocationThreshold = byteLimit / bytes
        return first
    }

    private static func allocatedBytes(_ buffer: CVPixelBuffer) -> Int {
        var rows = 0
        let planes = CVPixelBufferGetPlaneCount(buffer)
        if planes == 0 {
            rows = CVPixelBufferGetBytesPerRow(buffer) * CVPixelBufferGetHeight(buffer)
        } else {
            for plane in 0..<planes {
                rows += CVPixelBufferGetBytesPerRowOfPlane(buffer, plane) * CVPixelBufferGetHeightOfPlane(buffer, plane)
            }
        }
        return max(rows, CVPixelBufferGetDataSize(buffer))
    }

    private func scale(_ source: CVPixelBuffer, into target: CVPixelBuffer) -> Bool {
        guard CVPixelBufferLockBaseAddress(source, .readOnly) == kCVReturnSuccess else { return false }
        defer { CVPixelBufferUnlockBaseAddress(source, .readOnly) }
        guard CVPixelBufferLockBaseAddress(target, []) == kCVReturnSuccess else { return false }
        defer { CVPixelBufferUnlockBaseAddress(target, []) }
        if CVPixelBufferGetPixelFormatType(source) == kCVPixelFormatType_32BGRA {
            guard let input = CVPixelBufferGetBaseAddress(source), let output = CVPixelBufferGetBaseAddress(target) else { return false }
            return scalePlane(input: input, inputWidth: CVPixelBufferGetWidth(source), inputHeight: CVPixelBufferGetHeight(source),
                              inputStride: CVPixelBufferGetBytesPerRow(source), output: output,
                              outputWidth: CVPixelBufferGetWidth(target), outputHeight: CVPixelBufferGetHeight(target),
                              outputStride: CVPixelBufferGetBytesPerRow(target), bytesPerPixel: 4)
        }
        guard CVPixelBufferGetPlaneCount(source) == 2, CVPixelBufferGetPlaneCount(target) == 2 else { return false }
        for plane in 0..<2 {
            guard let input = CVPixelBufferGetBaseAddressOfPlane(source, plane), let output = CVPixelBufferGetBaseAddressOfPlane(target, plane) else { return false }
            let bytesPerPixel = plane == 0 ? 1 : 2
            guard scalePlane(input: input, inputWidth: CVPixelBufferGetWidthOfPlane(source, plane),
                             inputHeight: CVPixelBufferGetHeightOfPlane(source, plane),
                             inputStride: CVPixelBufferGetBytesPerRowOfPlane(source, plane), output: output,
                             outputWidth: CVPixelBufferGetWidthOfPlane(target, plane),
                             outputHeight: CVPixelBufferGetHeightOfPlane(target, plane),
                             outputStride: CVPixelBufferGetBytesPerRowOfPlane(target, plane),
                             bytesPerPixel: bytesPerPixel) else { return false }
        }
        return true
    }

    private func scalePlane(input: UnsafeMutableRawPointer, inputWidth: Int, inputHeight: Int, inputStride: Int,
                            output: UnsafeMutableRawPointer, outputWidth: Int, outputHeight: Int,
                            outputStride: Int, bytesPerPixel: Int) -> Bool {
        guard inputWidth > 0, inputHeight > 0, outputWidth > 0, outputHeight > 0, bytesPerPixel > 0 else { return false }
        let source = input.assumingMemoryBound(to: UInt8.self)
        let target = output.assumingMemoryBound(to: UInt8.self)
        for y in 0..<outputHeight {
            let sourceY = min(inputHeight - 1, y * inputHeight / outputHeight)
            for x in 0..<outputWidth {
                let sourceX = min(inputWidth - 1, x * inputWidth / outputWidth)
                memcpy(target + y * outputStride + x * bytesPerPixel,
                       source + sourceY * inputStride + sourceX * bytesPerPixel,
                       bytesPerPixel)
            }
        }
        return true
    }
}
