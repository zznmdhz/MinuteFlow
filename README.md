# MinuteFlow for Mac

MinuteFlow 是一款 macOS 14+ 原生会议录音与转写工具。原始录音保存在本机；开启 AI 功能后，应用按需向用户配置的服务发送短音频片段，并可根据逐字稿生成会议纪要。

## v0.5 已实现

- 使用 ScreenCaptureKit 录制系统声音，使用 AVAudioEngine 录制麦克风，两路分别保存为 M4A。
- 开始、暂停、继续、停止、菜单栏控制、实时音量、单路失败时降级继续录制。
- 录音文件按“日期时间 + 会议名称 + 声音来源”自动命名，并可在应用内播放或定位到 Finder。
- 最近会议可以重新打开、重命名和完整删除，删除范围包括原音频、逐字稿和纪要。
- 一个 AI 服务页面只填写一次 Base URL 和 Token；ASR 与总结共用该连接。
- 自动识别 MiMo Token Plan 地址，并用 `api-key` 请求头、`/chat/completions` + `input_audio` 调用 `mimo-v2.5-asr`。
- 其他自定义服务默认使用 OpenAI Compatible `/audio/transcriptions`，总结使用 `/chat/completions`。
- 内置真实连接测试：生成一段中文测试语音验证 ASR，并用短逐字稿验证总结模型。
- 基于语音活动动态切片：检测到约 0.7 秒停顿就提交；持续讲话默认最长约 3 秒提交一次，可在 2–8 秒间调整。
- 逐字稿保留“原始识别”，允许直接编辑，并可生成不覆盖原文的“规范化”版本。
- 权限页明确显示麦克风和屏幕/系统音频权限，并提供五秒双路录音自检与回放。
- API Key / Token 仅保存在 macOS 钥匙串，不写入会议文件或日志。

## 为什么仍有两个模型名称

这里不是两个服务配置。Base URL 和 Token 只填一次，但两项任务的模型职责不同：

```text
系统声 / 麦克风
    ├── 本地 M4A 原始录音
    └── 动态 WAV 短片段 → ASR 模型 → 可编辑逐字稿
                                      └── 文本模型 → Markdown 会议纪要
```

`mimo-v2.5-asr` 是专门的语音识别模型；会议总结需要当前 Token Plan 套餐支持的文本模型。关闭“会议总结”后只需填写 ASR 模型，不需要填写总结模型。

## MiMo Token Plan 配置

在“设置 → AI 服务”中填写：

1. Base URL：Token Plan 页面给出的 OpenAI Compatible 地址，例如中国区 `https://token-plan-cn.xiaomimimo.com/v1`。
2. API Key / Token：Token Plan 页面生成的 `tp-...` Token。
3. ASR 模型：`mimo-v2.5-asr`。
4. 如需纪要，再开启“会议总结”并填写套餐支持的文本模型。
5. 点击“测试当前配置”，分别查看语音识别和总结的真实返回与耗时。

应用会从 Base URL 自动派生请求地址；用户不需要手工填写完整 `/chat/completions` 接口。

没有有效 Token 时，录音仍会完整保存在本机，但不会上传音频、生成逐字稿或会议纪要。

## 数据目录

默认会议目录：

```text
~/Library/Application Support/MinuteFlow/Sessions/{UUID}/
├── metadata.json
├── audio/
│   ├── 2026-07-17_1430_项目周会_系统声.m4a
│   └── 2026-07-17_1430_项目周会_麦克风.m4a
├── transcript/
│   ├── segments.json
│   └── transcript.md
└── summary/
    └── summary.md
```

启用 ASR 后，临时 WAV 短片段会发送到所选服务，识别完成后从临时目录删除。启用总结时，逐字稿文本会发送到同一服务连接中的总结模型。

## 运行与测试

使用 Xcode 打开 `MinuteFlow.xcodeproj`，选择开发团队和“My Mac”后运行。首次录音需要授予麦克风与屏幕/系统音频录制权限；macOS 更新屏幕录制权限后，可能需要重启应用。

也可以执行：

```bash
swift test
```

测试覆盖音量计算、WAV 转换、双路协调与单路降级、会议持久化与删除、友好文件名、Token Plan 接口解析和逐字稿规范化。

## 当前边界

- 当前是“短片段近实时”转写，首段延迟由停顿/最长切片时长加网络响应时间构成，并非逐字流式识别。
- 两路声音分别识别并按有效录音时间排序，暂不做说话人声纹识别。
- 自定义服务必须兼容当前使用的 OpenAI 音频转写与 Chat Completions 请求格式。
- 远程模型的可用性、计费、速率限制和数据留存由对应服务商决定。
- 发布给其他 Mac 使用仍需开发者自行配置 Apple Developer ID 签名与公证。
