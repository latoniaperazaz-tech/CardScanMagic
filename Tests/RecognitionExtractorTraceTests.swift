import CoreGraphics
import CoreImage
import Foundation
import XCTest
@testable import CardScanMagic

/// These are observer equivalence and lifecycle tests through the real image
/// extractor. Generated images do not establish real-device card recall.
final class RecognitionExtractorTraceTests: XCTestCase {
    func testTraceOnOffPreservesEveryFeatureAndActualOCRClassifyCallCount() throws {
        let image = fixture(drawPips: true)
        let (without, offCounts) = try RecognitionCallProbe.measure {
            try RecognitionTrace.withCurrent(nil) { try PartialCardFeatureExtractor().extract(image: image) }
        }
        let trace = RecognitionTrace()
        let (with, onCounts) = try RecognitionCallProbe.measure {
            try RecognitionTrace.withCurrent(trace) { try PartialCardFeatureExtractor().extract(image: image) }
        }
        XCTAssertFalse(without.isEmpty)
        XCTAssertEqual(try featureData(without), try featureData(with))
        XCTAssertEqual(offCounts, onCounts)
        XCTAssertEqual(trace.callCounts, onCounts)
        XCTAssertEqual(onCounts["extractor"], 1)
        XCTAssertGreaterThan(onCounts["classify"] ?? 0, 0)
        XCTAssertGreaterThan(onCounts["ocr"] ?? 0, 0)
        XCTAssertTrue(with.allSatisfy { $0.traceCandidateID != nil })
        XCTAssertTrue(without.allSatisfy { $0.traceCandidateID == nil })
        XCTAssertTrue(JSONSerialization.isValidJSONObject(trace.snapshot()))
    }

    func testBlankCandidateKeepsItsFailureTraceWithoutProducingAFeature() throws {
        let trace = RecognitionTrace()
        let features = try RecognitionTrace.withCurrent(trace) {
            try PartialCardFeatureExtractor().extract(image: fixture(drawPips: false))
        }
        XCTAssertTrue(features.isEmpty)
        let failure = try XCTUnwrap(trace.entries.first {
            $0["stage"] as? String == "candidate" && $0["reason"] as? String == "NO_PIPS_AND_OCR_NIL"
        })
        XCTAssertNotNil(failure["candidateID"] as? Int)
        XCTAssertEqual(failure["featureProduced"] as? Bool, false)
        XCTAssertEqual(failure["suitState"] as? String, "notRun")
        XCTAssertTrue(trace.entries.contains { $0["reason"] as? String == "OCR_NIL" })
        XCTAssertTrue(JSONSerialization.isValidJSONObject(trace.snapshot()))
    }

    func testPipComponentsHaveStableIDsAndTheirActualEstimatorHandoff() throws {
        let trace = RecognitionTrace()
        let features = try RecognitionTrace.withCurrent(trace) {
            try PartialCardFeatureExtractor().extract(image: fixture(drawPips: true, tinyInk: true))
        }
        let feature = try XCTUnwrap(features.first { !$0.pipCenters.isEmpty })
        let candidateID = try XCTUnwrap(feature.traceCandidateID)
        let entries = trace.entries.filter { $0["candidateID"] as? Int == candidateID }
        let detected = entries.filter {
            $0["stage"] as? String == "componentDetected" && $0["purpose"] as? String == "pip"
        }
        let detectedIDs = Set(detected.compactMap { $0["componentID"] as? Int })
        XCTAssertEqual(detectedIDs.count, detected.count)
        XCTAssertTrue(detected.allSatisfy { $0["meanLuma"] is Double && $0["shapeState"] as? String == "notRun" })
        let handoff = entries.filter {
            $0["stage"] as? String == "componentRetained" && $0["state"] as? String == "estimatorInput"
        }
        XCTAssertEqual(handoff.count, feature.pipCenters.count)
        XCTAssertTrue(handoff.allSatisfy { detectedIDs.contains($0["componentID"] as? Int ?? -1) })
        let summary = try XCTUnwrap(entries.first {
            $0["stage"] as? String == "pipSummary" && $0["state"] as? String == "completed"
        })
        XCTAssertEqual(summary["estimatorInput"] as? [[String: Double]], RecognitionTrace.points(feature.pipCenters))
        XCTAssertTrue(entries.contains { $0["stage"] as? String == "componentShape" && $0["shapeScores"] != nil })
        XCTAssertTrue(entries.contains {
            $0["stage"] as? String == "componentFiltered" && $0["purpose"] as? String == "pip"
                && $0["reason"] as? String == "COMPONENT_MIN_PIXELS"
        })
        XCTAssertTrue(JSONSerialization.isValidJSONObject(trace.snapshot()))
    }

    func testTraceCapacityExhaustionDoesNotAlterFeaturesOrCalls() throws {
        let image = fixture(drawPips: true)
        let (without, withoutCounts) = try RecognitionCallProbe.measure {
            try RecognitionTrace.withCurrent(nil) { try PartialCardFeatureExtractor().extract(image: image) }
        }
        let trace = RecognitionTrace(maximumEntries: 2)
        let (limited, limitedCounts) = try RecognitionCallProbe.measure {
            try RecognitionTrace.withCurrent(trace) { try PartialCardFeatureExtractor().extract(image: image) }
        }
        XCTAssertEqual(try featureData(without), try featureData(limited))
        XCTAssertEqual(withoutCounts, limitedCounts)
        XCTAssertEqual(trace.entries.count, 2)
        XCTAssertGreaterThan(trace.truncatedEntries, 0)
    }

    func testInvalidImageTraceUsesNullInsteadOfNonFiniteGeometry() throws {
        let trace = RecognitionTrace()
        let features = try RecognitionTrace.withCurrent(trace) {
            try PartialCardFeatureExtractor().extract(image: CIImage(color: .white))
        }
        XCTAssertTrue(features.isEmpty)
        XCTAssertTrue(trace.entries.contains { $0["reason"] as? String == "INVALID_IMAGE_EXTENT" })
        XCTAssertTrue(JSONSerialization.isValidJSONObject(trace.snapshot()))
        XCTAssertNil(trace.callCounts["ocr"])
        XCTAssertNil(trace.callCounts["classify"])
    }

    private func featureData(_ values: [PartialCardFeatures]) throws -> Data {
        let fields: [[String: Any]] = values.map { value in
            ["boundingBox": RecognitionTrace.rect(value.boundingBox),
             "pipCenters": RecognitionTrace.points(value.pipCenters),
             "imageAspectRatio": value.imageAspectRatio, "visibleRegion": value.visibleRegion,
             "suitProbabilities": value.suitProbabilities, "suitConfidence": value.suitConfidence,
             "rankText": value.rankText as Any? ?? NSNull(), "rankTextConfidence": value.rankTextConfidence,
             "localizationConfidence": value.localizationConfidence, "surfaceAnchored": value.surfaceAnchored,
             "pipStructureConfidence": value.pipStructureConfidence, "bodySuitSupportingPips": value.bodySuitSupportingPips,
             "bodyPipCount": value.bodyPipCount, "uncertainRegions": value.uncertainRegions.map(RecognitionTrace.rect),
             "clippedPipCandidates": RecognitionTrace.points(value.clippedPipCandidates)]
        }
        return try JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])
    }

    private func fixture(drawPips: Bool, tinyInk: Bool = false) -> CIImage {
        let canvas = CGContext(data: nil, width: 320, height: 380, bitsPerComponent: 8,
            bytesPerRow: 320 * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        canvas.setFillColor(CGColor(gray: 0.08, alpha: 1))
        canvas.fill(CGRect(x: 0, y: 0, width: 320, height: 380))
        let card = CGRect(x: 60, y: 54, width: 180, height: 252)
        canvas.setFillColor(CGColor(gray: 0.98, alpha: 1))
        canvas.fill(card)
        if drawPips {
            let points = [(0.3, 0.18), (0.7, 0.18), (0.5, 0.5), (0.3, 0.82), (0.7, 0.82)]
            canvas.setFillColor(CGColor(red: 0.85, green: 0.02, blue: 0.02, alpha: 1))
            for point in points {
                let center = CGPoint(x: card.minX + point.0 * card.width, y: card.minY + point.1 * card.height)
                canvas.beginPath()
                canvas.move(to: CGPoint(x: center.x, y: center.y - 13))
                canvas.addLine(to: CGPoint(x: center.x + 10, y: center.y))
                canvas.addLine(to: CGPoint(x: center.x, y: center.y + 13))
                canvas.addLine(to: CGPoint(x: center.x - 10, y: center.y))
                canvas.closePath()
                canvas.fillPath()
            }
        }
        if tinyInk {
            canvas.setFillColor(CGColor(gray: 0, alpha: 1))
            canvas.fill(CGRect(x: 105, y: 140, width: 2, height: 2))
        }
        return CIImage(cgImage: canvas.makeImage()!)
    }
}
