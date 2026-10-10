using System.ComponentModel;
using System.Collections.ObjectModel;
using System.Diagnostics;
using System.Reflection;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Threading;
using MinuteFlow.Core;
using NAudio.Wave;

namespace MinuteFlow.Windows;

public partial class MainWindow : Window
{
    private readonly MeetingRepository repository;
    private readonly SettingsStore settings;
    private readonly HttpClient http = new() { Timeout = TimeSpan.FromSeconds(60) };
    private readonly ModelClient client;
    private readonly DispatcherTimer refresh = new() { Interval = TimeSpan.FromMilliseconds(100) };
    private readonly DispatcherTimer save = new() { Interval = TimeSpan.FromMilliseconds(650) };
    private readonly bool smoke;
    private readonly System.Windows.Forms.NotifyIcon? tray;
    private MeetingSession? current;
    private readonly List<TranscriptSegment> transcript = [];
    private readonly ObservableCollection<TranscriptRow> transcriptRows = [];
    private RecordingEngine? engine;
    private CancellationTokenSource? operation;
    private Task? operationTask;
    private bool loading, titleCommitting, dirtyTranscript, dirtySummary, dirtyDocument, closing;
    private string originalTitle = "";
    private string preview = "";
    private double lastFinalTime;
    private WaveOutEvent? playback;
    private AudioFileReader? playbackFile;
    private DateTimeOffset lastNotice;
    public MainWindow(string root, bool smoke = false)
    {
        this.smoke = smoke; repository = new MeetingRepository(Path.Combine(root, "Sessions")); settings = new SettingsStore(root); client = new ModelClient(http);
        InitializeComponent();
        TranscriptRows.ItemsSource = transcriptRows;
        VersionLabel.Text = "v" + (Assembly.GetExecutingAssembly().GetName().Version?.ToString(3) ?? "0.13.0");
        var context = new ContextMenu();
        AddMenu(context, "重命名会议", BeginTitleEdit); AddMenu(context, "在文件资源管理器中显示", () => RevealMeeting()); AddMenu(context, "删除会议（可恢复）", DeleteCurrent);
        History.ContextMenu = context;
        History.PreviewMouseRightButtonDown += (_, e) => { if (ItemsControl.ContainerFromElement(History, e.OriginalSource as DependencyObject) is ListBoxItem item) item.IsSelected = true; };
        refresh.Tick += (_, _) => RefreshStatus(); refresh.Start();
        save.Tick += (_, _) => { save.Stop(); FlushEdits(); };
        settings.Changed += () => Notice("配置已保存。正在录音时，新配置会立即用于后续转写。");
        Closing += OnClosing;
        if (!smoke) Microsoft.Win32.SystemEvents.PowerModeChanged += PowerChanged;
        StateChanged += (_, _) => { if (WindowState == WindowState.Minimized && engine is not null && tray is not null) Notice("录音仍在继续；可通过系统托盘暂停或结束。"); };
        if (!smoke)
        {
            tray = new System.Windows.Forms.NotifyIcon { Icon = new System.Drawing.Icon(Path.Combine(AppContext.BaseDirectory, "assets", "MinuteFlow.ico")), Visible = true, Text = "MinuteFlow" };
            var menu = new System.Windows.Forms.ContextMenuStrip();
            menu.Items.Add("显示 MinuteFlow", null, (_, _) => Dispatcher.Invoke(BringToFront));
            menu.Items.Add("暂停 / 恢复录音", null, (_, _) => Dispatcher.Invoke(() => PauseRecording(this, new RoutedEventArgs())));
            menu.Items.Add("结束录音", null, async (_, _) => await Dispatcher.InvokeAsync(async () => await StopRecordingAsync()));
            tray.ContextMenuStrip = menu; tray.DoubleClick += (_, _) => Dispatcher.Invoke(BringToFront);
        }
        RecoverInterruptedSessions(); ReloadHistory();
        Notice(string.IsNullOrEmpty(settings.CredentialError) ? settings.Configuration.IsConfigured ? "AI 配置已加载，录音时会实时识别。" : "请在设置中保存 AI 配置；未配置时仍可录音并在事后补全。" : settings.CredentialError);
    }
    private static void AddMenu(ContextMenu menu, string title, Action action) { var item = new MenuItem { Header = title }; item.Click += (_, _) => action(); menu.Items.Add(item); }
    private void BringToFront() { Show(); WindowState = WindowState.Normal; Activate(); }
    private void PowerChanged(object sender, Microsoft.Win32.PowerModeChangedEventArgs e)
    {
        if (e.Mode != Microsoft.Win32.PowerModes.Suspend) return;
        Dispatcher.Invoke(() => { if (engine is not null && !engine.IsPaused) { engine.Pause(); Notice("电脑进入睡眠，录音已暂停。唤醒后请主动恢复或结束录音。"); } });
    }
    private void RecoverInterruptedSessions()
    {
        foreach (var session in repository.List().Where(s => s.RecordingStatus is "recording" or "paused" or "preparing" or "saving"))
        {
            session.RecordingStatus = "interrupted"; session.EndTime ??= session.UpdatedAt;
            foreach (var reference in new[] { session.MicrophoneAudioURL, session.SystemAudioURL }.Where(r => r is not null))
            {
                try { var path = repository.ResolvePath(session.Id, reference); using var reader = new AudioFileReader(path); session.Duration = Math.Max(session.Duration, reader.TotalTime.TotalSeconds); var written = new DateTimeOffset(File.GetLastWriteTimeUtc(path)); if (written > session.EndTime) session.EndTime = written; } catch { }
            }
            session.UpdatedAt = DateTimeOffset.Now; repository.Save(session);
        }
    }
    private void ReloadHistory()
    {
        loading = true; var selected = current?.Id;
        var sessions = repository.List(); History.ItemsSource = sessions;
        if (selected is not null) History.SelectedItem = sessions.FirstOrDefault(s => s.Id == selected);
        loading = false;
    }
    private void HistorySelected(object sender, SelectionChangedEventArgs e)
    {
        if (loading || engine is not null || operation is not null) return;
        if (History.SelectedItem is MeetingSession session) SelectMeeting(session);
    }
    private void SelectMeeting(MeetingSession session)
    {
        var selectedId = session.Id;
        FlushEdits(); CommitTitle(); StopPlaying(); session = repository.List().FirstOrDefault(s => s.Id == selectedId) ?? session; current = session; loading = true;
        if (History.ItemsSource is List<MeetingSession> meetings) History.SelectedItem = meetings.FirstOrDefault(s => s.Id == selectedId);
        transcript.Clear(); transcriptRows.Clear(); transcript.AddRange(repository.LoadTranscript(session.Id));
        SummaryEditor.Text = repository.LoadDocument(session.Id, "会议纪要.md") ?? "";
        DocumentEditor.Text = repository.LoadDocument(session.Id, "AI排版文稿.md") ?? "";
        TitleDisplay.Text = session.Title; TitleEditor.Visibility = Visibility.Collapsed; TitleDisplay.Visibility = Visibility.Visible;
        foreach (ComboBoxItem source in SourcePicker.Items) if (source.Tag as string == session.SourceSelection) SourcePicker.SelectedItem = source;
        dirtyTranscript = dirtySummary = dirtyDocument = false; preview = ""; lastFinalTime = transcript.Select(s => s.EndTime).DefaultIfEmpty().Max(); loading = false;
        RenderTranscript(); RefreshStatus();
    }
    private void NewRecording(object sender, RoutedEventArgs e)
    {
        if (engine is not null || operation is not null) return;
        FlushEdits(); CommitTitle(); StopPlaying(); current = null; transcript.Clear(); transcriptRows.Clear(); preview = ""; lastFinalTime = 0;
        loading = true; History.SelectedItem = null; SummaryEditor.Text = ""; DocumentEditor.Text = ""; loading = false;
        TitleDisplay.Text = "新录音"; TitleDisplay.Visibility = Visibility.Visible; TitleEditor.Visibility = Visibility.Collapsed;
        RenderTranscript(); RefreshStatus();
    }
    private async void StartRecording(object sender, RoutedEventArgs e)
    {
        if (engine is not null || operation is not null) return;
        NewRecording(sender, e);
        var sources = ((ComboBoxItem)SourcePicker.SelectedItem).Tag.ToString() ?? "both";
        current = repository.Create($"未命名会议 {DateTime.Now:yyyy-MM-dd HH-mm}", sources); TitleDisplay.Text = current.Title;
        engine = new RecordingEngine(current, repository, settings, client);
        var startedEngine = engine;
        engine.Recognized += segment => Dispatcher.BeginInvoke(() =>
        {
            if (current?.Id != startedEngine.Session.Id) return;
            if (!segment.IsFinal) { if (segment.EndTime > lastFinalTime) { preview = segment.Text; PreviewLabel.Text = "识别中：" + preview; } return; }
            // Preserve user edits, never merge a new ASR response into edited text.
            TranscriptEditing.AppendOrMerge(transcript, segment);
            lastFinalTime = Math.Max(lastFinalTime, segment.EndTime); preview = ""; PreviewLabel.Text = "";
            dirtyTranscript = true; ScheduleSave(); RenderTranscript();
        });
        engine.Notice += message => Dispatcher.BeginInvoke(() => Notice(message, true));
        try { engine.Start(); MicLabel.Text = current.MicrophoneAudioURL is null ? "麦克风 · 未启用" : "麦克风 · " + engine.Recorder.MicrophoneName; foreach (ComboBoxItem source in SourcePicker.Items) if (source.Tag as string == current.SourceSelection) SourcePicker.SelectedItem = source; ReloadHistory(); Notice("录音已开始。原始音轨持续保存，AI 失败也不会中断录音。"); }
        catch (Exception error) { await engine.DisposeAsync(); engine = null; current.RecordingStatus = "failed"; current.UpdatedAt = DateTimeOffset.Now; repository.Save(current); ReloadHistory(); Notice("无法开始录音：" + error.Message + "。请在设置检测音频设备及麦克风权限。"); }
        RefreshStatus();
    }
    private void PauseRecording(object sender, RoutedEventArgs e)
    {
        if (engine is null) return;
        try { if (engine.IsPaused) engine.Resume(); else engine.Pause(); RefreshStatus(); RenderTranscript(); } catch (Exception error) { Notice(error.Message); }
    }
    private async void StopRecording(object sender, RoutedEventArgs e) => await StopRecordingAsync();
    private async Task StopRecordingAsync()
    {
        if (engine is null || operation is not null) return;
        var ended = engine; operation = new CancellationTokenSource(); RefreshStatus(); StatusLabel.Text = "正在保存";
        try
        {
            operationTask = ended.StopAsync(); await operationTask; FlushEdits();
            if (current is not null && (ended.SystemPeak < 0.006 && current.SourceSelection is "both" or "system")) Notice("录音已保存，系统声音没有检测到有效声音；完整回放仍包含麦克风声音。");
            else Notice("录音已保存，完整回放已生成。");
        }
        catch (Exception error)
        {
            ended.Session.RecordingStatus = "completed"; ended.Session.MixState = "failed"; ended.Session.MixMessage = error.Message; repository.Save(ended.Session);
            Notice("原始录音已保存，但完整回放生成失败：" + error.Message + "。可点击重新生成完整回放。");
        }
        finally { await ended.DisposeAsync(); engine = null; operation.Dispose(); operation = null; operationTask = null; FlushEdits(); ReloadHistory(); RefreshStatus(); }
        if (current is not null && transcript.Count > 0 && !closing)
        {
            await RunOperation(async token => { if (settings.Configuration.AutomaticTitle) await GenerateTitleAsync(current, transcript, token); if (settings.Configuration.AutomaticSummary) await GenerateDocumentAsync(false, token); });
        }
    }
    private void RefreshStatus()
    {
        if (!IsInitialized) return;
        var active = engine is not null; var busy = operation is not null;
        var duration = active ? engine!.Recorder.Elapsed : current?.Duration ?? 0;
        TimerLabel.Text = MeetingTime.Format(duration);
        StatusLabel.Text = active ? engine!.IsPaused ? "已暂停" : "正在录音" : current is null ? "准备就绪" : current.RecordingStatus == "interrupted" ? "已恢复录音" : "已完成";
        StartButton.IsEnabled = !active && !busy; SourcePicker.IsEnabled = !active && !busy; History.IsEnabled = !active && !busy; NewButton.IsEnabled = !active && !busy;
        PauseButton.IsEnabled = active && !busy; StopButton.IsEnabled = active && !busy; PauseButton.Content = engine?.IsPaused == true ? "恢复" : "暂停";
        BackfillButton.IsEnabled = current is not null && !active && !busy; AnalyzeSpeakersButton.IsEnabled = current is not null && !active && !busy;
        RebuildMixButton.IsEnabled = current is not null && !active && !busy;
        SummaryButton.IsEnabled = FormatButton.IsEnabled = TitleButton.IsEnabled = current is not null && transcript.Count > 0 && !active && !busy;
        BatchTitleButton.IsEnabled = !active && !busy; CancelButton.IsEnabled = busy && !active;
        WorkProgress.Visibility = busy ? Visibility.Visible : Visibility.Collapsed;
        SystemMeter.Value = active && !engine!.IsPaused && duration - engine.LastSystemSample < 0.5 ? Math.Min(1, engine.SystemLevel * 5) : 0; MicMeter.Value = active && !engine!.IsPaused && duration - engine.LastMicrophoneSample < 0.5 ? Math.Min(1, engine.MicrophoneLevel * 5) : 0;
        SystemMeter.IsEnabled = current?.SystemAudioURL is not null; MicMeter.IsEnabled = current?.MicrophoneAudioURL is not null;
        if (playbackFile is not null) { PlaybackLabel.Text = $"{playbackFile.CurrentTime:hh\\:mm\\:ss} / {playbackFile.TotalTime:hh\\:mm\\:ss}"; PlaybackSlider.Value = playbackFile.TotalTime.TotalSeconds <= 0 ? 0 : playbackFile.CurrentTime.TotalSeconds / playbackFile.TotalTime.TotalSeconds; }
        if (active && !busy && engine!.ShouldAutoPause)
        {
            engine.Pause(); BringToFront();
            var result = MessageBox.Show(this, $"连续 {settings.Configuration.SilenceMinutes} 分钟未检测到有效声音，录音已暂停。\n点击“是”继续录音；点击“否”结束并保存；点击“取消”保持暂停。", "防止忘关录音", MessageBoxButton.YesNoCancel, MessageBoxImage.Information);
            if (result == MessageBoxResult.Yes) { try { engine.Resume(); } catch (Exception error) { Notice(error.Message); } } else if (result == MessageBoxResult.No) _ = StopRecordingAsync();
        }
        if (active && !busy && !engine!.IsPaused && duration >= TimeSpan.FromHours(10).TotalSeconds)
        {
            engine.Pause(); BringToFront(); MessageBox.Show(this, "本次录音达到 10 小时，已触发 WAV 容量保护并暂停。请结束保存，再新建录音。", "长录音保护", MessageBoxButton.OK, MessageBoxImage.Information);
        }
        if (tray is not null) tray.Text = active ? $"MinuteFlow · {(engine!.IsPaused ? "已暂停" : "正在录音")} {MeetingTime.Format(duration)}" : "MinuteFlow";
    }
    private void Notice(string message, bool throttle = false)
    {
        if (throttle && DateTimeOffset.Now - lastNotice < TimeSpan.FromSeconds(3)) return;
        lastNotice = DateTimeOffset.Now; NoticeLabel.Text = message;
    }
    private void RenderTranscript()
    {
        EmptyTranscriptLabel.Visibility = transcript.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
        var mode = TranscriptMode.SelectedIndex;
        var readOnly = mode != 1 || operation is not null || engine is not null && !engine.IsPaused;
        for (var index = 0; index < transcript.Count; index++)
        {
            var segment = transcript[index];
            var speaker = segment.SpeakerID is not null && current?.SpeakerNames?.TryGetValue(segment.SpeakerID, out var renamed) == true ? renamed : segment.SpeakerID;
            speaker = speaker?.Replace("system-speaker-", "电脑 · 说话人 ").Replace("speaker-", "说话人 ");
            var label = segment.Label.Replace(segment.SpeakerID ?? "\0", speaker ?? "\0");
            TranscriptRow row;
            if (index < transcriptRows.Count && transcriptRows[index].Segment.Id == segment.Id) row = transcriptRows[index];
            else
            {
                row = new TranscriptRow(segment, edited => { if (loading || current is null) return; edited.UserEdited = true; edited.NormalizedText = null; dirtyTranscript = true; ScheduleSave(); });
                transcriptRows.Insert(index, row);
            }
            row.Update(segment, label, mode == 0 ? segment.OriginalText ?? segment.Text : mode == 2 ? segment.NormalizedText ?? segment.Text : segment.Text, readOnly);
        }
        while (transcriptRows.Count > transcript.Count) transcriptRows.RemoveAt(transcriptRows.Count - 1);
    }
    private void TranscriptLabelClicked(object sender, MouseButtonEventArgs e)
    {
        if ((sender as FrameworkElement)?.DataContext is not TranscriptRow row) return;
        if (e.ClickCount == 2 && engine is null && operation is null) RenameSpeaker(row.Segment);
        else if (e.ClickCount == 1) PlayAt(row.Segment.StartTime);
    }
    private void TranscriptModeChanged(object sender, SelectionChangedEventArgs e) { if (IsInitialized) { FlushEdits(); RenderTranscript(); } }
    private void ScheduleSave() { save.Stop(); save.Start(); }
    private void FlushEdits()
    {
        save.Stop(); if (current is null || loading) return;
        var changed = dirtyTranscript || dirtySummary || dirtyDocument;
        if (dirtyTranscript) { repository.SaveTranscript(current.Id, transcript); current.TranscriptFileURL = "逐字稿.json"; dirtyTranscript = false; }
        if (dirtySummary) { repository.SaveDocument(current.Id, "会议纪要.md", SummaryEditor.Text); current.SummaryFileURL = "会议纪要.md"; dirtySummary = false; }
        if (dirtyDocument) { repository.SaveDocument(current.Id, "AI排版文稿.md", DocumentEditor.Text); current.FormattedDocumentFileURL = "AI排版文稿.md"; dirtyDocument = false; }
        if (changed) { current.UpdatedAt = DateTimeOffset.Now; repository.Save(current); }
    }
    private void SummaryTextChanged(object sender, TextChangedEventArgs e) { if (!loading && current is not null) { dirtySummary = true; ScheduleSave(); } }
    private void DocumentTextChanged(object sender, TextChangedEventArgs e) { if (!loading && current is not null) { dirtyDocument = true; ScheduleSave(); } }
    private void NormalizeTranscript(object sender, RoutedEventArgs e) { if (current is null || operation is not null) return; foreach (var segment in transcript) segment.NormalizedText = TranscriptEditing.Normalize(segment.Text); dirtyTranscript = true; FlushEdits(); TranscriptMode.SelectedIndex = 2; RenderTranscript(); }
    private void TitleDoubleClick(object sender, MouseButtonEventArgs e) { if (e.ClickCount == 2) BeginTitleEdit(); }
    private void BeginTitleEdit()
    {
        if (current is null || engine is not null || operation is not null) return;
        originalTitle = current.Title; TitleEditor.Text = current.Title; TitleDisplay.Visibility = Visibility.Collapsed; TitleEditor.Visibility = Visibility.Visible; TitleEditor.Focus(); TitleEditor.SelectAll();
    }
    private void TitleKeyDown(object sender, KeyEventArgs e)
    {
        if (e.Key == Key.Enter) { CommitTitle(); e.Handled = true; }
        if (e.Key == Key.Escape) { TitleEditor.Text = originalTitle; TitleEditor.Visibility = Visibility.Collapsed; TitleDisplay.Visibility = Visibility.Visible; e.Handled = true; }
    }
    private void TitleLostFocus(object sender, KeyboardFocusChangedEventArgs e) => CommitTitle();
    private void CommitTitle()
    {
        if (titleCommitting || TitleEditor.Visibility != Visibility.Visible || current is null || engine is not null || operation is not null) return;
        if (TitleEditor.Text.Trim() == current.Title) { TitleEditor.Visibility = Visibility.Collapsed; TitleDisplay.Visibility = Visibility.Visible; return; }
        titleCommitting = true;
        try { FlushEdits(); current = repository.Rename(current, TitleEditor.Text); current.TitleWasAutomaticallyGenerated = false; repository.Save(current); TitleDisplay.Text = current.Title; ReloadHistory(); }
        catch (Exception error) { Notice("改名未完成：" + error.Message); }
        finally { TitleEditor.Visibility = Visibility.Collapsed; TitleDisplay.Visibility = Visibility.Visible; titleCommitting = false; }
    }
    private void RenameSpeaker(TranscriptSegment segment)
    {
        if (current is null || segment.SpeakerID is null) return;
        var name = InputDialog.Ask(this, "修改说话人名称", current.SpeakerNames?.GetValueOrDefault(segment.SpeakerID) ?? segment.SpeakerID);
        if (string.IsNullOrWhiteSpace(name)) return;
        current.SpeakerNames ??= []; current.SpeakerNames[segment.SpeakerID] = name.Trim(); current.UpdatedAt = DateTimeOffset.Now; repository.Save(current); RenderTranscript();
    }
    private void DeleteCurrent()
    {
        if (current is null || engine is not null || operation is not null) return;
        if (MessageBox.Show(this, $"将“{current.Title}”移动到 MinuteFlow 的 Trash 目录？\n录音和文档可从该目录恢复。", "删除会议", MessageBoxButton.YesNo) != MessageBoxResult.Yes) return;
        FlushEdits(); CommitTitle(); var trash = repository.MoveToTrash(current.Id); current = null; dirtyTranscript = dirtySummary = dirtyDocument = false; NewRecording(this, new RoutedEventArgs()); ReloadHistory(); Notice("会议已移到可恢复目录：" + trash);
    }
    private void OpenSettings(object sender, RoutedEventArgs e) { var dialog = new SettingsWindow(settings, client) { Owner = this }; dialog.ShowDialog(); }
    private static void Reveal(string path) { if (File.Exists(path)) Process.Start(new ProcessStartInfo("explorer.exe", "/select,\"" + path + "\"") { UseShellExecute = true }); else Process.Start(new ProcessStartInfo("explorer.exe", "\"" + path + "\"") { UseShellExecute = true }); }
    private void RevealMeeting() { if (current is not null) Reveal(repository.DirectoryFor(current.Id)); }
    private void OpenMeeting(object sender, RoutedEventArgs e) => RevealMeeting();
    private void OpenRoot(object sender, RoutedEventArgs e) => Reveal(repository.Root);
    private void OpenTranscript(object sender, RoutedEventArgs e) { if (current is null) return; var file = Path.Combine(repository.DirectoryFor(current.Id), "逐字稿.md"); Reveal(File.Exists(file) ? file : repository.DirectoryFor(current.Id)); }
    private void PlayMixed(object sender, RoutedEventArgs e) => Play(current?.MixedAudioURL ?? current?.MicrophoneAudioURL ?? current?.SystemAudioURL);
    private void PlayMicrophone(object sender, RoutedEventArgs e) => Play(current?.MicrophoneAudioURL);
    private void PlaySystem(object sender, RoutedEventArgs e) => Play(current?.SystemAudioURL);
    private void StopPlayback(object sender, RoutedEventArgs e) => StopPlaying();
    private void StopPlaying() { playback?.Stop(); playback?.Dispose(); playback = null; playbackFile?.Dispose(); playbackFile = null; PlaybackLabel.Text = ""; PlaybackSlider.Value = 0; }
    private void Play(string? reference, double start = 0)
    {
        if (current is null || reference is null || engine is not null) { Notice("录音尚未保存，或该音轨未启用。"); return; }
        try { StopPlaying(); playbackFile = new AudioFileReader(repository.ResolvePath(current.Id, reference)); playbackFile.CurrentTime = TimeSpan.FromSeconds(Math.Clamp(start, 0, playbackFile.TotalTime.TotalSeconds)); playback = new WaveOutEvent(); playback.Init(playbackFile); playback.Play(); }
        catch (Exception error) { StopPlaying(); Notice("无法回放：" + error.Message); }
    }
    private void PlayAt(double seconds) => Play(current?.MixedAudioURL ?? current?.MicrophoneAudioURL ?? current?.SystemAudioURL, seconds);
    private void PlaybackSeek(object sender, MouseButtonEventArgs e) { if (playbackFile is not null) playbackFile.CurrentTime = TimeSpan.FromSeconds(playbackFile.TotalTime.TotalSeconds * PlaybackSlider.Value); }
    private void CancelOperation(object sender, RoutedEventArgs e) => operation?.Cancel();
    private async Task RunOperation(Func<CancellationToken, Task> action)
    {
        if (operation is not null || engine is not null) return;
        CommitTitle(); FlushEdits(); StopPlaying(); operation = new CancellationTokenSource(); RefreshStatus(); RenderTranscript();
        try { operationTask = action(operation.Token); await operationTask; }
        catch (OperationCanceledException) { Notice("处理已取消，已经保存的内容保留，之后可继续补全。"); }
        catch (Exception error) { Notice("处理未完成：" + RecordingEngine.SafeError(error, settings.Configuration.Token)); }
        finally { operation.Dispose(); operation = null; operationTask = null; ReloadHistory(); RefreshStatus(); RenderTranscript(); }
    }
    private async void Backfill(object sender, RoutedEventArgs e)
    {
        if (current is null) return; var meeting = current;
        await RunOperation(async token =>
        {
            await PostTranscriber.RunAsync(meeting, repository, settings, client, transcript, (value, text) => { WorkProgress.Value = value; Notice(text); }, RenderTranscript, token);
            if (settings.Configuration.AutomaticTitle) await GenerateTitleAsync(meeting, transcript, token);
            if (settings.Configuration.AutomaticSummary) await GenerateDocumentAsync(false, token);
        });
    }
    private async void GenerateSummary(object sender, RoutedEventArgs e) => await RunOperation(token => GenerateDocumentAsync(false, token));
    private async void GenerateDocument(object sender, RoutedEventArgs e) => await RunOperation(token => GenerateDocumentAsync(true, token));
    private async Task GenerateDocumentAsync(bool formatted, CancellationToken token)
    {
        if (current is null) return;
        Notice(formatted ? "正在生成 AI 文稿…" : "正在生成会议纪要…");
        var text = await client.SummarizeLongAsync(TranscriptText(transcript), settings.Configuration, formatted, token); token.ThrowIfCancellationRequested();
        loading = true;
        if (formatted) { DocumentEditor.Text = text; current.FormattedDocumentFileURL = "AI排版文稿.md"; repository.SaveDocument(current.Id, "AI排版文稿.md", text); }
        else { SummaryEditor.Text = text; current.SummaryFileURL = "会议纪要.md"; repository.SaveDocument(current.Id, "会议纪要.md", text); }
        loading = false; current.UpdatedAt = DateTimeOffset.Now; repository.Save(current); Notice("AI 文档已保存，可直接在会议目录查看。");
    }
    private static string TranscriptText(IEnumerable<TranscriptSegment> segments) => string.Join("\n\n", segments.Select(s => $"{s.Label}\n{s.NormalizedText ?? s.Text}"));
    private async void GenerateTitle(object sender, RoutedEventArgs e) { if (current is not null) await RunOperation(token => GenerateTitleAsync(current, transcript, token, true)); }
    private async Task GenerateTitleAsync(MeetingSession session, IReadOnlyList<TranscriptSegment> segments, CancellationToken token, bool force = false)
    {
        if (!force && session.TitleWasAutomaticallyGenerated == false) return;
        if (segments.Count == 0 || !settings.Configuration.IsConfigured || string.IsNullOrWhiteSpace(settings.Configuration.TextModel)) return;
        var evidence = TranscriptText(segments);
        if (evidence.Length > 12000)
        {
            var samples = new List<string>(); for (var i = 0; i < evidence.Length; i += Math.Max(1, evidence.Length / 8)) samples.Add(evidence.Substring(i, Math.Min(1300, evidence.Length - i))); evidence = string.Join("\n…\n", samples);
        }
        var result = await client.CompleteAsync("根据会议内容生成一个具体简洁的中文会议主题（8–30字），只返回主题文字，不加日期、引号或说明。不要使用未命名会议、会议纪要等泛化标题。", evidence, settings.Configuration, token);
        token.ThrowIfCancellationRequested(); result = result.Split('\n')[0].Trim(' ', '"', '“', '”', '#', '*');
        if (result.Length < 2) throw new InvalidDataException("模型未返回有效会议主题。");
        session = repository.Rename(session, result); session.TitleWasAutomaticallyGenerated = true; repository.Save(session);
        if (current?.Id == session.Id) { current = session; TitleDisplay.Text = session.Title; }
        Notice("主题和会议文件夹已同步更新。");
    }
    private async void GenerateHistoricalTitles(object sender, RoutedEventArgs e) => await RunOperation(async token =>
    {
        foreach (var meeting in repository.List())
        {
            token.ThrowIfCancellationRequested();
            if (meeting.TitleWasAutomaticallyGenerated == false || !meeting.Title.StartsWith("未命名", StringComparison.Ordinal)) continue;
            var segments = repository.LoadTranscript(meeting.Id); if (segments.Count == 0) continue;
            await GenerateTitleAsync(meeting, segments, token);
        }
        Notice("可识别主题的历史会议已整理；手动名称和无逐字稿会议保留。");
    });
    private async void RebuildMix(object sender, RoutedEventArgs e)
    {
        if (current is null) return; var meeting = current;
        await RunOperation(async token => { var path = Path.Combine(repository.DirectoryFor(meeting.Id), "完整回放.wav"); await Task.Run(() => AudioFiles.Mix(meeting.SystemAudioURL is null ? null : repository.ResolvePath(meeting.Id, meeting.SystemAudioURL), meeting.MicrophoneAudioURL is null ? null : repository.ResolvePath(meeting.Id, meeting.MicrophoneAudioURL), path, meeting.Duration, token), token); meeting.MixedAudioURL = "完整回放.wav"; meeting.MixState = "ready"; meeting.UpdatedAt = DateTimeOffset.Now; repository.Save(meeting); Notice("完整回放已生成。"); });
    }
    private async void AnalyzeSpeakers(object sender, RoutedEventArgs e)
    {
        if (current is null || transcript.Count == 0) return; var meeting = current;
        await RunOperation(async token =>
        {
            var turns = await Task.Run(() =>
            {
                var result = new List<SpeakerTurn>(); var clusters = new Dictionary<string, SpeakerClusterer>();
                foreach (var segment in transcript)
                {
                    token.ThrowIfCancellationRequested(); var source = segment.Source; var reference = source == "system" ? meeting.SystemAudioURL : source == "microphone" ? meeting.MicrophoneAudioURL : meeting.MixedAudioURL;
                    reference ??= meeting.MixedAudioURL ?? meeting.MicrophoneAudioURL ?? meeting.SystemAudioURL;
                    using var reader = new AudioFileReader(repository.ResolvePath(meeting.Id, reference)); reader.CurrentTime = TimeSpan.FromSeconds(segment.StartTime);
                    var provider = AudioFiles.Mono48(reader); var length = (int)(Math.Min(4, Math.Max(0.5, segment.EndTime - segment.StartTime)) * AudioRecorder.SampleRate); var samples = new float[length]; var read = provider.Read(samples, 0, length);
                    if (!clusters.TryGetValue(source, out var cluster)) clusters[source] = cluster = new SpeakerClusterer();
                    var id = cluster.Analyze(samples.AsSpan(0, read), AudioRecorder.SampleRate); if (source == "system") id = "system-" + id;
                    result.Add(new SpeakerTurn(segment.StartTime, segment.EndTime, id, source));
                }
                return result;
            }, token);
            for (var i = 0; i < transcript.Count; i++) transcript[i].SpeakerID = turns[i].SpeakerID;
            repository.SaveTranscript(meeting.Id, transcript); SaveSpeakerTimeline(meeting, turns); Notice("本地声学聚类已完成；说话人标签可手动调整。");
        });
    }
    private void SaveSpeakerTimeline(MeetingSession meeting, IReadOnlyList<SpeakerTurn> turns)
    {
        repository.SaveDocument(meeting.Id, "说话人时间轴.json", System.Text.Json.JsonSerializer.Serialize(new { version = 1, generatedAt = DateTimeOffset.UtcNow, sourceFileName = meeting.MixedAudioURL ?? meeting.MicrophoneAudioURL ?? meeting.SystemAudioURL ?? "", speakerCount = turns.Select(t => t.SpeakerID).Distinct().Count(), turns, method = "localAcousticClustering", note = "本地近似聚类，并非可靠身份识别" }, MeetingRepository.Json));
        meeting.DiarizationFileURL = "说话人时间轴.json"; meeting.UpdatedAt = DateTimeOffset.Now; repository.Save(meeting);
    }
    private async void ImportAudio(object sender, RoutedEventArgs e)
    {
        if (engine is not null || operation is not null) return;
        var picker = new Microsoft.Win32.OpenFileDialog { Filter = "音频文件|*.wav;*.m4a;*.mp3;*.aac;*.wma|全部文件|*.*" };
        if (picker.ShowDialog(this) == true) await ImportAudioAsync(picker.FileName);
    }
    public async Task ImportAudioAsync(string path)
    {
        await RunOperation(async token =>
        {
            if (!File.Exists(path)) throw new FileNotFoundException("导入文件不存在。", path);
            using var reader = new AudioFileReader(path); var meeting = repository.Create(Path.GetFileNameWithoutExtension(path), "microphone");
            meeting.MicrophoneAudioURL = "原始录音" + Path.GetExtension(path).ToLowerInvariant(); var copied = repository.ResolvePath(meeting.Id, meeting.MicrophoneAudioURL); await Task.Run(() => File.Copy(path, copied, false));
            meeting.Duration = reader.TotalTime.TotalSeconds; meeting.RecordingStatus = "completed"; meeting.EndTime = meeting.StartTime.AddSeconds(meeting.Duration);
            // Register the copied original before any optional conversion. A
            // failure or cancellation must still leave a playable history entry.
            meeting.MixState = "queued"; meeting.UpdatedAt = DateTimeOffset.Now; repository.Save(meeting); SelectMeeting(meeting); ReloadHistory();
            try
            {
                var mixed = Path.Combine(repository.DirectoryFor(meeting.Id), "完整回放.wav"); await Task.Run(() => AudioFiles.Mix(null, copied, mixed, meeting.Duration, token), token);
                meeting.MixedAudioURL = "完整回放.wav"; meeting.MixState = "ready"; meeting.UpdatedAt = DateTimeOffset.Now; repository.Save(meeting); current = meeting;
                Notice("录音已复制到新的会议目录，可点击补全整段录音生成逐字稿。");
            }
            catch (Exception error)
            {
                meeting.MixState = "failed"; meeting.MixMessage = error is OperationCanceledException ? "完整回放生成已取消，原始录音已保留。" : error.Message; meeting.UpdatedAt = DateTimeOffset.Now; repository.Save(meeting); current = meeting;
                Notice("原始录音已导入，可从历史会议播放或转写；完整回放未生成：" + meeting.MixMessage);
            }
        });
    }
    private async void OnClosing(object? sender, CancelEventArgs e)
    {
        if (closing || smoke) { FlushEdits(); CommitTitle(); return; }
        if (engine is not null)
        {
            e.Cancel = true;
            if (operation is not null)
            {
                closing = true;
                if (operationTask is not null) { try { await operationTask; } catch (Exception error) { Notice(error.Message); } }
                Close(); return;
            }
            if (MessageBox.Show(this, "正在录音。结束并保存后退出？", "MinuteFlow", MessageBoxButton.YesNo) != MessageBoxResult.Yes) return;
            closing = true; await StopRecordingAsync(); Close(); return;
        }
        if (operation is not null)
        {
            e.Cancel = true; operation.Cancel(); closing = true; if (operationTask is not null) { try { await operationTask; } catch (OperationCanceledException) { } catch (Exception error) { Notice(error.Message); } } Close(); return;
        }
        FlushEdits(); CommitTitle(); refresh.Stop(); tray?.Dispose(); StopPlaying(); Microsoft.Win32.SystemEvents.PowerModeChanged -= PowerChanged; http.Dispose();
    }
    public void PerformSmokeTest()
    {
        var meeting = repository.Create("测试会议", "both"); SelectMeeting(meeting);
        if (TitleEditor.Visibility != Visibility.Collapsed) throw new Exception("Title must start read-only.");
        BeginTitleEdit(); if (TitleEditor.Visibility != Visibility.Visible) throw new Exception("Double-click edit unavailable."); TitleEditor.Text = "测试会议更名"; CommitTitle();
        if (current?.Title != "测试会议更名" || Path.GetFileName(repository.DirectoryFor(meeting.Id)) != current.Title) throw new Exception("Rename did not synchronize.");
        var before = File.GetLastWriteTimeUtc(Path.Combine(repository.DirectoryFor(meeting.Id), MeetingRepository.MetadataName)); SelectMeeting(current); FlushEdits(); if (File.GetLastWriteTimeUtc(Path.Combine(repository.DirectoryFor(meeting.Id), MeetingRepository.MetadataName)) != before) throw new Exception("Browsing changed mtime.");
        for (var index = 0; index < 1000; index++) transcript.Add(new TranscriptSegment { StartTime = index, EndTime = index + 1, Text = "用于验证长逐字稿的可见行复用。", OriginalText = "用于验证长逐字稿的可见行复用。", Source = "microphone" });
        RenderTranscript(); TranscriptRows.BringIntoView(); TranscriptRows.ScrollIntoView(transcriptRows[0]); UpdateLayout(); Dispatcher.Invoke(() => { }, DispatcherPriority.ContextIdle);
        var realized = Enumerable.Range(0, transcriptRows.Count).Count(i => TranscriptRows.ItemContainerGenerator.ContainerFromIndex(i) is not null);
        if (realized is < 1 or > 100 || TranscriptRows.ItemContainerGenerator.ContainerFromIndex(0) is null) throw new Exception("Long transcript must render a nonzero bounded visible viewport.");
        TranscriptRows.ScrollIntoView(transcriptRows[^1]); UpdateLayout(); Dispatcher.Invoke(() => { }, DispatcherPriority.ContextIdle);
        realized = Enumerable.Range(0, transcriptRows.Count).Count(i => TranscriptRows.ItemContainerGenerator.ContainerFromIndex(i) is not null);
        if (realized is < 1 or > 100 || TranscriptRows.ItemContainerGenerator.ContainerFromIndex(transcriptRows.Count - 1) is null || TranscriptRows.ItemContainerGenerator.ContainerFromIndex(0) is not null) throw new Exception("Scrolling a long transcript did not recycle offscreen controls.");
        TranscriptRows.ScrollIntoView(transcriptRows[0]); UpdateLayout(); Dispatcher.Invoke(() => { }, DispatcherPriority.ContextIdle);
        transcriptRows[0].DisplayText = "手动修改已保存。"; FlushEdits();
        if (repository.LoadTranscript(meeting.Id)[0].Text != "手动修改已保存。" || transcript[0].OriginalText != "用于验证长逐字稿的可见行复用。") throw new Exception("Virtualized editing lost original text or saved edits.");
        settings.Save(new ModelConfiguration(), "smoke-test-not-a-real-token"); var reloaded = new SettingsStore(settings.Root); if (reloaded.Configuration.Token != "smoke-test-not-a-real-token") throw new Exception("DPAPI reload failed.");
        using (var writer = new WaveFileWriter(repository.ResolvePath(meeting.Id, meeting.MicrophoneAudioURL), new WaveFormat(48000, 16, 1))) { var tone = Enumerable.Range(0, 4800).Select(i => (float)(0.1 * Math.Sin(i * Math.PI * 2 * 440 / 48000))).ToArray(); writer.WriteSamples(tone, 0, tone.Length); }
        var output = Path.Combine(repository.DirectoryFor(meeting.Id), "完整回放.wav"); AudioFiles.Mix(null, repository.ResolvePath(meeting.Id, meeting.MicrophoneAudioURL), output, 0.1); using (var reader = new WaveFileReader(output)) if (Math.Abs(reader.TotalTime.TotalSeconds - 0.1) > 0.005) throw new Exception("Mix duration incorrect.");
        var dialog = new SettingsWindow(settings, client, false); dialog.Show(); dialog.UpdateLayout(); dialog.Close();
    }
}

public sealed class TranscriptRow : INotifyPropertyChanged
{
    private readonly Action<TranscriptSegment> edited;
    private string label = "", displayText = "";
    private bool readOnly;
    public TranscriptSegment Segment { get; private set; }
    public string Label => label;
    public bool IsReadOnly => readOnly;
    public string DisplayText
    {
        get => displayText;
        set { if (readOnly || value == displayText) return; displayText = value; Segment.Text = value; edited(Segment); PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(nameof(DisplayText))); }
    }
    public event PropertyChangedEventHandler? PropertyChanged;
    public TranscriptRow(TranscriptSegment segment, Action<TranscriptSegment> edited) { Segment = segment; this.edited = edited; }
    public void Update(TranscriptSegment segment, string nextLabel, string text, bool isReadOnly)
    {
        Segment = segment;
        if (label != nextLabel) { label = nextLabel; PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(nameof(Label))); }
        if (displayText != text) { displayText = text; PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(nameof(DisplayText))); }
        if (readOnly != isReadOnly) { readOnly = isReadOnly; PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(nameof(IsReadOnly))); }
    }
}

internal static class InputDialog
{
    public static string? Ask(Window owner, string title, string initial)
    {
        var dialog = new Window { Owner = owner, Title = title, Width = 420, Height = 165, ResizeMode = ResizeMode.NoResize, WindowStartupLocation = WindowStartupLocation.CenterOwner };
        var layout = new StackPanel { Margin = new Thickness(18) }; var field = new TextBox { Text = initial, Padding = new Thickness(8) }; var button = new Button { Content = "保存", Margin = new Thickness(0, 12, 0, 0), Padding = new Thickness(10), IsDefault = true };
        button.Click += (_, _) => dialog.DialogResult = true; layout.Children.Add(field); layout.Children.Add(button); dialog.Content = layout; dialog.Loaded += (_, _) => { field.Focus(); field.SelectAll(); };
        return dialog.ShowDialog() == true ? field.Text : null;
    }
}
