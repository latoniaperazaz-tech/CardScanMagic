import CoreMedia
import Foundation

struct CameraFormatOption: Equatable {
    let index: Int
    let width: Int32
    let height: Int32
    let frameRate: Int
}

enum CameraCapturePolicy {
    static let preferredFrameRates = [60, 30]
    static let preferredWidth: Int32 = 1920
    static let preferredHeight: Int32 = 1080

    static func preferredFormat(from options: [CameraFormatOption]) -> CameraFormatOption? {
        options.filter { preferredFrameRates.contains($0.frameRate) }.sorted { lhs, rhs in
            let lhsIsPreferredSize = hasPreferredDimensions(lhs)
            let rhsIsPreferredSize = hasPreferredDimensions(rhs)
            if lhsIsPreferredSize != rhsIsPreferredSize {
                return lhsIsPreferredSize
            }
            if lhs.frameRate != rhs.frameRate {
                return frameRatePriority(lhs.frameRate) < frameRatePriority(rhs.frameRate)
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

    private static func hasPreferredDimensions(_ option: CameraFormatOption) -> Bool {
        option.width == preferredWidth && option.height == preferredHeight
    }

    private static func frameRatePriority(_ frameRate: Int) -> Int {
        preferredFrameRates.firstIndex(of: frameRate) ?? preferredFrameRates.count
    }
}
