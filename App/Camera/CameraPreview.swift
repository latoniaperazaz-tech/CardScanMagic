import AVFoundation
import SwiftUI
import UIKit

struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession
    let detections: [CardDetection]

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.configure(session: session, detections: detections)
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {
        uiView.configure(session: session, detections: detections)
    }
}

/// The overlay is laid out by AVCaptureVideoPreviewLayer itself. With
/// `.resizeAspectFill`, raw view-size multiplication is wrong because the
/// camera image is cropped before it reaches the screen.
final class PreviewView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }

    var previewLayer: AVCaptureVideoPreviewLayer {
        guard let layer = layer as? AVCaptureVideoPreviewLayer else {
            fatalError("PreviewView must use AVCaptureVideoPreviewLayer")
        }
        return layer
    }

    private let overlayView = UIView()
    private var displayedDetections: [CardDetection] = []
    private var detectionViews: [DetectionBoxView] = []

    override init(frame: CGRect) {
        super.init(frame: frame)
        configureView()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureView()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        overlayView.frame = bounds
        redrawDetections()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        applyPortraitOrientation()
    }

    func configure(session: AVCaptureSession, detections: [CardDetection]) {
        if previewLayer.session !== session {
            previewLayer.session = session
        }
        applyPortraitOrientation()
        updateDetections(detections)
    }

    private func configureView() {
        backgroundColor = .black
        previewLayer.videoGravity = .resizeAspectFill

        overlayView.backgroundColor = .clear
        overlayView.isUserInteractionEnabled = false
        overlayView.isAccessibilityElement = false
        overlayView.accessibilityElementsHidden = true
        overlayView.clipsToBounds = true
        addSubview(overlayView)
    }

    private func applyPortraitOrientation() {
        guard let connection = previewLayer.connection,
              connection.isVideoOrientationSupported else {
            return
        }
        connection.videoOrientation = .portrait
    }

    private func updateDetections(_ detections: [CardDetection]) {
        displayedDetections = detections
        redrawDetections()
    }

    private func redrawDetections() {
        guard !bounds.isEmpty else { return }

        let visibleDetections = Array(displayedDetections.prefix(12))
        while detectionViews.count < visibleDetections.count {
            let boxView = DetectionBoxView()
            detectionViews.append(boxView)
            overlayView.addSubview(boxView)
        }

        UIView.performWithoutAnimation {
            for (index, detection) in visibleDetections.enumerated() {
                let boxView = detectionViews[index]
                let rect = overlayRect(for: detection.boundingBox)
                let isVisible = !rect.isNull && !rect.isEmpty && rect.intersects(bounds)

                boxView.isHidden = !isVisible
                guard isVisible else { continue }
                boxView.frame = rect.integral
                boxView.configure(with: detection)
            }

            for boxView in detectionViews.dropFirst(visibleDetections.count) {
                boxView.isHidden = true
            }
        }
    }

    private func overlayRect(for visionRect: CGRect) -> CGRect {
        let unitRect = CGRect(x: 0, y: 0, width: 1, height: 1)
        let clippedVisionRect = visionRect.standardized.intersection(unitRect)
        guard !clippedVisionRect.isNull, !clippedVisionRect.isEmpty else {
            return .null
        }

        // Vision has a lower-left origin. Metadata output coordinates use the
        // upper-left origin consumed by AVCaptureVideoPreviewLayer.
        let metadataRect = CGRect(
            x: clippedVisionRect.minX,
            y: 1 - clippedVisionRect.maxY,
            width: clippedVisionRect.width,
            height: clippedVisionRect.height
        )
        return previewLayer.layerRectConverted(fromMetadataOutputRect: metadataRect)
    }
}

private final class DetectionBoxView: UIView {
    private let borderLayer = CAShapeLayer()
    private let label = UILabel()

    override init(frame: CGRect = .zero) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        clipsToBounds = false

        borderLayer.fillColor = UIColor.clear.cgColor
        borderLayer.lineWidth = 3
        borderLayer.lineJoin = .round
        layer.addSublayer(borderLayer)

        label.font = .monospacedDigitSystemFont(ofSize: 12, weight: .bold)
        label.textAlignment = .center
        label.clipsToBounds = true
        label.isAccessibilityElement = false
        label.layer.cornerRadius = 5
        addSubview(label)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()

        borderLayer.frame = bounds
        let insetX = min(1.5, bounds.width / 2)
        let insetY = min(1.5, bounds.height / 2)
        let borderRect = bounds.insetBy(dx: insetX, dy: insetY)
        borderLayer.path = UIBezierPath(
            roundedRect: borderRect,
            cornerRadius: min(6, min(borderRect.width, borderRect.height) / 2)
        ).cgPath

        let labelHeight: CGFloat = 22
        let labelWidth = min(max(label.intrinsicContentSize.width + 12, 54), 132)
        let preferredLabelY = frame.minY < labelHeight + 6 ? 4 : -labelHeight - 5
        let containerBounds = superview?.bounds ?? .null
        let minimumLabelX = -frame.minX
        let maximumLabelX = containerBounds.width - frame.minX - labelWidth
        let minimumLabelY = -frame.minY
        let maximumLabelY = containerBounds.height - frame.minY - labelHeight
        let labelX = min(max(0, minimumLabelX), maximumLabelX)
        let labelY = min(max(preferredLabelY, minimumLabelY), maximumLabelY)
        label.frame = CGRect(x: labelX, y: labelY, width: labelWidth, height: labelHeight)
    }

    func configure(with detection: CardDetection) {
        let isRed: Bool
        switch detection.card.suit {
        case .hearts?, .diamonds?:
            isRed = true
        case .clubs?, .spades?, nil:
            isRed = false
        }
        let color = isRed ? UIColor.systemRed : UIColor.white
        borderLayer.strokeColor = color.cgColor
        label.backgroundColor = color
        label.textColor = isRed ? .white : .black
        label.text = "\(detection.card.displayText)  \(Int(detection.confidence * 100))%"
        setNeedsLayout()
    }
}
