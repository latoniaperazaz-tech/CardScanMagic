# PHASE 1 Diagnostics 交付报告

范围仅为诊断、收尾记录、JSON/TXT 导出和相关测试。PHASE 2–5 未开始。

## 基线和提交

- 冻结分支：`phase1-event-capture`
- 冻结标签：`phase1-frozen-827a600`
- 冻结提交：`827a6007b454ef907629192f9c2204337c486c4f`
- 诊断分支：`phase1-device-diagnostics`
- 诊断提交：`52c19aea2ad65eb6a8d36573dc1e373b619d06d5`
- 最终 CI：https://github.com/latoniaperazaz-tech/CardScanMagic/actions/runs/34470962734

## 结果和取出数据

原 Diagnostics 没有完整会话导出，逐 Event 入选帧与结果未串联，耗时只保留最近 512 样本，内存峰值未按会话清零。这些缺口已补齐。

按原有 111 操作进入扫描。完成测试后，点扫描页右上角暂停，保持 App 前台，等待当前识别及 UI 回调收尾。满 3 张自动停止、识别错误停止也会保存报告；扫描中清空会保存旧会话并开始新会话。

iPhone 文件 → 浏览 → 我的 iPhone → 计算机：

- `Phase1DebugSummary.txt`：最新测试，可直接阅读。
- `Phase1DebugSummary.json`：最新测试结构化数据。
- `Phase1Diagnostics/Phase1-<UUID>.json/.txt`：每次独立测试归档。

Windows 可用 Apple Devices / iTunes 的设备文件共享，选中“计算机”保存这些文件。导出失败会在 Xcode 控制台显示 `[Phase1DebugSummary] exportFailed`。强制结束 App 不保证导出。

完整 20 项字段映射及口径见仓库 `docs/PHASE1_DEVICE_DIAGNOSTICS.md`。

## 内存和线程

Camera 只收集标量元数据；Diagnostics 不持有像素对象。全会话耗时采用固定 4096 桶对数直方图，P50/P95 为约 1% 桶间隔的上界近似，count/max 精确。内存每 250ms 独立采样；这是进程 resident 的采样峰值，不能等同于操作系统高水位。

详情默认最多 20,000 帧、5,000 个窗口、10,000 次识别、1,000 个决策。超出后明确导出 `truncation` 和 `metadataComplete=false`。独立唯一计数身份表达到每种 200,000 上限后，会标记 `uniqueCountersExact=false`。真机验收应检查这些完整性标志。

每次测试拥有独立 UUID recorder。活动令牌记录已经开始的 Camera/Recognition/UI 回调，结束报告只通过异步 notify 等待收尾，Camera 不等识别、不编码、不写盘。重置时先在 scheduler 原锁内取出最终计数。

清空发生在 Camera callback 与 submit 之间的过渡帧，显式记录原 Camera 会话 ID，不改变既有处理 Session 选择。已经发出的 UI 记牌回调通过 receipt 报告接收或拒绝，防止识别错误先关闭统计而漏掉正式记录。

## 分辨率与识别能力

1280 保持为 `CaptureConfiguration.snapshotMaximumDimension` 默认值，可通过 Pipeline 配置传入。没有添加手机设置开关。既有池预算可能进一步缩小，立即选中的实时识别也可能用 native 帧；报告记录每帧快照真实尺寸以及每次识别输入的尺寸和来源。

captureWindow 与物理 Track 使用不同 ID。报告保留所有关联 Track 决策，通过共有捕获时间戳说明关联，不把窗口当作物理身份，也不融合两张牌的证据。

对照冻结提交验证：RecognitionEngine、Motion、Ring、EventBuilder、FrameInformationScorer、Track/Timeline、PartialRankEstimator、PartialCardFeatureExtractor、PartialEvidenceFusion、SessionGate、CaptureConfiguration、ContentView 和 PresentationModeView 源码未改。Pool 分配/缩放策略与 Scheduler 选帧/驱逐算法未改；其增量仅为诊断计数、尺寸及重置快照。111、最多 3 张、单帧强证据、Session 牌值去重保持。

## 文件清单

修改：

- `App/Camera/CameraService.swift`
- `App/Recognition/CaptureDiagnostics.swift`
- `App/Recognition/CaptureSnapshotPool.swift`
- `App/Recognition/EventFrameScheduler.swift`
- `App/Recognition/ScanPipeline.swift`
- `App/ScanViewModel.swift`
- `Tests/CaptureSnapshotPoolTests.swift`
- `project.yml`

新增：

- `App/Recognition/DiagnosticRecordReceipt.swift`
- `App/Recognition/Phase1DebugExporter.swift`
- `App/Recognition/Phase1DebugSummary.swift`
- `Tests/CaptureDiagnosticsTests.swift`
- `Tests/EventFrameSchedulerDiagnosticsTests.swift`
- `Tests/Phase1DebugExporterTests.swift`
- `Tests/Phase1DiagnosticsIntegrationTests.swift`
- `docs/PHASE1_DEVICE_DIAGNOSTICS.md`

## 验证记录

Python：60 passed，19.06 秒。最终提交 `a510239` 的 Swift 测试：183 tests，0 failures；Release iPhone build：`BUILD SUCCEEDED`。CI：[34471579619](https://github.com/latoniaperazaz-tech/CardScanMagic/actions/runs/34471579619)。

IPA：[CardScanMagic-unsigned.ipa](a510239/CardScanMagic-unsigned.ipa)，5,488,308 bytes。SHA-256：`83C7F952575E09299CC27E93EBA63507842B01567CC1D56AD8C95CDBAD690783`。已检查包含 Core ML 编译模型、可执行文件、`UIFileSharingEnabled=true` 和 `LSSupportsOpeningDocumentsInPlace=true`。

尚未安装本诊断版到真机，未产生实际手机 FPS、延迟、峰值内存或模糊扑克牌召回率数据。本报告只提供自动化测试与构建证据。
