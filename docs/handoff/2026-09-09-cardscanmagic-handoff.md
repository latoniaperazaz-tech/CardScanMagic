# CardScanMagic 交接文档

更新时间：2026-09-09  
当前分支：`highspeed-dedup-test-clean`  
项目目录：`C:\Users\Administrator.DESKTOP-068VNB6\Documents\Codex\2026-09-05\xia\outputs\CardScanMagic`

## 先看结论

当前工作已经完成了一个可运行的 Partial Card Inference MVP，并开始做
iPhone 14 Pro 的高速采集参数调整。下一窗口接手时，**不要把当前工作树当成
“已经编译验收”的版本**：Python 部分已经有回归结果，Swift 相机部分只能在本
Windows 环境做静态检查，尚未在 Xcode 或真机编译。

用户现在问过是否还要训练模型。准确回答是：

- 运行当前 Partial MVP **不需要立刻训练新模型**。它主要用标准 A-10 花色点
  模板、OpenCV 颜色/轮廓和几何匹配。
- iOS 现有识别路径仍可以接入已有的 52 类 Core ML 模型，但模型不是 Partial
  MVP 的核心；仓库当前没有保证存在可编译的 `.mlpackage` 权重。
- 若目标是严重运动模糊、角标完全不可见、只剩少量点仍要高准确率，后续很可能
  需要用 iPhone 14 Pro 的真实视频做小规模微调/训练。必须先采集和测量失败样本，
  不要现在盲目训练。

## 用户目标和约束

目标不是普通的 52 类完整卡牌分类，而是：牌面只露出局部、只看见部分花色点、
只看到牌边、角标不可见、倾斜、遮挡和运动模糊时，输出 A-10 的候选排名；证据不
足时输出 `unknown`，不能伪造唯一答案。用户明确要求当前不做 UI、不开始新模型
训练，也不要把主要精力重新放回 52 类 YOLO。

用户希望最终能够用高速摄像头捕捉运动中的牌，并解释最高候选的依据。当前验收
重点是相机实际曝光/帧率/对焦和真实数据，不是单看代码里写了 `120`。

## 已完成的 Python MVP

### 模块

- `src/rules/card_templates.py`
  - `CARD_TEMPLATES` 覆盖 `A`、`2` 到 `10`。
  - 每个 pip 保存归一化 `x`、`y`、`orientation`、`role`。
  - `CardTemplate` 还提供数量、中心点、行列结构等派生信息。
- `src/features/suit_detector.py`
  - HSV 红色/黑色分组、轮廓 Hu 形状比较和保守的 `unknown` 概率。
  - 只能稳定判断颜色时，不强制在 diamond/heart 或 club/spade 中选一个。
- `src/features/pip_detector.py`
  - threshold、HSV、形态学、connected components、轮廓和轻微粘连分裂。
  - 红色 mask 与暗色 mask 分开连通域，避免暗牌面吞掉红色 pip。
  - 每个候选含 `cx`、`cy`、`area`、`shape_score`、`suit_guess` 等。
- `src/geometry/visible_region.py`
  - 通过边缘、长直线、牌面比例和边界接触推断 `top/bottom/left/right`、角落、
    `center/full/unknown` 以及概率分布。
- `src/geometry/card_localizer.py`
  - 在桌面、手、键盘等背景中寻找可能的白色牌面，并输出候选 ROI。
- `src/inference/partial_rank_inference.py`
  - 对每个 A-10 模板搜索 translation、scale、rotation，必要时做 affine/
    projective refinement。
  - 允许 missing pips、crop、遮挡、位置误差和透视误差。
  - 分数考虑 pip 距离、非法位置、可由裁切解释的缺失点、可见区域、数量、中心点、
    上下中点、左右结构和对称性。
  - 没有足够证据时返回 `rank = "unknown"`。
- `src/geometry/card_localizer.py` 和 `src/inference/evidence_fusion.py`
  - 前者从复杂背景中给出牌面候选 ROI，后者融合 pip layout、suit、visible region
    和场景证据，并执行 unknown 门控。
- `debug_partial.py`
  - `python debug_partial.py --image test.jpg --localize` 输出排名、证据和调试图。
  - 调试图保存到 `outputs/debug_*.jpg`。
- `src/adapters/pretrained_model.py`
  - 只保留预训练模型适配接口；没有权重时 Partial MVP 仍应运行。

### Python 测试

最近一次回归结果：`60 passed`。覆盖模板完整性、A-10 完整布局、5 的右侧/顶部
裁切、局部点、15 度旋转、透视误差、容易混淆的 4/5、5/9、6/7、6/8、8/10、
运动模糊 pip、花色形状、场景定位和空图 unknown。

建议重新运行：

```powershell
cd C:\Users\Administrator.DESKTOP-068VNB6\Documents\Codex\2026-09-05\xia\outputs\CardScanMagic
python -m pytest -q
```

## 真实视频测试结果

已分析的视频：

`D:\微信\xwechat_files\wxid_dcd6zop4onlp12_0bec\msg\video\2026-09\2fe8dbc22960ab45752077ce7954046c.mp4`

已知信息：720x1280、30 FPS、约 4.3 秒、129 帧；疑似微信压缩。人工观察为红色
A。输出统计在：

`work/video2_eval/summary.json`

关键结果：

- 处理 43 帧，定位到牌面候选 27 帧，检测到 pip 证据 13 帧。
- 4 帧把 rank 排到 A，并且都为 A；最佳调试图是
  `outputs/debug_frame_108.jpg`。
- 花色在可靠帧上仍多为 `unknown`。
- 这些可靠帧的最终 rank confidence 约 0.21--0.22，不能宣传成 88% 精准识别。
- 其它模糊帧的 top rank 可能是 3/4 等，因此跨帧投票、质量门控和真实高帧率素材
  仍需要继续做。

以前用户提供的另一个视频路径是：

`D:\微信\xwechat_files\wxid_dcd6zop4onlp12_0bec\msg\video\2026-09\8c9c06d40c6db2cd6e0690045df440e2.mp4`

不要默认它已经经过同样的评估；如果要测试，应单独生成新的 summary。

示例命令（脚本参数以实际文件为准）：

```powershell
python work/run_video_eval.py "D:\微信\xwechat_files\wxid_dcd6zop4onlp12_0bec\msg\video\2026-09\2fe8dbc22960ab45752077ce7954046c.mp4" --step 1 --out work/video_recheck
```

## iPhone 14 Pro 相机方向

用户的设备是 iPhone 14 Pro。已查到的硬件/系统事实：主摄 48MP、24mm、f/1.78；
普通视频最高 4K/60；慢动作有 1080p/120 或 240；Action mode 最高 2.8K/60，
主要用于手机自身抖动，且要求较亮环境。当前场景是手机固定、扑克牌高速移动，
所以没有启用 Action mode，也没有开启视频防抖。

设计文档：

`docs/plans/2026-09-09-fast-card-capture-design.md`

当前相机代码的意图：

- 优先物理 `.builtInWideAngleCamera`，固定 1x，避免虚拟三摄在运动中自动换镜头。
- 优先 `1920x1080/120fps`，然后 `1920x1080/60fps`，再退回支持的高速格式。
- 连续自动曝光，但把 `activeMaxExposureDuration` 目标设为约 `1/500s`，按 active
  format 的范围钳制；需要强而均匀的光线，否则 ISO 会升高、画面变噪或变暗。
- 连续自动对焦 + `.near`，关闭 smooth autofocus；固定 1x 以后失去虚拟相机的自动
  微距镜头切换，牌离镜头太近可能无法对焦，必须真机量距离。
- 关闭视频防抖，因为手机固定而目标在动。
- 诊断日志记录设备 ID、是否虚拟设备、分辨率、配置帧率、帧持续时间、支持帧率范围、
  曝光上限、实际交付 FPS、实际曝光、ISO、lens position、对焦/曝光调整状态。

## 当前工作树状态（非常重要）

当前不是干净树。不要使用 `git reset --hard`、`git checkout --` 或删除输出目录。
这些改动混合了用户/前序工作和本次相机优化，必须先逐个阅读再提交。

已修改：

- `App/Camera/CameraService.swift`：相机选择、格式、曝光、防抖、诊断；最近又做了
  一次“异常不吞掉、回读实际帧率、重置诊断、固定 zoom/禁低光 boost”的修正，**尚未
  在 Swift 编译器验证**。
- `README.md`：相机策略和 Partial MVP 使用说明已经更新。
- `Tests/test_partial_matching.py`
- `debug_partial.py`
- `src/features/pip_detector.py`
- `src/geometry/__init__.py`
- `src/geometry/visible_region.py`
- `src/inference/__init__.py`
- `src/inference/evidence_fusion.py`
- `src/inference/partial_rank_inference.py`

未跟踪但应保留：

- `App/Camera/CameraCapturePolicy.swift`
- `Tests/CameraCapturePolicyTests.swift`
- `Tests/test_card_localizer.py`
- `Tests/test_scene_inference.py`
- `src/geometry/card_localizer.py`
- `artifact/`、`work/`：模型/评估/调试产物，先不要批量清理。

最近相关提交：

- `09cb724 Implement partial card inference MVP`
- `ab98bb7 Document fast card capture tuning`

## 相机 Swift 未完成项

Windows 环境没有 `xcodebuild`、Xcode 或 iOS SDK，所以以下事项不能在本机声称已
完成：

1. 在 Mac 上用 XcodeGen 重新生成工程，并编译 `CardScanMagic` 与 XCTest。
2. 检查 `CameraService.swift` 最近修改是否通过 Swift 5/Xcode 15 编译，尤其是
   `isVirtualDevice`、`isLowLightBoostSupported`、`automaticallyEnablesLowLightBoostWhenAvailable`
   等 AVFoundation API。
3. `configureBestFrameRate` 当前改为抛出配置错误，并在没有 60/120 格式时设置 active
   format 的真实最大帧率；要检查 session 配置失败时的清理路径。
4. `onModeChanged` 仍把“配置后的目标/回读帧率”显示成一个整数；UI 文案最好写成
   “目标/配置 fps”，实际 delivered FPS 只以诊断日志为准。
5. `SharpFrameSampler.swift` 仍按全画面 sharpness 评分。清晰桌面可能胜过模糊牌；后续
   应改成牌 ROI/候选区域评分，并让短窗口等待 2--4 帧后再选最清晰帧。
6. 物理 1x 的最近对焦距离没有软件保证。必须用真实牌在 15/20/25/30 cm 等距离测试，
   记录是否清晰，再决定保留物理广角还是恢复虚拟相机/宏切换。

## 真机验收清单

在 iPhone 14 Pro 上使用原生相机采集路径，记录以下数据，不要用微信压缩视频替代：

- 日志中的 `type`、`id`、`virtual`，确认是否真的是物理后置广角 1x。
- delivered buffer 是否 `1920x1080`，PTS 计算出的 FPS 是否接近 120（降级时接近 60）。
- 实际 `exposure` 是否长期不超过约 2 ms（1/500 s）。
- ISO 是否长期顶满；若顶满，增加均匀持续光，不要先放宽曝光。
- lens position、focusAdjusting 是否来回搜索。
- 牌距 15/20/25/30 cm 的清晰度和漏检情况。
- 快速连续发牌时是否丢帧、是否有足够清晰候选。
- 连续运行 5 分钟后的温度和实际 FPS。
- 中国 50 Hz LED 灯下是否有条纹；优先无频闪持续光源。

## 推荐接手顺序

1. 先阅读本文件、`docs/plans/2026-09-09-fast-card-capture-design.md`，再看 `git status`
   和 `git diff`；不要回滚已有 Python 改动。
2. 在 Mac 上生成工程并编译/跑 Swift 单测；先修编译问题，再做任何算法扩展。
3. 在 iPhone 14 Pro 真机完成上面的相机验收，保存原始日志和短视频。
4. 用真实高帧率素材运行 Python MVP，检查牌 ROI 定位、pip 数量、visible region、
   rank candidates 和 unknown 门控。
5. 优先改 ROI sharpness、跨帧证据融合和花色形状区分；不要先训练 52 类模型。
6. 收集至少覆盖距离、光照、速度、旋转、遮挡和牌面花色的失败样本后，再决定是否
   需要微调模型。训练前必须有明确的错误类型和可量化基线。

## 交接时的诚实表述

可以说：当前 MVP 能在合成牌面和部分真实帧上给出合理的 A-10 候选，并在证据弱时
返回 unknown；相机代码已经按 14 Pro 高速采集方向调整，但还没有真机证明 120 FPS、
1/500 s 曝光和稳定对焦。

不能说：已经“精准捕捉”“100% 识别”“模型已经训练好”或“Action mode 能解决高速
牌面模糊”。当前视频中 A 的正确排序仍属于低置信度结果，花色尚未稳定。
