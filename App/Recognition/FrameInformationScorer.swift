import Foundation

/// Scheduling utility, deliberately not cardness or recognition confidence.
/// Never discard an event frame solely because this score is low.
enum FrameInformationScorer {
    static func score(luma: [UInt8], motionScore: Double) -> Double {
        let motion = motionScore.isFinite ? min(1, max(0, motionScore)) : 0
        guard luma.count == 1024 else { return 0.8 * sqrt(motion) }
        var minimum = 255
        var maximum = 0
        var gradient = 0
        for y in 0..<32 {
            for x in 0..<32 {
                let value = Int(luma[y * 32 + x])
                minimum = min(minimum, value)
                maximum = max(maximum, value)
                if x > 0 { gradient += abs(value - Int(luma[y * 32 + x - 1])) }
                if y > 0 { gradient += abs(value - Int(luma[(y - 1) * 32 + x])) }
            }
        }
        let contrast = Double(maximum - minimum) / 255
        let detail = Double(gradient) / Double(2 * 32 * 31 * 255)
        // Static texture contributes at most 0.2. A blurred transient at the
        // default trigger level (0.08) outranks even a sharp empty backdrop.
        return min(1, 0.8 * sqrt(motion) + 0.12 * contrast + 0.08 * detail)
    }
}
