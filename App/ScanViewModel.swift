import AVFoundation
import Foundation
import UIKit

@MainActor
final class ScanViewModel: ObservableObject {
    /// This app is used for a three-card 炸金花 deal. Keeping the limit
    /// in one place prevents a fourth card (or a duplicate callback) from
    /// leaking into the history while the camera is still shutting down.
    static let cardsPerRound = 3

    @Published private(set) var records: [CardRecord] = []
    @Published private(set) var detections: [CardDetection] = []
    @Published private(set) var isScanning = false
    @Published private(set) var isPreparing = false
    @Published private(set) var isRoundComplete = false
    @Published private(set) var statusText = "准备就绪"
    @Published var alertMessage: String?

    let camera = CameraService()
    private let pipeline = ScanPipeline()
    private var activeSessionID: ScanPipeline.SessionID?
    private var startRequestID: UInt64 = 0

    init() {
        camera.onDroppedFrame = { [weak self] in self?.pipeline.cameraDroppedFrame() }
        camera.onCallbackBegan = { [weak self] timestamp in self?.pipeline.cameraCallbackBegan(timestamp: timestamp) }
        camera.onFrame = { [weak self] pixelBuffer, timestamp, orientation in
            self?.pipeline.submit(
                pixelBuffer: pixelBuffer,
                timestamp: timestamp,
                orientation: orientation,
                cameraCounted: true
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
        pipeline.onRecordsWithDiagnostics = { [weak self] sessionID, newRecords, receipt in
            Task { @MainActor in
                var accepted: [CardRecord] = []
                defer { receipt.complete(accepted: accepted) }
                guard let self,
                      self.isScanning,
                      self.activeSessionID == sessionID else {
                    return
                }

                // A single model update can contain more than one confirmed
                // track, and an older queued callback can arrive just as the
                // third card completes the hand. De-duplicate again at the UI
                // boundary and take only the remaining slots as a final guard.
                let uniqueRecords = self.uniqueRecords(from: newRecords)
                let remaining = max(0, Self.cardsPerRound - self.records.count)
                if remaining > 0 {
                    accepted = Array(uniqueRecords.prefix(remaining))
                    self.records.append(contentsOf: accepted)
                }

                if self.records.count >= Self.cardsPerRound {
                    self.completeRound()
                }
            }
        }
        pipeline.onDetections = { [weak self] sessionID, newDetections in
            Task { @MainActor in
                guard let self,
                      self.isScanning,
                      self.activeSessionID == sessionID else {
                    return
                }
                guard !self.isRoundComplete,
                      self.records.count < Self.cardsPerRound else {
                    self.detections = []
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

        guard records.count < Self.cardsPerRound else {
            isRoundComplete = true
            statusText = "本轮已完成 · 请先清空"
            return
        }

        isPreparing = true
        isRoundComplete = false
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
        isRoundComplete = false
        statusText = records.isEmpty
            ? "已暂停"
            : "已暂停 · \(records.count)/\(Self.cardsPerRound) 张"
    }

    func clearRecords() {
        records.removeAll()
        detections = []
        isRoundComplete = false
        statusText = isScanning ? "扫描中 · 等待发牌" : "准备下一手"

        if let sessionID = pipeline.resetRecordedState() {
            // Update this before the asynchronous pipeline callback can reach
            // the main actor, so a pre-clear result cannot reappear.
            activeSessionID = sessionID
        }
    }

    private func handleCameraError(_ error: Error) {
        finishScanning(with: error, status: "无法扫描")
    }

    /// Stops capture as soon as the three-card hand is complete. This avoids
    /// spending inference time on the table after the hand and makes the
    /// result deterministic when the performer turns the phone over.
    private func completeRound() {
        guard isScanning else { return }

        startRequestID &+= 1
        activeSessionID = nil
        pipeline.stop()
        camera.stop()
        isPreparing = false
        isScanning = false
        detections = []
        isRoundComplete = true
        statusText = "已识别 \(Self.cardsPerRound) 张 · 本轮完成"
    }

    private func uniqueRecords(from incoming: [CardRecord]) -> [CardRecord] {
        var knownCards = Set(records.map(\.card))
        return incoming.filter { record in
            knownCards.insert(record.card).inserted
        }
    }

    private func finishScanning(with error: Error, status: String) {
        startRequestID &+= 1
        activeSessionID = nil
        pipeline.stop()
        camera.stop()
        isPreparing = false
        isScanning = false
        detections = []
        isRoundComplete = false
        statusText = status
        alertMessage = error.localizedDescription
    }

    deinit {
        camera.stop()
        pipeline.stop()
    }
}
