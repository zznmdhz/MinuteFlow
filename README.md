# MinuteFlow for Mac

MinuteFlow 是一个本地优先的 macOS 会议录音工具。当前仓库实现 PRD 中的 **v0.1 技术验证版**：分别捕获系统声音与麦克风声音，提供录音控制、实时音量、菜单栏状态和本地会话保存。

## 当前能力

- 支持 macOS 14 及以上，使用 Swift 6、SwiftUI 与 AppKit。
- 使用 ScreenCaptureKit 捕获系统声音，不采集视频画面，并排除 MinuteFlow 自身播放的声音。
- 使用 AVAudioEngine 捕获默认麦克风。
- 系统声音与麦克风分别保存为 `system.m4a` 和 `microphone.m4a`。
- 默认采用 AAC、48 kHz；系统声为双声道，麦克风按输入设备声道数保存（最多双声道）。
- 支持开始、暂停、继续、停止并保存，显示有效录音时长与两路实时音量。
- 任一路启动或运行异常时，另一路尽可能继续录制。
- 主窗口关闭后应用继续驻留菜单栏，录音不会停止。
- 权限不足时说明所需权限、用途及系统设置入口。
- 每次录音创建独立会话目录，并以原子写入方式保存 `metadata.json`。

## 工程结构

```text
MinuteFlow/
├── App/                 应用入口、菜单栏与依赖装配
├── Core/
│   ├── Audio/           系统声音、麦克风、音频写入与音量计算
│   ├── Permissions/     麦克风和屏幕录制权限
│   ├── Recording/       RecordingCoordinator
│   └── Storage/         本地会议目录与 metadata.json
├── Features/
│   ├── Recording/       主录音界面、菜单栏和音量组件
│   └── Settings/        v0.1 录音与隐私设置
├── Models/              会话、来源和录音状态模型
└── Shared/              通用格式化工具
```

录音逻辑不位于 SwiftUI View 中。`RecordingCoordinator` 只负责流程协调，底层捕获、文件写入、权限和存储均通过独立服务完成。

## 权限要求

第一次录制时，macOS 会请求：

1. **麦克风**：用于单独录制用户发言。
2. **屏幕与系统音频录制**：用于录制腾讯会议、飞书、Zoom、Teams 或浏览器播放的声音。MinuteFlow 不会保存屏幕画面。

如果系统声音权限此前被拒绝，请前往“系统设置 → 隐私与安全性 → 屏幕与系统音频录制”启用 MinuteFlow，随后重新启动应用。麦克风权限位于“系统设置 → 隐私与安全性 → 麦克风”。

## 运行方式

1. 使用 Xcode 16 或更高版本打开 `MinuteFlow.xcodeproj`。
2. 在 MinuteFlow Target 的 Signing & Capabilities 中选择自己的开发团队。
3. 选择 “My Mac” 并运行。
4. 建议用浏览器或会议应用播放一段声音，选择“系统声音 + 麦克风”完成双路验证。
5. 停止后点击“在 Finder 中显示”，检查两个 M4A 文件是否可播放。

项目文件由 `project.yml` 生成。如需重新生成，请先安装 XcodeGen，再在项目目录执行 `xcodegen generate`。

## 测试

Xcode 中选择 Product → Test，或运行：

```bash
xcodebuild -project MinuteFlow.xcodeproj -scheme MinuteFlow -destination 'platform=macOS' test
```

仓库也包含 Swift Package 描述，可用 `swift test` 运行不依赖签名和权限弹窗的基础单元测试。测试覆盖音量计算、双路协调与单路降级、会话目录和元数据持久化。

## 数据位置

沙盒版默认保存到：

```text
~/Library/Containers/com.minuteflow.app/Data/Library/Application Support/MinuteFlow/Sessions/{UUID}/
├── metadata.json
└── audio/
    ├── system.m4a
    └── microphone.m4a
```

实际仅创建用户选择的声音来源文件。

## v0.1 当前限制

- 当前只录制默认显示器关联的系统声音和默认麦克风，不提供指定应用或输入设备切换。
- 暂停期间不写入音频，因此文件时长与界面显示的有效录音时长一致；不保留暂停空白。
- v0.1 不生成 `mixed.m4a`，后续版本再进行停止后的混音。
- 不包含实时转写、会议纪要、远程 API、历史录音导入或复杂码率设置。
- 若录音过程中切换或断开音频设备，当前版本会提示异常；自动切换将在后续稳定版完善。

