import CoreGraphics
import Foundation

/// PHASE 1 capture/scheduling settings; none of these are card confidence gates.
struct CaptureConfiguration {
    var historyCapacity = 30
    var preFrames = 6
    var postFrames = 6
    var maximumEventFrames = 25
    var pendingEventCapacity = 26
    var snapshotMaximumDimension = 1280
    var snapshotByteLimit = 72 * 1_024 * 1_024
    /// Normalized raw-buffer coordinates. The default covers the whole image.
    var motionROI = CGRect(x: 0, y: 0, width: 1, height: 1)
    var motionThreshold = 0.08
    var motionReleaseThreshold = 0.035
}
