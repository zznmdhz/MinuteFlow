# MinuteFlow for Mac

MinuteFlow 是一个本地保存录音、按需调用云端模型的 macOS 会议记录工具。当前版本支持双路录音、MiMo / GLM 语音识别、结构化逐字稿、MiMo / DeepSeek / GLM 会议总结以及完整会议删除。

## 已实现能力

- macOS 14+，Swift 6、SwiftUI、AppKit、ScreenCaptureKit 与 AVAudioEngine。
- 系统声音和麦克风分别保存为 `system.m4a`、`microphone.m4a`。
- 支持开始、暂停、继续、停止、菜单栏控制、实时音量与异常降级。
- 关闭窗口后继续录音；退出应用前先停止并安全保存。
- 最近会议可重新打开，也可通过列表垃圾桶或右键菜单彻底删除。
- 录音时将声音转换为 16 kHz 单声道 WAV，每约 10 秒上传一个片段进行近实时转写。
- 小米 MiMo：`mimo-v2.5-asr`，调用 `https://api.xiaomimimo.com/v1/chat/completions`。
- 智谱 GLM：`glm-asr-2512`，调用 `https://open.bigmodel.cn/api/paas/v4/audio/transcriptions`。
- 支持自定义兼容 `/audio/transcriptions` 的 ASR 服务。
- 转写片段包含时间、来源、文本和确认状态，持续写入会议目录。
- 使用 MiMo、DeepSeek、GLM 或自定义 OpenAI Compatible Chat API 生成 Markdown 会议纪要。
- API Key 只写入 macOS 钥匙串，不保存在配置文件、会议目录或日志中。

## 模型职责

语音识别和会议总结是两条独立链路：

```text
系统声 / 麦克风
    ├── 本地 M4A 原始录音
    └── 10 秒 WAV 片段 → MiMo-ASR 或 GLM-ASR → 结构化逐字稿
                                                   ↓
                              MiMo / DeepSeek / GLM 文本模型
                                                   ↓
                                              Markdown 纪要
```

DeepSeek 当前用于处理逐字稿和生成总结，不作为 ASR 模型。小米与智谱均有专门的音频输入模型，所以语音识别设置中使用它们的 ASR 型号。

## 首次配置

1. 打开“设置 → 语音识别”。
2. 选择“小米 MiMo ASR”或“智谱 GLM-ASR”。
3. 填写对应平台的 API Key；模型名和官方接口已预设。
4. 如需会议总结，进入“设置 → 会议总结”，选择 MiMo、DeepSeek 或 GLM，填写模型名和 API Key。
5. 可选择转写完成后自动生成纪要，也可以在会议详情中手动点击“生成纪要”。

没有填写 API Key 时，MinuteFlow 仍会完整录音，但不会上传音频或生成文字。

## 数据与隐私

完整 M4A 录音始终保存在本机。启用 ASR 后，只有约 10 秒的临时 WAV 片段会发送到所选模型，识别完成后立即删除临时文件。启用总结时，逐字稿文本会发送到所选总结模型。

默认会议目录：

```text
~/Library/Containers/com.minuteflow.app/Data/Library/Application Support/MinuteFlow/Sessions/{UUID}/
├── metadata.json
├── audio/
│   ├── system.m4a
│   └── microphone.m4a
├── transcript/
│   ├── segments.json
│   └── transcript.md
└── summary/
    └── summary.md
```

## 工程结构

```text
MinuteFlow/
├── App/                  应用入口、菜单栏、依赖装配
├── Core/
│   ├── Audio/            双路捕获、M4A 写入、音量
│   ├── Transcription/    WAV 分段、MiMo / GLM ASR 客户端
│   ├── Summary/          MiMo / DeepSeek / GLM 总结客户端
│   ├── Recording/        RecordingCoordinator
│   ├── Storage/          会话、逐字稿、纪要与删除
│   ├── Security/         Keychain
│   └── Permissions/      macOS 权限
├── Features/             主界面、模型设置、会议详情
├── Models/               会话与结构化逐字稿模型
└── Shared/
```

## 运行与测试

使用 Xcode 打开 `MinuteFlow.xcodeproj`，选择开发团队和 “My Mac” 后运行。首次录音需要授予麦克风与屏幕/系统音频录制权限。

基础测试也可通过 Swift Package 执行：

```bash
swift test
```

测试覆盖音量计算、WAV 转换、双路协调和单路降级、会议持久化与删除、逐字稿/纪要保存以及官方模型接口解析。

## 当前边界

- “实时转写”采用约 10 秒分段，因此文字延迟通常为片段时长加网络响应时间。
- MiMo 官方 ASR 接收 WAV/MP3 的 Base64 音频；GLM-ASR 单片段限制不超过 30 秒，本项目的 10 秒 WAV 同时满足两者要求。
- 两路声音分别识别并按有效录音时间排序，不进行说话人声纹识别。
- 远程模型的可用性、费用、速率限制和内容留存策略由对应服务商决定。
- 当前未实现本地部署 MiMo-ASR 权重；设置中的 MiMo 指小米官方 API。

