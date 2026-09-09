import CoreGraphics
import Foundation

struct CardDetection: Equatable {
    let card: CardFace
    let confidence: Float
    let boundingBox: CGRect
    /// Dimensions of the image after the orientation supplied to Vision has
    /// been applied. The preview uses this to reproduce aspect-fill cropping
    /// exactly, instead of treating a portrait Vision box as landscape video.
    let orientedImageSize: CGSize
    /// Independent rank/suit or layout evidence agrees with this face. Reusing
    /// the same classifier on a crop does not count as independent support.
    let hasIndependentSupport: Bool

    init(
        card: CardFace,
        confidence: Float,
        boundingBox: CGRect,
        orientedImageSize: CGSize = CGSize(width: 1080, height: 1920),
        hasIndependentSupport: Bool = false
    ) {
        self.card = card
        self.confidence = confidence
        self.boundingBox = boundingBox
        self.orientedImageSize = orientedImageSize
        self.hasIndependentSupport = hasIndependentSupport
    }
}
