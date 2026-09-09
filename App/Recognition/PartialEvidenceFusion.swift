import CoreGraphics
import Foundation

enum PartialEvidenceFusion {
    struct Evidence {
        let features: PartialCardFeatures
        let layout: PartialRankResult
    }

    static func fuse(model: [CardDetection], local: [Evidence], imageSize: CGSize) -> [CardDetection] {
        var remaining = model.filter { $0.confidence.isFinite }
        var fused: [CardDetection] = []
        for evidence in local {
            let features = evidence.features
            guard features.localizationConfidence >= 0.50 else { continue }
            let nearby = remaining.filter { overlaps($0.boundingBox, features.boundingBox) }
            let layoutRank = evidence.layout.confidence >= 0.70 ? evidence.layout.rank : nil
            let textRank = features.rankTextConfidence >= 0.80 ? features.rankText : nil
            let suits = features.suitProbabilities.filter { $0.value.isFinite }
                .sorted { $0.value > $1.value }
            let bestSuit = suits.first
            let suitResolved = features.suitConfidence >= 0.60
                && (bestSuit?.value ?? 0) >= 0.65
                && (bestSuit?.value ?? 0) - (suits.dropFirst().first?.value ?? 0) >= 0.15

            // Conflicting readable cues veto this region, including a model
            // label. A color or unresolved layout never vetoes a model alone.
            let rankConflict = textRank != nil && layoutRank != nil && textRank != layoutRank
            if rankConflict {
                remaining.removeAll { overlaps($0.boundingBox, features.boundingBox) }
                continue
            }
            let rank = textRank ?? layoutRank
            let suit = suitResolved ? bestSuit.flatMap { parseSuit($0.key) } : nil
            let conflicting = nearby.contains { detection in
                detection.confidence >= 0.80
                    && ((rank != nil && detection.card.rank != rank)
                        || (suit != nil && detection.card.suit != suit))
            }
            if conflicting {
                remaining.removeAll { overlaps($0.boundingBox, features.boundingBox) }
                continue
            }
            guard let rank, let suit,
                  let card = CardFace.parse(rank + String(suit.rawValue)) else { continue }
            let rankConfidence = textRank != nil ? features.rankTextConfidence : evidence.layout.confidence
            let localConfidence = min(rankConfidence, features.suitConfidence)
            let agreeing = nearby.filter { $0.card == card }.max { $0.confidence < $1.confidence }
            let dualRankSupport = textRank != nil && layoutRank == textRank
            let strongLayout = layoutRank != nil && evidence.layout.confidence >= 0.90
                && features.pipCenters.count >= 4
            let independent = (agreeing?.confidence ?? 0) >= 0.65
                || dualRankSupport || strongLayout
            let confidence: Float
            if let agreeing {
                // This is an evidence score, not a calibrated probability.
                // Repeated model crops do not receive this support bonus.
                confidence = Float(min(0.99, 0.60 * Double(agreeing.confidence)
                    + 0.40 * localConfidence + 0.08))
            } else {
                confidence = Float(min(0.98, localConfidence))
            }
            remaining.removeAll { overlaps($0.boundingBox, features.boundingBox) }
            fused.append(CardDetection(card: card, confidence: confidence,
                boundingBox: features.boundingBox, orientedImageSize: imageSize,
                hasIndependentSupport: independent))
        }
        // Multiple overlapping local crops remain one observation.
        var result: [CardDetection] = []
        for detection in (fused + remaining).sorted(by: { $0.confidence > $1.confidence }) {
            if result.contains(where: { overlaps($0.boundingBox, detection.boundingBox) }) { continue }
            result.append(detection)
        }
        return result
    }

    private static func parseSuit(_ value: String) -> CardFace.Suit? {
        switch value {
        case "club": return .clubs
        case "diamond": return .diamonds
        case "heart": return .hearts
        case "spade": return .spades
        default: return nil
        }
    }

    private static func overlaps(_ first: CGRect, _ second: CGRect) -> Bool {
        let a = first.standardized
        let b = second.standardized
        let intersection = a.intersection(b)
        let smaller = min(a.width * a.height, b.width * b.height)
        guard !intersection.isNull, smaller.isFinite, smaller > 0 else { return false }
        return intersection.width * intersection.height / smaller >= 0.65
    }
}
