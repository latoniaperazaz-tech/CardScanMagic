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

    func recognize(pixelBuffer: CVPixelBuffer) throws -> [CardDetection] {
        // AVCaptureVideoDataOutput may deliver either the sensor's native
        // landscape buffer or an already-rotated portrait buffer depending on
        // the selected camera format/iOS version.  Passing `.up` blindly for
        // the rear camera makes Vision see a portrait card sideways on some
        // devices, which is especially damaging to rank/suit classification.
        // Derive the orientation from the actual buffer so the same build works
        // with both kinds of output.
        let orientation = Self.orientation(for: pixelBuffer)
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
                boundingBox: observation.boundingBox
            )
        }
    }

    /// The rear camera is configured for portrait output.  A landscape pixel
    /// buffer therefore needs a clockwise quarter turn before Vision sees the
    /// portrait image; a portrait buffer is already correctly oriented.
    /// Keeping this helper pure also makes the orientation decision easy to
    /// verify without requiring a camera in tests.
    static func orientation(for pixelBuffer: CVPixelBuffer) -> CGImagePropertyOrientation {
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        return width > height ? .right : .up
    }
}
