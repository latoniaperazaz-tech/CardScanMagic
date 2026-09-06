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

    init(
        card: CardFace,
        confidence: Float,
        boundingBox: CGRect,
        orientedImageSize: CGSize = CGSize(width: 1080, height: 1920)
    ) {
        self.card = card
        self.confidence = confidence
        self.boundingBox = boundingBox
        self.orientedImageSize = orientedImageSize
    }
}
