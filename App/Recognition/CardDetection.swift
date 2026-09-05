import CoreGraphics
import Foundation

struct CardDetection: Equatable {
    let card: CardFace
    let confidence: Float
    let boundingBox: CGRect
}
