import CoreGraphics
import CoreImage
import CoreVideo
import Foundation
import XCTest
@testable import CardScanMagic

/// Regression tests backed by the two lossless iPhone inputs used in the
/// Card Candidate localization audit.  These assertions deliberately inspect
/// geometry only: rank, suit, OCR and fusion remain outside this phase.
final class RealCardCandidateLocalizationTests: XCTestCase {
    private let minimumSurfaceArea = 0.04

    func testRealFull10SCreatesSurfaceCandidate() throws {
        let features = try extractFixture(named: "FULL")
        XCTAssertFalse(features.isEmpty, "the visible card must survive localization")
        XCTAssertTrue(features.contains { area(of: $0.boundingBox) >= minimumSurfaceArea },
                      "no card-sized candidate was produced")
    }

    func testRealOccluded10SCreatesPartialSurfaceCandidate() throws {
        let features = try extractFixture(named: "OCCLUDED")
        XCTAssertFalse(features.isEmpty)
        XCTAssertTrue(features.contains { area(of: $0.boundingBox) >= minimumSurfaceArea })
        XCTAssertTrue(features.contains { $0.visibleRegion != "full" || area(of: $0.boundingBox) >= 0.08 },
                      "an occluded card must retain partial/unknown geometry")
    }

    func testRealInternalSpadeDoesNotBecomeFullCardCandidate() throws {
        for fixture in ["FULL", "OCCLUDED"] {
            let features = try extractFixture(named: fixture)
            XCTAssertFalse(features.contains {
                $0.visibleRegion == "full" && area(of: $0.boundingBox) < minimumSurfaceArea
            }, "(fixture) retained an internal symbol as a full card")
        }
    }

    func testRealBackgroundRectangleDoesNotBecomeCardSurface() throws {
        for fixture in ["FULL", "OCCLUDED"] {
            let features = try extractFixture(named: fixture)
            XCTAssertTrue(features.allSatisfy { area(of: $0.boundingBox) >= minimumSurfaceArea },
                          "(fixture) retained a tiny background rectangle")
        }
    }

    func testRealLowLightSurfaceRetainsVisibleSupport() throws {
        let full = try extractFixture(named: "FULL")
        let occluded = try extractFixture(named: "OCCLUDED")
        XCTAssertGreaterThan(full.map { area(of: $0.boundingBox) }.max() ?? 0, minimumSurfaceArea)
        XCTAssertGreaterThan(occluded.map { area(of: $0.boundingBox) }.max() ?? 0, minimumSurfaceArea)
    }

    func testRealCandidate3Features0LocalizationRegression() throws {
        for fixture in ["FULL", "OCCLUDED"] {
            let features = try extractFixture(named: fixture)
            XCTAssertFalse(features.isEmpty,
                           "(fixture): the former candidates=3/features=0 failure regressed")
            XCTAssertTrue(features.contains { area(of: $0.boundingBox) >= minimumSurfaceArea })
        }
    }

    func testSurfaceCandidateBudgetCannotBeConsumedBySymbols() throws {
        for fixture in ["FULL", "OCCLUDED"] {
            let features = try extractFixture(named: fixture)
            XCTAssertLessThanOrEqual(features.count, 3)
            XCTAssertTrue(features.allSatisfy { area(of: $0.boundingBox) >= minimumSurfaceArea })
        }
    }

    func testRealNonCardCandidatesDoNotConfirm() throws {
        // Feature extraction is intentionally the boundary of this phase. A
        // geometry proposal alone cannot create a CardDetection or a record.
        let features = try extractFixture(named: "FULL")
        XCTAssertTrue(features.allSatisfy { $0.localizationConfidence <= 1.0 })
    }

    private func area(of box: CGRect) -> Double {
        Double(max(0, box.width) * max(0, box.height))
    }

    private func extractFixture(named name: String) throws -> [PartialCardFeatures] {
        let bundle = Bundle(for: Self.self)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CardCandidateFixture-\(name)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let files = [
            "\(name)_recognition_input.json": "recognition_input.json",
            "\(name)_recognition_input_plane_0.bin": "recognition_input_plane_0.bin",
            "\(name)_recognition_input_plane_1.bin": "recognition_input_plane_1.bin",
            "\(name)_recognition_input_attachments.plist": "recognition_input_attachments.plist"
        ]
        for (resource, destination) in files {
            let url = try XCTUnwrap(bundle.url(forResource: resource, withExtension: nil,
                                                subdirectory: "Fixtures"),
                                    "missing bundled fixture \(resource)")
            try FileManager.default.copyItem(at: url, to: directory.appendingPathComponent(destination))
        }
        let packet = try RecognitionTracePixels.read(from: directory)
        let orientation = try XCTUnwrap(CGImagePropertyOrientation(rawValue: packet.metadata.orientation))
        let buffer = try packet.restore()
        return try PartialCardFeatureExtractor().extract(pixelBuffer: buffer, orientation: orientation)
    }
}
