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
        RecognitionTrace.call("fusion")
        let trace = RecognitionTrace.current
        let previousCandidate = trace?.candidateID
        trace?.candidateID = nil
        defer { trace?.candidateID = previousCandidate }
        trace?.event("fusion.input", ["modelDetections": RecognitionTrace.detections(model),
            "localCount": local.count, "width": Double(imageSize.width), "height": Double(imageSize.height)])
        let usableModel = model.filter {
            traceCheck(validConfidence(Double($0.confidence)), "MODEL_CONFIDENCE_INVALID")
                && traceCheck(validBox($0.boundingBox), "MODEL_BOX_INVALID")
        }
        let usableLocal: [ResolvedEvidence] = traceCheck(imageSize.width.isFinite, "IMAGE_WIDTH_INVALID")
            && traceCheck(imageSize.height.isFinite, "IMAGE_HEIGHT_INVALID")
            && traceCheck(imageSize.width > 0, "IMAGE_WIDTH_NONPOSITIVE")
            && traceCheck(imageSize.height > 0, "IMAGE_HEIGHT_NONPOSITIVE") ? local.compactMap(resolve) : []

        // Resolve all overlapping cues before consuming any model observation.
        // A later crop must be able to veto an earlier crop's provisional face.
        let vetoedRegions = usableLocal.indices.compactMap { index -> CGRect? in
            let evidence = usableLocal[index]
            let previous = trace?.candidateID
            trace?.candidateID = evidence.source.features.traceCandidateID
            defer { trace?.candidateID = previous }
            let conflictRank = qualifiedConflictRank(evidence)
            let conflictSuit = qualifiedConflictSuit(evidence)
            let modelConflict = usableModel.contains { detection in
                detection.confidence >= 0.80 && overlaps(detection.boundingBox, evidence.box)
                    && ((conflictRank != nil && detection.card.rank != conflictRank)
                        || (conflictSuit != nil && detection.card.suit != conflictSuit))
            }
            let localConflict = usableLocal.indices.contains { otherIndex in
                guard index != otherIndex else { return false }
                let other = usableLocal[otherIndex]
                guard overlaps(evidence.box, other.box) else { return false }
                let otherRank = qualifiedConflictRank(other)
                let otherSuit = qualifiedConflictSuit(other)
                return (conflictRank != nil && otherRank != nil && conflictRank != otherRank)
                    || (conflictSuit != nil && otherSuit != nil && conflictSuit != otherSuit)
            }
            let rankConflict = evidence.hasRankConflict
            let veto = rankConflict || modelConflict || localConflict
            trace?.event("fusion.conflict", ["vetoed": veto,
                "rankConflict": rankConflict, "modelConflict": modelConflict,
                "localConflict": localConflict, "qualifiedRank": conflictRank as Any? ?? NSNull(),
                "qualifiedSuit": conflictSuit.map { String($0.rawValue) } as Any? ?? NSNull()])
            return veto ? evidence.box : nil
        }
        var remaining = usableModel.filter { detection in
            !vetoedRegions.contains { overlaps($0, detection.boundingBox) }
        }
        var fused: [CardDetection] = []
        for evidence in usableLocal {
            trace?.candidateID = evidence.source.features.traceCandidateID
            defer { trace?.candidateID = nil }
            guard traceCheck(!vetoedRegions.contains(where: { overlaps($0, evidence.box) }), "FUSION_CONFLICT_VETO"),
                  let rank = traceOptional(evidence.rank, "FUSION_RANK_UNRESOLVED"),
                  let suit = traceOptional(evidence.suit, "FUSION_SUIT_UNRESOLVED"),
                  let card = traceOptional(CardFace.parse(rank + String(suit.rawValue)), "FUSION_CARD_INVALID") else {
                trace?.event("fusion.candidate", ["accepted": false, "reason": "FAILED_PRECEDING_CHECK",
                    "finalCard": NSNull(), "confidence": NSNull(), "remainingChecks": "notEvaluated"])
                continue
            }
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
            guard traceCheck(evidence.textRank != nil || agreeing != nil || pipTopologySupport,
                             "FUSION_NO_QUALIFIED_RANK_SUPPORT") else {
                trace?.event("fusion.candidate", ["accepted": false, "reason": "FUSION_NO_QUALIFIED_RANK_SUPPORT",
                    "finalCard": NSNull(), "confidence": NSNull(), "pipTopologySupport": pipTopologySupport])
                continue
            }
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
            trace?.event("fusion.candidate", ["accepted": true, "reason": "FUSION_ACCEPTED",
                "finalCard": card.code, "confidence": confidence, "rankConfidence": rankConfidence,
                "suitConfidence": features.suitConfidence, "localConfidence": localConfidence,
                "pipTopologySupport": pipTopologySupport, "dualRankSupport": dualRankSupport,
                "strongLayout": strongLayout, "hasIndependentSupport": independent,
                "agreeingModelConfidence": agreeing?.confidence as Any? ?? NSNull()])
        }
        // Repeated crops of the same face remain one observation. Different
        // faces must survive to the coordinator's unresolved-conflict gate.
        var result: [CardDetection] = []
        for detection in (fused + remaining).sorted(by: {
            $0.confidence == $1.confidence ? $0.card.code < $1.card.code : $0.confidence > $1.confidence
        }) {
            if result.contains(where: {
                $0.card == detection.card && overlaps($0.boundingBox, detection.boundingBox)
            }) {
                trace?.event("fusion.dedup", ["card": detection.card.code, "reason": "OVERLAPPING_SAME_FACE"])
                continue
            }
            result.append(detection)
        }
        trace?.candidateID = nil
        trace?.event("fusion.result", ["status": "completed", "finalDetections": RecognitionTrace.detections(result),
            "usableLocalCount": usableLocal.count, "usableModelCount": usableModel.count])
        return result
    }

    private static func resolve(_ evidence: Evidence) -> ResolvedEvidence? {
        let features = evidence.features
        let trace = RecognitionTrace.current
        let previous = trace?.candidateID
        trace?.candidateID = features.traceCandidateID
        defer { trace?.candidateID = previous }
        trace?.event("fusion.resolveInput", ["boundingBox": RecognitionTrace.rect(features.boundingBox),
            "localizationConfidence": features.localizationConfidence,
            "rankText": features.rankText as Any? ?? NSNull(), "rankTextConfidence": features.rankTextConfidence,
            "layoutRank": evidence.layout.rank as Any? ?? NSNull(), "layoutConfidence": evidence.layout.confidence,
            "suitProbabilities": features.suitProbabilities, "suitConfidence": features.suitConfidence])
        guard traceCheck(validBox(features.boundingBox), "LOCAL_BOX_INVALID"),
              traceCheck(validConfidence(features.localizationConfidence), "LOCALIZATION_CONFIDENCE_INVALID"),
              traceCheck(features.localizationConfidence >= 0.50, "LOCALIZATION_CONFIDENCE_LOW", ["value": features.localizationConfidence, "minimum": 0.50]),
              traceCheck(validConfidence(features.rankTextConfidence), "OCR_CONFIDENCE_INVALID"),
              traceCheck(validConfidence(evidence.layout.confidence), "LAYOUT_CONFIDENCE_INVALID"),
              traceCheck(validConfidence(features.suitConfidence), "SUIT_CONFIDENCE_INVALID"),
              traceCheck(features.suitProbabilities.count == 4, "SUIT_DISTRIBUTION_INCOMPLETE"),
              traceCheck(features.suitProbabilities.allSatisfy({ parseSuit($0.key) != nil && validConfidence($0.value) }), "SUIT_DISTRIBUTION_INVALID"),
              traceCheck(abs(features.suitProbabilities.values.reduce(0, +) - 1) <= 0.01, "SUIT_DISTRIBUTION_NOT_NORMALIZED") else {
            trace?.event("fusion.resolve", ["accepted": false, "reason": "FAILED_PRECEDING_CHECK",
                "remainingChecks": "notEvaluated"])
            return nil
        }
        let suits = features.suitProbabilities.sorted { $0.value > $1.value }
        let bestSuit = suits.first
        var evaluatedSuitMargin: Double?
        let suitResolved = traceCheck(features.suitConfidence >= 0.60, "SUIT_CONFIDENCE_LOW", ["value": features.suitConfidence, "minimum": 0.60])
            && traceCheck((bestSuit?.value ?? 0) >= 0.65, "SUIT_TOP1_LOW", ["value": bestSuit?.value as Any? ?? NSNull(), "minimum": 0.65])
            && traceCheck(captureMetric((bestSuit?.value ?? 0) - (suits.dropFirst().first?.value ?? 0), into: &evaluatedSuitMargin) >= 0.15,
                          "SUIT_MARGIN_LOW", ["value": evaluatedSuitMargin as Any? ?? NSNull(), "minimum": 0.15])
        let result = ResolvedEvidence(
            source: evidence,
            layoutRank: traceCheck(evidence.layout.confidence >= 0.70, "FUSION_LAYOUT_CONFIDENCE_LOW", ["value": evidence.layout.confidence, "minimum": 0.70]) ? parsedRank(evidence.layout.rank) : nil,
            textRank: traceCheck(features.rankTextConfidence >= 0.80, "FUSION_OCR_CONFIDENCE_LOW", ["value": features.rankTextConfidence, "minimum": 0.80]) ? parsedRank(features.rankText) : nil,
            suit: suitResolved ? bestSuit.flatMap { parseSuit($0.key) } : nil
        )
        trace?.event("fusion.suit", ["status": "evaluated", "probabilities": features.suitProbabilities,
            "top1": bestSuit?.key as Any? ?? NSNull(), "top2": suits.dropFirst().first?.key as Any? ?? NSNull(),
            "top1Probability": bestSuit?.value as Any? ?? NSNull(),
            "top2Probability": suits.dropFirst().first?.value as Any? ?? NSNull(),
            "margin": evaluatedSuitMargin as Any? ?? NSNull(),
            "marginStatus": evaluatedSuitMargin == nil ? "notEvaluated" : "evaluated",
            "confidence": features.suitConfidence, "resolved": suitResolved,
            "finalSuit": result.suit.map { String($0.rawValue) } as Any? ?? NSNull()])
        trace?.event("fusion.resolve", ["accepted": true, "layoutRank": result.layoutRank as Any? ?? NSNull(),
            "textRank": result.textRank as Any? ?? NSNull(), "finalRank": result.rank as Any? ?? NSNull(),
            "finalSuit": result.suit.map { String($0.rawValue) } as Any? ?? NSNull(),
            "ocrStatus": features.rankText == nil ? "OCR_NIL" : "available"])
        return result
    }

    /// Wrapping the already evaluated expression preserves guard/&& short circuiting.
    /// No production predicate is evaluated again to explain a rejected result.
    private static func traceCheck(_ value: Bool, _ reason: String,
                                   _ fields: @autoclosure () -> [String: Any] = [:]) -> Bool {
        if let trace = RecognitionTrace.current {
            var details = fields()
            details["status"] = "evaluated"; details["passed"] = value; details["reason"] = reason
            trace.event("fusion.check", details)
        }
        return value
    }

    private static func captureMetric(_ value: Double, into observed: inout Double?) -> Double {
        observed = value
        return value
    }

    private static func traceOptional<T>(_ value: T?, _ reason: String) -> T? {
        RecognitionTrace.current?.event("fusion.check", ["status": "evaluated", "passed": value != nil, "reason": reason])
        return value
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
        let trace = RecognitionTrace.current
        let previous = trace?.candidateID
        trace?.candidateID = features.traceCandidateID
        defer { trace?.candidateID = previous }
        let count = distinctPipCount(features.pipCenters)
        let numericRanks: Set<String> = ["A", "2", "3", "4", "5", "6", "7", "8", "9", "10"]
        trace?.event("fusion.pipInput", ["distinctPipCount": count, "bodyPipCount": features.bodyPipCount,
            "inputPipCount": features.pipCenters.count, "bodySuitSupportingPips": features.bodySuitSupportingPips,
            "pipStructureConfidence": features.pipStructureConfidence, "surfaceAnchored": features.surfaceAnchored,
            "visibleRegion": features.visibleRegion, "candidates": layout.candidates.map {
                ["rank": $0.rank, "probability": $0.probability, "score": $0.score,
                 "matchedCount": $0.matchedCount] as [String: Any]
            }])
        guard let rank = traceOptional(evidence.layoutRank, "PIP_LAYOUT_RANK_UNRESOLVED"),
              traceCheck(numericRanks.contains(rank), "PIP_LAYOUT_RANK_NONNUMERIC"),
              traceCheck(count > 0, "PIP_INPUT_EMPTY"),
              traceCheck(count == features.bodyPipCount, "PIP_BODY_COUNT_MISMATCH"),
              traceCheck(count == features.pipCenters.count, "PIP_DUPLICATE_OR_INVALID_INPUT"),
              traceCheck(validConfidence(features.pipStructureConfidence), "PIP_STRUCTURE_INVALID"),
              traceCheck(features.pipStructureConfidence >= 0.70, "PIP_STRUCTURE_LOW", ["value": features.pipStructureConfidence, "minimum": 0.70]),
              traceCheck(features.bodySuitSupportingPips >= min(count, 3), "BODY_SUIT_SUPPORT_COUNT_LOW"),
              traceCheck(features.bodySuitSupportingPips <= count, "BODY_SUIT_SUPPORT_COUNT_INVALID"),
              traceCheck(Double(features.bodySuitSupportingPips) / Double(count) >= 0.60, "BODY_SUIT_SUPPORT_FRACTION_LOW"),
              traceCheck(layout.candidates.count == numericRanks.count, "PIP_DISTRIBUTION_COUNT_INVALID"),
              traceCheck(Set(layout.candidates.map(\.rank)) == numericRanks, "PIP_DISTRIBUTION_RANKS_INVALID"),
              traceCheck(layout.candidates.allSatisfy({
                  validConfidence($0.probability) && validConfidence($0.score)
                      && $0.matchedCount >= 0 && $0.matchedCount <= count
              }), "PIP_DISTRIBUTION_VALUES_INVALID"),
              traceCheck(abs(layout.candidates.reduce(0) { $0 + $1.probability } - 1) <= 0.01,
                         "PIP_DISTRIBUTION_NOT_NORMALIZED") else {
            trace?.event("fusion.pipSupport", ["accepted": false, "reason": "FAILED_PRECEDING_CHECK",
                "remainingChecks": "notEvaluated"])
            return false
        }
        let ordered = layout.candidates.sorted { $0.probability > $1.probability }
        var evaluatedLayoutMargin: Double?
        guard let best = traceOptional(ordered.first, "PIP_DISTRIBUTION_EMPTY"),
              traceCheck(best.rank == rank, "PIP_WINNER_MISMATCH"),
              traceCheck(best.matchedCount == count, "PIP_LAYOUT_UNMATCHED_INPUT"),
              traceCheck(best.score >= 0.72, "PIP_LAYOUT_SCORE_LOW", ["value": best.score, "minimum": 0.72]),
              traceCheck(best.probability >= 0.27, "PIP_LAYOUT_PROBABILITY_LOW", ["value": best.probability, "minimum": 0.27]),
              traceCheck(captureMetric(best.probability - ordered[1].probability, into: &evaluatedLayoutMargin) >= 0.055,
                         "PIP_LAYOUT_MARGIN_LOW", ["value": evaluatedLayoutMargin as Any? ?? NSNull(), "minimum": 0.055]) else {
            trace?.event("fusion.pipSupport", ["accepted": false, "reason": "FAILED_PRECEDING_CHECK",
                "remainingChecks": "notEvaluated"])
            return false
        }
        // A complete card establishes absolute pip positions and visible empty
        // positions for A/2/3. A partial crop still needs several matching pips.
        if features.surfaceAnchored {
            let result = traceCheck(features.visibleRegion == "full", "PIP_ANCHORED_REGION_NOT_FULL")
            trace?.event("fusion.pipSupport", ["accepted": result, "reason": result ? "ANCHORED_PIP_TOPOLOGY" : "PIP_ANCHORED_REGION_NOT_FULL"])
            return result
        }
        let partialRegions: Set<String> = ["left", "right", "top", "bottom", "center",
            "top_left", "top_right", "bottom_left", "bottom_right"]
        let result = traceCheck(count >= 3, "PIP_PARTIAL_COUNT_LOW")
            && traceCheck(partialRegions.contains(features.visibleRegion), "PIP_PARTIAL_REGION_UNQUALIFIED")
        trace?.event("fusion.pipSupport", ["accepted": result,
            "reason": result ? "PARTIAL_PIP_TOPOLOGY" : "FAILED_PRECEDING_CHECK"])
        return result
    }

    /// Retaining ordinary ink components must not give unqualified layout
    /// guesses the power to veto a working Core ML or another local result.
    private static func qualifiedConflictRank(_ evidence: ResolvedEvidence) -> String? {
        if let text = evidence.textRank { return text }
        return hasPipTopologyEvidence(evidence) ? evidence.layoutRank : nil
    }

    private static func qualifiedConflictSuit(_ evidence: ResolvedEvidence) -> CardFace.Suit? {
        if evidence.textRank != nil { return evidence.suit }
        let features = evidence.source.features
        let trace = RecognitionTrace.current
        let previous = trace?.candidateID
        trace?.candidateID = features.traceCandidateID
        defer { trace?.candidateID = previous }
        let count = distinctPipCount(features.pipCenters)
        guard traceCheck(count > 0, "CONFLICT_SUIT_PIP_COUNT_EMPTY"),
              traceCheck(count == features.bodyPipCount, "CONFLICT_SUIT_PIP_COUNT_MISMATCH"),
              traceCheck(features.bodySuitSupportingPips >= min(count, 3), "CONFLICT_SUIT_SUPPORT_COUNT_LOW"),
              traceCheck(features.bodySuitSupportingPips <= count, "CONFLICT_SUIT_SUPPORT_COUNT_INVALID"),
              traceCheck(Double(features.bodySuitSupportingPips) / Double(count) >= 0.60,
                         "CONFLICT_SUIT_SUPPORT_FRACTION_LOW") else { return nil }
        return evidence.suit
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
