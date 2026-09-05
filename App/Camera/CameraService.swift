import AVFoundation
import Foundation
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
    var onFrame: ((CVPixelBuffer, TimeInterval) -> Void)?
    var onError: ((Error) -> Void)?
    var onModeChanged: ((Int) -> Void)?

    private let sessionQueue = DispatchQueue(label: "com.cardscanmagic.camera.session")
    private let outputQueue = DispatchQueue(label: "com.cardscanmagic.camera.frames")
    private let runStateLock = NSLock()
    private var isConfigured = false
    private var configuredFrameRate = 30
    private var wantsToRun = false

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

    private func configureIfNeeded() throws -> Int {
        guard !isConfigured else { return configuredFrameRate }
        guard let camera = AVCaptureDevice.default(
            .builtInWideAngleCamera,
            for: .video,
            position: .back
        ) else {
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
        if let connection = output.connection(with: .video), connection.isVideoOrientationSupported {
            connection.videoOrientation = .portrait
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
        // A high frame rate is useful only if the card still has enough
        // pixels to read. Some iPhones expose 240 fps at 720p as well as
        // 1080p; prefer the 1080p family first, then choose its fastest mode.
        // Only fall back to another resolution when no 1080p high-speed mode
        // exists. This avoids accidentally selecting a 4K/60 format (large but
        // slower) or a very soft 720p/240 format on a fast-deal setup.
        let desiredRates = [240, 120, 60]
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
        onFrame?(pixelBuffer, timestamp)
    }
}
