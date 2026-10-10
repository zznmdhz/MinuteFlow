# Windows 独立验证记录

日期：2026-10-10。目标版本：0.13.0。此文稿由独立验证 agent 编写，测试与实现由不同 agent 负责。

## 验证方法与范围

行为检查在 `windows/tests/MinuteFlow.Core.Tests` 中，使用实际产品类和固定无敏感数据样本，不调用用户的真实模型账户，也不访问已有会议录音。运行失败返回非零退出状态，逐项列出 PASS/FAIL，Windows 专用检查在非 Windows 环境明确列出 SKIP。

```text
dotnet run --project windows/tests/MinuteFlow.Core.Tests -c Release
```

`dotnet test` 不能代替此命令：本项目使用无第三方测试框架的控制台检查器，GitHub 工作流必须真正执行它。

跨平台样本：`Fixtures/swift-session.json`、`swift-transcript.json`、`windows-session.json`、`会议纪要.md`。样本覆盖中文名称、ISO8601 时区和小数秒、Mac percent-encoded file URL、Windows 相对 WAV 文件名、原始/编辑/校正文字、speakerID、recognitionFragments 和旧版本未知字段。

## 自动行为检查

|范围|具体检查|执行环境与状态|
|---|---|---|
|数据兼容|Swift metadata/逐字稿解码，未知字段及原始识别证据重存不丢；Windows 日期/相对路径解码|Mac .NET 实际执行通过|
|历史数据|读取/浏览不修改逐字稿/纪要/metadata 的 mtime；相同内容不重写；未改标题不重写|Mac .NET 实际执行通过|
|目录操作|改名移动全部会议文件并保持 UUID；文件 URL 重定位；重名避碰；Windows 保留名称；防目录穿越；可恢复删除|Mac .NET 实际执行通过|
|逐字稿|乱序识别结果落盘按时间排序；已编辑文字和 originalText 分别保留；导入 Mac 人工编辑片段不被实时合并改写|Mac .NET 实际执行通过|
|凭据|普通配置 JSON 排除 Token；模型服务错误脱敏；401 不自动重试|Mac .NET 实际执行通过|
|ASR HTTP|MiMo input_audio data URL/api-key 与语种规范；自定义 multipart/Bearer 及 WAV；取消请求；拒绝仿冒 MiMo 域名|Mac .NET 实际执行通过|
|切片|一小时合成静音无请求切片；3秒预览；约700ms停顿定稿；15秒最长块；手动暂停 flush 与重复 flush|Mac .NET 实际执行通过；不是一小时硬件录音|
|防忘关|30/60分钟边界、有效声音重置、关闭选项、非有限值和迟到 callback|Mac .NET 模拟时钟实际执行通过；不是等待一小时实测|
|临时服务故障|503 重试同一音频成功、429 三次后停止|Mac .NET 实际执行通过|
|Windows 凭据|真实 DPAPI 保存/重开；空 Token 更新保留已有值；损坏保护文件可恢复|仅 Windows 执行；Mac SKIP|
|Windows 文件音频|真实 NAudio 脉冲混音；已知 callback 时间戳重叠裁剪与缺口填零；原轨 hash 不变；取消不覆盖输出；混音头部余量|仅 Windows 执行；Mac SKIP。不包含实际 WASAPI 设备|
|事后转写|部分已覆盖区间仍补齐剩余；保留用户编辑；取消保留已完成文字且不标完成|仅 Windows 执行；Mac SKIP。HTTP 为固定模拟服务|
|暂停状态机|无法恢复音频来源时 Resume 报错并保持 paused；不自动恢复录音|仅 Windows 执行；Mac SKIP。不调用真实设备|

第一轮 Core 检查暴露实际失败：未改标题更新 mtime、迟到音频 callback 让活动时间倒退、MiMo 同时发送 Bearer 与 api-key。后续检查又实际捕获了导入 Mac 人工编辑片段被实时追加改写的问题。修复后的最终 **24/24 Core 行为检查**在 Mac .NET 10 上执行通过，退出状态为 0。

另有 **10 项 Windows 条件检查**。独立跨编译曾捕获 NAudio `MMDeviceCollection` 不实现 IDisposable 的真实编译错误；实现者修复后跨编译成功，0 警告/0 错误。此构建结果不等于 Windows 运行结果。GitHub Windows 执行全部检查时应得到 **34/34**；发布时必须引用真实 Actions 日志，未执行或失败时不得填通过。

## 独立审查发现与修复要求

|严重度|发现|验收方式|
|---|---|---|
|P1|任一已有转写与新块重叠时跳过整块，会永久遗漏剩余音频却标为完成|部分覆盖区间测试，按未覆盖区间实际切片补齐|
|P1|Windows 混音时间轴写 `monotonic`，Mac 只接受 `captureClock`/`callbackClock`|修为共享枚举值并检查 Mac 解码|
|P1|Windows 说话人时间轴缺 Mac required 字段，包括 result version/date/source/count、turn id/confidence|补齐共享 JSON schema 并检查 Mac 解码|
|P1|延迟包与现存音轨重叠仍追加导致轨道增长；混音扩大有效录音时长|已知时间戳包的真实文件检查，保留原片与裁重叠|
|P1|原始 float32 WAV 约6.2小时达到 RIFF 4GiB 容量限制|已改 PCM16，加入10小时容量自动暂停与拒绝恢复超限会话；需实机长时测试|
|P1|两路高音量相加硬裁剪，失去峰值余量|同时0.9幅度的合成音频检查输出峰值≤0.8|
|P1|停止时混音失败可能留下错误 saving 状态|原轨保留，失败 metadata 可重新生成完整回放|
|P1|删除会议后才保存待编辑内容，访问已移走目录|删除前先保存并结束编辑，再清空选择|
|P2|退出正在取消的后台任务时，CancellationException 由 async void 穿出|关闭逻辑处理取消后再退出，不能弹非预期错误|
|P2|无声检测接受 Infinity 或迟到 callback，让暂停提前/延后|单调活动时间与无效样本测试|
|P2|重复失焦提交无实际标题修改仍改变自动标题标记|未改动直接退出编辑模式|
|P2|导入 Mac 人工编辑记录没有 Windows UserEdited 字段，被实时合并追加|新增实际失败回归，修复后 Core 检查通过|
|P2|设备丢失/容量上限时恢复失败，仍提前清除暂停状态|只在 Recorder.Resume 成功后清除 paused，Windows 条件检查|
|P2|网络暂时错误无有限重试，待转写数据积压|503/429 预算检查，401无重试|

上述问题已逐项反馈实现 agent，并确认修复源码已经落地。Core 问题已有实际通过结果；音频、DPAPI、补全与 Windows 状态机检查仍以真实 Windows Actions 日志为运行证据。硬件相关行为仍保留实机门禁。

## 仍需 Windows 实机验证

GitHub Windows runner 可执行 WPF 启动、自包含程序、DPAPI 与合成文件音频检查，但无法证明真实麦克风、声卡、蓝牙设备和权限交互正确。以下项目必须在真实 Windows 10/11 电脑核验：

- 麦克风、系统声和双路录音的实际音量、完整回放、启动差与音视频同步。
- 真实暂停/恢复是否排除停录时间，蓝牙断开、设备切换、单路故障、静音系统声和权限拒绝是否正确保留录音。
- 一小时以上录音的内存、CPU、磁盘、尾部保存与回放；休眠/唤醒后的恢复行为。
- 连续30/60分钟真实无声自动暂停，弹窗保持暂停，只有主动选择才恢复或结束。
- 真实多人讲话的本地聚类误差；模型服务实际连通和识别质量。
- Windows 对新发布程序的签名/安全提示与实际安装升级流程。

发布前如上述门禁没有完成，应明确使用 Windows preview 标记，不能宣称双平台完整稳定版或 100% 无问题。公开发布不包含任何用户录音、真实 Token、受保护凭据或测试安装所需个人秘密。
