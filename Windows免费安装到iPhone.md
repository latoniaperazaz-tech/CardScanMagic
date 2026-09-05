# Windows 免费安装到 iPhone

这个流程只用于自己测试。GitHub 的 Mac 机器负责编译，Windows 上的 Sideloadly
负责用你的免费 Apple ID 给 App 签名并装到自己的 iPhone。Apple ID 密码不需要、也
不应该填进 GitHub。

## 第一次打包

1. 在 GitHub 打开本工程的私有仓库，点顶部 `Actions`。
2. 左侧选择 `Build unsigned iPhone test app`，点 `Run workflow`，再点一次蓝色
   `Run workflow`。
3. 等待完成。第一次通常是 15 到 30 分钟，因为它会下载并转换扑克牌模型。
4. 点进入这次绿色的构建，在最下方 `Artifacts` 下载
   `CardScanMagic-unsigned-ipa`，解压后得到 `CardScanMagic-unsigned.ipa`。

## 装到 iPhone

1. 从 <https://sideloadly.io/> 下载 Windows 版 Sideloadly 并安装。
2. 用可以传数据的数据线连接 iPhone 14 Pro；在 iPhone 上选择信任这台电脑。
3. 打开 Sideloadly，把 `CardScanMagic-unsigned.ipa` 拖进窗口。
4. 填自己的 Apple ID，点 `Start`。若 Apple ID 开了双重认证，按它的提示输入
   Apple 账户网站生成的 app-specific password。
5. 装好后，在 iPhone 的 `设置 > 通用 > VPN 与设备管理` 中信任自己的开发者账号。
6. 打开 `Card Scan Magic`，允许相机。先点播放图标，再把手机屏幕朝下放桌面测试。

## 你需要知道的限制

- 免费 Apple ID 签名的 App 约七天失效。到期后用 Sideloadly 再安装一次即可。
- Apple 对免费账号同时安装的自签名 App 数量有限制；先只装这一个。
- 这是未签名 IPA，不能双击安装，也不能用 AirDrop 装；必须由 Sideloadly 重新签名。
- GitHub 只看得到工程代码和构建日志；相机画面不会上传，Apple ID 也不会上传。

## 构建失败时

在 GitHub Actions 中打开失败的步骤，复制红色报错文字即可。不要把 Apple ID 密码、
双重认证验证码或 app-specific password 发出来。
