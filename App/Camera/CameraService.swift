import AVFoundation
import Foundation
import ImageIO
import UIKit

enum CameraError: LocalizedError {
    case accessDenied
    case noRearCamera
    case cannotAddInput
    case cannotAddOutput

    var errorDescription: String? {
        switch self {
        case .accessDenied: return "请在系统设置中允许此 App 使用相机。"
        case .noRearCamera: return "找不到后置摄像头。"
        case .cannotAddInput: return "无法连接后置摄像头。"
        case .cannotAddOutput: return "无法读取摄像头画面。"
        }
    }
}

final class CameraService: NSObject {
    let session = AVCaptureSession()
    /// The orientation accompanying each callback describes the exact pixel
    /// buffer delivered by AVCaptureVideoDataOutput. Some camera formats keep
    /// the sensor's landscape memory while others deliver portrait pixels, so
    /// this is determined per sample rather than assumed at setup time.
    var onFrame: ((CVPixelBuffer, TimeInterval, CGImagePropertyOrientation) -> Void)?
    var onError: ((Error) -> Void)?
    var onModeChanged: ((Int) -> Void)?

    private let sessionQueue = DispatchQueue(label: "com.cardscanmagic.camera.session")
    private let outputQueue = DispatchQueue(label: "com.cardscanmagic.camera.frames")
    private let runStateLock = NSLock()
    private var isConfigured = false
    private var configuredFrameRate = 30
    private var wantsToRun = false
    private let outputOrientation: AVCaptureVideoOrientation = .portrait

    func start() {
        setWantsToRun(true)
        requestAccess { [weak self] granted in
            guard let self else { return }
            guard granted else {
                self.report(CameraError.accessDenied)
                return
            }
            self.sessionQueue.async {
                guard self.isWantedToRun else { return }
                do {
                    let frameRate = try self.configureIfNeeded()
                    guard !self.session.isRunning else {
                        DispatchQueue.main.async { [weak self] in
                            self?.onModeChanged?(frameRate)
                        }
                        return
                    }
                    self.session.startRunning()
                    DispatchQueue.main.async { [weak self] in
                        UIApplication.shared.isIdleTimerDisabled = true
                        self?.onModeChanged?(frameRate)
                    }
                } catch {
                    self.report(error)
                }
            }
        }
    }

    func stop() {
        setWantsToRun(false)
        sessionQueue.async { [weak self] in
            guard let self else { return }
            if self.session.isRunning {
                self.session.stopRunning()
            }
            DispatchQueue.main.async { UIApplication.shared.isIdleTimerDisabled = false }
        }
    }

    private func requestAccess(completion: @escaping (Bool) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            completion(true)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video, completionHandler: completion)
        default:
            completion(false)
        }
    }

    /// Prefer a virtual rear-camera device when the phone offers one. On an
    /// iPhone 14 Pro this gives AVFoundation its virtual multi-camera device,
    /// allowing its normal automatic lens selection to choose a close-focus
    /// constituent camera as a card passes very near the phone. Older phones
    /// retain the same physical-wide-camera fallback as before.
    private func preferredRearCamera() -> AVCaptureDevice? {
        let preferredTypes: [AVCaptureDevice.DeviceType] = [
            .builtInTripleCamera,
            .builtInDualWideCamera,
            .builtInWideAngleCamera
        ]
        let devices = AVCaptureDevice.DiscoverySession(
            deviceTypes: preferredTypes,
            mediaType: .video,
            position: .back
        ).devices

        return preferredTypes.compactMap { type in
            devices.first { $0.deviceType == type }
        }.first
    }

    private func configureIfNeeded() throws -> Int {
        guard !isConfigured else { return configuredFrameRate }
        guard let camera = preferredRearCamera() else {
            throw CameraError.noRearCamera
        }

        let input = try AVCaptureDeviceInput(device: camera)
        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: outputQueue)
        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        ]

        session.beginConfiguration()
        var wasConfigured = false
        defer {
            if !wasConfigured {
                if session.inputs.contains(where: { $0 === input }) {
                    session.removeInput(input)
                }
                if session.outputs.contains(where: { $0 === output }) {
                    session.removeOutput(output)
                }
            }
            session.commitConfiguration()
        }
        session.sessionPreset = .inputPriority

        guard session.canAddInput(input) else { throw CameraError.cannotAddInput }
        session.addInput(input)

        guard session.canAddOutput(output) else { throw CameraError.cannotAddOutput }
        session.addOutput(output)

        let frameRate = configureBestFrameRate(for: camera)
        if let connection = output.connection(with: .video) {
            // Set the connection when the output supports it so the preview
            // and video-data stream use the same display orientation. This is
            // not guaranteed to rotate the CVPixelBuffer's backing memory on
            // every iOS/camera format, however; captureOutput therefore
            // derives Vision's orientation from each buffer's dimensions.
            if connection.isVideoOrientationSupported {
                connection.videoOrientation = outputOrientation
            }
            if connection.isVideoStabilizationSupported {
                connection.preferredVideoStabilizationMode = .off
            }
        }
        isConfigured = true
        configuredFrameRate = frameRate
        wasConfigured = true
        return frameRate
    }

    @discardableResult
    private func configureBestFrameRate(for camera: AVCaptureDevice) -> Int {
        // The neural model is intentionally capped near 30 inferences/sec, so
        // 240 capture fps only makes individual frames darker indoors without
        // yielding more model decisions. A virtual multi-camera gets 60 fps
        // first: it doubles available exposure time and gives its automatic
        // close-focus lens switch a stable card image, while still sampling
        // more frames than the recognizer consumes. Other phones retain the
        // 120 fps preference.
        // Prefer 1080p formats, then fall back to the clearest supported mode.
        let usesVirtualRearCamera = [
            AVCaptureDevice.DeviceType.builtInTripleCamera,
            .builtInDualWideCamera
        ].contains(camera.deviceType)
        let desiredRates = usesVirtualRearCamera ? [60, 120] : [120, 60]
        let formats = camera.formats.compactMap { format -> (format: AVCaptureDevice.Format, width: Int32, height: Int32, rate: Int)? in
            let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            guard let rate = desiredRates.first(where: { supports(frameRate: Double($0), in: format) }) else {
                return nil
            }
            return (format, dimensions.width, dimensions.height, rate)
        }
        let preferredFormats = formats.filter {
            hasDimensions($0.format, width: 1920, height: 1080)
        }
        let selectionPool = preferredFormats.isEmpty ? formats : preferredFormats
        let selected = selectionPool
            .sorted { lhs, rhs in
                if lhs.rate != rhs.rate { return lhs.rate > rhs.rate }
                let lhsArea = Int64(lhs.width) * Int64(lhs.height)
                let rhsArea = Int64(rhs.width) * Int64(rhs.height)
                return lhsArea > rhsArea
            }
            .first

        do {
            try camera.lockForConfiguration()
            defer { camera.unlockForConfiguration() }
            if let selected {
                camera.activeFormat = selected.format
                let duration = CMTime(value: 1, timescale: CMTimeScale(selected.rate))
                camera.activeVideoMinFrameDuration = duration
                camera.activeVideoMaxFrameDuration = duration
            }
            if camera.isFocusModeSupported(.continuousAutoFocus) {
                camera.focusMode = .continuousAutoFocus
            }
            if camera.isExposureModeSupported(.continuousAutoExposure) {
                camera.exposureMode = .continuousAutoExposure
            }
            if camera.isSmoothAutoFocusSupported {
                camera.isSmoothAutoFocusEnabled = false
            }
            if camera.isAutoFocusRangeRestrictionSupported {
                camera.autoFocusRangeRestriction = .near
            }
            if let selected {
                return selected.rate
            }
        } catch {
            return 30
        }

        // A very old or unusual camera can have neither mode. Leave its
        // default timing untouched instead of asking for an unsupported rate.
        let maximumRate = camera.activeFormat.videoSupportedFrameRateRanges
            .map(\.maxFrameRate)
            .max() ?? 30
        return max(1, Int(maximumRate.rounded(.down)))
    }

    private func supports(frameRate: Double, in format: AVCaptureDevice.Format) -> Bool {
        format.videoSupportedFrameRateRanges.contains {
            $0.minFrameRate <= frameRate && $0.maxFrameRate >= frameRate
        }
    }

    private func hasDimensions(_ format: AVCaptureDevice.Format, width: Int32, height: Int32) -> Bool {
        let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
        return dimensions.width == width && dimensions.height == height
    }

    private func report(_ error: Error) {
        DispatchQueue.main.async { [weak self] in self?.onError?(error) }
    }

    private var isWantedToRun: Bool {
        runStateLock.lock()
        defer { runStateLock.unlock() }
        return wantsToRun
    }

    private func setWantsToRun(_ value: Bool) {
        runStateLock.lock()
        wantsToRun = value
        runStateLock.unlock()
    }
}

extension CameraService: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
        // A video-data connection may expose either the sensor's native
        // landscape buffer or a physically rotated portrait buffer. Use the
        // dimensions of this exact sample rather than a one-time assumption
        // made during session setup. This also covers devices where
        // `isVideoOrientationSupported` is false (the normal rear-camera
        // fallback is `.right`).
        let orientation = Self.visionOrientation(for: pixelBuffer)
        onFrame?(pixelBuffer, timestamp, orientation)
    }

    static func visionOrientation(for pixelBuffer: CVPixelBuffer) -> CGImagePropertyOrientation {
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)

        guard width > 0, height > 0 else {
            // Invalid dimensions are not expected from AVCaptureVideoDataOutput,
            // but `.right` is the safe rear-camera sensor fallback if one does
            // occur.
            return .right
        }

        // Rear-camera sensor buffers are landscape. A clockwise quarter-turn
        // presents them in the app's locked portrait orientation. If the
        // output has already rotated the pixels, width < height and no Vision
        // rotation is needed.
        return width > height ? .right : .up
    }
}
