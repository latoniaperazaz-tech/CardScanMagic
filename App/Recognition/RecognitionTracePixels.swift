import CoreImage
import CoreVideo
import CryptoKit
import Foundation
import ImageIO

enum RecognitionTraceIOError: Error {
    case invalidBuffer, allocation(Int32), unsupportedAttachment(String), corruptArchive, imageEncoding
}

/// Owned plane bytes. No camera buffer or lazy CIImage survives capture().
struct RecognitionTracePixels {
    struct Plane: Codable {
        let width: Int
        let height: Int
        let bytesPerRow: Int
        let file: String
        let sha256: String
    }
    struct Metadata: Codable {
        let width: Int
        let height: Int
        let pixelFormat: UInt32
        let orientation: UInt32
        let planar: Bool
        let planes: [Plane]
        let attachmentsFile: String
        let metadataComplete: Bool
        let unsupportedAttachments: [String]
    }
    let metadata: Metadata
    let planes: [Data]
    let attachments: Data

    static func byteCount(_ buffer: CVPixelBuffer) -> Int {
        if CVPixelBufferIsPlanar(buffer) {
            return (0..<CVPixelBufferGetPlaneCount(buffer)).reduce(0) {
                $0 + CVPixelBufferGetBytesPerRowOfPlane(buffer, $1) * CVPixelBufferGetHeightOfPlane(buffer, $1)
            }
        }
        return CVPixelBufferGetBytesPerRow(buffer) * CVPixelBufferGetHeight(buffer)
    }

    static func capture(_ buffer: CVPixelBuffer, orientation: CGImagePropertyOrientation) throws -> Self {
        let code = CVPixelBufferLockBaseAddress(buffer, .readOnly)
        guard code == kCVReturnSuccess else { throw RecognitionTraceIOError.allocation(code) }
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let planar = CVPixelBufferIsPlanar(buffer)
        let count = planar ? CVPixelBufferGetPlaneCount(buffer) : 1
        var descriptions: [Plane] = []
        var bytes: [Data] = []
        for index in 0..<count {
            let width = planar ? CVPixelBufferGetWidthOfPlane(buffer, index) : CVPixelBufferGetWidth(buffer)
            let height = planar ? CVPixelBufferGetHeightOfPlane(buffer, index) : CVPixelBufferGetHeight(buffer)
            let stride = planar ? CVPixelBufferGetBytesPerRowOfPlane(buffer, index) : CVPixelBufferGetBytesPerRow(buffer)
            let address = planar ? CVPixelBufferGetBaseAddressOfPlane(buffer, index) : CVPixelBufferGetBaseAddress(buffer)
            guard let address, width > 0, height > 0, stride > 0 else { throw RecognitionTraceIOError.invalidBuffer }
            let data = Data(bytes: address, count: stride * height)
            bytes.append(data)
            descriptions.append(Plane(width: width, height: height, bytesPerRow: stride,
                file: "recognition_input_plane_\(index).bin", sha256: digest(data)))
        }
        var unsupported: [String] = []
        func archive(_ value: Any, path: String) -> Any? {
            if CFGetTypeID(value as CFTypeRef) == CGColorSpaceGetTypeID() {
                let color = value as! CGColorSpace
                if let icc = color.copyICCData() {
                    return ["traceType": "CGColorSpace", "icc": icc as Data]
                }
                if let name = color.name {
                    return ["traceType": "CGColorSpace", "name": name as String]
                }
                unsupported.append(path); return nil
            }
            if let map = value as? [String: Any] {
                var output: [String: Any] = [:]
                for (key, child) in map { output[key] = archive(child, path: path + "." + key) }
                return output
            }
            if let array = value as? [Any] {
                return array.enumerated().compactMap { archive($0.element, path: path + "[\($0.offset)]") }
            }
            if value is String || value is NSNumber || value is Data || value is Date { return value }
            unsupported.append(path); return nil
        }
        var attachmentGroups: [String: Any] = [:]
        for (name, mode) in [("propagate", CVAttachmentMode.shouldPropagate),
                             ("noPropagate", CVAttachmentMode.shouldNotPropagate)] {
            let values = CVBufferCopyAttachments(buffer, mode) as? [String: Any] ?? [:]
            attachmentGroups[name] = archive(values, path: name)
        }
        let attachments = try PropertyListSerialization.data(fromPropertyList: attachmentGroups,
                                                              format: .binary, options: 0)
        return Self(metadata: Metadata(width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer),
            pixelFormat: CVPixelBufferGetPixelFormatType(buffer), orientation: orientation.rawValue,
            planar: planar, planes: descriptions, attachmentsFile: "recognition_input_attachments.plist",
            metadataComplete: unsupported.isEmpty, unsupportedAttachments: unsupported),
            planes: bytes, attachments: attachments)
    }

    func write(to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (description, data) in zip(metadata.planes, planes) {
            try data.write(to: directory.appendingPathComponent(description.file), options: .atomic)
        }
        try attachments.write(to: directory.appendingPathComponent(metadata.attachmentsFile), options: .atomic)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(metadata).write(to: directory.appendingPathComponent("recognition_input.json"), options: .atomic)
    }

    static func read(from directory: URL) throws -> Self {
        let metadata = try JSONDecoder().decode(Metadata.self,
            from: Data(contentsOf: directory.appendingPathComponent("recognition_input.json")))
        guard metadata.width > 0, metadata.width <= 16384, metadata.height > 0, metadata.height <= 16384,
              metadata.planes.count >= 1, metadata.planes.count <= 4 else { throw RecognitionTraceIOError.corruptArchive }
        var data: [Data] = []
        for plane in metadata.planes {
            guard plane.file == URL(fileURLWithPath: plane.file).lastPathComponent,
                  plane.bytesPerRow > 0, plane.bytesPerRow <= 131072,
                  plane.height > 0, plane.height <= 16384 else { throw RecognitionTraceIOError.corruptArchive }
            let bytes = try Data(contentsOf: directory.appendingPathComponent(plane.file))
            guard bytes.count == plane.bytesPerRow * plane.height, digest(bytes) == plane.sha256 else {
                throw RecognitionTraceIOError.corruptArchive
            }
            data.append(bytes)
        }
        guard metadata.attachmentsFile == "recognition_input_attachments.plist" else {
            throw RecognitionTraceIOError.corruptArchive
        }
        return Self(metadata: metadata, planes: data,
            attachments: try Data(contentsOf: directory.appendingPathComponent(metadata.attachmentsFile)))
    }

    func restore(strict: Bool = true) throws -> CVPixelBuffer {
        guard !strict || metadata.metadataComplete else {
            throw RecognitionTraceIOError.unsupportedAttachment(metadata.unsupportedAttachments.joined(separator: ","))
        }
        var value: CVPixelBuffer?
        let attributes: [String: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey as String: [:],
            kCVPixelBufferBytesPerRowAlignmentKey as String: metadata.planes[0].bytesPerRow
        ]
        let code = CVPixelBufferCreate(kCFAllocatorDefault, metadata.width, metadata.height,
                                      metadata.pixelFormat, attributes as CFDictionary, &value)
        guard code == kCVReturnSuccess, let buffer = value else { throw RecognitionTraceIOError.allocation(code) }
        guard CVPixelBufferIsPlanar(buffer) == metadata.planar,
              (metadata.planar ? CVPixelBufferGetPlaneCount(buffer) : 1) == planes.count else {
            throw RecognitionTraceIOError.corruptArchive
        }
        let lockCode = CVPixelBufferLockBaseAddress(buffer, [])
        guard lockCode == kCVReturnSuccess else { throw RecognitionTraceIOError.allocation(lockCode) }
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        for index in planes.indices {
            let source = metadata.planes[index]
            let stride = metadata.planar ? CVPixelBufferGetBytesPerRowOfPlane(buffer, index) : CVPixelBufferGetBytesPerRow(buffer)
            let height = metadata.planar ? CVPixelBufferGetHeightOfPlane(buffer, index) : CVPixelBufferGetHeight(buffer)
            let width = metadata.planar ? CVPixelBufferGetWidthOfPlane(buffer, index) : CVPixelBufferGetWidth(buffer)
            let address = metadata.planar ? CVPixelBufferGetBaseAddressOfPlane(buffer, index) : CVPixelBufferGetBaseAddress(buffer)
            guard let address, height == source.height, width == source.width else { throw RecognitionTraceIOError.corruptArchive }
            memset(address, 0, stride * height)
            planes[index].withUnsafeBytes { bytes in
                for row in 0..<height {
                    memcpy(address.advanced(by: row * stride), bytes.baseAddress!.advanced(by: row * source.bytesPerRow),
                           min(stride, source.bytesPerRow))
                }
            }
        }
        func unarchive(_ value: Any) -> Any {
            if let map = value as? [String: Any] {
                if map["traceType"] as? String == "CGColorSpace" {
                    if let data = map["icc"] as? Data, let space = CGColorSpace(iccData: data as CFData) { return space }
                    if let name = map["name"] as? String, let space = CGColorSpace(name: name as CFString) { return space }
                }
                return map.mapValues(unarchive)
            }
            if let array = value as? [Any] { return array.map(unarchive) }
            return value
        }
        let archived = try PropertyListSerialization.propertyList(from: attachments, format: nil) as? [String: Any] ?? [:]
        for (name, mode) in [("propagate", CVAttachmentMode.shouldPropagate),
                             ("noPropagate", CVAttachmentMode.shouldNotPropagate)] {
            if let values = archived[name] as? [String: Any] {
                CVBufferSetAttachments(buffer, values.mapValues(unarchive) as CFDictionary, mode)
            }
        }
        return buffer
    }

    static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}
