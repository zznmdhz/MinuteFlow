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
|Windows 凭据|真实 DPAPI 保存/重开；空 Token 更新保留已有值；损坏保护文件可恢复|候选 Windows Actions 实际通过；Mac SKIP|
|Windows 文件音频|真实 NAudio 脉冲混音；已知 callback 时间戳重叠裁剪与缺口填零；原轨 hash 不变；取消不覆盖输出；混音头部余量|候选 Windows Actions 实际通过；Mac SKIP。不包含实际 WASAPI 设备|
|事后转写|部分已覆盖区间仍补齐剩余；保留用户编辑；取消保留已完成文字且不标完成|候选 Windows Actions 实际通过；HTTP 为固定模拟服务|
|暂停状态机|无法恢复音频来源时 Resume 报错并保持 paused；不自动恢复录音|候选 Windows Actions 实际通过。不调用真实设备|

第一轮 Core 检查暴露实际失败：未改标题更新 mtime、迟到音频 callback 让活动时间倒退、MiMo 同时发送 Bearer 与 api-key。后续检查又实际捕获了导入 Mac 人工编辑片段被实时追加改写的问题。修复后的第一批 **24/24 Core 行为检查**在 Mac .NET 10 上执行通过，退出状态为 0。

最后冻结前增加一项42小时历史录音时长格式回归，检查 `42:25:15`、负数/NaN 安全显示及列表/时间轴一致性。最新 **25/25 Core检查**已在本机实际通过，退出状态0；最终检查数量为 **25 项 Core＋10 项 Windows专用＝35 项**，已在下列冻结候选 Windows 运行中全部通过。第一轮候选34项保留其真实数量。

另有 **10 项 Windows 条件检查**。独立跨编译曾捕获 NAudio `MMDeviceCollection` 不实现 IDisposable 的真实编译错误；实现者修复后跨编译成功，0 警告/0 错误。随后在下列真实 Windows Actions 候选运行中全部执行，日志明确 **34/34 behavioral checks passed**，10 项 Windows 条件检查均 PASS，无 SKIP。

## 已核验的 Windows 候选运行

### 最终应用源码：12ef027，双平台完整工作流通过

- [Actions run 38033209888，Windows job 114158239250](https://github.com/zznmdhz/MinuteFlow/actions/runs/38033209888/job/114158239250)，提交 `12ef027d439f3cbdb499c27567a34470f69924d2`。独立核对 jobs 元数据和真实 Windows 日志，工作流结论 success，版本门禁 `0.13.0 (16)`，明确 **35/35 behavioral checks passed**；10项 Windows 条件检查全部实际执行通过。
- 最终源码只在前一冻结候选基础上将剩余播放时间/事后转写进度显示改为已测 `MeetingTime.Format`。严格1000段 WPF 虚拟化检查保持不变；最新自包含 EXE 和安装后 EXE 两次 smoke、Installer 编译/实际安装/卸载及两份 Windows 产物上传均 success。
- [同一 run 的 Mac job 114158239146](https://github.com/zznmdhz/MinuteFlow/actions/runs/38033209888/job/114158239146) 版本门禁、回归、双架构构建和上传全部 success。主分支已同步相同应用提交；[main run 38033394849](https://github.com/zznmdhz/MinuteFlow/actions/runs/38033394849) 是相同源码的重复工作流，记录时仍在进行。
- 应用源码已冻结，后续本报告/发布说明的提交不再改变应用功能。最终 `v0.13.0` tag 工作流还会重新执行35项 Windows检查、Mac回归与双平台打包，并在两平台均通过后成对发布；发布存在与最终文件校验和由主 agent 最后核验。

### 冻结候选：35 项及严格 WPF 虚拟化检查通过

- [Actions run 38029852414，Windows job 114148310230](https://github.com/zznmdhz/MinuteFlow/actions/runs/38029852414/job/114148310230)。提交：`6e6ea9a89fe1c6caefc0a908b74004b552d655f7`。
- 独立读取并核对真实日志：Windows Server 2025、.NET SDK 10.0.401，版本门禁 `0.13.0 (16)`，明确 **35/35 behavioral checks passed**，无失败、无 Windows 条件检查 SKIP。
- 35 项包括42小时显示、混音容量/NaN拒绝保护旧回放、真实 DPAPI、文件脉冲/重叠/缺口混音、事后转写差集与取消、人工编辑保留、失败恢复保持暂停等。
- 独立核对该提交的严格 `PerformSmokeTest` 源码，并确认对应打包步骤 success：实际创建1000段；首段容器存在，可见容器数量为1–100；滚动至末段后末段容器存在，首段容器已回收，可见数量仍为1–100；滚回首段后编辑保存且原识别文字未变。0 容器不能假通过。
- 严格 smoke 随已发布自包含 EXE 执行；安装到临时目录后再执行同一 smoke。`build-windows.ps1` 逐项检查退出状态，任一步失败会终止工作流。两次 smoke、Inno Setup 编译、实际安装/卸载和 ZIP/Setup 产物上传步骤均成功。
- 同一 run 的 Mac 版本门禁、回归、双架构打包与上传也全部 success。分支运行的 release job 为 skipped（非 tag），不能把这次候选上传当成已发布 Release。
- 后续 `12ef027` 显示修复已由上方最终完整工作流重新通过；本节保留前一严格虚拟化候选的独立证据。

### 第一轮候选：34 项通过（历史记录）

- [Actions run 38029184421，Windows job 114146340044](https://github.com/zznmdhz/MinuteFlow/actions/runs/38029184421/job/114146340044)。提交：`bf3de90169281772fcf6b19da1f8be6d498e5105`；分支：`codex/windows-dual-platform`。
- 执行系统：Windows Server 2025 / 10.0.26100；SDK：.NET 10.0.401。不是用户的 Windows 10/11 音频电脑。
- 日志版本门禁：两个平台 `0.13.0 (16)`。34 项真实行为检查全部通过。
- `build-windows.ps1` 成功完成自包含 win-x64 发布、已发布 EXE 的 WPF/配置/文件音频 smoke、自包含 ZIP、Inno Setup 安装包编译、临时目录安装、安装后 EXE smoke 与卸载门禁，步骤结论 success。
- 已上传 Windows ZIP 和 Setup.exe 两份候选产物。此时尚不是最终 tag 的成对 Release。
- 候选通过后又补了逐轨启动降级、静音无 callback 定稿、虚拟化逐字稿及更严格的 UI smoke 等改动，已由上方 `6e6ea9a` 的完整工作流重新验证；不能只用这次旧34项运行替代最新验证。

## 独立审查发现与修复要求

|严重度|发现|验收方式|
|---|---|---|
|P1|任一已有转写与新块重叠时跳过整块，会永久遗漏剩余音频却标为完成|部分覆盖区间测试，按未覆盖区间实际切片补齐|
|P1|Windows 混音时间轴写 `monotonic`，Mac 只接受 `captureClock`/`callbackClock`|修为共享枚举值并检查 Mac 解码|
|P1|Windows 说话人时间轴缺 Mac required 字段，包括 result version/date/source/count、turn id/confidence|补齐共享 JSON schema 并检查 Mac 解码|
|P1|延迟包与现存音轨重叠仍追加导致轨道增长；混音扩大有效录音时长|已知时间戳包的真实文件检查，保留原片与裁重叠|
|P1|原始 float32 WAV 约6.2小时达到 RIFF 4GiB 容量限制|已改 PCM16，加入10小时容量自动暂停与拒绝恢复超限会话；需实机长时测试|
|P1|导入/重混超长音频仍可能生成超限 WAV，转换失败前原文件元数据未登记|混音10小时/非有限时轴预检保护旧输出与输入；导入先登记原文件，再可选混音；已有 Windows 混音取消检查增加42小时/NaN预检断言，不增加检查总数|
|P1|两路高音量相加硬裁剪，失去峰值余量|同时0.9幅度的合成音频检查输出峰值≤0.8|
|P1|停止时混音失败可能留下错误 saving 状态|原轨保留，失败 metadata 可重新生成完整回放|
|P1|删除会议后才保存待编辑内容，访问已移走目录|删除前先保存并结束编辑，再清空选择|
|P2|退出正在取消的后台任务时，CancellationException 由 async void 穿出|关闭逻辑处理取消后再退出，不能弹非预期错误|
|P2|无声检测接受 Infinity 或迟到 callback，让暂停提前/延后|单调活动时间与无效样本测试|
|P2|重复失焦提交无实际标题修改仍改变自动标题标记|未改动直接退出编辑模式|
|P2|导入 Mac 人工编辑记录没有 Windows UserEdited 字段，被实时合并追加|新增实际失败回归，修复后 Core 检查通过|
|P2|设备丢失/容量上限时恢复失败，仍提前清除暂停状态|只在 Recorder.Resume 成功后清除 paused，Windows 条件检查|
|P2|网络暂时错误无有限重试，待转写数据积压|503/429 预算检查，401无重试|

上述问题已逐项反馈实现 agent，并确认修复源码已经落地。最终 `12ef027` 的 Core、合成文件音频、DPAPI、补全与 Windows 状态机已有上述35项日志实际通过结果，严格1000行 WPF smoke及安装流程已通过。硬件相关行为仍保留实机门禁。

## Mac 本机验证交接证据

以下由主 agent 在用户 Mac 上实际核验后交接，不伪装成 Windows 验证 agent 独立操作的结果：

- Mac v0.13.0 已安装，沿用原稳定本机签名；codesign 深度/严格校验通过，包含 arm64/x86_64 两架构。
- 实际启动及历史列表显示正常，设置提示已保存 Token 保留；没有重新收集或写入用户真实 Token。
- Mac 本机44项回归检查全部通过，既有会议录音保留。Windows 真实硬件结论仍与此分开。

## 仍需 Windows 实机验证

GitHub Windows runner 可执行 WPF 启动、自包含程序、DPAPI 与合成文件音频检查，但无法证明真实麦克风、声卡、蓝牙设备和权限交互正确。以下项目必须在真实 Windows 10/11 电脑核验：

- 麦克风、系统声和双路录音的实际音量、完整回放、启动差与音视频同步。
- 真实暂停/恢复是否排除停录时间，蓝牙断开、设备切换、单路故障、静音系统声和权限拒绝是否正确保留录音。
- 一小时以上录音的内存、CPU、磁盘、尾部保存与回放；休眠/唤醒后的恢复行为。
- 连续30/60分钟真实无声自动暂停，弹窗保持暂停，只有主动选择才恢复或结束。
- 真实多人讲话的本地聚类误差；模型服务实际连通和识别质量。
- Windows 对新发布程序的签名/安全提示与实际安装升级流程。

发布前如上述门禁没有完成，应明确使用 Windows preview 标记，不能宣称双平台完整稳定版或 100% 无问题。公开发布不包含任何用户录音、真实 Token、受保护凭据或测试安装所需个人秘密。
