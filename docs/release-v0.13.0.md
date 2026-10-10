# MinuteFlow v0.13.0 — macOS + Windows

首次双平台发布：Mac 保留 Swift 原生应用，Windows 新增 WPF/.NET 自包含应用。
两个版本使用相同产品版本、会议数据约定、更新说明及 GitHub 发布流程。

Windows 实现系统声音/麦克风分轨录音、完整回放、暂停恢复、静音防忘关、实时
及事后转写、MiMo Token Plan/自定义接口、DPAPI 凭据、AI 主题/纪要/文稿、
会议管理、可编辑逐字稿、本地说话人标签与托盘。Mac 新增 Windows 日期/路径/
WAV/时间轴读取兼容，并修正 MiMo 仿冒域名判断。

下载 Mac universal ZIP（Apple Silicon + Intel），或 Windows x64 安装程序/
便携 ZIP。Windows 已包含 .NET 运行时，不要求另装 SDK 或虚拟声卡。

这是首个 Windows preview 发布。自动构建及行为验证与真实音频硬件验收分别
记录；不把无声 CI 环境当作麦克风/蓝牙/长录音已实测。Windows 自动地点记录
尚未实现，WAV 单场有效录音上限 10 小时。Windows 未 Authenticode 签名；
CI Mac 包为临时签名、未公证，本机安装沿用已有固定签名身份。

计划、功能差异与测试证据：

- [完整更新计划](windows-migration-plan.md)
- [双平台功能矩阵](platform-feature-matrix.md)
- [独立验证记录](windows-independent-validation.md)
- [Windows 使用说明](../windows/README.md)

以后共用 `version.json`。需求和缺陷修复分别核对两端；一个 tag 同时生成两端
软件及 SHA256。任一构建/行为检查失败不会自动发布两端 Release。
