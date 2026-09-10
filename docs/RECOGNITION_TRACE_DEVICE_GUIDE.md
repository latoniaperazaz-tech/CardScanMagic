# Build 3 Recognition Trace 真机操作

本功能只观察生产中间值，不修复识别算法，也不把生成图测试通过解释为真机 9C 已识别成功。

## 开启 Trace

1. 安装本次 **Recognition Trace 诊断版**（Release 优化，编译时含 RECOGNITION_TRACE）。
2. 按现有 111 操作进入扫描界面。暂停扫描后，在 Trace 面板打开开关。
3. 选择测试标签 FULL 9C 或 OCCLUDED 9C。开关和标签在下一轮开始生效。
4. 清空后开始新轮。A/B 必须各自新开一轮，防止原 Session 同牌值保护干扰第二次实验。
5. 同一张梅花 9，以相同距离、角度、光线分别测试露角和遮角；每轮建议只录几秒，得到失败/成功现象即暂停。

正式普通包不包含开关入口；编译开关默认关闭。诊断包的运行时开关也默认关闭，保留用户主动开启状态。Trace 不改变 111、最多 3 张、Track 或 Session 去重。

手机面板显示正在运行的识别、最近完成识别及更新时间，各候选的 Pip 数、Rank/Suit、OCR、Fusion、Track 和 UI 回执。OCR_NIL 是可选线索缺失，不能单独当成失败原因。结果显示 notRun/null 表示该阶段没有执行或没有该计算，不是测得零。

## 暂停并导出整个 Session

完成一轮后暂停扫描，保持 App 前台，等面板显示本轮 Session 的“已导出”。面板可能仍显示上一轮导出提示，必须核对 Session 名称，并确认对应 session_manifest.json 的 finishedAt 属于本次测试。已有 Recognition / UI 回执和后台写盘收尾后才生成最终 manifest。不要通过强杀 App 结束测试。

iPhone“文件”→“浏览”→“我的 iPhone”→“计算机”→ RecognitionTrace：

```
RecognitionTrace/
  Session-<runID>-<sessionID>/
    session_manifest.json
    Phase1DebugSummary.json
    Phase1DebugSummary.txt
    Recognition-<recognitionID>/
      recognition_input.json
      recognition_input_plane_0.bin
      recognition_input_plane_1.bin          # 平面格式才有
      recognition_input_attachments.plist
      recognition_input.jpg
      roi.jpg
      candidate_<id>.jpg
      rectified_<id>.jpg                      # 实际执行矫正才有
      pip_overlay_<id>.jpg
      recognition_trace.json
    Event-<captureWindowID>/
      event_manifest.json
  Comparisons/
    FULL_9C_vs_OCCLUDED_9C_latest.md
    FULL_9C_vs_OCCLUDED_9C_<A-runID>_<B-runID>.md
```

以实际 artifacts 和 artifactStates 为准，surface 工作图等辅助图也在对应 Recognition 目录。缺失阶段不会伪造图片。

将 **整个 Session 文件夹**压缩/复制到电脑；Windows 可用 Apple Devices（或 iTunes）→设备→文件共享→“计算机”，保存 RecognitionTrace 文件夹。无需 Xcode 才能导出。

检查 session_manifest.json 的 complete、errors、omittedRecognitions、droppedFrameMetadata；再检查每个 trace 的 metadataComplete / truncatedEntries、inputSaved / artifactStates。超限或写入失败会标明不完整，正式识别继续。Event manifest 引用同一 Session 下的 Recognition，不要只拷一个 Event 小文件夹。

窗口 ID 和物理 Track ID 是不同空间。一帧可关联多个窗口，历史识别可在窗口生成后补关联。Timeline 的历史重放、checkpoint 推进和最终发布有不同标记，只有 timeline.published 表示新发布决策。

## 找到 FULL / OCCLUDED 差异报告

先完成并暂停 FULL 9C，再新开一轮完成 OCCLUDED 9C。Session 显示“已导出”之后，后台才开始生成 A/B 报告；此刻 latest 仍可能是旧文件。继续保持前台，等待 Comparisons 下同时包含本次两轮 runID 的固定报告出现，再复制整个 RecognitionTrace 文件夹。自动比较选择各标签最近导出的 Session；打开报告后核对头部两个 Session 和 runID 正确。

报告包括：

- 是否为相同构建/模型/系统，输入 source、尺寸、方向是否一致。
- 各阶段实际覆盖率；遮角测试没有候选时明确显示 candidate 阶段差异。
- 能建立单候选几何对应时，列出 first observed difference。
- 每次识别的候选区域、Pip 数与中心、Rank 9/10/8 原始分数、margin、Club 分布、OCR、Fusion、最终检测、Track/UI 状态。
- 实际终止分支和原检查值；失败的可选分支与最终无结果分开描述。

多候选或输入条件不同不会强行配对，也不会把 A 的 Suit 与 B 的 Rank 合并。时间戳、随机 ID 和 FULL/OCCLUDED 标签自身不作为证据差异。

报告只解释已导出事实。若两轮丢帧、截断、图片缺失或未形成可比候选，先按报告限制判断；不直接据此修改阈值或算法。

手机差异报告采用有界摘要：每 Session 最多展示 80 次识别，最多读取 32 MiB 原 Trace、保留 2 MiB 摘要，单份超过 4 MiB 不加载。达到限制会显示 PARTIAL COMPARISON，逐项列出原文件路径与省略原因。完整 Session 的原始 JSON/图片不因此删除或截断；需要更多细节时按引用打开原 Trace。

## 1280 与真实像素

Trace 保存实际输入来源 native / snapshot、originalWidth/Height、snapshotWidth/Height、scaleFactor、scaleX/scaleY、方向、像素格式和颜色附件。1280 配置不变，快照实际尺寸仍由既有预算规则决定。

Extractor 自己原有的 640 工作图、320 surface 图、448 candidate 上限也没有改变，会记录实际工作尺寸。JPEG 用于看图；严格重放使用保存的原 pixel planes 与附件，校验各 plane 和附件 SHA-256。

只有 snapshot 的输入无法恢复同一帧原生像素，因此不能把不同帧 native / snapshot 的所有差异都归因于缩放。

## 将真实失败帧放回完整 RecognitionEngine

在具备 Xcode 的 Mac 上，检出与诊断包 sourceRevision 对应的干净源码，安装项目原有依赖、Python 3 与 XcodeGen。

下载与诊断 IPA 同一次 CI 构建的 **RecognitionTrace-replay-model** 附件。解压后包含 replay_model_manifest.json 和 App/Models/CardDetector.mlpackage（外部单文件模型则为 .mlmodel）；将它们按原目录结构放到工程根目录。附件就是本次实际参与编译的模型源包，避免重新导出产生不同包内容。

完整保留 Session 及所选 Recognition 子目录，进入工程根目录运行：

```bash
bash scripts/replay_recognition_trace.sh "/absolute/Session-.../Recognition-..."
```

模拟器名称不同可设置 TRACE_SIMULATOR_DESTINATION。脚本设置 TEST_RUNNER_RECOGNITION_TRACE_REPLAY_DIR，并执行：

```
RealFrameReplayTests/testExportedProductionInputThroughFullEngineWhenProvided
```

脚本先核对 Session 索引、源码提交和 modelSHA256；不匹配会停止。测试还原 CVPixelBuffer 和 orientation，调用真正的 RecognitionEngine → Core ML / PartialCardFeatureExtractor → PartialRankEstimator → PartialEvidenceFusion，比较 Trace OFF/ON 的完整结果与调用次数，写出原目录的 replay_trace.json。

脚本还会核验本次新输出的像素来源、方向、格式、Engine 完成记录和实际调用次数，成功后写 replay_verification.json。没有新文件、测试被跳过或仅残留旧文件时不会报告成功。

没有实际真机目录时，该专项测试明确 SKIP；另外的完整 Engine、无损回放和观察等价测试照常执行，不 mock Pip 或 Rank。

需要从 JPEG / candidate 图进行便利回放，可在同一 App 测试宿主中调用：

```swift
let engine = try RecognitionEngine()
let result = try RecognitionTraceReplay.run(imageURL: imageURL, engine: engine)
```

它仍进入真实完整 Engine，但标为 imageOrCandidateReplay；有损 JPEG 与改变视野后的 candidate 不等于原全帧严格重放。

上述单帧回放定位 Engine 内部结果。Track / Session / UI 失败还需看完整 Session 的原时间序列和回执，不能用单帧回放伪称复现多帧去重行为。当前手机没有离线运行 XCTest 的按钮，Windows 不能本地运行 iOS Vision/Core ML；可将完整导出留在本地，交给具备同环境的 Mac 运行。

## 资源与失败处理

Camera 不编码图片、不写盘、不等待 Recognition 或 Trace writer。真正入选的 Recognition 在后台建立有界的像素副本；图像编码、文件 IO 和 A/B 生成在独立 utility 队列。

默认诊断预算：每轮最多 500 次 Recognition、20,000 条帧元数据；图像排队预算 96 MiB、累计图像预算 768 MiB。单次中间值同时受条数和递归大小预算保护；后台不把所有完整 Trace 常驻内存。预算是诊断配置，不是识别阈值；图片、元数据和报告会明确说明超限。

开启 Trace 存在可测性能开销，不能声称 capture FPS 与关闭时相同。原 Phase1 报告仍记录掉帧、耗时和内存，用于评估诊断开销。所有识别语义对照使用同一输入及原时间序列。

本轮完成后停止；等待真实 FULL/OCCLUDED 两份生产 Trace，再决定是否另行修复识别。
