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
        let schemaVersion: Int
        let width: Int
        let height: Int
        let pixelFormat: UInt32
        let orientation: UInt32
        let planar: Bool
        let planes: [Plane]
        let attachmentsFile: String
        let attachmentsSHA256: String
        let metadataComplete: Bool
        let unsupportedAttachments: [String]
    }
    let metadata: Metadata
    let planes: [Data]
    let attachments: Data

    // These are archive-validation limits, not recognition parameters. Validate
    // before loading bytes or allocating a CVPixelBuffer from an imported trace.
    private static let maximumPixelBytes = 256 * 1024 * 1024
    private static let maximumAttachmentBytes = 4 * 1024 * 1024

    static func byteCount(_ buffer: CVPixelBuffer) -> Int {
        if CVPixelBufferIsPlanar(buffer) {
            return (0..<CVPixelBufferGetPlaneCount(buffer)).reduce(0) {
                let product = CVPixelBufferGetBytesPerRowOfPlane(buffer, $1)
                    .multipliedReportingOverflow(by: CVPixelBufferGetHeightOfPlane(buffer, $1))
                let sum = $0.addingReportingOverflow(product.partialValue)
                return product.overflow || sum.overflow ? Int.max : sum.partialValue
            }
        }
        let product = CVPixelBufferGetBytesPerRow(buffer).multipliedReportingOverflow(by: CVPixelBufferGetHeight(buffer))
        return product.overflow ? Int.max : product.partialValue
    }

    static func capture(_ buffer: CVPixelBuffer, orientation: CGImagePropertyOrientation) throws -> Self {
        guard byteCount(buffer) > 0, byteCount(buffer) <= maximumPixelBytes else {
            throw RecognitionTraceIOError.invalidBuffer
        }
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
            if CFGetTypeID(value as CFTypeRef) == CGColorSpace.typeID {
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
        guard attachments.count <= maximumAttachmentBytes else { throw RecognitionTraceIOError.invalidBuffer }
        let result = Self(metadata: Metadata(schemaVersion: 2,
            width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer),
            pixelFormat: CVPixelBufferGetPixelFormatType(buffer), orientation: orientation.rawValue,
            planar: planar, planes: descriptions, attachmentsFile: "recognition_input_attachments.plist",
            attachmentsSHA256: digest(attachments),
            metadataComplete: unsupported.isEmpty, unsupportedAttachments: unsupported),
            planes: bytes, attachments: attachments)
        try result.validate()
        return result
    }

    func write(to directory: URL) throws {
        try validate()
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
            from: readFile("recognition_input.json", from: directory, maximumBytes: maximumAttachmentBytes))
        try validateMetadata(metadata)
        var data: [Data] = []
        for plane in metadata.planes {
            let bytes = try readFile(plane.file, from: directory, maximumBytes: plane.bytesPerRow * plane.height)
            guard bytes.count == plane.bytesPerRow * plane.height, digest(bytes) == plane.sha256 else {
                throw RecognitionTraceIOError.corruptArchive
            }
            data.append(bytes)
        }
        let result = Self(metadata: metadata, planes: data,
            attachments: try readFile(metadata.attachmentsFile, from: directory, maximumBytes: maximumAttachmentBytes))
        try result.validate()
        return result
    }

    func restore(strict: Bool = true) throws -> CVPixelBuffer {
        try validate()
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
        guard code == kCVReturnSuccess, let allocated = value else { throw RecognitionTraceIOError.allocation(code) }
        guard CVPixelBufferIsPlanar(allocated) == metadata.planar,
              (metadata.planar ? CVPixelBufferGetPlaneCount(allocated) : 1) == planes.count else {
            throw RecognitionTraceIOError.corruptArchive
        }
        var matchingStride = true
        for (index, source) in metadata.planes.enumerated() {
            let width = metadata.planar ? CVPixelBufferGetWidthOfPlane(allocated, index) : CVPixelBufferGetWidth(allocated)
            let height = metadata.planar ? CVPixelBufferGetHeightOfPlane(allocated, index) : CVPixelBufferGetHeight(allocated)
            let stride = metadata.planar ? CVPixelBufferGetBytesPerRowOfPlane(allocated, index) : CVPixelBufferGetBytesPerRow(allocated)
            guard width == source.width, height == source.height else { throw RecognitionTraceIOError.corruptArchive }
            matchingStride = matchingStride && stride == source.bytesPerRow
        }
        // Different hardware can choose a different IOSurface row alignment.
        // CVPixelBufferCreateWith*Bytes preserves the original stride in that
        // case; a release callback owns the copied memory for the buffer's life.
        let buffer = matchingStride ? allocated : try makeExactStrideBuffer()
        let lockCode = CVPixelBufferLockBaseAddress(buffer, [])
        guard lockCode == kCVReturnSuccess else { throw RecognitionTraceIOError.allocation(lockCode) }
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        for index in planes.indices {
            let source = metadata.planes[index]
            let stride = metadata.planar ? CVPixelBufferGetBytesPerRowOfPlane(buffer, index) : CVPixelBufferGetBytesPerRow(buffer)
            let height = metadata.planar ? CVPixelBufferGetHeightOfPlane(buffer, index) : CVPixelBufferGetHeight(buffer)
            let width = metadata.planar ? CVPixelBufferGetWidthOfPlane(buffer, index) : CVPixelBufferGetWidth(buffer)
            let address = metadata.planar ? CVPixelBufferGetBaseAddressOfPlane(buffer, index) : CVPixelBufferGetBaseAddress(buffer)
            // A strict replay preserves every archived row byte, including
            // padding. Never silently truncate a plane to the allocator stride.
            guard let address, height == source.height, width == source.width,
                  stride >= source.bytesPerRow, !strict || stride == source.bytesPerRow else {
                throw RecognitionTraceIOError.corruptArchive
            }
            memset(address, 0, stride * height)
            planes[index].withUnsafeBytes { bytes in
                for row in 0..<height {
                    memcpy(address.advanced(by: row * stride), bytes.baseAddress!.advanced(by: row * source.bytesPerRow),
                           source.bytesPerRow)
                }
            }
        }
        func unarchive(_ value: Any) throws -> Any {
            if let map = value as? [String: Any] {
                if map["traceType"] as? String == "CGColorSpace" {
                    if let data = map["icc"] as? Data, let space = CGColorSpace(iccData: data as CFData) { return space }
                    if let name = map["name"] as? String, let space = CGColorSpace(name: name as CFString) { return space }
                    throw RecognitionTraceIOError.corruptArchive
                }
                return try map.mapValues(unarchive)
            }
            if let array = value as? [Any] { return try array.map(unarchive) }
            return value
        }
        guard let archived = try PropertyListSerialization.propertyList(from: attachments, format: nil) as? [String: Any],
              Set(archived.keys) == Set(["propagate", "noPropagate"]),
              archived["propagate"] is [String: Any], archived["noPropagate"] is [String: Any] else {
            throw RecognitionTraceIOError.corruptArchive
        }
        for (name, mode) in [("propagate", CVAttachmentMode.shouldPropagate),
                             ("noPropagate", CVAttachmentMode.shouldNotPropagate)] {
            if let values = archived[name] as? [String: Any] {
                CVBufferSetAttachments(buffer, try values.mapValues(unarchive) as CFDictionary, mode)
            }
        }
        return buffer
    }

    private final class ReplayPlaneStorage {
        let addresses: [UnsafeMutableRawPointer]
        init(sizes: [Int]) throws {
            var allocated: [UnsafeMutableRawPointer] = []
            for size in sizes {
                guard let address = malloc(size) else {
                    allocated.forEach { free($0) }
                    throw RecognitionTraceIOError.allocation(kCVReturnAllocationFailed)
                }
                allocated.append(address)
            }
            addresses = allocated
        }
        deinit { addresses.forEach { free($0) } }
    }

    private func makeExactStrideBuffer() throws -> CVPixelBuffer {
        let storage = try ReplayPlaneStorage(sizes: metadata.planes.map { $0.bytesPerRow * $0.height })
        let reference = Unmanaged.passRetained(storage).toOpaque()
        var buffer: CVPixelBuffer?
        let status: CVReturn
        if metadata.planar {
            var addresses = storage.addresses.map { Optional($0) }
            var widths = metadata.planes.map(\.width)
            var heights = metadata.planes.map(\.height)
            var strides = metadata.planes.map(\.bytesPerRow)
            status = CVPixelBufferCreateWithPlanarBytes(kCFAllocatorDefault, metadata.width, metadata.height,
                metadata.pixelFormat, nil, 0, addresses.count, &addresses, &widths, &heights, &strides,
                { reference, _, _, _, _ in
                    if let reference { Unmanaged<ReplayPlaneStorage>.fromOpaque(reference).release() }
                }, reference, nil, &buffer)
        } else {
            status = CVPixelBufferCreateWithBytes(kCFAllocatorDefault, metadata.width, metadata.height,
                metadata.pixelFormat, storage.addresses[0], metadata.planes[0].bytesPerRow,
                { reference, _ in
                    if let reference { Unmanaged<ReplayPlaneStorage>.fromOpaque(reference).release() }
                }, reference, nil, &buffer)
        }
        guard status == kCVReturnSuccess, let buffer else {
            Unmanaged<ReplayPlaneStorage>.fromOpaque(reference).release()
            throw RecognitionTraceIOError.allocation(status)
        }
        return buffer
    }

    private static func validateMetadata(_ metadata: Metadata) throws {
        guard metadata.schemaVersion == 2,
              metadata.width > 0, metadata.width <= 16384,
              metadata.height > 0, metadata.height <= 16384,
              CGImagePropertyOrientation(rawValue: metadata.orientation) != nil,
              metadata.planes.count >= 1, metadata.planes.count <= 4,
              metadata.planar || metadata.planes.count == 1,
              metadata.attachmentsFile == "recognition_input_attachments.plist",
              isDigest(metadata.attachmentsSHA256),
              metadata.metadataComplete == metadata.unsupportedAttachments.isEmpty else {
            throw RecognitionTraceIOError.corruptArchive
        }
        var total = 0
        for (index, plane) in metadata.planes.enumerated() {
            guard plane.file == "recognition_input_plane_\(index).bin",
                  plane.width > 0, plane.width <= metadata.width,
                  plane.height > 0, plane.height <= metadata.height,
                  plane.bytesPerRow > 0, plane.bytesPerRow <= 131072,
                  isDigest(plane.sha256) else { throw RecognitionTraceIOError.corruptArchive }
            let bytes = plane.bytesPerRow * plane.height
            guard bytes <= maximumPixelBytes - total else { throw RecognitionTraceIOError.corruptArchive }
            total += bytes
        }
        // Validate active bytes for every format currently used by Camera and
        // CaptureSnapshotPool before accepting caller-supplied row padding.
        switch metadata.pixelFormat {
        case kCVPixelFormatType_32BGRA:
            guard !metadata.planar, metadata.planes[0].bytesPerRow >= metadata.width * 4 else {
                throw RecognitionTraceIOError.corruptArchive
            }
        case kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange:
            guard metadata.planar, metadata.planes.count == 2,
                  metadata.planes[0].bytesPerRow >= metadata.width,
                  metadata.planes[1].bytesPerRow >= ((metadata.width + 1) / 2) * 2 else {
                throw RecognitionTraceIOError.corruptArchive
            }
        default:
            break // Core Video validates the remaining format's plane geometry.
        }
    }

    private func validate() throws {
        try Self.validateMetadata(metadata)
        guard planes.count == metadata.planes.count,
              attachments.count <= Self.maximumAttachmentBytes,
              Self.digest(attachments) == metadata.attachmentsSHA256 else {
            throw RecognitionTraceIOError.corruptArchive
        }
        for (description, bytes) in zip(metadata.planes, planes) {
            guard bytes.count == description.bytesPerRow * description.height,
                  Self.digest(bytes) == description.sha256 else { throw RecognitionTraceIOError.corruptArchive }
        }
    }

    private static func isDigest(_ value: String) -> Bool {
        value.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    private static func readFile(_ name: String, from directory: URL, maximumBytes: Int) throws -> Data {
        let root = directory.resolvingSymlinksInPath().standardizedFileURL
        let file = root.appendingPathComponent(name).resolvingSymlinksInPath().standardizedFileURL
        guard file.deletingLastPathComponent().path == root.path else { throw RecognitionTraceIOError.corruptArchive }
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? NSNumber,
              size.int64Value >= 0, size.int64Value <= Int64(maximumBytes) else {
            throw RecognitionTraceIOError.corruptArchive
        }
        let bytes = try Data(contentsOf: file)
        guard bytes.count <= maximumBytes else { throw RecognitionTraceIOError.corruptArchive }
        return bytes
    }

    static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}
