import CoreGraphics
import Foundation

struct PartialRankCandidate {
    let rank: String
    let probability: Double
    let score: Double
    let matchedCount: Int
}

struct PartialRankResult {
    let rank: String?
    let confidence: Double
    let candidates: [PartialRankCandidate]
}

enum PartialRankEstimator {
    private static let cardAspect = 2.5 / 3.5
    private static let tolerance = 0.055
    private static let maximumPairHypotheses = 384

    private struct Point {
        let x: Double
        let y: Double
    }

    private struct Template {
        let rank: String
        let points: [Point]
        var centerIndex: Int? {
            points.firstIndex { abs($0.x - 0.5) < 0.04 && abs($0.y - 0.5) < 0.04 }
        }
    }

    private struct Transform {
        let a: Double
        let b: Double
        let tx: Double
        let ty: Double
        let plausibility: Double

        func apply(_ point: Point) -> Point {
            let x = point.x * PartialRankEstimator.cardAspect
            return Point(x: a * x - b * point.y + tx, y: b * x + a * point.y + ty)
        }
    }

    private struct Match {
        let observed: Int
        let template: Int
        let distance: Double
    }

    private struct Score {
        var value = 0.0
        var matchedCount = 0
        var visibleMissingCount = 0
        var uncertainMissingCount = 0
        var matchQuality = 0.0
    }

    private static let templates: [Template] = [
        makeTemplate("A", [(0.5, 0.5)]),
        makeTemplate("2", [(0.5, 0.18), (0.5, 0.82)]),
        makeTemplate("3", [(0.5, 0.18), (0.5, 0.5), (0.5, 0.82)]),
        makeTemplate("4", [(0.3, 0.18), (0.7, 0.18), (0.3, 0.82), (0.7, 0.82)]),
        makeTemplate("5", [(0.3, 0.18), (0.7, 0.18), (0.5, 0.5), (0.3, 0.82), (0.7, 0.82)]),
        makeTemplate("6", [(0.3, 0.18), (0.7, 0.18), (0.3, 0.5), (0.7, 0.5), (0.3, 0.82), (0.7, 0.82)]),
        makeTemplate("7", [(0.3, 0.18), (0.7, 0.18), (0.5, 0.34), (0.3, 0.5), (0.7, 0.5), (0.3, 0.82), (0.7, 0.82)]),
        makeTemplate("8", [(0.3, 0.18), (0.7, 0.18), (0.5, 0.34), (0.3, 0.5), (0.7, 0.5), (0.5, 0.66), (0.3, 0.82), (0.7, 0.82)]),
        makeTemplate("9", [(0.3, 0.15), (0.7, 0.15), (0.3, 0.38), (0.7, 0.38), (0.5, 0.5), (0.3, 0.62), (0.7, 0.62), (0.3, 0.85), (0.7, 0.85)]),
        makeTemplate("10", [(0.3, 0.15), (0.7, 0.15), (0.5, 0.29), (0.3, 0.38), (0.7, 0.38), (0.3, 0.62), (0.7, 0.62), (0.5, 0.71), (0.3, 0.85), (0.7, 0.85)])
    ]

    /// Input points use x-right/y-down coordinates within the upright image crop.
    /// Region hints refer to which part of the card is visible, not image quadrants.
    /// Uncertain rectangles use the same normalized crop coordinates as the points.
    /// A surface anchor requires a complete, upright, geometrically located card;
    /// it supplies the card coordinate system independently of the detected pips.
    static func infer(
        points: [CGPoint],
        imageAspectRatio: Double,
        visibleRegion: String = "unknown",
        uncertainRegions: [CGRect] = [],
        surfaceAnchored: Bool = false
    ) -> PartialRankResult {
        guard imageAspectRatio.isFinite, imageAspectRatio > 0 else { return emptyResult() }
        let viewport = Point(x: min(imageAspectRatio, 1), y: min(1 / imageAspectRatio, 1))
        let region = normalizedRegion(visibleRegion)
        let uncertainty = uncertainRegions.compactMap { rect -> CGRect? in
            let value = rect.standardized
            guard value.minX.isFinite, value.minY.isFinite, value.maxX.isFinite, value.maxY.isFinite,
                  value.width > 0, value.height > 0 else { return nil }
            let clipped = value.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
            return clipped.isNull || clipped.isEmpty ? nil : clipped
        }
        var observed: [Point] = []
        for point in points.prefix(64) {
            let x = Double(point.x)
            let y = Double(point.y)
            guard x.isFinite, y.isFinite, (0...1).contains(x), (0...1).contains(y) else { continue }
            let candidate = Point(x: x * viewport.x, y: y * viewport.y)
            guard !observed.contains(where: { hypot($0.x - candidate.x, $0.y - candidate.y) < 0.012 }) else { continue }
            observed.append(candidate)
            if observed.count == 14 { break }
        }
        guard !observed.isEmpty else { return emptyResult() }
        // Canonical order makes the capped hypothesis search independent of detector ordering.
        observed.sort { $0.y == $1.y ? $0.x < $1.x : $0.y < $1.y }
        let hasSurfaceAnchor = surfaceAnchored && region == "full"
        let scores = templates.map { template in
            if hasSurfaceAnchor {
                return anchoredScore(template: template, observed: observed, viewport: viewport,
                                     uncertainRegions: uncertainty)
            }
            return bestScore(template: template, observed: observed, viewport: viewport,
                             region: region, uncertainRegions: uncertainty)
        }
        let maximum = scores.map(\.value).max() ?? 0
        let temperature = observed.count >= 4 ? 0.065 : 0.085
        let weights = scores.map { exp(($0.value - maximum) / temperature) }
        let totalWeight = weights.reduce(0, +)
        var candidates: [PartialRankCandidate] = []
        for index in templates.indices {
            let candidate = PartialRankCandidate(rank: templates[index].rank,
                probability: weights[index] / totalWeight,
                score: scores[index].value, matchedCount: scores[index].matchedCount)
            candidates.append(candidate)
        }
        candidates.sort { lhs, rhs in
            if lhs.probability == rhs.probability { return lhs.rank < rhs.rank }
            return lhs.probability > rhs.probability
        }
        let best = candidates[0]
        let margin = best.probability - candidates[1].probability
        let centeredFullAce = observed.count == 1 && region == "full" && best.rank == "A"
            && hypot(observed[0].x / viewport.x - 0.5, observed[0].y / viewport.y - 0.5) < 0.12
        let bestIndex = templates.firstIndex { $0.rank == best.rank }!
        let winningScore = scores[bestIndex]
        // One or two pips cannot locate a card on their own. A separately
        // established surface can: its visible empty positions distinguish
        // A/2 from larger layouts without fabricating additional observed pips.
        let anchoredSupport = hasSurfaceAnchor && winningScore.matchedCount == observed.count
            && winningScore.visibleMissingCount == 0 && winningScore.matchQuality >= 0.85
        let support = anchoredSupport ? 1 : (centeredFullAce ? 0.75 : min(1, Double(observed.count) / 3))
        let confidence = min(1, support * (0.52 * best.score + 0.30 * best.probability + 0.18 * min(1, margin * 4)))
        // If all distinguishing pips could be hidden, structural preferences
        // must not turn that missing information into a specific rank.
        let ambiguousOcclusion = !uncertainty.isEmpty && scores.enumerated().contains { index, score in
            index != bestIndex && score.matchedCount == observed.count
                && score.visibleMissingCount == 0 && score.matchQuality >= 0.85
                && (score.uncertainMissingCount > 0 || winningScore.uncertainMissingCount > 0)
        }
        // Similarity fits can explain coincident subsets of multiple ranks. A ranked
        // candidate alone is not evidence that a blurred or partial card is resolved.
        let resolved = !ambiguousOcclusion && ((centeredFullAce && !hasSurfaceAnchor && uncertainty.isEmpty) || (
            (observed.count >= 2 || (anchoredSupport && best.rank == "A"))
                && best.matchedCount == observed.count && best.score >= 0.72
                && confidence >= 0.52 && best.probability >= 0.27 && margin >= 0.055
                && (observed.count >= 3 || (region == "full" && best.probability >= 0.42))
        ))
        return PartialRankResult(rank: resolved ? best.rank : nil, confidence: confidence, candidates: candidates)
    }

    private static func makeTemplate(_ rank: String, _ coordinates: [(Double, Double)]) -> Template {
        Template(rank: rank, points: coordinates.map { Point(x: $0.0, y: $0.1) })
    }

    private static func emptyResult() -> PartialRankResult {
        PartialRankResult(rank: nil, confidence: 0, candidates: templates.map {
            PartialRankCandidate(rank: $0.rank, probability: 0.1, score: 0, matchedCount: 0)
        })
    }

    private static func normalizedRegion(_ region: String) -> String {
        let value = region.lowercased()
        return ["full", "left", "right", "top", "bottom", "top_left", "top_right",
                "bottom_left", "bottom_right", "center"].contains(value) ? value : "unknown"
    }

    private static func bestScore(template: Template, observed: [Point], viewport: Point,
                                  region: String, uncertainRegions: [CGRect]) -> Score {
        var best = Score()
        if observed.count < 2 || template.points.count < 2 {
            for source in template.points {
                for target in observed {
                    for scale in [0.55, 0.85, 1.15, 1.65, 2.4] {
                        for angle in [0.0, 15, -15, 90, 180, 270] {
                            let radians = angle * .pi / 180
                            let a = scale * cos(radians)
                            let b = scale * sin(radians)
                            let transform = Transform(a: a, b: b,
                                tx: target.x - a * source.x * cardAspect + b * source.y,
                                ty: target.y - b * source.x * cardAspect - a * source.y, plausibility: 0.52)
                            let score = score(template: template, observed: observed, viewport: viewport,
                                              transform: transform, region: region,
                                              uncertainRegions: uncertainRegions)
                            if score.value > best.value { best = score }
                        }
                    }
                }
            }
            return best
        }

        let templatePairs = template.points.count * (template.points.count - 1) / 2
        let observedPairs = observed.count * (observed.count - 1) / 2
        let total = templatePairs * observedPairs * 2
        let budget = min(total, maximumPairHypotheses)
        var ordinal = 0
        var sample = 0
        for sourceA in 0..<(template.points.count - 1) {
            for sourceB in (sourceA + 1)..<template.points.count {
                for targetA in 0..<(observed.count - 1) {
                    for targetB in (targetA + 1)..<observed.count {
                        for reverse in [false, true] {
                            let selected = sample < budget && ordinal == sample * total / budget
                            ordinal += 1
                            guard selected else { continue }
                            sample += 1
                            guard let transform = similarity(
                                sourceA: template.points[sourceA], sourceB: template.points[sourceB],
                                targetA: observed[reverse ? targetB : targetA],
                                targetB: observed[reverse ? targetA : targetB]
                            ) else { continue }
                            let score = score(template: template, observed: observed, viewport: viewport,
                                              transform: transform, region: region,
                                              uncertainRegions: uncertainRegions)
                            if score.value > best.value { best = score }
                        }
                    }
                }
            }
        }
        return best
    }

    private static func anchoredScore(template: Template, observed: [Point], viewport: Point,
                                      uncertainRegions: [CGRect]) -> Score {
        var best = Score()
        // The card is already upright and rectified. Both ends are valid,
        // including the asymmetric extra pip on a seven.
        for upsideDown in [false, true] {
            let projected = template.points.map { point in
                Point(x: (upsideDown ? 1 - point.x : point.x) * viewport.x,
                      y: (upsideDown ? 1 - point.y : point.y) * viewport.y)
            }
            let candidate = score(template: template, observed: observed, viewport: viewport,
                                  projected: projected, plausibility: 1, region: "full",
                                  uncertainRegions: uncertainRegions)
            if candidate.value > best.value { best = candidate }
        }
        return best
    }

    private static func similarity(sourceA: Point, sourceB: Point, targetA: Point, targetB: Point) -> Transform? {
        let sx = (sourceB.x - sourceA.x) * cardAspect
        let sy = sourceB.y - sourceA.y
        let tx = targetB.x - targetA.x
        let ty = targetB.y - targetA.y
        let sourceLength = hypot(sx, sy)
        let targetLength = hypot(tx, ty)
        guard sourceLength >= 0.045, targetLength >= 0.025 else { return nil }
        let scale = targetLength / sourceLength
        guard (0.16...6).contains(scale) else { return nil }
        let denominator = sourceLength * sourceLength
        let a = (sx * tx + sy * ty) / denominator
        let b = (sx * ty - sy * tx) / denominator
        return Transform(a: a, b: b, tx: targetA.x - a * sourceA.x * cardAspect + b * sourceA.y,
                         ty: targetA.y - b * sourceA.x * cardAspect - a * sourceA.y,
                         plausibility: exp(-0.08 * abs(log(scale))))
    }

    private static func score(template: Template, observed: [Point], viewport: Point,
                              transform: Transform, region: String,
                              uncertainRegions: [CGRect]) -> Score {
        let projected = template.points.map { transform.apply($0) }
        return score(template: template, observed: observed, viewport: viewport,
                     projected: projected, plausibility: transform.plausibility,
                     region: region, uncertainRegions: uncertainRegions)
    }

    private static func score(template: Template, observed: [Point], viewport: Point,
                              projected: [Point], plausibility: Double, region: String,
                              uncertainRegions: [CGRect]) -> Score {
        var possible: [Match] = []
        for (observedIndex, point) in observed.enumerated() {
            for (templateIndex, target) in projected.enumerated() {
                let distance = hypot(point.x - target.x, point.y - target.y)
                if distance <= tolerance {
                    possible.append(Match(observed: observedIndex, template: templateIndex, distance: distance))
                }
            }
        }
        possible.sort { $0.distance < $1.distance }
        var observedMask = 0
        var templateMask = 0
        var matched = 0
        var distanceTotal = 0.0
        for match in possible {
            guard observedMask & (1 << match.observed) == 0, templateMask & (1 << match.template) == 0 else { continue }
            observedMask |= 1 << match.observed
            templateMask |= 1 << match.template
            matched += 1
            distanceTotal += exp(-pow(match.distance / tolerance, 2))
        }
        let margin = tolerance * 0.4
        var visibleMask = 0
        var uncertainMask = 0
        for (index, point) in projected.enumerated() where point.x >= -margin && point.y >= -margin
            && point.x <= viewport.x + margin && point.y <= viewport.y + margin {
            visibleMask |= 1 << index
            if isUncertain(point, viewport: viewport, regions: uncertainRegions) {
                uncertainMask |= 1 << index
            }
        }
        // A detected pip stays positive evidence even inside an uncertain
        // rectangle. Only unseen points may be excused as possibly occluded.
        let uncertainMissingMask = uncertainMask & ~templateMask
        let expectedMask = (region == "full" ? (1 << template.points.count) - 1 : visibleMask)
            & ~uncertainMissingMask
        let cropMissing = (visibleMask & ~uncertainMissingMask & ~templateMask).nonzeroBitCount
        let missing = (expectedMask & ~templateMask).nonzeroBitCount
        let expected = Double(expectedMask.nonzeroBitCount)
        let coverage = Double(matched) / Double(observed.count)
        let unexpected = exp(-1.15 * Double(observed.count - matched))
        let distance = matched > 0 ? distanceTotal / Double(matched) : 0
        let visibleCoverage = max(0, 1 - Double(missing) / max(expected, 1))
        let countScore = exp(-abs(Double(observed.count) - expected) / max(1.25, expected * 0.48))
        var centerScore = 0.7
        if let index = template.centerIndex {
            if templateMask & (1 << index) != 0 {
                centerScore = 1
            } else if uncertainMissingMask & (1 << index) != 0 {
                centerScore = 0.7
            } else {
                centerScore = cropMissing > 0 ? 0.45 : 0.2
            }
        }
        var middleMatched = false
        var compatible = 0
        for (index, point) in template.points.enumerated() where templateMask & (1 << index) != 0 {
            if abs(point.x - 0.5) < 0.04 || abs(point.y - 0.5) < 0.04 { middleMatched = true }
            if regionContains(region, point: point) { compatible += 1 }
        }
        let middleUncertain = template.points.enumerated().contains { index, point in
            (abs(point.x - 0.5) < 0.04 || abs(point.y - 0.5) < 0.04)
                && uncertainMissingMask & (1 << index) != 0
        }
        let middleScore = middleMatched ? 1 : (middleUncertain ? 0.7 : (matched >= 2 ? 0.58 : 0.35))
        var relevantSymmetry = 0
        var symmetryTotal = 0.0
        for (index, point) in template.points.enumerated() where point.x < 0.49 {
            if let mirror = template.points.firstIndex(where: { abs($0.x - (1 - point.x)) < 0.001 && abs($0.y - point.y) < 0.001 }),
               visibleMask & (1 << index) != 0, visibleMask & (1 << mirror) != 0,
               uncertainMissingMask & ((1 << index) | (1 << mirror)) == 0 {
                relevantSymmetry += 1
                let pairCount = (templateMask & ((1 << index) | (1 << mirror))).nonzeroBitCount
                symmetryTotal += pairCount == 2 ? 1 : (pairCount == 1 ? 0.35 : 0)
            }
        }
        let symmetry = relevantSymmetry > 0 ? symmetryTotal / Double(relevantSymmetry) : 0.6
        let regionScore = region != "unknown" && region != "full" && matched > 0
            ? 0.065 + 0.9 * Double(compatible) / Double(matched) : 0.7
        let fit = 0.22 * coverage + 0.12 * unexpected + 0.15 * distance + 0.16 * visibleCoverage
        let support = 0.08 * countScore + 0.08 * min(1, Double(matched) / 3)
        let structure = 0.055 * centerScore + 0.035 * middleScore + 0.055 * symmetry + 0.055 * regionScore
        let value = (fit + support + structure) * plausibility
        return Score(value: min(1, max(0, value)), matchedCount: matched,
                     visibleMissingCount: missing,
                     uncertainMissingCount: uncertainMissingMask.nonzeroBitCount,
                     matchQuality: distance)
    }

    private static func isUncertain(_ point: Point, viewport: Point, regions: [CGRect]) -> Bool {
        let normalized = CGPoint(
            x: point.x / max(viewport.x, 0.0001),
            y: point.y / max(viewport.y, 0.0001))
        return regions.contains { region in
            region.contains(normalized)
        }
    }

    private static func regionContains(_ region: String, point: Point) -> Bool {
        if region == "center" { return (0.23...0.77).contains(point.x) && (0.23...0.77).contains(point.y) }
        if region.contains("left") && point.x > 0.6 { return false }
        if region.contains("right") && point.x < 0.4 { return false }
        if region.contains("top") && point.y > 0.6 { return false }
        if region.contains("bottom") && point.y < 0.4 { return false }
        return true
    }
}
