import AVFoundation
import Foundation
import UIKit

@MainActor
final class ScanViewModel: ObservableObject {
    @Published private(set) var records: [CardRecord] = []
    @Published private(set) var isScanning = false
    @Published private(set) var statusText = "准备就绪"
    @Published var alertMessage: String?

    let camera = CameraService()
    private let pipeline = ScanPipeline()

    init() {
        camera.onFrame = { [weak self] pixelBuffer, timestamp in
            self?.pipeline.submit(pixelBuffer: pixelBuffer, timestamp: timestamp)
        }
        camera.onError = { [weak self] error in
            Task { @MainActor in
                self?.pipeline.stop()
                self?.camera.stop()
                self?.isScanning = false
                self?.statusText = "无法扫描"
                self?.alertMessage = error.localizedDescription
            }
        }
        camera.onModeChanged = { [weak self] frameRate in
            Task { @MainActor in
                self?.statusText = "扫描中 · \(frameRate) fps"
            }
        }
        pipeline.onRecords = { [weak self] newRecords in
            Task { @MainActor in
                self?.records.append(contentsOf: newRecords)
            }
        }
        pipeline.onError = { [weak self] error in
            Task { @MainActor in
                self?.pipeline.stop()
                self?.camera.stop()
                self?.isScanning = false
                self?.statusText = "识别已暂停"
                self?.alertMessage = error.localizedDescription
            }
        }
    }

    func startScanning() {
        do {
            try pipeline.prepare()
            pipeline.start()
            isScanning = true
            statusText = "正在连接相机"
            camera.start()
        } catch {
            isScanning = false
            statusText = "缺少模型"
            alertMessage = error.localizedDescription
        }
    }

    func stopScanning() {
        pipeline.stop()
        camera.stop()
        isScanning = false
        statusText = "已暂停"
    }

    func clearRecords() {
        records.removeAll()
        pipeline.resetRecordedState()
    }

    deinit {
        camera.stop()
    }
}
