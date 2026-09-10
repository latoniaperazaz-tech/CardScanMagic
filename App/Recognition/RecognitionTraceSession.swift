import CoreImage
import CoreVideo
import Foundation
import ImageIO
import UIKit
import UniformTypeIdentifiers

/// Metadata is locked briefly; pixels are owned copies and disk work is serialized separately.
final class RecognitionTraceSession {
    let runID: String
    let sessionID: UInt64
    let configuration: RecognitionTraceConfiguration
    let directory: URL
    var onLive: ((String, String) -> Void)?
    var onExport: ((URL, Bool) -> Void)?
    private let queue = DispatchQueue(label: "com.cardscanmagic.trace.writer", qos: .utility)
    private let lock = NSLock()
    private let imageContext = CIContext(options: [.cacheIntermediates: false])
    private var queuedBytes = 0
    private var reservedSessionBytes = 0
    private var recognitionCount = 0
    private var omittedRecognitions = 0
    private var droppedFrameMetadata = 0
    private var frameMetadata: [UInt64: [String: Any]] = [:]
    private var errors: [String] = []
    private var latestCompletedID: String?
    private var latestCompletedText = ""
    private var latestRunningID: String?
    private var metadataCost = 0
    // Writer-queue-only state.
    private var attempts: [[String: Any]] = []
    private var artifacts: [String: [String]] = [:]
    private var artifactStates: [String: [[String: Any]]] = [:]
    private var uiReceipts: [String: [[String: Any]]] = [:]

    init(runID: UUID, sessionID: UInt64, configuration: RecognitionTraceConfiguration) {
        self.runID = runID.uuidString; self.sessionID = sessionID; self.configuration = configuration
        directory = configuration.directory.appendingPathComponent("Session-\(runID.uuidString)-\(sessionID)", isDirectory: true)
    }

    func sourceFrame(_ id: UInt64, timestamp: Double, originalWidth: Int, originalHeight: Int,
                     snapshotWidth: Int, snapshotHeight: Int) {
        lock.lock(); defer { lock.unlock() }
        guard frameMetadata.count < configuration.maximumFrameMetadata else { droppedFrameMetadata += 1; return }
        frameMetadata[id] = ["timestamp": timestamp, "originalWidth": originalWidth, "originalHeight": originalHeight,
            "snapshotWidth": snapshotWidth, "snapshotHeight": snapshotHeight,
            "scaleFactor": Double(max(snapshotWidth, snapshotHeight)) / Double(max(originalWidth, originalHeight)),
            "scaleX": Double(snapshotWidth) / Double(originalWidth), "scaleY": Double(snapshotHeight) / Double(originalHeight)]
    }

    func makeTrace(frameID: UInt64, source: String, width: Int, height: Int,
                   timestamp: Double, orientation: CGImagePropertyOrientation) -> RecognitionTrace? {
        lock.lock()
        guard recognitionCount < configuration.maximumRecognitions else {
            omittedRecognitions += 1; lock.unlock(); onLive?("", "Trace 容量已满；本轮导出不完整"); return nil
        }
        recognitionCount += 1
        let metadata = frameMetadata[frameID]
        let lastCompleted = latestCompletedText
        lock.unlock()
        let trace = RecognitionTrace(frameID: frameID, sessionID: sessionID, runID: runID)
        trace.event("recognitionSelected", [
            "source": source, "width": width, "height": height, "timestamp": timestamp,
            "orientation": orientation.rawValue, "original": metadata as Any? ?? NSNull(),
            "testLabel": configuration.testLabel])
        let id = trace.recognitionID
        trace.imageSink = { [weak self] name, image in self?.image(name, image: image, recognitionID: id) }
        trace.overlaySink = { [weak self] name, image, components, uncertain in
            self?.overlay(name, image: image, components: components, uncertain: uncertain, recognitionID: id)
        }
        lock.lock(); latestRunningID = trace.recognitionID; lock.unlock()
        onLive?(trace.recognitionID, "Recognition \(trace.recognitionID.prefix(8)) · running\n\(source) \(width)×\(height)"
            + (lastCompleted.isEmpty ? "" : "\n最近完成：\n" + lastCompleted))
        return trace
    }

    func captureInput(_ buffer: CVPixelBuffer, orientation: CGImagePropertyOrientation, trace: RecognitionTrace) {
        let bytes = RecognitionTracePixels.byteCount(buffer)
        guard reserve(bytes) else {
            artifactState(trace.recognitionID, "recognition_input", "failed", "TRACE_CAPACITY")
            trace.event("traceIO", ["reason": "TRACE_CAPACITY", "artifact": "recognition_input"]); return
        }
        do {
            let packet = try RecognitionTracePixels.capture(buffer, orientation: orientation)
            trace.event("losslessInput", ["pixelFormat": packet.metadata.pixelFormat,
                "orientation": orientation.rawValue, "width": packet.metadata.width, "height": packet.metadata.height,
                "metadataComplete": packet.metadata.metadataComplete,
                "unsupportedAttachments": packet.metadata.unsupportedAttachments])
            let id = trace.recognitionID
            queue.async { [self] in
                defer { release(bytes) }
                let folder = recognitionDirectory(id)
                do {
                    try packet.write(to: folder)
                    artifacts[id, default: []] += packet.metadata.planes.map(\.file)
                        + ["recognition_input.json", packet.metadata.attachmentsFile]
                    if !packet.metadata.metadataComplete { failure("INPUT_METADATA_INCOMPLETE \(id)") }
                    let restored = try packet.restore(strict: false)
                    try writeJPEG(CIImage(cvPixelBuffer: restored).oriented(orientation),
                                  to: folder.appendingPathComponent("recognition_input.jpg"))
                    artifacts[id, default: []].append("recognition_input.jpg")
                    artifactStates[id, default: []].append(["artifact": "recognition_input", "state": "saved",
                        "losslessMetadataComplete": packet.metadata.metadataComplete])
                } catch {
                    artifactStates[id, default: []].append(["artifact": "recognition_input", "state": "failed", "error": String(describing: error)])
                    failure("INPUT_WRITE_FAILED \(id): \(error)")
                }
            }
        } catch {
            release(bytes); failure("INPUT_CAPTURE_FAILED \(trace.recognitionID): \(error)")
            artifactState(trace.recognitionID, "recognition_input", "failed", String(describing: error))
            trace.event("traceIO", ["reason": "INPUT_CAPTURE_FAILED", "error": String(describing: error)])
        }
    }

    func image(_ name: String, image: CIImage, recognitionID: String) {
        let extent = image.extent.integral
        guard !extent.isInfinite, !extent.isEmpty, !extent.isNull,
              extent.minX.isFinite, extent.minY.isFinite, extent.width.isFinite, extent.height.isFinite,
              extent.width <= 8192, extent.height <= 8192,
              name == URL(fileURLWithPath: name).lastPathComponent else {
            artifactState(recognitionID, name, "failed", "INVALID_IMAGE")
            failure("INVALID_IMAGE \(recognitionID)/\(name)"); return
        }
        let width = Int(extent.width), height = Int(extent.height), byteCount = Int(extent.width * extent.height) * 4
        guard reserve(byteCount) else { artifactState(recognitionID, name, "failed", "TRACE_CAPACITY"); return }
        // Freeze the actual stage pixels now. The writer never retains a lazy source CIImage.
        var pixels = Data(count: byteCount)
        pixels.withUnsafeMutableBytes { pointer in
            imageContext.render(image, toBitmap: pointer.baseAddress!, rowBytes: width * 4,
                                bounds: extent, format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
        }
        guard let provider = CGDataProvider(data: pixels as CFData),
              let frozen = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else {
            release(byteCount); failure("IMAGE_FREEZE_FAILED \(recognitionID)/\(name)"); return
        }
        queue.async { [self] in
            defer { release(byteCount) }
            do {
                let folder = recognitionDirectory(recognitionID)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try writeJPEG(frozen, to: folder.appendingPathComponent(name))
                artifacts[recognitionID, default: []].append(name)
                artifactStates[recognitionID, default: []].append(["artifact": name, "state": "saved"])
            } catch {
                artifactStates[recognitionID, default: []].append(["artifact": name, "state": "failed", "error": String(describing: error)])
                failure("IMAGE_WRITE_FAILED \(recognitionID)/\(name): \(error)")
            }
        }
    }

    private func overlay(_ name: String, image: CIImage, components: [[String: Any]],
                         uncertain: [CGRect], recognitionID: String) {
        guard let cg = imageContext.createCGImage(image, from: image.extent),
              let canvas = CGContext(data: nil, width: cg.width, height: cg.height,
                bitsPerComponent: 8, bytesPerRow: cg.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            failure("OVERLAY_RENDER_FAILED \(recognitionID)"); return
        }
        let bounds = CGRect(x: 0, y: 0, width: cg.width, height: cg.height)
        canvas.draw(cg, in: bounds)
        canvas.setLineWidth(1.5)
        for rect in uncertain {
            canvas.setFillColor(UIColor.yellow.withAlphaComponent(0.25).cgColor)
            canvas.fill(CGRect(x: rect.minX * bounds.width, y: rect.minY * bounds.height,
                               width: rect.width * bounds.width, height: rect.height * bounds.height))
        }
        for component in components {
            guard let box = component["boundingBox"] as? [String: Double],
                  let x = box["x"], let y = box["y"], let width = box["width"], let height = box["height"] else { continue }
            let retained = component["retained"] as? Bool == true
            let color: UIColor = component["clipped"] as? Bool == true ? .cyan : (retained ? .green : .red)
            canvas.setStrokeColor(color.cgColor)
            canvas.stroke(CGRect(x: x, y: y, width: width, height: height))
            if let center = component["center"] as? [String: Double], let px = center["x"], let py = center["y"] {
                canvas.setFillColor(color.cgColor)
                canvas.fillEllipse(in: CGRect(x: px * bounds.width - 2, y: py * bounds.height - 2, width: 4, height: 4))
            }
        }
        guard let result = canvas.makeImage() else { failure("OVERLAY_IMAGE_FAILED \(recognitionID)"); return }
        self.image(name, image: CIImage(cgImage: result), recognitionID: recognitionID)
    }

    func complete(_ trace: RecognitionTrace) {
        trace.imageSink = nil
        trace.overlaySink = nil
        let snapshot = trace.snapshot()
        let live = RecognitionTracePresentation.text(snapshot)
        lock.lock()
        latestCompletedID = trace.recognitionID; latestCompletedText = live
        if latestRunningID == trace.recognitionID { latestRunningID = nil }
        lock.unlock()
        onLive?(trace.recognitionID, live)
        // Queue only a bounded snapshot; retain lightweight indexes after writing.
        // Keeping every full snapshot until session end otherwise scales to gigabytes.
        let cost = max(4096, trace.estimatedBytes)
        guard reserveMetadata(cost) else {
            lock.lock(); omittedRecognitions += 1; lock.unlock()
            return
        }
        queue.async { [self] in
            defer { releaseMetadata(cost) }
            do {
                let folder = recognitionDirectory(trace.recognitionID)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try RecognitionTraceJSON.data(snapshot).write(to: folder.appendingPathComponent("recognition_trace.json"), options: .atomic)
                attempts.append(["recognitionID": trace.recognitionID, "frameID": String(trace.frameID),
                    "metadataComplete": trace.truncatedEntries == 0])
            } catch { failure("TRACE_WRITE_FAILED \(trace.recognitionID): \(error)") }
        }
    }

    func recordUI(recognitionID: String, records: [[String: Any]]) {
        queue.async { [self] in uiReceipts[recognitionID, default: []] += records }
        lock.lock()
        let text = latestCompletedID == recognitionID && latestRunningID == nil ? latestCompletedText : nil
        lock.unlock()
        if let text { onLive?(recognitionID, text + "\nUI: " + RecognitionTracePresentation.value(records)) }
    }

    func finish(_ summary: Phase1DebugSummary) {
        // Called only after existing camera, recognition and asynchronous UI receipts have finished.
        queue.async { [self] in
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                try encoder.encode(summary).write(to: directory.appendingPathComponent("Phase1DebugSummary.json"), options: .atomic)
                try summary.text.write(to: directory.appendingPathComponent("Phase1DebugSummary.txt"), atomically: true, encoding: .utf8)
                var index: [[String: Any]] = []
                for retained in attempts {
                    guard let id = retained["recognitionID"] as? String,
                          let frameText = retained["frameID"] as? String, let frame = UInt64(frameText) else { continue }
                    let traceURL = recognitionDirectory(id).appendingPathComponent("recognition_trace.json")
                    guard var attempt = try JSONSerialization.jsonObject(with: Data(contentsOf: traceURL)) as? [String: Any] else {
                        throw RecognitionTraceIOError.corruptArchive
                    }
                    let windows = summary.events.filter { $0.frameIDs.contains(frame) }
                    attempt["captureWindowIDs"] = windows.map { String($0.eventID) }
                    attempt["artifacts"] = artifacts[id] ?? []
                    attempt["artifactStates"] = artifactStates[id] ?? []
                    attempt["uiReceipts"] = uiReceipts[id] ?? []
                    let names = artifacts[id] ?? []
                    attempt["inputSaved"] = names.contains("recognition_input.json")
                    attempt["testLabel"] = configuration.testLabel
                    attempt["inputState"] = names.contains("recognition_input.json") ? "saved" : "notSaved"
                    let folder = recognitionDirectory(id)
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    try RecognitionTraceJSON.data(attempt).write(to: folder.appendingPathComponent("recognition_trace.json"), options: .atomic)
                    index.append(["recognitionID": id, "frameID": String(frame),
                        "captureWindowIDs": windows.map { String($0.eventID) },
                        "traceFile": "Recognition-\(id)/recognition_trace.json"])
                }
                for event in summary.events {
                    let folder = directory.appendingPathComponent("Event-\(event.eventID)")
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    let eventData = try JSONSerialization.jsonObject(with: encoder.encode(event))
                    let linked = index.filter { ($0["captureWindowIDs"] as? [String] ?? []).contains(String(event.eventID)) }
                    try RecognitionTraceJSON.data(["event": eventData, "recognitions": linked,
                        "associationMeaning": "capture windows, not physical identity; references the containing Session"])
                        .write(to: folder.appendingPathComponent("event_manifest.json"), options: .atomic)
                }
                lock.lock()
                let errors = self.errors, omitted = omittedRecognitions, dropped = droppedFrameMetadata
                lock.unlock()
                let complete = errors.isEmpty && omitted == 0 && dropped == 0 && summary.metadataComplete
                    && attempts.allSatisfy { ($0["metadataComplete"] as? Bool) == true }
                let manifest: [String: Any] = [
                    "schemaVersion": 1, "runID": runID, "sessionID": String(sessionID),
                    "testLabel": configuration.testLabel, "complete": complete,
                    "recognitions": index, "errors": errors, "omittedRecognitions": omitted,
                    "droppedFrameMetadata": dropped, "phase1MetadataComplete": summary.metadataComplete,
                    "build": Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown",
                    "sourceRevision": Bundle.main.infoDictionary?["TraceSourceRevision"] as? String ?? "unknown",
                    "modelSHA256": Bundle.main.infoDictionary?["TraceModelSHA256"] as? String ?? "unknown",
                    "systemVersion": ProcessInfo.processInfo.operatingSystemVersionString,
                    "device": UIDevice.current.model,
                    "snapshotMaximumDimension": summary.snapshotMaximumDimension,
                    "queuedByteLimit": configuration.maximumQueuedBytes,
                    "sessionByteLimit": configuration.maximumSessionBytes,
                    "reason": summary.reason, "finishedAt": ISO8601DateFormatter().string(from: Date())]
                try RecognitionTraceJSON.data(manifest).write(to: directory.appendingPathComponent("session_manifest.json"), options: .atomic)
                onExport?(directory, complete)
                // A comparison failure cannot invalidate an already exported Session.
                do { try RecognitionTraceComparison.update(in: configuration.directory) }
                catch { onLive?("", "Session 已保存，A/B 报告生成失败：\(error)") }
            } catch {
                failure("SESSION_EXPORT_FAILED: \(error)")
                onLive?("", "Trace 导出失败：\(error)")
                onExport?(directory, false)
            }
        }
    }

    func flush(_ completion: @escaping () -> Void) { queue.async(execute: completion) }

    private func recognitionDirectory(_ id: String) -> URL {
        directory.appendingPathComponent("Recognition-\(id)", isDirectory: true)
    }
    private func artifactState(_ id: String, _ artifact: String, _ state: String, _ reason: String) {
        queue.async { [self] in
            artifactStates[id, default: []].append(["artifact": artifact, "state": state, "reason": reason])
        }
    }
    private func reserve(_ count: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard count > 0, count <= configuration.maximumQueuedBytes - queuedBytes,
              count <= configuration.maximumSessionBytes - reservedSessionBytes else {
            if errors.count < 100 { errors.append("TRACE_CAPACITY requested=\(count)") }
            return false
        }
        queuedBytes += count; reservedSessionBytes += count; return true
    }
    private func reserveMetadata(_ count: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard count > 0, count <= 32 * 1024 * 1024 - metadataCost else {
            if errors.count < 100 { errors.append("TRACE_METADATA_QUEUE_CAPACITY requested=\(count)") }
            return false
        }
        metadataCost += count; return true
    }
    private func releaseMetadata(_ count: Int) { lock.lock(); metadataCost -= count; lock.unlock() }
    private func release(_ count: Int) { lock.lock(); queuedBytes -= count; lock.unlock() }
    private func failure(_ message: String) {
        lock.lock(); if errors.count < 100 { errors.append(message) }; lock.unlock()
    }
    private func writeJPEG(_ image: CIImage, to file: URL) throws {
        guard let cg = imageContext.createCGImage(image, from: image.extent) else { throw RecognitionTraceIOError.imageEncoding }
        try writeJPEG(cg, to: file)
    }
    private func writeJPEG(_ image: CGImage, to file: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(file as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw RecognitionTraceIOError.imageEncoding
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.95] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw RecognitionTraceIOError.imageEncoding }
    }
}
