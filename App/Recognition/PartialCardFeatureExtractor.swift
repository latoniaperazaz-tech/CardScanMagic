import CoreGraphics
import CoreImage
import CoreVideo
import Foundation
import ImageIO
import Vision

struct PartialCardFeatures {
    let boundingBox: CGRect
    let pipCenters: [CGPoint]
    let imageAspectRatio: Double
    let visibleRegion: String
    let suitProbabilities: [String: Double]
    let suitConfidence: Double
    let rankText: String?
    let rankTextConfidence: Double
    let localizationConfidence: Double
    var surfaceAnchored = false
    var pipStructureConfidence = 0.0
    var bodySuitSupportingPips = 0
    var bodyPipCount = 0
    /// Normalized x-right/y-down crop regions; not claims of hand identity.
    var uncertainRegions: [CGRect] = []
    /// Retained ink fragments whose centroid is biased by the image boundary.
    /// Their center is not an established physical pip center for topology.
    var clippedPipCandidates: [CGPoint] = []
}

/// Serialized by RecognitionEngine. Coordinates follow Vision for boxes and
/// the Python reference's top-left convention for candidate-local pip centers.
final class PartialCardFeatureExtractor {
    private struct Raster {
        let width: Int
        let height: Int
        let rgba: [UInt8]
    }

    private struct Component {
        let pixels: [Int]
        let bounds: CGRect
        let center: CGPoint
    }

    private struct Candidate {
        let image: CIImage
        let boundingBox: CGRect
        let region: String
        let confidence: Double
    }

    private struct Pip {
        let center: CGPoint
        let area: Int
        let scores: [String: Double]
        let shapeConfidence: Double
        let isClipped: Bool
        // Shape similarity gates suit evidence, but must not gate retention of
        // a geometric pip candidate used by PartialRankEstimator.
        let suitEligible: Bool
    }

    private let context = CIContext(options: [.cacheIntermediates: false])
    private static let suits = ["club", "diamond", "heart", "spade"]
    private static let gridSize = 32
    private static let references = makeReferences()
    private static let unitRect = CGRect(x: 0, y: 0, width: 1, height: 1)

    func extract(
        pixelBuffer: CVPixelBuffer,
        orientation: CGImagePropertyOrientation
    ) throws -> [PartialCardFeatures] {
        try extract(image: CIImage(cvPixelBuffer: pixelBuffer).oriented(orientation))
    }

    // The image entry point also permits deterministic tests without a camera.
    func extract(image: CIImage) throws -> [PartialCardFeatures] {
        guard !image.extent.isInfinite, !image.extent.isEmpty, !image.extent.isNull else { return [] }
        let bounded = resized(image, maximumDimension: 640)
        guard let cgImage = context.createCGImage(bounded, from: bounded.extent) else { return [] }
        let rectangleRequest = VNDetectRectanglesRequest()
        rectangleRequest.maximumObservations = 3
        rectangleRequest.minimumConfidence = 0.50
        rectangleRequest.minimumSize = 0.08
        rectangleRequest.minimumAspectRatio = 0.32
        rectangleRequest.maximumAspectRatio = 1.0
        rectangleRequest.quadratureTolerance = 32
        try VNImageRequestHandler(cgImage: cgImage, orientation: .up).perform([rectangleRequest])

        var candidates: [Candidate] = []
        for rectangle in rectangleRequest.results ?? [] {
            // A detector can invent a closing edge at the image border. Leave
            // clipped surfaces to the fallback instead of calling them full.
            let box = rectangle.boundingBox.intersection(Self.unitRect)
            guard Self.visibleRegion(for: box) == "full" else { continue }
            let size = bounded.extent.size
            func vector(_ point: CGPoint) -> CIVector {
                CIVector(x: point.x * size.width, y: point.y * size.height)
            }
            var corrected = bounded.applyingFilter("CIPerspectiveCorrection", parameters: [
                "inputTopLeft": vector(rectangle.topLeft),
                "inputTopRight": vector(rectangle.topRight),
                "inputBottomLeft": vector(rectangle.bottomLeft),
                "inputBottomRight": vector(rectangle.bottomRight)
            ])
            if corrected.extent.width > corrected.extent.height {
                corrected = corrected.oriented(.right)
            }
            let aspect = Double(corrected.extent.width / corrected.extent.height)
            guard (0.58...0.86).contains(aspect) else { continue }
            candidates.append(Candidate(
                image: resized(corrected, maximumDimension: 448),
                boundingBox: box,
                region: "full",
                confidence: Double(rectangle.confidence)
            ))
        }

        // Surface components keep cards with an off-screen corner or side;
        // VNDetectRectangles alone requires four corners and misses these.
        let surfaceImage = resized(bounded, maximumDimension: 320)
        if let raster = rasterize(surfaceImage) {
            for surface in surfaceCandidates(raster) {
                guard candidates.count < 3 else { break }
                if candidates.contains(where: { Self.overlap($0.boundingBox, surface.box) > 0.60 }) {
                    continue
                }
                let extent = bounded.extent
                let crop = CGRect(
                    x: surface.box.minX * extent.width,
                    y: surface.box.minY * extent.height,
                    width: surface.box.width * extent.width,
                    height: surface.box.height * extent.height
                ).intersection(extent)
                guard crop.width >= 16, crop.height >= 16 else { continue }
                let region = surface.region
                var cropped = bounded.cropped(to: crop)
                if region == "full", cropped.extent.width > cropped.extent.height {
                    cropped = cropped.oriented(.right)
                }
                candidates.append(Candidate(
                    image: resized(cropped, maximumDimension: 448),
                    boundingBox: surface.box,
                    region: region,
                    confidence: surface.confidence
                ))
            }
        }

        var results: [PartialCardFeatures] = []
        for candidate in candidates.prefix(3) {
            guard let raster = rasterize(candidate.image) else { continue }
            let uncertainRegions = detectUncertainRegions(raster)
            let pips = extractPips(raster).filter { pip in
                !uncertainRegions.contains { $0.contains(pip.center) }
            }
            let rank = try recognizeRank(in: candidate.image)
            guard !pips.isEmpty || rank.text != nil else { continue }
            let aspectRatio = Double(raster.width) / Double(raster.height)
            let bodyPips = pips.filter {
                !$0.isClipped
                    && !Self.isCornerIndex($0.center, aspectRatio: aspectRatio, region: candidate.region)
            }
            // Corner glyphs cannot supply the only suit evidence for a body
            // topology. OCR still uses the existing combined suit path.
            let suit = combineSuits(rank.text == nil ? bodyPips : pips)
            let dominantSuit = suit.probabilities.max { $0.value < $1.value }?.key
            let supporting = bodyPips.filter {
                $0.suitEligible && $0.shapeConfidence >= 0.60
                    && $0.scores.max(by: { $0.value < $1.value })?.key == dominantSuit
            }.count
            let areas = bodyPips.map { Double($0.area) }.sorted()
            let medianArea = areas.isEmpty ? 1 : areas[areas.count / 2]
            let consistent = areas.filter { $0 >= medianArea * 0.5 && $0 <= medianArea * 2 }.count
            let structure = bodyPips.isEmpty ? 0 : Double(consistent) / Double(bodyPips.count)
            results.append(PartialCardFeatures(
                boundingBox: candidate.boundingBox,
                pipCenters: bodyPips.map(\.center),
                imageAspectRatio: aspectRatio,
                visibleRegion: candidate.region,
                suitProbabilities: suit.probabilities,
                suitConfidence: suit.confidence,
                rankText: rank.text,
                rankTextConfidence: rank.confidence,
                localizationConfidence: candidate.confidence,
                surfaceAnchored: candidate.region == "full",
                pipStructureConfidence: structure,
                bodySuitSupportingPips: supporting,
                bodyPipCount: bodyPips.count,
                uncertainRegions: uncertainRegions,
                clippedPipCandidates: pips.filter(\.isClipped).map(\.center)
            ))
        }
        return results
    }

    private static func isCornerIndex(_ point: CGPoint, aspectRatio: Double, region: String) -> Bool {
        let cardAspect = 2.5 / 3.5
        var x = Double(point.x)
        var y = Double(point.y)
        // A single clipped axis leaves the other physical dimension intact.
        // Reconstruct that axis before applying index-strip exclusions so the
        // enlarged corner of a partial card is not counted as a body pip.
        switch region {
        case "full": break
        case "left", "right":
            let fraction = aspectRatio / cardAspect
            guard fraction <= 1.08 else { return false }
            x = x * min(1, fraction) + (region == "right" ? max(0, 1 - fraction) : 0)
        case "top", "bottom":
            let fraction = cardAspect / aspectRatio
            guard fraction <= 1.08 else { return false }
            y = y * min(1, fraction) + (region == "bottom" ? max(0, 1 - fraction) : 0)
        default:
            // Both axes clipped: absolute index position is not established.
            return false
        }
        return (x < 0.20 || x > 0.80) && (y < 0.30 || y > 0.70)
    }

    static func visibleRegion(for box: CGRect) -> String {
        let left = box.minX <= 0.012
        let right = box.maxX >= 0.988
        let top = box.maxY >= 0.988
        let bottom = box.minY <= 0.012
        switch (left, right, top, bottom) {
        case (false, false, false, false): return "full"
        case (false, true, false, false): return "left"
        case (true, false, false, false): return "right"
        case (false, false, false, true): return "top"
        case (false, false, true, false): return "bottom"
        case (false, true, false, true): return "top_left"
        case (true, false, false, true): return "top_right"
        case (false, true, true, false): return "bottom_left"
        case (true, false, true, false): return "bottom_right"
        default: return "unknown"
        }
    }

    private func resized(_ image: CIImage, maximumDimension: CGFloat) -> CIImage {
        let extent = image.extent
        guard !extent.isInfinite, !extent.isEmpty else { return image }
        let translated = image.transformed(by: CGAffineTransform(
            translationX: -extent.minX, y: -extent.minY
        ))
        let scale = min(1, maximumDimension / max(extent.width, extent.height))
        return translated.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
    }

    private func rasterize(_ image: CIImage) -> Raster? {
        guard let cg = context.createCGImage(image, from: image.extent) else { return nil }
        let width = cg.width
        let height = cg.height
        guard width >= 3, height >= 3 else { return nil }
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        let rendered = rgba.withUnsafeMutableBytes { bytes -> Bool in
            guard let canvas = CGContext(
                data: bytes.baseAddress,
                width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                    | CGBitmapInfo.byteOrder32Big.rawValue
            ) else { return false }
            canvas.draw(cg, in: CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
            return true
        }
        return rendered ? Raster(width: width, height: height, rgba: rgba) : nil
    }

    private func surfaceCandidates(_ raster: Raster) -> [(box: CGRect, region: String, confidence: Double)] {
        let count = raster.width * raster.height
        var values = [Int](repeating: 0, count: 256)
        for index in 0..<count {
            let offset = index * 4
            values[Int(max(raster.rgba[offset], raster.rgba[offset + 1], raster.rgba[offset + 2]))] += 1
        }
        let floor = min(215, max(125, percentile(values, fraction: 0.58)))
        var mask = [UInt8](repeating: 0, count: count)
        for index in 0..<count {
            let offset = index * 4
            let channels = (Int(raster.rgba[offset]), Int(raster.rgba[offset + 1]), Int(raster.rgba[offset + 2]))
            let bright = max(channels.0, channels.1, channels.2)
            let dark = min(channels.0, channels.1, channels.2)
            let saturation = 255 * (bright - dark) / max(1, bright)
            if (saturation < 82 && bright >= floor)
                || (saturation < 42 && bright >= max(112, floor - 24)) {
                mask[index] = 1
            }
        }
        return components(mask, width: raster.width, height: raster.height)
            .filter { $0.pixels.count >= max(120, count / 75) }
            .sorted { $0.pixels.count > $1.pixels.count }
            .prefix(6)
            .compactMap { component in
                let box = component.bounds
                guard box.width >= 16, box.height >= 16 else { return nil }
                let occupancy = Double(component.pixels.count) / Double(box.width * box.height)
                guard occupancy >= 0.46 else { return nil }
                let normalized = CGRect(
                    x: box.minX / CGFloat(raster.width),
                    y: 1 - box.maxY / CGFloat(raster.height),
                    width: box.width / CGFloat(raster.width),
                    height: box.height / CGFloat(raster.height)
                )
                var region = Self.visibleRegion(for: normalized)
                let aspect = Double(min(box.width, box.height) / max(box.width, box.height))
                // A bright bounding box is not proof of four physical card
                // edges. Avoid anchoring an arbitrary white patch as a full
                // card when its surface is irregular or its aspect disagrees.
                if region == "full", occupancy < 0.78 || !(0.58...0.86).contains(aspect) {
                    region = "unknown"
                }
                let confidence = region == "unknown" ? 0.36 : min(0.78, 0.44 + occupancy * 0.34)
                return (normalized, region, confidence)
            }
    }

    private func extractPips(_ raster: Raster) -> [Pip] {
        let count = raster.width * raster.height
        var histogram = [Int](repeating: 0, count: 256)
        for index in 0..<count {
            let offset = index * 4
            let gray = (Int(raster.rgba[offset]) * 77 + Int(raster.rgba[offset + 1]) * 150
                + Int(raster.rgba[offset + 2]) * 29) >> 8
            histogram[gray] += 1
        }
        let whiteLevel = percentile(histogram, fraction: 0.72)
        guard whiteLevel >= 100 else { return [] }
        let darkThreshold = min(165, max(38, whiteLevel - 42))
        var redMask = [UInt8](repeating: 0, count: count)
        var darkMask = redMask
        for index in 0..<count {
            let offset = index * 4
            let red = Int(raster.rgba[offset])
            let green = Int(raster.rgba[offset + 1])
            let blue = Int(raster.rgba[offset + 2])
            let gray = (red * 77 + green * 150 + blue * 29) >> 8
            let isRed = red >= 45 && red - green >= 20 && red - blue >= 16
            redMask[index] = isRed ? 1 : 0
            darkMask[index] = !isRed && gray <= darkThreshold ? 1 : 0
        }

        var pips: [Pip] = []
        for (mask, isRed) in [(redMask, true), (darkMask, false)] {
            let plausible = components(mask, width: raster.width, height: raster.height).filter {
                $0.pixels.count >= max(8, count / 14000)
                    && Double($0.pixels.count) <= Double(count) * 0.095
                    && $0.bounds.width >= 3 && $0.bounds.height >= 3
            }.sorted { $0.pixels.count > $1.pixels.count }
            for component in plausible.prefix(24) {
                let area = component.pixels.count
                let box = component.bounds
                guard area >= max(8, count / 14000), Double(area) <= Double(count) * 0.095,
                      box.width >= 3, box.height >= 3 else { continue }
                let aspect = Double(box.width / box.height)
                let occupancy = Double(area) / Double(box.width * box.height)
                // Thin card outlines and long motion trails contain location,
                // not enough shape information to classify a suit.
                guard aspect > 0.30, aspect < 2.4, occupancy > 0.20 else { continue }
                let shape = classify(component, imageWidth: raster.width, isRed: isRed)
                let center = CGPoint(x: component.center.x / CGFloat(raster.width),
                                     y: component.center.y / CGFloat(raster.height))
                if pips.contains(where: {
                    hypot($0.center.x - center.x, $0.center.y - center.y) < 0.020
                }) { continue }
                let isClipped = box.minX <= 1 || box.minY <= 1
                    || box.maxX >= CGFloat(raster.width - 1) || box.maxY >= CGFloat(raster.height - 1)
                pips.append(Pip(center: center, area: area, scores: shape.probabilities,
                                shapeConfidence: shape.confidence * (isClipped ? 0.2 : 1),
                                isClipped: isClipped,
                                suitEligible: shape.similarity >= 0.61))
            }
        }
        return Array(pips.sorted { $0.area > $1.area }.prefix(18)).sorted {
            $0.center.y == $1.center.y ? $0.center.x < $1.center.x : $0.center.y < $1.center.y
        }
    }

    /// Large non-paper components are uncertain visibility, including those
    /// entering from an edge. A bounded tile mask follows the component rather
    /// than marking its entire bounding box (which could hide visible pips).
    private func detectUncertainRegions(_ raster: Raster) -> [CGRect] {
        let count = raster.width * raster.height
        var histogram = [Int](repeating: 0, count: 256)
        for index in 0..<count {
            let offset = index * 4
            histogram[Int(max(raster.rgba[offset], max(raster.rgba[offset + 1], raster.rgba[offset + 2])))] += 1
        }
        let whiteLevel = percentile(histogram, fraction: 0.72)
        var mask = [UInt8](repeating: 0, count: count)
        for index in 0..<count {
            let offset = index * 4
            let r = Int(raster.rgba[offset])
            let g = Int(raster.rgba[offset + 1])
            let b = Int(raster.rgba[offset + 2])
            let bright = max(r, max(g, b))
            let dark = min(r, min(g, b))
            let saturation = 255 * (bright - dark) / max(1, bright)
            mask[index] = (bright < whiteLevel - 42 || saturation > 65) ? 1 : 0
        }
        let grid = 16
        var foreground = [Int](repeating: 0, count: grid * grid)
        for component in components(mask, width: raster.width, height: raster.height)
            where component.pixels.count >= max(32, count / 35) {
            // An unusually large Ace glyph is still printed evidence, not an
            // occluder. This exception does not relax suit classification.
            let sample = component.pixels[component.pixels.count / 2] * 4
            let r = Int(raster.rgba[sample]), g = Int(raster.rgba[sample + 1])
            let b = Int(raster.rgba[sample + 2])
            let shape = classify(component, imageWidth: raster.width,
                                 isRed: r >= 45 && r - g >= 20 && r - b >= 16)
            if shape.similarity >= 0.61 && shape.confidence >= 0.60 { continue }
            for index in component.pixels {
                let x = min(grid - 1, (index % raster.width) * grid / raster.width)
                let y = min(grid - 1, (index / raster.width) * grid / raster.height)
                foreground[y * grid + x] += 1
            }
        }
        let cellArea = Double(count) / Double(grid * grid)
        return foreground.indices.compactMap { index in
            guard Double(foreground[index]) >= cellArea * 0.15 else { return nil }
            return CGRect(x: Double(index % grid) / Double(grid),
                          y: Double(index / grid) / Double(grid),
                          width: 1.0 / Double(grid), height: 1.0 / Double(grid))
        }
    }

    private func classify(
        _ component: Component, imageWidth: Int, isRed: Bool
    ) -> (probabilities: [String: Double], similarity: Double, confidence: Double) {
        let grid = Self.gridSize
        var normalized = [Bool](repeating: false, count: grid * grid)
        let pixels = Set(component.pixels)
        let box = component.bounds
        for y in 0..<grid {
            for x in 0..<grid {
                let sampleX = Int(box.minX + (CGFloat(x) + 0.5) * box.width / CGFloat(grid))
                let sampleY = Int(box.minY + (CGFloat(y) + 0.5) * box.height / CGFloat(grid))
                normalized[y * grid + x] = pixels.contains(sampleY * imageWidth + sampleX)
            }
        }
        var shapeScores: [String: Double] = [:]
        for suit in Self.suits {
            guard let reference = Self.references[suit] else { continue }
            var best = 0.0
            for rotation in 0..<4 {
                var intersection = 0
                var union = 0
                for y in 0..<grid {
                    for x in 0..<grid {
                        let index: Int
                        switch rotation {
                        case 1: index = x * grid + grid - 1 - y
                        case 2: index = (grid - 1 - y) * grid + grid - 1 - x
                        case 3: index = (grid - 1 - x) * grid + y
                        default: index = y * grid + x
                        }
                        let a = normalized[y * grid + x]
                        let b = reference[index]
                        if a && b { intersection += 1 }
                        if a || b { union += 1 }
                    }
                }
                best = max(best, Double(intersection) / Double(max(1, union)))
            }
            shapeScores[suit] = best
        }
        let colorSuits = isRed ? ["diamond", "heart"] : ["club", "spade"]
        let ordered = colorSuits.compactMap { shapeScores[$0] }.sorted(by: >)
        let best = ordered.first ?? 0
        let gap = best - (ordered.dropFirst().first ?? best)
        let shapeConfidence = min(1, max(0, (best - 0.57) / 0.32)) * min(1, gap / 0.18)
        let logits = Self.suits.map { suit in
            11 * (shapeScores[suit] ?? 0) + (colorSuits.contains(suit) ? 1.6 : -1.6)
        }
        let maximum = logits.max() ?? 0
        let weights = logits.map { exp($0 - maximum) }
        let total = weights.reduce(0, +)
        let probabilities = Dictionary(uniqueKeysWithValues: zip(Self.suits, weights.map { $0 / total }))
        return (probabilities, best, shapeConfidence)
    }

    private func combineSuits(_ pips: [Pip]) -> (probabilities: [String: Double], confidence: Double) {
        // Low-similarity components remain valid geometric pip candidates,
        // but cannot contribute suit confidence. This preserves the existing
        // suit threshold semantics while allowing topology-only rank evidence.
        let suitPips = pips.filter(\.suitEligible)
        guard !suitPips.isEmpty else {
            return (Dictionary(uniqueKeysWithValues: Self.suits.map { ($0, 0.25) }), 0)
        }
        var accumulated = Dictionary(uniqueKeysWithValues: Self.suits.map { ($0, 0.0) })
        let largest = Double(suitPips.map(\.area).max() ?? 1)
        var totalWeight = 0.0
        var confidenceSum = 0.0
        for pip in suitPips {
            let weight = (0.3 + 0.7 * Double(pip.area) / largest) * max(0.1, pip.shapeConfidence)
            totalWeight += weight
            confidenceSum += weight * pip.shapeConfidence
            for suit in Self.suits {
                accumulated[suit, default: 0] += weight * (pip.scores[suit] ?? 0)
            }
        }
        let probabilities = accumulated.mapValues { $0 / totalWeight }
        let ordered = probabilities.values.sorted(by: >)
        let separation = (ordered.first ?? 0) - (ordered.dropFirst().first ?? 0)
        return (probabilities, confidenceSum / totalWeight * min(1, separation / 0.35))
    }

    private func recognizeRank(in image: CIImage) throws -> (text: String?, confidence: Double) {
        guard let cg = context.createCGImage(image, from: image.extent) else { return (nil, 0) }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .fast
        request.usesLanguageCorrection = false
        request.recognitionLanguages = ["en-US"]
        request.minimumTextHeight = 0.035
        var ranks: [String: Double] = [:]
        for orientation in [CGImagePropertyOrientation.up, .down] {
            try VNImageRequestHandler(cgImage: cg, orientation: orientation).perform([request])
            for observation in request.results ?? [] {
                let box = observation.boundingBox
                // Rank letters in the middle of a scene are not corner indexes.
                guard box.width <= 0.35, box.height <= 0.32,
                      box.midX < 0.28 || box.midX > 0.72,
                      box.midY < 0.33 || box.midY > 0.67,
                      let candidate = observation.topCandidates(1).first else { continue }
                let rank = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
                guard ["A", "2", "3", "4", "5", "6", "7", "8", "9", "10", "J", "Q", "K"].contains(rank),
                      candidate.confidence >= 0.50 else { continue }
                ranks[rank] = max(ranks[rank] ?? 0, Double(candidate.confidence))
            }
            if !ranks.isEmpty { break }
        }
        let ordered = ranks.sorted { $0.value > $1.value }
        guard let best = ordered.first else { return (nil, 0) }
        if ordered.count > 1, best.value - ordered[1].value < 0.20 { return (nil, 0) }
        return (best.key, best.value)
    }

    private func percentile(_ histogram: [Int], fraction: Double) -> Int {
        let target = Int(Double(histogram.reduce(0, +)) * fraction)
        var cumulative = 0
        for value in 0..<histogram.count {
            cumulative += histogram[value]
            if cumulative >= target { return value }
        }
        return 255
    }

    private func components(_ mask: [UInt8], width: Int, height: Int) -> [Component] {
        var visited = [Bool](repeating: false, count: mask.count)
        var result: [Component] = []
        for seed in mask.indices where mask[seed] != 0 && !visited[seed] {
            var queue = [seed]
            visited[seed] = true
            var cursor = 0
            var minX = width
            var minY = height
            var maxX = 0
            var maxY = 0
            var sumX = 0
            var sumY = 0
            while cursor < queue.count {
                let index = queue[cursor]
                cursor += 1
                let x = index % width
                let y = index / width
                minX = min(minX, x)
                maxX = max(maxX, x)
                minY = min(minY, y)
                maxY = max(maxY, y)
                sumX += x
                sumY += y
                for dy in -1...1 {
                    let nextY = y + dy
                    guard nextY >= 0, nextY < height else { continue }
                    for dx in -1...1 {
                        let nextX = x + dx
                        guard nextX >= 0, nextX < width else { continue }
                        let next = nextY * width + nextX
                        if mask[next] != 0 && !visited[next] {
                            visited[next] = true
                            queue.append(next)
                        }
                    }
                }
            }
            guard queue.count >= 8 else { continue }
            result.append(Component(
                pixels: queue,
                bounds: CGRect(x: CGFloat(minX), y: CGFloat(minY),
                               width: CGFloat(maxX - minX + 1), height: CGFloat(maxY - minY + 1)),
                center: CGPoint(x: CGFloat(sumX) / CGFloat(queue.count),
                                y: CGFloat(sumY) / CGFloat(queue.count))
            ))
        }
        return result
    }

    private static func overlap(_ first: CGRect, _ second: CGRect) -> CGFloat {
        let intersection = first.intersection(second)
        guard !intersection.isNull else { return 0 }
        let area = intersection.width * intersection.height
        let union = first.width * first.height + second.width * second.height - area
        return union > 0 ? area / union : 0
    }

    private static func makeReferences() -> [String: [Bool]] {
        let sourceSize = 128
        func circle(_ x: Double, _ y: Double, _ cx: Double, _ cy: Double, _ radius: Double) -> Bool {
            (x - cx) * (x - cx) + (y - cy) * (y - cy) <= radius * radius
        }
        func triangle(_ x: Double, _ y: Double, baseY: Double, tipY: Double,
                      halfWidth: Double) -> Bool {
            let position = (y - tipY) / (baseY - tipY)
            return position >= 0 && position <= 1 && abs(x - 64) <= halfWidth * position
        }
        var references: [String: [Bool]] = [:]
        for suit in suits {
            var source = [Bool](repeating: false, count: sourceSize * sourceSize)
            var minX = sourceSize
            var maxX = 0
            var minY = sourceSize
            var maxY = 0
            for iy in 0..<sourceSize {
                for ix in 0..<sourceSize {
                    let x = Double(ix)
                    let y = Double(iy)
                    let ink: Bool
                    switch suit {
                    case "diamond":
                        let horizontal: Double = abs(x - 64.0) / 44.0
                        let vertical: Double = abs(y - 64.0) / 52.0
                        ink = horizontal + vertical <= 1.0
                    case "heart":
                        ink = circle(x, y, 39, 43, 25) || circle(x, y, 89, 43, 25)
                            || triangle(x, y, baseY: 45, tipY: 118, halfWidth: 46)
                    case "club":
                        ink = circle(x, y, 64, 32, 25) || circle(x, y, 40, 60, 25)
                            || circle(x, y, 88, 60, 25) || (abs(x - 64) <= 9 && y >= 60 && y <= 111)
                            || triangle(x, y, baseY: 114, tipY: 86, halfWidth: 27)
                    default:
                        ink = circle(x, y, 39, 70, 25) || circle(x, y, 89, 70, 25)
                            || triangle(x, y, baseY: 70, tipY: 10, halfWidth: 46)
                            || (abs(x - 64) <= 8 && y >= 70 && y <= 111)
                            || triangle(x, y, baseY: 114, tipY: 91, halfWidth: 25)
                    }
                    if ink {
                        source[iy * sourceSize + ix] = true
                        minX = min(minX, ix)
                        maxX = max(maxX, ix)
                        minY = min(minY, iy)
                        maxY = max(maxY, iy)
                    }
                }
            }
            var reference = [Bool](repeating: false, count: gridSize * gridSize)
            for y in 0..<gridSize {
                for x in 0..<gridSize {
                    let sx = minX + Int((Double(x) + 0.5) * Double(maxX - minX + 1) / Double(gridSize))
                    let sy = minY + Int((Double(y) + 0.5) * Double(maxY - minY + 1) / Double(gridSize))
                    reference[y * gridSize + x] = source[sy * sourceSize + sx]
                }
            }
            references[suit] = reference
        }
        return references
    }
}
