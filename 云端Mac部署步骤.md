# 云端 Mac 部署步骤

这份工程已经把 App 逻辑写好了，但 Windows 不能把 Core ML 模型变成 iPhone
可用版本，也不能给 iPhone 签名。所以只差在一台云端 Mac 上做一次导出和安装。

## 先准备

1. 把整个 `CardScanMagic` 文件夹上传到云端 Mac。
2. 在云端 Mac 安装 Xcode，并至少登录一次你的 Apple ID。
3. 打开终端，进入这个文件夹。

## 只需复制执行的命令

```bash
cd CardScanMagic
python3 -m venv .venv
source .venv/bin/activate
pip install -r scripts/requirements-export.txt
python scripts/export_coreml.py --download
brew install xcodegen
xcodegen generate
open CardScanMagic.xcodeproj
```

前半段会下载开源扑克牌模型，并转换成 iPhone 认识的 `CardDetector.mlpackage`。
最后会打开 Xcode 工程。转换通常需要几分钟，模型文件约几十 MB，不要在中途关掉
终端。

## 在 Xcode 里装到 iPhone

1. 左边点最上面的蓝色工程图标，再点 `CardScanMagic`。
2. 点 `Signing & Capabilities`，把 `Team` 改为自己的 Apple ID。
3. 把 `Bundle Identifier` 改成别人不会重复的名字，例如
   `com.你的英文名.cardscanmagic`。
4. 用数据线连接 iPhone 14 Pro，在 Xcode 顶部选择这台 iPhone。
5. 点左上角三角形运行按钮。第一次 iPhone 若问是否信任电脑，选择信任。

免费 Apple ID 装的测试 App 有效期是七天。到期后，把 iPhone 再连到云端 Mac，点一次
运行按钮就能续七天。它不需要上架 App Store。

## 第一次实测

先在屏幕朝上时点播放按钮。然后把手机屏幕朝下平放在桌上，后置摄像头自然朝上。
让牌面朝镜头从画面任意位置经过；发完后翻回手机，画面会保留按经过顺序识别出的多张牌。

建议桌面两边各有一盏柔光灯。第一轮用较慢的发牌动作测试，确认牌面不会反光或模糊，
再逐渐加快。这个版本不会上传摄像头画面，识别都在 iPhone 本机完成。
