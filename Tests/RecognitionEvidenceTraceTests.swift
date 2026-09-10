import CoreGraphics
import CoreImage
import CoreVideo
import XCTest
@testable import CardScanMagic

/// These fixtures establish observation equivalence, not real-camera recall.
final class RecognitionEvidenceTraceTests: XCTestCase {
    private let imageSize = CGSize(width: 560, height: 720)
    private let nine: [CGPoint] = [(0.3, 0.15), (0.7, 0.15), (0.3, 0.38), (0.7, 0.38),
        (0.5, 0.5), (0.3, 0.62), (0.7, 0.62), (0.3, 0.85), (0.7, 0.85)]
        .map { CGPoint(x: $0.0, y: $0.1) }

    func testRankTraceOnOffPreservesAllCandidatesAndOneInference() throws {
        for points in [nine, Array(nine.dropLast()), [], [CGPoint(x: 0.5, y: 0.5)], nine + [nine[0]]] {
            let trace = RecognitionTrace()
            let off = RecognitionCallProbe.measure {
                PartialRankEstimator.infer(points: points, imageAspectRatio: 2.5 / 3.5,
                    visibleRegion: "full", surfaceAnchored: true)
            }
            let on = RecognitionCallProbe.measure {
                RecognitionTrace.withCurrent(trace) {
                    PartialRankEstimator.infer(points: points, imageAspectRatio: 2.5 / 3.5,
                        visibleRegion: "full", surfaceAnchored: true)
                }
            }
            assertEqual(off.0, on.0)
            XCTAssertEqual(off.1, ["estimator": 1])
            XCTAssertEqual(off.1, on.1)
            XCTAssertEqual(trace.callCounts, on.1)
            XCTAssertEqual(trace.entries.filter { $0["stage"] as? String == "rank.result" }.count, 1)
        }
    }

    func testRankTraceRetainsRealMissingAndOccludedCounts() throws {
        let trace = RecognitionTrace()
        let points = nine.filter { abs($0.x - 0.5) > 0.1 }
        let result = RecognitionTrace.withCurrent(trace) {
            PartialRankEstimator.infer(points: points, imageAspectRatio: 2.5 / 3.5,
                visibleRegion: "full", uncertainRegions: [CGRect(x: 0.42, y: 0.2, width: 0.16, height: 0.60)],
                surfaceAnchored: true)
        }
        XCTAssertNil(result.rank)
        let ranks = trace.entries.filter { $0["stage"] as? String == "rank.candidate" }
        XCTAssertEqual(ranks.count, 10)
        let nineTrace = try XCTUnwrap(ranks.first { $0["rank"] as? String == "9" })
        XCTAssertEqual(nineTrace["matchedCount"] as? Int, 8)
        XCTAssertEqual(nineTrace["visibleMissingCount"] as? Int, 0)
        XCTAssertEqual(nineTrace["ignoredOccludedCount"] as? Int, 1)
        XCTAssertEqual(nineTrace["extraCount"] as? Int, 0)
        XCTAssertTrue(nineTrace["layoutConfidence"] is NSNull)
        XCTAssertTrue(failedReasons(trace).contains("PIP_OCCLUSION_AMBIGUOUS"))
        XCTAssertNoThrow(try JSONSerialization.data(withJSONObject: trace.snapshot()))
    }

    func testEmptyRankInputIsNotEvaluatedNotFabricatedZeroScores() throws {
        let trace = RecognitionTrace()
        _ = RecognitionTrace.withCurrent(trace) {
            PartialRankEstimator.infer(points: [], imageAspectRatio: 1)
        }
        XCTAssertFalse(trace.entries.contains { $0["stage"] as? String == "rank.candidate" })
        let result = try XCTUnwrap(trace.entries.last)
        XCTAssertEqual(result["status"] as? String, "notEvaluated")
        XCTAssertTrue(result["candidates"] is NSNull)
        XCTAssertTrue(result["confidence"] is NSNull)
    }

    func testFusionPreservesResultsAndCallsForAcceptedAndRejectedEvidence() throws {
        var weakSuit = makeFeature(); weakSuit = replacing(weakSuit, suitConfidence: 0.2)
        var weakBody = makeFeature(); weakBody.bodySuitSupportingPips = 1
        var unanchored = makeFeature(); unanchored.surfaceAnchored = false
        let empty = replacing(makeFeature(), points: [])
        for feature in [makeFeature(), weakSuit, weakBody, unanchored, empty] {
            let trace = RecognitionTrace()
            let off = RecognitionCallProbe.measure { run(feature) }
            let on = RecognitionCallProbe.measure { RecognitionTrace.withCurrent(trace) { run(feature) } }
            assertEqual(off.0, on.0)
            XCTAssertEqual(off.1, ["estimator": 1, "fusion": 1])
            XCTAssertEqual(off.1, on.1)
            XCTAssertEqual(trace.callCounts, on.1)
            XCTAssertNoThrow(try JSONSerialization.data(withJSONObject: trace.snapshot()))
        }
    }

    func testFusionFailureRecordsFirstRealGuardAndLeavesLaterChecksUnevaluated() throws {
        let trace = RecognitionTrace()
        let feature = replacing(makeFeature(), localization: 0.49)
        let result = RecognitionTrace.withCurrent(trace) { run(feature) }
        XCTAssertTrue(result.isEmpty)
        let checks = trace.entries.filter { $0["stage"] as? String == "fusion.check" }
        XCTAssertTrue(failedReasons(trace).contains("LOCALIZATION_CONFIDENCE_LOW"))
        XCTAssertFalse(checks.contains { $0["reason"] as? String == "OCR_CONFIDENCE_INVALID" })
        XCTAssertFalse(trace.entries.contains { $0["stage"] as? String == "fusion.suit" })
    }

    func testCandidateIdentitySurvivesRankAndFusionWithoutLeakingScope() {
        let trace = RecognitionTrace()
        trace.candidateID = 91
        let feature = makeFeature(candidateID: 17)
        _ = RecognitionTrace.withCurrent(trace) { run(feature) }
        XCTAssertEqual(trace.candidateID, 91)
        for entry in trace.entries where ["rank.input", "rank.result", "fusion.resolveInput", "fusion.suit", "fusion.candidate"]
            .contains(entry["stage"] as? String ?? "") {
            XCTAssertEqual(entry["candidateID"] as? Int, 17, "\(entry)")
        }
    }

    func testBodySuitRejectionHasSpecificReason() {
        var feature = makeFeature(); feature.bodySuitSupportingPips = 1
        let trace = RecognitionTrace()
        XCTAssertTrue(RecognitionTrace.withCurrent(trace) { run(feature) }.isEmpty)
        XCTAssertTrue(failedReasons(trace).contains("BODY_SUIT_SUPPORT_COUNT_LOW"))
        XCTAssertTrue(failedReasons(trace).contains("FUSION_NO_QUALIFIED_RANK_SUPPORT"))
    }

    func testModelConflictIsObservedAndDoesNotChangeFusionResult() throws {
        let feature = makeFeature()
        let model = CardDetection(card: try XCTUnwrap(CardFace.parse("8h")), confidence: 0.96,
            boundingBox: feature.boundingBox, orientedImageSize: imageSize)
        let trace = RecognitionTrace()
        let evidence = RecognitionEngine.partialEvidence(from: [feature])
        let off = RecognitionCallProbe.measure { PartialEvidenceFusion.fuse(model: [model], local: evidence, imageSize: imageSize) }
        let on = RecognitionCallProbe.measure {
            RecognitionTrace.withCurrent(trace) { PartialEvidenceFusion.fuse(model: [model], local: evidence, imageSize: imageSize) }
        }
        assertEqual(off.0, on.0)
        XCTAssertTrue(on.0.isEmpty)
        XCTAssertEqual(off.1, on.1)
        XCTAssertTrue(trace.entries.contains { $0["stage"] as? String == "fusion.conflict" && $0["modelConflict"] as? Bool == true })
    }

    func testTraceCapacityExhaustionCannotChangeEvidenceResults() {
        let feature = makeFeature()
        let off = run(feature)
        let trace = RecognitionTrace(maximumEntries: 1)
        let on = RecognitionTrace.withCurrent(trace) { run(feature) }
        assertEqual(off, on)
        XCTAssertEqual(trace.entries.count, 1)
        XCTAssertGreaterThan(trace.truncatedEntries, 0)
    }

    func testCompleteProductionEngineOnOffUsesBundledCoreMLAndSameCalls() throws {
        // Intentionally no mock model, inferred rank, or pre-extracted pip input.
        // A missing model is a failure, not a skipped production-chain test.
        let engine = try RecognitionEngine()
        for (name, image) in [("coveredNine", fixture()), ("blank", CIImage(color: CIColor(red: 0.1, green: 0.15, blue: 0.1))
            .cropped(to: CGRect(origin: .zero, size: imageSize)))] {
            let input = try pixelBuffer(image)
            let trace = RecognitionTrace()
            let off = try RecognitionCallProbe.measure {
                try engine.recognize(pixelBuffer: input, orientation: .up)
            }
            let on = try RecognitionCallProbe.measure {
                try RecognitionTrace.withCurrent(trace) { try engine.recognize(pixelBuffer: input, orientation: .up) }
            }
            assertEqual(off.0, on.0)
            XCTAssertEqual(off.1, on.1, name)
            XCTAssertEqual(trace.callCounts, on.1, name)
            XCTAssertEqual(on.1["fusion"], 2, name)
            XCTAssertGreaterThanOrEqual(on.1["coreML"] ?? 0, 1, name)
            if name == "coveredNine" {
                XCTAssertGreaterThan(on.1["ocr"] ?? 0, 0)
                XCTAssertGreaterThan(on.1["classify"] ?? 0, 0)
                XCTAssertGreaterThan(on.1["estimator"] ?? 0, 0)
            }
            let phases = trace.entries.filter { $0["stage"] as? String == "fusion.input" }.compactMap { $0["fusionPass"] as? String }
            XCTAssertEqual(phases, ["first", "final"])
            XCTAssertEqual(trace.entries.filter { $0["stage"] as? String == "engine.final" }.count, 1)
            XCTAssertNoThrow(try JSONSerialization.data(withJSONObject: trace.snapshot()))
        }
    }

    private func run(_ feature: PartialCardFeatures) -> [CardDetection] {
        PartialEvidenceFusion.fuse(model: [], local: RecognitionEngine.partialEvidence(from: [feature]), imageSize: imageSize)
    }

    private func makeFeature(candidateID: Int? = nil) -> PartialCardFeatures {
        PartialCardFeatures(boundingBox: CGRect(x: 0.2, y: 0.1, width: 0.6, height: 0.8),
            pipCenters: nine, imageAspectRatio: 2.5 / 3.5, visibleRegion: "full",
            suitProbabilities: ["club": 0.97, "spade": 0.01, "heart": 0.01, "diamond": 0.01],
            suitConfidence: 0.96, rankText: nil, rankTextConfidence: 0,
            localizationConfidence: 0.95, surfaceAnchored: true, pipStructureConfidence: 0.95,
            bodySuitSupportingPips: 9, bodyPipCount: 9, traceCandidateID: candidateID)
    }

    private func replacing(_ feature: PartialCardFeatures, points: [CGPoint]? = nil,
                           suitConfidence: Double? = nil, localization: Double? = nil) -> PartialCardFeatures {
        PartialCardFeatures(boundingBox: feature.boundingBox, pipCenters: points ?? feature.pipCenters,
            imageAspectRatio: feature.imageAspectRatio, visibleRegion: feature.visibleRegion,
            suitProbabilities: feature.suitProbabilities, suitConfidence: suitConfidence ?? feature.suitConfidence,
            rankText: feature.rankText, rankTextConfidence: feature.rankTextConfidence,
            localizationConfidence: localization ?? feature.localizationConfidence,
            surfaceAnchored: feature.surfaceAnchored, pipStructureConfidence: feature.pipStructureConfidence,
            bodySuitSupportingPips: feature.bodySuitSupportingPips, bodyPipCount: feature.bodyPipCount,
            traceCandidateID: feature.traceCandidateID)
    }

    private func failedReasons(_ trace: RecognitionTrace) -> [String] {
        trace.entries.filter { $0["passed"] as? Bool == false }.compactMap { $0["reason"] as? String }
    }

    private func assertEqual(_ lhs: PartialRankResult, _ rhs: PartialRankResult,
                             file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(lhs.rank, rhs.rank, file: file, line: line)
        XCTAssertEqual(lhs.confidence, rhs.confidence, file: file, line: line)
        XCTAssertEqual(lhs.candidates.map(\.rank), rhs.candidates.map(\.rank), file: file, line: line)
        XCTAssertEqual(lhs.candidates.map(\.score), rhs.candidates.map(\.score), file: file, line: line)
        XCTAssertEqual(lhs.candidates.map(\.probability), rhs.candidates.map(\.probability), file: file, line: line)
        XCTAssertEqual(lhs.candidates.map(\.matchedCount), rhs.candidates.map(\.matchedCount), file: file, line: line)
    }

    private func assertEqual(_ lhs: [CardDetection], _ rhs: [CardDetection],
                             file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(lhs.map { $0.card.code }, rhs.map { $0.card.code }, file: file, line: line)
        XCTAssertEqual(lhs.map(\.confidence), rhs.map(\.confidence), file: file, line: line)
        XCTAssertEqual(lhs.map(\.boundingBox), rhs.map(\.boundingBox), file: file, line: line)
        XCTAssertEqual(lhs.map(\.orientedImageSize), rhs.map(\.orientedImageSize), file: file, line: line)
        XCTAssertEqual(lhs.map(\.hasIndependentSupport), rhs.map(\.hasIndependentSupport), file: file, line: line)
    }

    private func pixelBuffer(_ image: CIImage) throws -> CVPixelBuffer {
        var result: CVPixelBuffer?
        let status = CVPixelBufferCreate(kCFAllocatorDefault, Int(imageSize.width), Int(imageSize.height),
            kCVPixelFormatType_32BGRA, [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &result)
        XCTAssertEqual(status, kCVReturnSuccess)
        let buffer = try XCTUnwrap(result)
        CIContext(options: [.cacheIntermediates: false]).render(image, to: buffer)
        return buffer
    }

    private func fixture() -> CIImage {
        let canvas = CGContext(data: nil, width: 560, height: 720, bitsPerComponent: 8, bytesPerRow: 560 * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        canvas.setFillColor(CGColor(red: 0.05, green: 0.16, blue: 0.14, alpha: 1))
        canvas.fill(CGRect(origin: .zero, size: imageSize))
        let card = CGRect(x: 80, y: 60, width: 400, height: 560)
        canvas.setFillColor(CGColor(gray: 0.98, alpha: 1)); canvas.fill(card)
        for point in nine {
            canvas.saveGState()
            canvas.translateBy(x: card.minX + point.x * card.width - 19, y: card.maxY - point.y * card.height - 22)
            canvas.scaleBy(x: 38.0 / 112, y: 44.0 / 120)
            canvas.setFillColor(CGColor(gray: 0.025, alpha: 1))
            canvas.fillEllipse(in: CGRect(x: 31, y: 66, width: 50, height: 50))
            canvas.fillEllipse(in: CGRect(x: 7, y: 38, width: 50, height: 50))
            canvas.fillEllipse(in: CGRect(x: 55, y: 38, width: 50, height: 50))
            canvas.fill(CGRect(x: 47, y: 10, width: 18, height: 54))
            canvas.beginPath(); canvas.move(to: CGPoint(x: 29, y: 8))
            canvas.addLine(to: CGPoint(x: 83, y: 8)); canvas.addLine(to: CGPoint(x: 56, y: 36))
            canvas.closePath(); canvas.fillPath(); canvas.restoreGState()
        }
        canvas.setFillColor(CGColor(red: 0.69, green: 0.43, blue: 0.30, alpha: 1))
        for region in [CGRect(x: 0, y: 0, width: 0.19, height: 0.28), CGRect(x: 0.81, y: 0.72, width: 0.19, height: 0.28)] {
            canvas.fill(CGRect(x: card.minX + region.minX * card.width, y: card.maxY - region.maxY * card.height,
                width: region.width * card.width, height: region.height * card.height))
        }
        return CIImage(cgImage: canvas.makeImage()!)
    }
}
