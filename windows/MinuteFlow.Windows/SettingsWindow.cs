using System.Diagnostics;
using System.Windows;
using System.Windows.Controls;
using MinuteFlow.Core;

namespace MinuteFlow.Windows;

public sealed class SettingsWindow : Window
{
    private readonly SettingsStore store;
    private readonly ModelClient client;
    private readonly TextBox baseUrl = new(), asrModel = new(), textModel = new();
    private readonly PasswordBox token = new();
    private readonly ComboBox protocol = new(), language = new(), silence = new(), microphone = new();
    private readonly CheckBox asrEnabled = new() { Content = "录音时实时转写" }, automaticTitle = new() { Content = "结束后自动生成会议主题" }, automaticSummary = new() { Content = "结束后自动生成会议纪要" };
    private readonly TextBlock status = new() { TextWrapping = TextWrapping.Wrap };
    private readonly StackPanel buttons = new() { Orientation = Orientation.Horizontal };
    private readonly CancellationTokenSource cancellation = new();
    public SettingsWindow(SettingsStore store, ModelClient client, bool enumerateDevices = true)
    {
        this.store = store; this.client = client; Title = "设置与检测"; Width = 680; Height = 760; MinHeight = 560; WindowStartupLocation = WindowStartupLocation.CenterOwner; Background = System.Windows.Media.Brushes.White;
        var content = new StackPanel { Margin = new Thickness(24) }; Content = new ScrollViewer { Content = content, VerticalScrollBarVisibility = ScrollBarVisibility.Auto };
        content.Children.Add(new TextBlock { Text = "AI 服务", FontSize = 23, FontWeight = FontWeights.Bold, Margin = new Thickness(0, 0, 0, 14) });
        AddField(content, "Base URL（HTTPS）", baseUrl); AddField(content, "Token（留空保留已保存 Token）", token); AddField(content, "语音识别模型名称", asrModel); AddField(content, "主题 / 总结 / 文稿模型名称", textModel);
        protocol.ItemsSource = new[] { "自动判断协议", "MiMo Audio Chat（含 Token Plan）", "OpenAI Compatible 音频转写" }; AddField(content, "调用协议", protocol);
        language.ItemsSource = new[] { "auto", "zh", "en" }; AddField(content, "识别语言", language);
        content.Children.Add(asrEnabled); content.Children.Add(automaticTitle); content.Children.Add(automaticSummary);
        foreach (var checkbox in new[] { asrEnabled, automaticTitle, automaticSummary }) checkbox.Margin = new Thickness(0, 8, 0, 0);
        var save = Button("保存配置", Save); var testAsr = Button("测试语音模型", async () => await TestAsync(true)); var testText = Button("测试文本模型", async () => await TestAsync(false)); buttons.Children.Add(save); buttons.Children.Add(testAsr); buttons.Children.Add(testText); content.Children.Add(buttons);
        content.Children.Add(new TextBlock { Text = "已保存 Token 使用 Windows 当前用户保护（DPAPI），重启后自动加载。连接测试使用本次输入；保存后实时转写立即采用新配置。", TextWrapping = TextWrapping.Wrap, Foreground = System.Windows.Media.Brushes.Gray, Margin = new Thickness(0, 6, 0, 14) });
        content.Children.Add(Button("删除已保存 Token", () => { if (MessageBox.Show(this, "删除已保存的模型 Token？", "MinuteFlow", MessageBoxButton.YesNo) == MessageBoxResult.Yes) { store.ClearToken(); status.Text = "Token 已清除。"; } }));
        content.Children.Add(new Separator { Margin = new Thickness(0, 16, 0, 16) });
        content.Children.Add(new TextBlock { Text = "录音与保护", FontSize = 21, FontWeight = FontWeights.Bold });
        silence.ItemsSource = new[] { "连续 30 分钟无有效声音时暂停", "连续 60 分钟无有效声音时暂停", "关闭无声保护" }; AddField(content, "防止忘关录音", silence);
        content.Children.Add(new TextBlock { Text = "声音判断同时检查已启用的系统声音和麦克风；持续音乐或噪音可能阻止自动暂停。暂停后需主动选择恢复或结束。", TextWrapping = TextWrapping.Wrap, Foreground = System.Windows.Media.Brushes.Gray });
        microphone.Items.Add(new ComboBoxItem { Content = "系统默认麦克风", Tag = "" });
        try { if (enumerateDevices) foreach (var device in AudioRecorder.Microphones()) microphone.Items.Add(new ComboBoxItem { Content = device.Name, Tag = device.Id }); } catch (Exception error) { status.Text = "音频设备读取失败：" + error.Message; }
        AddField(content, "麦克风", microphone);
        var diagnostics = new WrapPanel(); diagnostics.Children.Add(Button("Windows 麦克风权限", () => Process.Start(new ProcessStartInfo("ms-settings:privacy-microphone") { UseShellExecute = true }))); diagnostics.Children.Add(Button("五秒双路录音自检", async () => await AudioSelfTestAsync())); diagnostics.Children.Add(Button("选择 WAV 测试识别", async () => await TestFileAsync())); content.Children.Add(diagnostics);
        content.Children.Add(new TextBlock { Text = "系统声音通过 WASAPI 回环录制，不需要录屏权限。首次使用请允许桌面应用访问麦克风。自检时请播放电脑声音并对麦克风说话。", TextWrapping = TextWrapping.Wrap, Foreground = System.Windows.Media.Brushes.Gray, Margin = new Thickness(0, 8, 0, 12) });
        content.Children.Add(status);
        var c = store.Configuration; baseUrl.Text = c.BaseUrl; asrModel.Text = c.AsrModel; textModel.Text = c.TextModel; protocol.SelectedIndex = (int)c.Protocol; language.SelectedItem = c.Language; if (language.SelectedIndex < 0) language.SelectedIndex = 0;
        silence.SelectedIndex = c.SilenceMinutes == 60 ? 1 : c.SilenceMinutes == 0 ? 2 : 0; asrEnabled.IsChecked = c.AsrEnabled; automaticTitle.IsChecked = c.AutomaticTitle; automaticSummary.IsChecked = c.AutomaticSummary;
        microphone.SelectedIndex = 0; foreach (ComboBoxItem item in microphone.Items) if (item.Tag as string == c.MicrophoneDeviceId) microphone.SelectedItem = item;
        if (string.IsNullOrEmpty(status.Text)) status.Text = !string.IsNullOrEmpty(store.CredentialError) ? store.CredentialError : string.IsNullOrEmpty(c.Token) ? "尚未保存 Token。" : "已加载当前 Windows 用户安全保存的 Token。";
        Closed += (_, _) => { cancellation.Cancel(); };
    }
    private static Button Button(string title, Action action) { var button = new Button { Content = title, Padding = new Thickness(10, 7, 10, 7), Margin = new Thickness(0, 12, 8, 0) }; button.Click += (_, _) => action(); return button; }
    private static void AddField(StackPanel parent, string title, Control field) { parent.Children.Add(new TextBlock { Text = title, Margin = new Thickness(0, 10, 0, 5) }); field.MinHeight = 32; parent.Children.Add(field); }
    private ModelConfiguration Draft()
    {
        return new ModelConfiguration { BaseUrl = baseUrl.Text.Trim(), Token = string.IsNullOrWhiteSpace(token.Password) ? store.Configuration.Token : token.Password.Trim(), AsrModel = asrModel.Text.Trim(), TextModel = textModel.Text.Trim(), Protocol = (ASRProtocol)Math.Max(0, protocol.SelectedIndex), Language = language.SelectedItem as string ?? "auto", AsrEnabled = asrEnabled.IsChecked == true, AutomaticTitle = automaticTitle.IsChecked == true, AutomaticSummary = automaticSummary.IsChecked == true, SilenceMinutes = silence.SelectedIndex == 1 ? 60 : silence.SelectedIndex == 2 ? 0 : 30, MicrophoneDeviceId = (microphone.SelectedItem as ComboBoxItem)?.Tag as string };
    }
    private void Save()
    {
        try { var c = Draft(); ModelClient.Endpoint(c.BaseUrl, "chat/completions"); store.Save(c, token.Password); token.Clear(); status.Text = "配置已保存并回读验证。下次启动会自动加载；正在录音的后续转写也立即使用新配置。"; }
        catch (Exception e) { status.Text = "保存失败：" + RecordingEngine.SafeError(e, token.Password); }
    }
    private async Task TestAsync(bool audio)
    {
        buttons.IsEnabled = false; var c = Draft();
        try
        {
            status.Text = "正在测试实际模型调用…";
            var result = audio ? await client.TranscribeAsync(WavePcm.Encode16Bit(new float[16000], 16000), c, cancellation.Token) : await client.CompleteAsync("请回复连接成功。", "连接测试", c, cancellation.Token);
            status.Text = audio ? "语音模型调用成功。测试使用静音音频，返回空文字属于正常情况；也可选择 WAV 进行真实识别测试。" : "文本模型调用成功：" + result;
        }
        catch (OperationCanceledException) { status.Text = "测试已取消。"; }
        catch (Exception e) { status.Text = "测试失败：" + RecordingEngine.SafeError(e, c.Token); }
        finally { buttons.IsEnabled = true; }
    }
    private async Task TestFileAsync()
    {
        var picker = new Microsoft.Win32.OpenFileDialog { Filter = "WAV 音频|*.wav" }; if (picker.ShowDialog(this) != true) return;
        try
        {
            using var reader = new NAudio.Wave.AudioFileReader(picker.FileName); var provider = AudioFiles.Mono48(reader); var samples = new float[AudioRecorder.SampleRate * 15]; var read = provider.Read(samples, 0, samples.Length);
            status.Text = "正在识别前 15 秒…"; var c = Draft(); var result = await client.TranscribeAsync(WavePcm.Encode16Bit(samples[..read], AudioRecorder.SampleRate), c, cancellation.Token); status.Text = string.IsNullOrWhiteSpace(result) ? "调用成功，当前音频没有识别出文字。" : result;
        }
        catch (OperationCanceledException) { status.Text = "测试已取消。"; }
        catch (Exception e) { status.Text = "识别失败：" + RecordingEngine.SafeError(e, Draft().Token); }
    }
    private async Task AudioSelfTestAsync()
    {
        var folder = Path.Combine(Path.GetTempPath(), "MinuteFlow-audio-test-" + Guid.NewGuid().ToString("N"));
        try
        {
            status.Text = "正在进行五秒自检，请播放电脑声音并说话…";
            var repository = new MeetingRepository(folder); var session = repository.Create("自检", "both"); using var recorder = new AudioRecorder(); double systemPeak = 0, micPeak = 0;
            recorder.Samples += (source, samples, _) => { var energy = WavePcm.Rms(samples); if (source == "system") systemPeak = Math.Max(systemPeak, energy); else micPeak = Math.Max(micPeak, energy); };
            recorder.Start(session, repository, Draft().MicrophoneDeviceId); await Task.Delay(TimeSpan.FromSeconds(5), cancellation.Token); recorder.Stop();
            status.Text = $"系统声音：{(systemPeak >= 0.006 ? "检测到有效声音" : "未检测到声音，请检查电脑是否在播放")}；麦克风：{(micPeak >= 0.006 ? "检测到有效声音" : "未检测到声音，请检查设备与权限")}。";
        }
        catch (OperationCanceledException) { status.Text = "自检已取消。"; }
        catch (Exception e) { status.Text = "录音自检失败：" + e.Message; }
        finally { try { if (Directory.Exists(folder)) Directory.Delete(folder, true); } catch { } }
    }
}
