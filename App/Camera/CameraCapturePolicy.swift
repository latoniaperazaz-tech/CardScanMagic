import CoreMedia
import Foundation

struct CameraFormatOption: Equatable {
    let index: Int
    let width: Int32
    let height: Int32
    let frameRate: Int
}

enum CameraCapturePolicy {
    // 120 FPS caps exposure at roughly 8.3 ms and makes indoor scenes
    // visibly dark. 60 FPS still captures fast card motion while leaving
    // twice the exposure budget; 120 FPS remains a hardware fallback.
    static let preferredFrameRates = [60, 30, 120]
    static let preferredWidth: Int32 = 1920
    static let preferredHeight: Int32 = 1080

    static func preferredFormat(from options: [CameraFormatOption]) -> CameraFormatOption? {
        options.filter { preferredFrameRates.contains($0.frameRate) }.sorted { lhs, rhs in
            if lhs.frameRate != rhs.frameRate {
                return frameRatePriority(lhs.frameRate) < frameRatePriority(rhs.frameRate)
            }
            let lhsIsPreferredSize = hasPreferredDimensions(lhs)
            let rhsIsPreferredSize = hasPreferredDimensions(rhs)
            if lhsIsPreferredSize != rhsIsPreferredSize {
                return lhsIsPreferredSize
            }
            let lhsArea = Int64(lhs.width) * Int64(lhs.height)
            let rhsArea = Int64(rhs.width) * Int64(rhs.height)
            return lhsArea > rhsArea
        }.first
    }

    static func clampedFrameDuration(
        frameRate: Int,
        minimum: CMTime,
        maximum: CMTime
    ) -> CMTime? {
        guard frameRate > 0, frameRate <= Int(Int32.max),
              minimum.isNumeric, maximum.isNumeric,
              CMTimeCompare(minimum, .zero) > 0,
              CMTimeCompare(maximum, minimum) >= 0 else {
            return nil
        }
        // Nanosecond rounding can put 1/120 below a hardware range boundary.
        // Preserve rational timing, including the device's exact endpoints.
        let requested = CMTime(value: 1, timescale: CMTimeScale(frameRate))
        if CMTimeCompare(requested, minimum) < 0 { return minimum }
        if CMTimeCompare(requested, maximum) > 0 { return maximum }
        return requested
    }

    static func clampedMaximumExposureDuration(
        minimum: CMTime,
        maximum: CMTime,
        frameDuration: CMTime
    ) -> CMTime? {
        guard minimum.isNumeric, maximum.isNumeric, frameDuration.isNumeric,
              CMTimeCompare(minimum, .zero) > 0,
              CMTimeCompare(maximum, minimum) >= 0,
              CMTimeCompare(frameDuration, minimum) >= 0 else {
            return nil
        }
        let upperBound = CMTimeCompare(maximum, frameDuration) <= 0 ? maximum : frameDuration
        let requested = CMTime(value: 1, timescale: 1_000)
        // Keep the hardware's rational endpoints, even when an endpoint has
        // the same seconds value as the request but a different timescale.
        if CMTimeCompare(requested, minimum) <= 0 { return minimum }
        if CMTimeCompare(requested, upperBound) >= 0 { return upperBound }
        return requested
    }

    private static func hasPreferredDimensions(_ option: CameraFormatOption) -> Bool {
        option.width == preferredWidth && option.height == preferredHeight
    }

    private static func frameRatePriority(_ frameRate: Int) -> Int {
        preferredFrameRates.firstIndex(of: frameRate) ?? preferredFrameRates.count
    }
}
