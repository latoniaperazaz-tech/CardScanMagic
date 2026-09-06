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
    private let request: VNCoreMLRequest

    init() throws {
        guard let modelURL = Bundle.main.url(forResource: "CardDetector", withExtension: "mlmodelc") else {
            throw RecognitionError.modelMissing
        }
        let configuration = MLModelConfiguration()
        // The preview compositor needs the GPU; keeping inference on the ANE
        // makes camera timing steadier on an iPhone 14 Pro.
        configuration.computeUnits = .cpuAndNeuralEngine
        let model = try MLModel(contentsOf: modelURL, configuration: configuration)
        request = VNCoreMLRequest(model: try VNCoreMLModel(for: model))
        // Unlike scale-fill, scale-fit keeps every part of the camera view in
        // scope, which is essential because cards may enter anywhere.
        request.imageCropAndScaleOption = .scaleFit
    }

    func recognize(
        pixelBuffer: CVPixelBuffer,
        orientation: CGImagePropertyOrientation
    ) throws -> [CardDetection] {
        // CameraService explicitly requests portrait video data and carries
        // that same orientation here. Do not infer it from width/height: a
        // camera format may be physically landscape even when the preview is
        // portrait, which was the source of the misaligned thin overlays.
        let orientedImageSize = Self.orientedImageSize(
            for: pixelBuffer,
            orientation: orientation
        )
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: orientation)
        try handler.perform([request])

        guard let observations = request.results as? [VNRecognizedObjectObservation] else {
            throw RecognitionError.modelUnsupported
        }

        return observations.compactMap { observation in
            guard let label = observation.labels.first,
                  let card = CardFace.parse(label.identifier) else {
                return nil
            }
            return CardDetection(
                card: card,
                confidence: label.confidence,
                boundingBox: observation.boundingBox,
                orientedImageSize: orientedImageSize
            )
        }
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
