import CoreGraphics
import CoreVideo
import ImageIO
import XCTest
@testable import CardScanMagic

final class RecognitionTracePixelsTests: XCTestCase {
    func testStrictRoundTripPreservesAllPlaneBytesAndEveryOrientation() throws {
        for format in [kCVPixelFormatType_32BGRA, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
                       kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange] {
            // Non-power-of-two dimensions include allocator row padding.
            let original = try makeBuffer(format: format, width: 66, height: 98)
            for raw in UInt32(1)...8 {
                let orientation = try XCTUnwrap(CGImagePropertyOrientation(rawValue: raw))
                let packet = try RecognitionTracePixels.capture(original, orientation: orientation)
                let restored = try packet.restore()
                let second = try RecognitionTracePixels.capture(restored, orientation: orientation)
                XCTAssertEqual(packet.metadata.orientation, raw)
                XCTAssertEqual(packet.metadata.pixelFormat, second.metadata.pixelFormat)
                XCTAssertEqual(packet.metadata.planar, second.metadata.planar)
                XCTAssertEqual(packet.metadata.planes.map(\.width), second.metadata.planes.map(\.width))
                XCTAssertEqual(packet.metadata.planes.map(\.height), second.metadata.planes.map(\.height))
                XCTAssertEqual(packet.metadata.planes.map(\.bytesPerRow), second.metadata.planes.map(\.bytesPerRow))
                XCTAssertEqual(packet.planes, second.planes, "format \(format), orientation \(raw)")
            }
        }
    }

    func testAttachmentsPreserveBothPropagationModesAndColorSpace() throws {
        let buffer = try makeBuffer()
        let customKey = "TraceRoundTripOnly" as CFString
        let color = try XCTUnwrap(CGColorSpace(name: CGColorSpace.displayP3))
        CVBufferSetAttachment(buffer, kCVImageBufferCGColorSpaceKey, color, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey,
                              kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(buffer, customKey,
            ["nested": ["label": "no-propagate", "values": [1, 2, 3]], "bytes": Data([0, 7, 255])] as CFDictionary,
            .shouldNotPropagate)
        let packet = try RecognitionTracePixels.capture(buffer, orientation: .leftMirrored)
        let restored = try packet.restore()
        var mode = CVAttachmentMode.shouldPropagate
        let values = try XCTUnwrap(CVBufferCopyAttachment(restored, customKey, &mode) as? NSDictionary)
        XCTAssertEqual(mode, .shouldNotPropagate)
        XCTAssertEqual(values["bytes"] as? Data, Data([0, 7, 255]))
        XCTAssertEqual((values["nested"] as? NSDictionary)?["label"] as? String, "no-propagate")
        let restoredColorValue = try XCTUnwrap(CVBufferCopyAttachment(restored, kCVImageBufferCGColorSpaceKey, &mode))
        XCTAssertEqual(CFGetTypeID(restoredColorValue), CGColorSpaceGetTypeID())
        let restoredColor = restoredColorValue as! CGColorSpace
        XCTAssertEqual(restoredColor.model, color.model)
        XCTAssertEqual(restoredColor.copyICCData().map { $0 as Data }, color.copyICCData().map { $0 as Data })
        XCTAssertEqual(mode, .shouldPropagate)
    }

    func testReplayPreservesOriginalIndependentPlaneStridesAcrossAllocatorAlignment() throws {
        for format in [kCVPixelFormatType_32BGRA, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange] {
            let packet = try RecognitionTracePixels.capture(makeBuffer(format: format), orientation: .right)
            var descriptions: [RecognitionTracePixels.Plane] = []
            var planes: [Data] = []
            for (index, source) in packet.metadata.planes.enumerated() {
                let stride = source.bytesPerRow + (index + 1) * 16
                var rows = Data(repeating: UInt8(211 + index), count: stride * source.height)
                for row in 0..<source.height {
                    rows.replaceSubrange(row * stride ..< row * stride + source.bytesPerRow,
                        with: packet.planes[index][row * source.bytesPerRow ..< (row + 1) * source.bytesPerRow])
                }
                planes.append(rows)
                descriptions.append(.init(width: source.width, height: source.height, bytesPerRow: stride,
                    file: source.file, sha256: RecognitionTracePixels.digest(rows)))
            }
            let metadata = RecognitionTracePixels.Metadata(schemaVersion: packet.metadata.schemaVersion,
                width: packet.metadata.width, height: packet.metadata.height, pixelFormat: packet.metadata.pixelFormat,
                orientation: packet.metadata.orientation, planar: packet.metadata.planar, planes: descriptions,
                attachmentsFile: packet.metadata.attachmentsFile, attachmentsSHA256: packet.metadata.attachmentsSHA256,
                metadataComplete: packet.metadata.metadataComplete, unsupportedAttachments: packet.metadata.unsupportedAttachments)
            let padded = RecognitionTracePixels(metadata: metadata, planes: planes, attachments: packet.attachments)
            let buffer = try padded.restore()
            let after = try RecognitionTracePixels.capture(buffer, orientation: .right)
            XCTAssertEqual(after.metadata.planes.map(\.bytesPerRow), descriptions.map(\.bytesPerRow))
            XCTAssertEqual(after.planes, planes)
        }
    }

    func testAttachmentCorruptionIsRejectedEvenWhenPlanesAreValid() throws {
        try withArchive { folder, packet in
            try Data([0, 1, 2]).write(to: folder.appendingPathComponent(packet.metadata.attachmentsFile))
            XCTAssertThrowsError(try RecognitionTracePixels.read(from: folder))
        }
    }

    func testMalformedAttachmentStructureDoesNotSilentlyReplayWithoutMetadata() throws {
        try withArchive { folder, packet in
            let data = try PropertyListSerialization.data(fromPropertyList: ["unexpected": "structure"], format: .binary, options: 0)
            try data.write(to: folder.appendingPathComponent(packet.metadata.attachmentsFile))
            try updateMetadata(folder) { $0["attachmentsSHA256"] = RecognitionTracePixels.digest(data) }
            let malformed = try RecognitionTracePixels.read(from: folder)
            XCTAssertThrowsError(try malformed.restore())
        }
    }

    func testIncompleteAttachmentsAreExplicitAndCannotUseStrictReplay() throws {
        try withArchive { folder, _ in
            try updateMetadata(folder) {
                $0["metadataComplete"] = false
                $0["unsupportedAttachments"] = ["propagate.unknownObject"]
            }
            let incomplete = try RecognitionTracePixels.read(from: folder)
            XCTAssertThrowsError(try incomplete.restore())
            // Preview may explicitly accept incomplete metadata; strict replay may not.
            XCTAssertNoThrow(try incomplete.restore(strict: false))
        }
    }

    func testInvalidMetadataRejectedBeforeReplayAllocation() throws {
        let mutations: [(inout [String: Any]) -> Void] = [
            { $0["schemaVersion"] = 99 },
            { $0["orientation"] = 0 },
            { $0["planes"] = [] },
            { $0["width"] = 0 },
            { $0["height"] = 16385 },
            { $0["attachmentsFile"] = "../other.plist" },
            { $0["attachmentsSHA256"] = "invalid" },
            { $0["metadataComplete"] = false },
            { object in
                var planes = object["planes"] as! [[String: Any]]
                planes[0]["width"] = 0; object["planes"] = planes
            },
            { object in
                var planes = object["planes"] as! [[String: Any]]
                planes[0]["bytesPerRow"] = Int.max; object["planes"] = planes
            },
            { object in
                var planes = object["planes"] as! [[String: Any]]
                planes[0]["file"] = "../recognition_input_plane_0.bin"; object["planes"] = planes
            }
        ]
        for (index, mutate) in mutations.enumerated() {
            try withArchive { folder, _ in
                try updateMetadata(folder, mutate)
                XCTAssertThrowsError(try RecognitionTracePixels.read(from: folder), "mutation \(index)")
            }
        }
    }

    func testMissingInMemoryPlaneIsThrownInsteadOfIndexingPastArray() throws {
        let packet = try RecognitionTracePixels.capture(makeBuffer(), orientation: .up)
        let invalid = RecognitionTracePixels(metadata: packet.metadata, planes: [], attachments: packet.attachments)
        XCTAssertThrowsError(try invalid.restore())
    }

    func testArchiveRejectsPlaneSymlinkOutsideRecognitionDirectory() throws {
        try withArchive { folder, packet in
            let outside = folder.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + ".bin")
            defer { try? FileManager.default.removeItem(at: outside) }
            try packet.planes[0].write(to: outside)
            let planeURL = folder.appendingPathComponent(packet.metadata.planes[0].file)
            try FileManager.default.removeItem(at: planeURL)
            try FileManager.default.createSymbolicLink(at: planeURL, withDestinationURL: outside)
            XCTAssertThrowsError(try RecognitionTracePixels.read(from: folder))
        }
    }

    private func makeBuffer(format: OSType = kCVPixelFormatType_32BGRA,
                            width: Int = 64, height: Int = 96) throws -> CVPixelBuffer {
        var result: CVPixelBuffer?
        let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height, format,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &result)
        XCTAssertEqual(status, kCVReturnSuccess)
        let buffer = try XCTUnwrap(result)
        XCTAssertEqual(CVPixelBufferLockBaseAddress(buffer, []), kCVReturnSuccess)
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let planar = CVPixelBufferIsPlanar(buffer)
        for index in 0..<(planar ? CVPixelBufferGetPlaneCount(buffer) : 1) {
            let address = planar ? CVPixelBufferGetBaseAddressOfPlane(buffer, index) : CVPixelBufferGetBaseAddress(buffer)
            let stride = planar ? CVPixelBufferGetBytesPerRowOfPlane(buffer, index) : CVPixelBufferGetBytesPerRow(buffer)
            let rows = planar ? CVPixelBufferGetHeightOfPlane(buffer, index) : CVPixelBufferGetHeight(buffer)
            let bytes = try XCTUnwrap(address).assumingMemoryBound(to: UInt8.self)
            for byte in 0..<(stride * rows) { bytes[byte] = UInt8((byte * 37 + index * 13) % 256) }
        }
        return buffer
    }

    private func withArchive(_ body: (URL, RecognitionTracePixels) throws -> Void) throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("TracePixels-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let packet = try RecognitionTracePixels.capture(makeBuffer(), orientation: .up)
        try packet.write(to: folder)
        try body(folder, packet)
    }

    private func updateMetadata(_ folder: URL, _ mutate: (inout [String: Any]) -> Void) throws {
        let url = folder.appendingPathComponent("recognition_input.json")
        var metadata = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        mutate(&metadata)
        try JSONSerialization.data(withJSONObject: metadata, options: [.sortedKeys]).write(to: url)
    }
}
