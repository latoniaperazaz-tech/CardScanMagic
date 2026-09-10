import CoreML
import CoreVideo
import Foundation
import ImageIO
import Vision

enum RecognitionError: LocalizedError {
    case modelMissing
    case modelUnsupported

    var errorDescription: String? {
        switch self {
        case .modelMissing:
            return "找不到扑克牌模型。请先导出并加入 CardDetector.mlpackage。"
        case .modelUnsupported:
            return "模型输出格式不适合 iPhone 识别层。请用项目内的导出脚本重新导出。"
        }
    }
}

/// The exported YOLO model contains Apple's NMS pipeline. Vision scales the
/// full camera frame to the model input and turns its output into labelled
/// object observations, including the model's `10h`/`As` card labels.
final class RecognitionEngine {
    private struct RegionRequest {
        let request: VNCoreMLRequest
        let region: CGRect
    }

    private static let fullFrameRegion = CGRect(x: 0, y: 0, width: 1, height: 1)
    // A 9:16 portrait frame becomes two roughly square model windows when its
    // height is split. Keep 1/8 of the height overlapped so a corner crossing
    // the tile boundary is visible in both requests.
    private static let nearTileSpan: CGFloat = 9.0 / 16.0
    private static let nearTileOverlap: CGFloat = 1.0 / 8.0

    // Keep this preflight in sync with CardEventCoordinator's first-pass
    // filters. Vision can return a low-confidence or tiny corner observation
    // even when the close card itself is not yet readable. Such an observation
    // must not suppress the magnified ROI pass, otherwise the coordinator will
    // discard it later and the UI appears to do nothing.
    private static let minimumFallbackConfidence: Float = 0.45
    private static let minimumFallbackBoxArea: CGFloat = 0.0007
    private static let minimumFallbackVisibleFraction: CGFloat = 0.20
    private static let minimumFallbackShortSide: CGFloat = 0.015
    private static let minimumFallbackShortToLongAspect: CGFloat = 0.20
    private static let minimumFallbackShortSidePixels: CGFloat = 18

    private let fullFrameRequest: VNCoreMLRequest
    private let portraitNearRequests: [RegionRequest]
    private let landscapeNearRequests: [RegionRequest]
    private let partialExtractor = PartialCardFeatureExtractor()

    init() throws {
        guard let modelURL = Bundle.main.url(forResource: "CardDetector", withExtension: "mlmodelc") else {
            throw RecognitionError.modelMissing
        }
        let configuration = MLModelConfiguration()
        // The preview compositor needs the GPU; keeping inference on the ANE
        // makes camera timing steadier on an iPhone 14 Pro.
        configuration.computeUnits = .cpuAndNeuralEngine
        let model = try MLModel(contentsOf: modelURL, configuration: configuration)
        let visionModel = try VNCoreMLModel(for: model)

        // Unlike scale-fill, scale-fit keeps every part of the camera view in
        // scope, which is essential because cards may enter anywhere.
        fullFrameRequest = Self.makeRequest(model: visionModel, region: Self.fullFrameRegion)

        // Keep independent request instances. Mutating one request's ROI while
        // another Vision request is in flight can otherwise produce stale
        // regions and mismatched overlay coordinates.
        let portraitRegions = Self.nearRegions(for: CGSize(width: 1, height: 2))
        portraitNearRequests = portraitRegions.map {
            RegionRequest(
                request: Self.makeRequest(model: visionModel, region: $0),
                region: $0
            )
        }
        let landscapeRegions = Self.nearRegions(for: CGSize(width: 2, height: 1))
        landscapeNearRequests = landscapeRegions.map {
            RegionRequest(
                request: Self.makeRequest(model: visionModel, region: $0),
                region: $0
            )
        }
    }

    func recognize(
        pixelBuffer: CVPixelBuffer,
        orientation: CGImagePropertyOrientation
    ) throws -> [CardDetection] {
        let trace = RecognitionTrace.current
        trace?.candidateID = nil
        trace?.componentID = nil
        trace?.event("engine.input", ["width": CVPixelBufferGetWidth(pixelBuffer),
            "height": CVPixelBufferGetHeight(pixelBuffer), "orientation": orientation.rawValue,
            "pixelFormat": CVPixelBufferGetPixelFormatType(pixelBuffer), "status": "started"])
        let previousPass = trace?.context["fusionPass"]
        defer {
            trace?.candidateID = nil
            trace?.componentID = nil
            trace?.context["fusionPass"] = previousPass
        }
        // CameraService explicitly requests portrait video data and carries
        // that same orientation here. Do not infer it from width/height: a
        // camera format may be physically landscape even when the preview is
        // portrait, which was the source of the misaligned thin overlays.
        let orientedImageSize = Self.orientedImageSize(
            for: pixelBuffer,
            orientation: orientation
        )
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: orientation)
        RecognitionTrace.call("coreML")
        try handler.perform([fullFrameRequest])

        // The full-frame pass is the normal path. A close card can occupy too
        // few model pixels after scale-fit, and Vision may still return a weak
        // false observation. Only a result that could survive the coordinator
        // is allowed to suppress the two magnified fallback requests.
        let fullFrameDetections = try detections(
            from: fullFrameRequest,
            region: nil,
            orientedImageSize: orientedImageSize
        )
        trace?.event("engine.model", ["pass": "full", "modelDetections": RecognitionTrace.detections(fullFrameDetections)])
        let features = try partialExtractor.extract(pixelBuffer: pixelBuffer, orientation: orientation)
        let evidence = Self.partialEvidence(from: features)
        var modelDetections = fullFrameDetections
        trace?.context["fusionPass"] = "first"
        let firstPass = PartialEvidenceFusion.fuse(model: modelDetections, local: evidence,
                                                   imageSize: orientedImageSize)
        if Self.shouldUseNearFallback(for: firstPass) {
            trace?.event("engine.nearFallback", ["status": "started"])
            let nearRequests = orientedImageSize.height >= orientedImageSize.width
                ? portraitNearRequests : landscapeNearRequests
            for _ in nearRequests { RecognitionTrace.call("coreML") }
            try handler.perform(nearRequests.map(\.request))
            modelDetections += try nearRequests.flatMap { regionRequest in
                try detections(from: regionRequest.request, region: regionRequest.region,
                               orientedImageSize: orientedImageSize)
            }
        } else {
            trace?.event("engine.nearFallback", ["status": "notRun", "reason": "USABLE_FIRST_PASS"])
        }
        trace?.event("engine.model", ["pass": "combined", "modelDetections": RecognitionTrace.detections(modelDetections)])
        trace?.context["fusionPass"] = "final"
        let result = PartialEvidenceFusion.fuse(model: modelDetections, local: evidence,
                                          imageSize: orientedImageSize)
        trace?.event("engine.final", ["status": "completed", "finalDetections": RecognitionTrace.detections(result)])
        return result
    }

    /// Shared with image integration tests so OCR-free fixtures exercise the
    /// same topology/visibility handoff as live RecognitionEngine frames.
    static func partialEvidence(from features: [PartialCardFeatures]) -> [PartialEvidenceFusion.Evidence] {
        features.map {
            let trace = RecognitionTrace.current
            let previous = trace?.candidateID
            trace?.candidateID = $0.traceCandidateID
            defer { trace?.candidateID = previous }
            return PartialEvidenceFusion.Evidence(features: $0, layout: PartialRankEstimator.infer(
                points: $0.pipCenters, imageAspectRatio: $0.imageAspectRatio,
                visibleRegion: $0.visibleRegion,
                uncertainRegions: $0.uncertainRegions,
                surfaceAnchored: $0.surfaceAnchored))
        }
    }

    private static func makeRequest(
        model: VNCoreMLModel,
        region: CGRect
    ) -> VNCoreMLRequest {
        let request = VNCoreMLRequest(model: model)
        request.imageCropAndScaleOption = .scaleFit
        request.regionOfInterest = region
        return request
    }

    private func detections(
        from request: VNCoreMLRequest,
        region: CGRect?,
        orientedImageSize: CGSize
    ) throws -> [CardDetection] {
        guard let observations = request.results as? [VNRecognizedObjectObservation] else {
            RecognitionTrace.current?.event("engine.model", ["status": "error", "reason": "MODEL_OUTPUT_UNSUPPORTED",
                "region": region.map { RecognitionTrace.rect($0) } as Any? ?? NSNull()])
            throw RecognitionError.modelUnsupported
        }

        RecognitionTrace.current?.event("engine.modelObservations", [
            "region": region.map { RecognitionTrace.rect($0) } as Any? ?? NSNull(),
            "observations": observations.map { observation in
                ["boundingBox": RecognitionTrace.rect(observation.boundingBox),
                 "labels": observation.labels.map { ["identifier": $0.identifier, "confidence": $0.confidence] as [String: Any] }]
            }])
        let result: [CardDetection] = observations.compactMap { observation in
            guard let label = observation.labels.first,
                  let card = CardFace.parse(label.identifier) else {
                return nil
            }

            let boundingBox = region.map {
                Self.mapBoundingBox(observation.boundingBox, from: $0)
            } ?? observation.boundingBox
            return CardDetection(
                card: card,
                confidence: label.confidence,
                boundingBox: boundingBox,
                orientedImageSize: orientedImageSize
            )
        }
        RecognitionTrace.current?.event("engine.modelPass", [
            "region": region.map { RecognitionTrace.rect($0) } as Any? ?? NSNull(),
            "modelDetections": RecognitionTrace.detections(result)])
        return result
    }

    /// Returns true when the normal full-frame result is too weak to trust.
    /// The caller should run the magnified near-card tiles in that case.
    ///
    /// This is intentionally a little duplicate of CardEventCoordinator's
    /// sanitization gate. RecognitionEngine needs the decision before handing
    /// detections to the coordinator; sharing the same conservative values
    /// prevents a weak result from short-circuiting the only useful fallback.
    static func shouldUseNearFallback(for detections: [CardDetection]) -> Bool {
        !detections.contains(where: isUsableFullFrameDetection)
    }

    private static func isUsableFullFrameDetection(_ detection: CardDetection) -> Bool {
        guard detection.confidence.isFinite,
              detection.confidence >= minimumFallbackConfidence,
              detection.orientedImageSize.width.isFinite,
              detection.orientedImageSize.height.isFinite,
              detection.orientedImageSize.width > 0,
              detection.orientedImageSize.height > 0 else {
            return false
        }

        let unitRect = CGRect(x: 0, y: 0, width: 1, height: 1)
        let original = detection.boundingBox.standardized
        guard original.minX.isFinite,
              original.minY.isFinite,
              original.maxX.isFinite,
              original.maxY.isFinite,
              original.width > 0,
              original.height > 0 else {
            return false
        }

        let originalArea = original.width * original.height
        guard originalArea.isFinite, originalArea > 0 else { return false }

        let clipped = original.intersection(unitRect)
        guard !clipped.isNull,
              clipped.width > 0,
              clipped.height > 0 else {
            return false
        }

        let clippedArea = clipped.width * clipped.height
        guard clippedArea >= minimumFallbackBoxArea,
              clippedArea / originalArea >= minimumFallbackVisibleFraction else {
            return false
        }

        let shortSide = min(clipped.width, clipped.height)
        let longSide = max(clipped.width, clipped.height)
        guard shortSide >= minimumFallbackShortSide,
              longSide > 0,
              shortSide / longSide >= minimumFallbackShortToLongAspect else {
            return false
        }

        let minimumImageSide = min(
            detection.orientedImageSize.width,
            detection.orientedImageSize.height
        )
        return minimumImageSide * shortSide >= minimumFallbackShortSidePixels
    }

    /// Returns two overlapping normalized regions covering the complete frame.
    /// Vision's ROI and observation coordinates both use a lower-left origin.
    static func nearRegions(for imageSize: CGSize) -> [CGRect] {
        guard imageSize.width.isFinite,
              imageSize.height.isFinite,
              imageSize.width > 0,
              imageSize.height > 0 else {
            return []
        }

        if imageSize.height >= imageSize.width {
            let upperY = nearTileSpan - nearTileOverlap
            return [
                CGRect(x: 0, y: 0, width: 1, height: nearTileSpan),
                CGRect(x: 0, y: upperY, width: 1, height: nearTileSpan)
            ]
        }

        let rightX = nearTileSpan - nearTileOverlap
        return [
            CGRect(x: 0, y: 0, width: nearTileSpan, height: 1),
            CGRect(x: rightX, y: 0, width: nearTileSpan, height: 1)
        ]
    }

    /// Maps a detection returned in an ROI-local coordinate system to the
    /// full-image normalized coordinate system used by CardEventCoordinator.
    static func mapBoundingBox(_ localBox: CGRect, from region: CGRect) -> CGRect {
        let box = localBox.standardized
        return CGRect(
            x: region.minX + box.minX * region.width,
            y: region.minY + box.minY * region.height,
            width: box.width * region.width,
            height: box.height * region.height
        )
    }

    static func orientedImageSize(
        for pixelBuffer: CVPixelBuffer,
        orientation: CGImagePropertyOrientation
    ) -> CGSize {
        orientedImageSize(
            rawImageSize: CGSize(
                width: CGFloat(CVPixelBufferGetWidth(pixelBuffer)),
                height: CGFloat(CVPixelBufferGetHeight(pixelBuffer))
            ),
            orientation: orientation
        )
    }

    static func orientedImageSize(
        rawImageSize: CGSize,
        orientation: CGImagePropertyOrientation
    ) -> CGSize {
        switch orientation {
        case .left, .right, .leftMirrored, .rightMirrored:
            return CGSize(width: rawImageSize.height, height: rawImageSize.width)
        default:
            return rawImageSize
        }
    }
}
