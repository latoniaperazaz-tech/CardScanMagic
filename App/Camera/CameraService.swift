import AVFoundation
import Foundation
import ImageIO
import UIKit

enum CameraError: LocalizedError {
    case accessDenied
    case noRearCamera
    case cannotAddInput
    case cannotAddOutput
    case unsupportedFrameDuration

    var errorDescription: String? {
        switch self {
        case .accessDenied: return "请在系统设置中允许此 App 使用相机。"
        case .noRearCamera: return "找不到后置摄像头。"
        case .cannotAddInput: return "无法连接后置摄像头。"
        case .cannotAddOutput: return "无法读取摄像头画面。"
        case .unsupportedFrameDuration: return "摄像头帧率配置失败，请重新开始扫描。"
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
    var onDroppedFrame: (() -> Void)?
    var onCallbackCompleted: ((TimeInterval) -> Void)?
    var onError: ((Error) -> Void)?
    var onModeChanged: ((Int) -> Void)?

    private let sessionQueue = DispatchQueue(label: "com.cardscanmagic.camera.session")
    private let outputQueue = DispatchQueue(label: "com.cardscanmagic.camera.frames")
    private let loggingQueue = DispatchQueue(label: "com.cardscanmagic.camera.logging", qos: .utility)
    private let runStateLock = NSLock()
    private let diagnosticsLock = NSLock()
    private var isConfigured = false
    private var configuredFrameRate = 30
    private var wantsToRun = false
    private var activeCamera: AVCaptureDevice?
    private var diagnosticsStartTime: TimeInterval?
    private var diagnosticsFrameCount = 0
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
                    self.resetDiagnostics()
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
            self.resetDiagnostics()
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

    /// Prefer the physical 1x camera so a fast card cannot trigger a virtual
    /// device lens switch while it crosses the recognition zone.
    private func preferredRearCamera() -> AVCaptureDevice? {
        let preferredTypes: [AVCaptureDevice.DeviceType] = [
            .builtInWideAngleCamera,
            .builtInTripleCamera,
            .builtInDualWideCamera
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
        activeCamera = camera

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
                activeCamera = nil
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

        let frameRate = try configureBestFrameRate(for: camera)
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
            logConfiguration(
                camera: camera,
                connection: connection,
                frameRate: frameRate
            )
        }
        isConfigured = true
        configuredFrameRate = frameRate
        wasConfigured = true
        return frameRate
    }

    @discardableResult
    private func configureBestFrameRate(for camera: AVCaptureDevice) throws -> Int {
        // Prefer short sampling intervals for fast passes. Each timing value
        // remains clamped to the selected device format's rational bounds.
        let desiredRates = CameraCapturePolicy.preferredFrameRates
        let formats = camera.formats.enumerated().compactMap { index, format -> (format: AVCaptureDevice.Format, option: CameraFormatOption)? in
            let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            guard let rate = desiredRates.first(where: { supports(frameRate: Double($0), in: format) }) else {
                return nil
            }
            return (
                format,
                CameraFormatOption(
                    index: index,
                    width: dimensions.width,
                    height: dimensions.height,
                    frameRate: rate
                )
            )
        }
        let selectedOption = CameraCapturePolicy.preferredFormat(
            from: formats.map(\.option)
        )
        let selected = selectedOption.flatMap { option in
            formats.first { $0.option.index == option.index }
        }

        try camera.lockForConfiguration()
        defer { camera.unlockForConfiguration() }

        let targetRate: Double
        if let selected {
            guard let range = selected.format.videoSupportedFrameRateRanges.first(where: {
                $0.minFrameRate <= Double(selected.option.frameRate)
                    && $0.maxFrameRate >= Double(selected.option.frameRate)
            }), let duration = CameraCapturePolicy.clampedFrameDuration(
                frameRate: selected.option.frameRate,
                minimum: range.minFrameDuration,
                maximum: range.maxFrameDuration
            ) else {
                throw CameraError.unsupportedFrameDuration
            }
            camera.activeFormat = selected.format
            setFrameDuration(for: camera, duration: duration)
            targetRate = 1.0 / duration.seconds
        } else {
            // An unusual camera keeps its default timing. Never synthesize an
            // unsupported fallback duration from a floating-point frame rate.
            targetRate = 30
        }

        if camera.isFocusModeSupported(.continuousAutoFocus) {
            camera.focusMode = .continuousAutoFocus
        }
        if camera.isExposureModeSupported(.continuousAutoExposure) {
            camera.exposureMode = .continuousAutoExposure
            if let maximumExposure = CameraCapturePolicy.clampedMaximumExposureDuration(
                minimum: camera.activeFormat.minExposureDuration,
                maximum: camera.activeFormat.maxExposureDuration,
                frameDuration: camera.activeVideoMinFrameDuration
            ) {
                // Auto exposure can raise ISO, but a short ceiling may leave
                // dark scenes underexposed. Do not change low-light or focus ranges.
                camera.activeMaxExposureDuration = maximumExposure
            }
        }
        if camera.isSmoothAutoFocusSupported {
            camera.isSmoothAutoFocusEnabled = false
        }

        let requestedZoom = 1.0
        let clampedZoom = min(
            max(requestedZoom, camera.minAvailableVideoZoomFactor),
            camera.maxAvailableVideoZoomFactor
        )
        camera.videoZoomFactor = clampedZoom

        return effectiveFrameRate(for: camera, fallback: targetRate)
    }

    private func setFrameDuration(for camera: AVCaptureDevice, duration: CMTime) {
        if CMTimeCompare(duration, camera.activeVideoMaxFrameDuration) > 0 {
            camera.activeVideoMaxFrameDuration = duration
            camera.activeVideoMinFrameDuration = duration
        } else {
            camera.activeVideoMinFrameDuration = duration
            camera.activeVideoMaxFrameDuration = duration
        }
    }

    private func effectiveFrameRate(
        for camera: AVCaptureDevice,
        fallback: Double
    ) -> Int {
        let seconds = camera.activeVideoMaxFrameDuration.seconds
        let rate = seconds.isFinite && seconds > 0 ? 1.0 / seconds : fallback
        return max(1, Int(rate.rounded()))
    }

    private func supports(frameRate: Double, in format: AVCaptureDevice.Format) -> Bool {
        format.videoSupportedFrameRateRanges.contains {
            $0.minFrameRate <= frameRate && $0.maxFrameRate >= frameRate
        }
    }

    private func logConfiguration(
        camera: AVCaptureDevice,
        connection: AVCaptureConnection,
        frameRate: Int
    ) {
        let dimensions = CMVideoFormatDescriptionGetDimensions(
            camera.activeFormat.formatDescription
        )
        let exposureCeiling = camera.activeMaxExposureDuration.seconds
        let minimumDuration = camera.activeVideoMinFrameDuration.seconds
        let maximumDuration = camera.activeVideoMaxFrameDuration.seconds
        let supportedRange = camera.activeFormat.videoSupportedFrameRateRanges
            .map { range in
                String(format: "%.1f-%.1f", range.minFrameRate, range.maxFrameRate)
            }
            .joined(separator: ",")
        print(
            "[Camera] device=\(camera.localizedName) "
                + "id=\(camera.uniqueID) "
                + "type=\(camera.deviceType.rawValue) "
                + "virtual=\(camera.isVirtualDevice) "
                + "format=\(dimensions.width)x\(dimensions.height) "
                + "configuredFPS=\(frameRate) "
                + String(format: "frameDuration=%.6f-%.6fms ",
                         minimumDuration * 1_000, maximumDuration * 1_000)
                + "supportedFPS=\(supportedRange) "
                + String(format: "zoom=%.2f ", camera.videoZoomFactor)
                + String(format: "maxExposure=%.3fms ", exposureCeiling * 1_000)
                + "stabilization=\(connection.activeVideoStabilizationMode.rawValue)"
        )
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

    private func resetDiagnostics() {
        diagnosticsLock.lock()
        diagnosticsStartTime = nil
        diagnosticsFrameCount = 0
        diagnosticsLock.unlock()
    }
}

extension CameraService: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        let callbackStart = ProcessInfo.processInfo.systemUptime
        defer { onCallbackCompleted?(ProcessInfo.processInfo.systemUptime - callbackStart) }
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
        emitDiagnostics(
            pixelBuffer: pixelBuffer,
            timestamp: timestamp,
            connection: connection
        )
        // A video-data connection may expose either the sensor's native
        // landscape buffer or a physically rotated portrait buffer. Use the
        // dimensions of this exact sample rather than a one-time assumption
        // made during session setup. This also covers devices where
        // `isVideoOrientationSupported` is false (the normal rear-camera
        // fallback is `.right`).
        let orientation = Self.visionOrientation(for: pixelBuffer)
        onFrame?(pixelBuffer, timestamp, orientation)
    }

    func captureOutput(_ output: AVCaptureOutput, didDrop sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        onDroppedFrame?()
    }

    private func emitDiagnostics(
        pixelBuffer: CVPixelBuffer,
        timestamp: TimeInterval,
        connection: AVCaptureConnection
    ) {
        guard isWantedToRun, timestamp.isFinite, let camera = activeCamera else { return }

        diagnosticsLock.lock()
        diagnosticsFrameCount += 1
        guard let startTime = diagnosticsStartTime else {
            diagnosticsStartTime = timestamp
            diagnosticsFrameCount = 1
            diagnosticsLock.unlock()
            return
        }
        let elapsed = timestamp - startTime
        guard elapsed >= 1.0 else {
            diagnosticsLock.unlock()
            return
        }

        let deliveredFPS = Double(diagnosticsFrameCount) / elapsed
        diagnosticsStartTime = timestamp
        diagnosticsFrameCount = 0
        diagnosticsLock.unlock()

        let exposureMilliseconds = camera.exposureDuration.seconds * 1_000
        let message =
            "[Camera] delivered=\(CVPixelBufferGetWidth(pixelBuffer))x"
                + "\(CVPixelBufferGetHeight(pixelBuffer)) "
                + String(format: "fps=%.1f exposure=%.3fms ISO=%.0f ",
                         deliveredFPS, exposureMilliseconds, camera.iso)
                + String(format: "lens=%.3f ", camera.lensPosition)
                + "focusAdjusting=\(camera.isAdjustingFocus) "
                + "exposureAdjusting=\(camera.isAdjustingExposure) "
                + "stabilization=\(connection.activeVideoStabilizationMode.rawValue)"
        loggingQueue.async { print(message) }
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
