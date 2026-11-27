# AgentPulse for Apple platforms

AgentPulse 的 SwiftUI 客户端，支持 macOS 14+ 和 iPhone（iOS 17+）。使用同一个 Xcode 工程和同一套配对、认证与同步代码。

## 当前功能

- 导入 Host 终端生成的直连二维码图片。在 iPhone 上也可从「照片」中选择图片。
- 首次配对校验二维码中的证书指纹，并等待 Host 终端确认。配对后的设备凭据保存在系统钥匙串，Native WSS 使用 Host CA 和稳定的 Host 名称验证服务器。
- 查看 Codex 会话、消息、进度、工具活动、计划和待处理请求。每个会话显示最近 250 条事件，当前 App 进程内手动重连时按游标补齐缺口。
- 可断开、重新连接或清除本机保存的一个 Host。要吊销 Host 侧设备授权，使用 Host 的设备管理命令。

本版范围为直连观察。Relay、相机实时扫描、远程审批和发消息尚未实现。

## 本机编译

在 Xcode 中打开 `AgentPulse.xcodeproj`，选择 `AgentPulse` scheme，再选择 `My Mac` 运行。也可在命令行构建。

```bash
xcodebuild -project AgentPulse.xcodeproj -scheme AgentPulse \
  -destination 'platform=macOS' -derivedDataPath build/macOS CODE_SIGN_IDENTITY=- build
open build/macOS/Build/Products/Debug/AgentPulse.app
```

可在本目录用已有的 SDK 验证 iPhone 构建。

```bash
xcodebuild -project AgentPulse.xcodeproj -target AgentPulse -sdk iphoneos \
  -configuration Debug SYMROOT="$PWD/build/iOS/products" CODE_SIGNING_ALLOWED=NO build
```

用真机试用时，在 Xcode 的 Signing & Capabilities 中选择自己的 Team。若 Bundle Identifier 已被占用，使用自己的标识符，并选择已连接的 iPhone 运行。连接处于同一 Wi-Fi 的 Host 时，允许系统提示的本地网络访问。

如果 `xcode-select` 指向 Command Line Tools，可以只在当前终端指定 Xcode。

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
```

## 连接 Host

以下命令在运行 Codex 的电脑上执行。先从 `agentpulse-rs` 构建 Host 并准备 Codex CLI。版本基线为 Codex CLI `0.171.0`。本机或同一 Wi-Fi 测试时，`<HOST_IP>` 用 Host 的局域网 IPv4 地址，例如从 Mac 的 Wi-Fi 网络详情获取。使用已有 Host 时，可跳过已完成的初始化。

```bash
agentpulse init --name "My Mac"
agentpulse direct configure --bind <HOST_IP> \
  --native-endpoint <HOST_IP>:49320 --pairing-endpoint <HOST_IP>:49321
agentpulse serve --discover-threads
```

1. 在另一个终端运行 `agentpulse pair`，保存完整二维码及留白区域的截图。在两分钟内打开 App，选择 **Import Pairing QR Image** 或 **Choose QR from Photos**。
2. 回到 Host 终端，核对设备名称，输入 `y` 确认。App 会尝试连接并同步会话。
3. 从要工作的目录运行 `agentpulse codex`，开始或恢复会话。App 会自动发现会话，在列表中选择后可查看事件。
4. 使用 `agentpulse status` 查看 Host 状态。若 Host 用了 `--data-dir`，请给所有命令传相同的路径。

若 App 提示连接失败，先确认二维码中的地址可从当前设备访问，Host 仍在运行，而且没有其他 Native 客户端占用该连接。二维码过期后应重新生成。忘记本机凭据后可再次配对。
