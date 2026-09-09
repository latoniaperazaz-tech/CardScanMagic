import Foundation

struct CameraFormatOption: Equatable {
    let index: Int
    let width: Int32
    let height: Int32
    let frameRate: Int
}

enum CameraCapturePolicy {
    static let preferredFrameRates = [120, 60]
    static let preferredWidth: Int32 = 1920
    static let preferredHeight: Int32 = 1080
    static let maximumAutoExposureSeconds = 1.0 / 500.0

    static func preferredFormat(from options: [CameraFormatOption]) -> CameraFormatOption? {
        options.sorted { lhs, rhs in
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

    static func clampedMaximumExposureSeconds(
        minimum: Double,
        maximum: Double
    ) -> Double? {
        guard minimum.isFinite, maximum.isFinite, minimum > 0, maximum >= minimum else {
            return nil
        }
        return min(max(maximumAutoExposureSeconds, minimum), maximum)
    }

    private static func hasPreferredDimensions(_ option: CameraFormatOption) -> Bool {
        option.width == preferredWidth && option.height == preferredHeight
    }

    private static func frameRatePriority(_ frameRate: Int) -> Int {
        preferredFrameRates.firstIndex(of: frameRate) ?? preferredFrameRates.count
    }
}
