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
        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        ]
        output.setSampleBufferDelegate(self, queue: outputQueue)

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
        let formats = camera.formats

        let exact1080At120 = formats.first { format in
            hasDimensions(format, width: 1920, height: 1080) && supports(frameRate: 120, in: format)
        }
        let anyAt120 = formats.first { supports(frameRate: 120, in: $0) }
        let exact1080At60 = formats.first { format in
            hasDimensions(format, width: 1920, height: 1080) && supports(frameRate: 60, in: format)
        }
        let anyAt60 = formats.first { supports(frameRate: 60, in: $0) }
        let selected: (format: AVCaptureDevice.Format, frameRate: Int)?
        if let format = exact1080At120 ?? anyAt120 {
            selected = (format, 120)
        } else if let format = exact1080At60 ?? anyAt60 {
            selected = (format, 60)
        } else {
            selected = nil
        }

        do {
            try camera.lockForConfiguration()
            defer { camera.unlockForConfiguration() }
            if let selected {
                camera.activeFormat = selected.format
                let duration = CMTime(value: 1, timescale: CMTimeScale(selected.frameRate))
                camera.activeVideoMinFrameDuration = duration
                camera.activeVideoMaxFrameDuration = duration
                return selected.frameRate
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
