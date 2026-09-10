import CoreGraphics
import Foundation

enum PartialEvidenceFusion {
    struct Evidence {
        let features: PartialCardFeatures
        let layout: PartialRankResult
    }

    private struct ResolvedEvidence {
        let source: Evidence
        let layoutRank: String?
        let textRank: String?
        let suit: CardFace.Suit?

        var rank: String? { textRank ?? layoutRank }
        var box: CGRect { source.features.boundingBox }
        var hasRankConflict: Bool {
            textRank != nil && layoutRank != nil && textRank != layoutRank
        }
    }

    static func fuse(model: [CardDetection], local: [Evidence], imageSize: CGSize) -> [CardDetection] {
        let usableModel = model.filter {
            validConfidence(Double($0.confidence)) && validBox($0.boundingBox)
        }
        let usableLocal: [ResolvedEvidence] = imageSize.width.isFinite && imageSize.height.isFinite
            && imageSize.width > 0 && imageSize.height > 0 ? local.compactMap(resolve) : []

        // Resolve all overlapping cues before consuming any model observation.
        // A later crop must be able to veto an earlier crop's provisional face.
        let vetoedRegions = usableLocal.indices.compactMap { index -> CGRect? in
            let evidence = usableLocal[index]
            let modelConflict = usableModel.contains { detection in
                detection.confidence >= 0.80 && overlaps(detection.boundingBox, evidence.box)
                    && ((evidence.rank != nil && detection.card.rank != evidence.rank)
                        || (evidence.suit != nil && detection.card.suit != evidence.suit))
            }
            let localConflict = usableLocal.indices.contains { otherIndex in
                guard index != otherIndex else { return false }
                let other = usableLocal[otherIndex]
                guard overlaps(evidence.box, other.box) else { return false }
                return (evidence.rank != nil && other.rank != nil && evidence.rank != other.rank)
                    || (evidence.suit != nil && other.suit != nil && evidence.suit != other.suit)
            }
            return evidence.hasRankConflict || modelConflict || localConflict ? evidence.box : nil
        }
        var remaining = usableModel.filter { detection in
            !vetoedRegions.contains { overlaps($0, detection.boundingBox) }
        }
        var fused: [CardDetection] = []
        for evidence in usableLocal {
            guard !vetoedRegions.contains(where: { overlaps($0, evidence.box) }),
                  let rank = evidence.rank, let suit = evidence.suit,
                  let card = CardFace.parse(rank + String(suit.rawValue)) else { continue }
            let features = evidence.source.features
            let nearby = usableModel.filter { overlaps($0.boundingBox, evidence.box) }
            let rankConfidence = evidence.textRank != nil
                ? features.rankTextConfidence : evidence.source.layout.confidence
            let localConfidence = min(rankConfidence, features.suitConfidence)
            let agreeing = nearby.filter { $0.card == card }.max { $0.confidence < $1.confidence }
            let dualRankSupport = evidence.textRank != nil && evidence.layoutRank == evidence.textRank
            let pipTopologySupport = hasPipTopologyEvidence(evidence)
            // An unreadable corner may be replaced by body topology, but an
            // unqualified collection of dark components must not become a face.
            // Model and readable-rank support retain their existing paths.
            guard evidence.textRank != nil || agreeing != nil || pipTopologySupport else { continue }
            let strongLayout = evidence.layoutRank != nil && evidence.source.layout.confidence >= 0.90
                && pipTopologySupport
                && (distinctPipCount(features.pipCenters) >= 4 || features.surfaceAnchored)
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
        // Repeated crops of the same face remain one observation. Different
        // faces must survive to the coordinator's unresolved-conflict gate.
        var result: [CardDetection] = []
        for detection in (fused + remaining).sorted(by: {
            $0.confidence == $1.confidence ? $0.card.code < $1.card.code : $0.confidence > $1.confidence
        }) {
            if result.contains(where: {
                $0.card == detection.card && overlaps($0.boundingBox, detection.boundingBox)
            }) { continue }
            result.append(detection)
        }
        return result
    }

    private static func resolve(_ evidence: Evidence) -> ResolvedEvidence? {
        let features = evidence.features
        guard validBox(features.boundingBox),
              validConfidence(features.localizationConfidence), features.localizationConfidence >= 0.50,
              validConfidence(features.rankTextConfidence), validConfidence(evidence.layout.confidence),
              validConfidence(features.suitConfidence),
              features.suitProbabilities.count == 4,
              features.suitProbabilities.allSatisfy({ parseSuit($0.key) != nil && validConfidence($0.value) }),
              abs(features.suitProbabilities.values.reduce(0, +) - 1) <= 0.01 else {
            return nil
        }
        let suits = features.suitProbabilities.sorted { $0.value > $1.value }
        let bestSuit = suits.first
        let suitResolved = features.suitConfidence >= 0.60
            && (bestSuit?.value ?? 0) >= 0.65
            && (bestSuit?.value ?? 0) - (suits.dropFirst().first?.value ?? 0) >= 0.15
        return ResolvedEvidence(
            source: evidence,
            layoutRank: evidence.layout.confidence >= 0.70 ? parsedRank(evidence.layout.rank) : nil,
            textRank: features.rankTextConfidence >= 0.80 ? parsedRank(features.rankText) : nil,
            suit: suitResolved ? bestSuit.flatMap { parseSuit($0.key) } : nil
        )
    }

    private static func parsedRank(_ value: String?) -> String? {
        guard let value else { return nil }
        return CardFace.parse(value + "d")?.rank
    }

    private static func validConfidence(_ value: Double) -> Bool {
        value.isFinite && (0...1).contains(value)
    }

    private static func validBox(_ value: CGRect) -> Bool {
        let box = value.standardized
        return box.minX.isFinite && box.minY.isFinite && box.maxX.isFinite && box.maxY.isFinite
            && box.width > 0 && box.height > 0 && (box.width * box.height).isFinite
    }

    private static func distinctPipCount(_ points: [CGPoint]) -> Int {
        var distinct: [CGPoint] = []
        for point in points.prefix(64) {
            guard point.x.isFinite, point.y.isFinite,
                  (0...1).contains(point.x), (0...1).contains(point.y),
                  !distinct.contains(where: { hypot($0.x - point.x, $0.y - point.y) < 0.012 }) else {
                continue
            }
            distinct.append(point)
        }
        return distinct.count
    }

    private static func hasPipTopologyEvidence(_ evidence: ResolvedEvidence) -> Bool {
        let features = evidence.source.features
        let layout = evidence.source.layout
        let count = distinctPipCount(features.pipCenters)
        let numericRanks: Set<String> = ["A", "2", "3", "4", "5", "6", "7", "8", "9", "10"]
        guard let rank = evidence.layoutRank, numericRanks.contains(rank), count > 0,
              count == features.bodyPipCount, count == features.pipCenters.count,
              validConfidence(features.pipStructureConfidence), features.pipStructureConfidence >= 0.70,
              features.bodySuitSupportingPips >= min(count, 3),
              features.bodySuitSupportingPips <= count,
              Double(features.bodySuitSupportingPips) / Double(count) >= 0.60,
              layout.candidates.count == numericRanks.count,
              Set(layout.candidates.map(\.rank)) == numericRanks,
              layout.candidates.allSatisfy({
                  validConfidence($0.probability) && validConfidence($0.score)
                      && $0.matchedCount >= 0 && $0.matchedCount <= count
              }),
              abs(layout.candidates.reduce(0) { $0 + $1.probability } - 1) <= 0.01 else { return false }
        let ordered = layout.candidates.sorted { $0.probability > $1.probability }
        guard let best = ordered.first, best.rank == rank, best.matchedCount == count,
              best.score >= 0.72, best.probability >= 0.27,
              best.probability - ordered[1].probability >= 0.055 else { return false }
        // A complete card establishes absolute pip positions and visible empty
        // positions for A/2/3. A partial crop still needs several matching pips.
        if features.surfaceAnchored { return features.visibleRegion == "full" }
        let partialRegions: Set<String> = ["left", "right", "top", "bottom", "center",
            "top_left", "top_right", "bottom_left", "bottom_right"]
        return count >= 3 && partialRegions.contains(features.visibleRegion)
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
