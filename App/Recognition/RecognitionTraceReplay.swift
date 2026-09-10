import CoreImage
import CoreVideo
import Foundation
import ImageIO

enum RecognitionTraceReplay {
    struct Result {
        let detections: [CardDetection]
        let trace: [String: Any]
        let callCounts: [String: Int]
    }
    /// Real lossless exported input, same production Engine (including Core ML).
    static func run(recognitionDirectory: URL, engine: RecognitionEngine) throws -> Result {
        let packet = try RecognitionTracePixels.read(from: recognitionDirectory)
        let input = try packet.restore()
        guard let orientation = CGImagePropertyOrientation(rawValue: packet.metadata.orientation) else {
            throw RecognitionTraceIOError.corruptArchive
        }
        return try run(buffer: input, orientation: orientation, engine: engine, inputKind: "losslessProductionInput",
            replayFields: ["strict": true, "pixelArchiveSchemaVersion": packet.metadata.schemaVersion,
                "pixelPlaneHashes": packet.metadata.planes.map(\.sha256),
                "attachmentsSHA256": packet.metadata.attachmentsSHA256,
                "metadataComplete": packet.metadata.metadataComplete])
    }
    /// JPEG/candidate convenience path. Explicitly not pixel-equivalent to the original full frame.
    static func run(imageURL: URL, engine: RecognitionEngine) throws -> Result {
        guard let source = CGImageSourceCreateWithURL(imageURL as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw RecognitionTraceIOError.invalidBuffer }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any]
        let orientation = CGImagePropertyOrientation(rawValue: (properties?[kCGImagePropertyOrientation as String] as? UInt32) ?? 1) ?? .up
        var buffer: CVPixelBuffer?
        let result = CVPixelBufferCreate(kCFAllocatorDefault, image.width, image.height, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer)
        guard result == kCVReturnSuccess, let buffer else { throw RecognitionTraceIOError.allocation(result) }
        CIContext().render(CIImage(cgImage: image), to: buffer)
        return try run(buffer: buffer, orientation: orientation, engine: engine, inputKind: "imageOrCandidateReplay",
            replayFields: ["strict": false, "pixelEquivalentToProductionInput": false])
    }
    private static func run(buffer: CVPixelBuffer, orientation: CGImagePropertyOrientation,
                            engine: RecognitionEngine, inputKind: String, replayFields: [String: Any]) throws -> Result {
        let trace = RecognitionTrace()
        var fields = replayFields
        fields["inputKind"] = inputKind
        trace.event("replay", fields)
        let (detections, counts) = try RecognitionCallProbe.measure {
            try RecognitionTrace.withCurrent(trace) { try engine.recognize(pixelBuffer: buffer, orientation: orientation) }
        }
        return Result(detections: detections, trace: trace.snapshot(), callCounts: counts)
    }
}
