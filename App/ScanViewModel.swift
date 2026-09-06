import AVFoundation
import Foundation
import UIKit

@MainActor
final class ScanViewModel: ObservableObject {
    @Published private(set) var records: [CardRecord] = []
    @Published private(set) var detections: [CardDetection] = []
    @Published private(set) var isScanning = false
    @Published private(set) var isPreparing = false
    @Published private(set) var statusText = "准备就绪"
    @Published var alertMessage: String?

    let camera = CameraService()
    private let pipeline = ScanPipeline()
    private var activeSessionID: ScanPipeline.SessionID?
    private var startRequestID: UInt64 = 0

    init() {
        camera.onFrame = { [weak self] pixelBuffer, timestamp, orientation in
            self?.pipeline.submit(
                pixelBuffer: pixelBuffer,
                timestamp: timestamp,
                orientation: orientation
            )
        }
        camera.onError = { [weak self] error in
            Task { @MainActor in
                self?.handleCameraError(error)
            }
        }
        camera.onModeChanged = { [weak self] frameRate in
            Task { @MainActor in
                guard let self, self.isScanning else { return }
                self.statusText = "扫描中 · \(frameRate) fps"
            }
        }
        pipeline.onRecords = { [weak self] sessionID, newRecords in
            Task { @MainActor in
                guard let self,
                      self.isScanning,
                      self.activeSessionID == sessionID else {
                    return
                }
                self.records.append(contentsOf: newRecords)
            }
        }
        pipeline.onDetections = { [weak self] sessionID, newDetections in
            Task { @MainActor in
                guard let self,
                      self.isScanning,
                      self.activeSessionID == sessionID else {
                    return
                }
                self.detections = newDetections
            }
        }
        pipeline.onError = { [weak self] sessionID, error in
            Task { @MainActor in
                guard let self, self.activeSessionID == sessionID else { return }
                self.finishScanning(with: error, status: "识别已暂停")
            }
        }
    }

    func startScanning() {
        guard !isScanning, !isPreparing else { return }

        isPreparing = true
        statusText = "正在准备识别"
        startRequestID &+= 1
        let requestID = startRequestID

        Task { [weak self] in
            guard let self else { return }

            do {
                try await self.pipeline.prepare()
                guard self.startRequestID == requestID,
                      !self.isScanning else {
                    return
                }

                let sessionID = self.pipeline.start()
                self.activeSessionID = sessionID
                self.isPreparing = false
                self.isScanning = true
                self.statusText = "正在连接相机"
                self.camera.start()
            } catch {
                guard self.startRequestID == requestID else { return }
                self.isPreparing = false
                self.statusText = "缺少模型"
                self.alertMessage = error.localizedDescription
            }
        }
    }

    func startScanningIfNeeded() {
        guard !isScanning, !isPreparing else { return }
        startScanning()
    }

    func stopScanning() {
        startRequestID &+= 1
        activeSessionID = nil
        pipeline.stop()
        camera.stop()
        isPreparing = false
        isScanning = false
        detections = []
        statusText = "已暂停"
    }

    func clearRecords() {
        records.removeAll()
        detections = []

        if let sessionID = pipeline.resetRecordedState() {
            // Update this before the asynchronous pipeline callback can reach
            // the main actor, so a pre-clear result cannot reappear.
            activeSessionID = sessionID
        }
    }

    private func handleCameraError(_ error: Error) {
        finishScanning(with: error, status: "无法扫描")
    }

    private func finishScanning(with error: Error, status: String) {
        startRequestID &+= 1
        activeSessionID = nil
        pipeline.stop()
        camera.stop()
        isPreparing = false
        isScanning = false
        detections = []
        statusText = status
        alertMessage = error.localizedDescription
    }

    deinit {
        camera.stop()
        pipeline.stop()
    }
}
