# PHASE 1 真机 Diagnostics

冻结基线：`phase1-event-capture` / `phase1-frozen-827a600` → `827a6007b454ef907629192f9c2204337c486c4f`。
诊断补充单独位于 `phase1-device-diagnostics`。本次不包含 PHASE 2，也不修改识别、Motion、Ring、Track 的算法、阈值或 Session 牌值去重规则。

## 真机测试和取出文件

1. 安装经过签名的诊断版 App，按原有 `111` 操作进入扫描，进行一次测试。
2. 测试完成后点右上角“暂停扫描”。识别满 3 张自动停止、识别报错停止，也会结束报告。扫描过程中“清空”会保存旧会话并开始新会话。
3. 保持 App 在前台，等待已开始的识别回调收尾。导出不会等待后 6 帧，也不会继续识别被停止操作取消的排队帧；它只等待已经开始的诊断活动。
4. iPhone“文件”→“浏览”→“我的 iPhone”→“计算机”（App 显示名），查看 `Phase1DebugSummary.txt` 和 `.json`。`Phase1Diagnostics` 文件夹保存每次测试的唯一 UUID 文件，不被下一轮覆盖。
5. Windows 连接手机、解锁并信任电脑，在 Apple Devices（旧系统可用 iTunes）→设备→“文件共享”/“文件”→“计算机”，保存 Documents 中的报告。Mac 也可用 Finder 文件共享。

最新快捷文件按测试开始时间更新，较旧会话的迟到报告不会覆盖更新会话。JSON/TXT 编码和写盘都在独立 utility 队列。Xcode 控制台的 `[Phase1DebugSummary]` 输出保存路径；导出失败会输出 `exportFailed` 和错误。直接杀死 App 或系统终止进程不能保证导出，测试应通过暂停结束。

## 20 项验收字段

| 项目 | JSON 字段及口径 |
| --- | --- |
| 实际 Camera FPS | `cameraFrames`, `averageFPS`, 首末 Camera PTS；计入快照失败的相机送达帧 |
| Camera dropped frames | `droppedFrames`，AVFoundation didDrop 回调次数 |
| Callback P50/P95/max | `metrics.cameraCallback.{p50Ms,p95Ms,maxMs,count}` |
| Motion P50/P95 | `metrics.motionMeasure`，包含快照失败前已执行的测量 |
| captureWindow 总数 | `captureEvents`；`motionTriggers` 是原 Motion active 标志上升沿，`motionActiveSamples` 是所有 active 样本数 |
| 每个 Event 的 frameId | `events[].frameIDs` |
| 前 6 帧 | `preFramesReceived`, `missingPreFrames`, `obtainedRequestedPreFrames` |
| 后 6 帧 | `postFramesReceived`, `missingPostFrames`, `obtainedRequestedPostFrames`, `complete` |
| 入选 Recognition 帧 | `events[].selectedFrameIDs`, `recognitionAttempts`；重叠窗口可引用同一帧，全局只计一次 |
| InformationScore | `frames[].informationScore` 和每次 `recognitionAttempts[].informationScore` |
| Recognition 开始 | `recognitionAttempts[].startUptime` |
| Recognition 完成 | `recognitionAttempts[].completedUptime`, `status`, `acceptedBySession`, `error` |
| capture-to-result | `metrics.captureToResult`：该帧进入 submit 到引擎完成，限非空原始结果 |
| capture-to-confirmed | `metrics.captureToConfirmed`：Track 已知观测中最早捕获到发布决策；缺失时间数据单独计数，不编造延迟 |
| Pool allocation failure | `snapshotAllocationFailures`，CoreVideo 创建池或分配 buffer 失败；`snapshotFailures` 为所有快照失败 |
| Ring overwrite | `ringOverwrites`，Ring 覆盖旧帧次数 |
| Pending overflow | `eventOverflows`，超容量而驱逐的 pending **帧数**，不是丢失整个 Event 数 |
| resident memory peak | `residentMemoryPeakBytes`, `residentMemoryPeakMB`, `residentMemorySamples` |
| Event 具体牌值 | `events[].finalDecision[]`：Track UUID、牌值、置信度、duplicateCard、formallyRecorded |
| Event 无 Recognition result | `eventsWithNoRecognitionResult`, `events[].hasRecognitionResult`, `outcome` |

`recognitionCompletions` 包含返回空数组的完成回调；`recognitionResults` 只计有原始检测结果的帧。`trackDecisions` 包含重复牌 Debug 决策，`confirmedCards` / `formalRecords` 只计 UI 实际接收的正式记录。旧 Session 晚到结果保留供诊断并标记 `acceptedBySession=false`，不会因此记牌。

captureWindow 数字 ID 与物理 Track UUID 是两个编号空间。一个窗口可包含多个物理目标，一个 Track 也可能涉及多个窗口。报告通过共有捕获时间戳展示关联，保留所有关联决策；这种关联不证明物理身份，也不用于融合花色/点数。

## 统计精度、内存和线程

耗时单位为 ms。Camera PTS 用于标识帧，arrival/start/end/publish 使用单调递增 system uptime 秒，不能与墙上日期直接相减。每次测试使用独立 recorder 和 UUID，停止、清空、重启均不会把旧回调写进新 recorder。

耗时直方图覆盖完整会话，共 4096 个对数桶，桶间隔 1%，下限 0.001 ms；P50/P95 是桶上界近似值，count/max 精确。它不会只保留最后 512 次。内存每 250 ms 独立采样，不依赖识别成功；peak 是采样峰值，短于采样周期的尖峰可能遗漏。

Diagnostics 只保留标量元数据，不保留像素、CVPixelBuffer、UIImage 或 Core ML 对象。详细数据有明确容量限制，见 `limits`；到达上限时 `metadataComplete=false` 并记录 `truncation`。此时逐 Event 汇总只覆盖保留的详情，不能当作完整验收报告。唯一计数还受独立 identity 容量限制，超出时 `uniqueCountersExact=false`。真实测试应检查这两个标志。

Camera 只登记短时标量数据和活动计数，不等待 Recognition，不编码 JSON/JPEG/PNG，不写盘。活动结束通过 DispatchGroup notify 异步生成报告；创建报告、关联和格式化在采集锁之外进行。停止前在 scheduler 原锁内取得计数快照，避免 reset 清空本次数据。

## 原分辨率与 1280 对比

`CaptureConfiguration.snapshotMaximumDimension` 已是可配置参数，默认 1280；通过 `ScanPipeline(configuration:)` 传入，当前没有手机界面切换项。

该值是最长边上限，不保证输出一定为 1280。既有池算法还按 `snapshotByteLimit`（默认 72 MiB）和持帧数量缩小快照；参数本身在池中限制到 2…4096。报告保留配置值、每帧真实快照宽高、每次 Recognition 的实际输入宽高及 `source=native/snapshot`。

立即选中的实时帧可能用原始相机 buffer，历史帧使用快照。因此，仅提高上限不能声称完成了纯原图 vs 1280 的对照实验。应根据报告中的实际尺寸和来源比较；本轮不改变现有分辨率和选帧策略。

## 验证

本地 Python 回归：60 passed，19.06 秒。Swift 全套 XCTest、Release iPhone 编译及对应 IPA 以本次 GitHub Actions 结果为准，完成后在交付报告记录 commit/run/artifact。自动化测试不是手机性能数据；本次不声称已测得实际 FPS、延迟、内存或模糊牌召回率。
