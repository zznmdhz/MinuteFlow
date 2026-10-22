using System.Text.Json;
using System.Threading.Channels;
using MinuteFlow.Core;
using NAudio.Wave;

namespace MinuteFlow.Windows;

public sealed class RecordingEngine : IAsyncDisposable
{
    private readonly MeetingRepository repository;
    private readonly SettingsStore settings;
    private readonly ModelClient client;
    private readonly LiveRecognitionQueue queue = new();
    private readonly Dictionary<string, double> latestPartialEnd = new();
    private readonly Dictionary<string, double> finalizedEnd = new();
    private readonly CancellationTokenSource cancellation = new();
    private readonly Dictionary<string, SpeechSegmenter> segmenters = new() { ["system"] = new(), ["microphone"] = new() };
    private readonly Dictionary<string, SpeakerClusterer> speakers = new() { ["system"] = new(), ["microphone"] = new() };
    private readonly object processingGate = new();
    private readonly Task worker;
    private readonly System.Threading.Timer silenceFinalizer;
    private readonly HashSet<string> finalizedSilentSources = [];
    private bool stopping;
    private SilenceGuard silence;
    public AudioRecorder Recorder { get; } = new();
    public MeetingSession Session { get; }
    public double SystemLevel { get; private set; }
    public double MicrophoneLevel { get; private set; }
    public double SystemPeak { get; private set; }
    public double MicrophonePeak { get; private set; }
    public double LastSystemSample { get; private set; }
    public double LastMicrophoneSample { get; private set; }
    public bool IsPaused { get; private set; }
    public bool ShouldAutoPause { get { lock (processingGate) return !IsPaused && silence.ShouldPause(TimeSpan.FromSeconds(Recorder.Elapsed)); } }
    public event Action<TranscriptSegment>? Recognized;
    public event Action<string>? Notice;
    public RecordingEngine(MeetingSession session, MeetingRepository repository, SettingsStore settings, ModelClient client)
    {
        Session = session; this.repository = repository; this.settings = settings; this.client = client;
        silence = new SilenceGuard(TimeSpan.FromMinutes(settings.Configuration.SilenceMinutes));
        Recorder.Samples += OnSamples;
        Recorder.Faulted += message => Notice?.Invoke(message + "。请暂停录音后检查设备；原录音仍保留。");
        Recorder.AllSourcesInterrupted += message => { lock (processingGate) { IsPaused = true; Session.Duration = Recorder.Elapsed; Session.RecordingStatus = "paused"; try { repository.Save(Session); } catch { } } Notice?.Invoke(message); };
        settings.Changed += ConfigurationChanged;
        worker = Task.WhenAll(Enumerable.Range(0, 3).Select(_ => Task.Run(ProcessQueueAsync)));
        silenceFinalizer = new System.Threading.Timer(_ =>
        {
            lock (processingGate)
            {
                if (stopping || IsPaused) return;
                foreach (var source in segmenters.Keys)
                {
                    var last = source == "system" ? LastSystemSample : LastMicrophoneSample;
                    if (last <= 0 || Recorder.Elapsed - last < 0.8 || !finalizedSilentSources.Add(source)) continue;
                    // WASAPI loopback may stop emitting packets during silence.
                    // Finalize pending speech without waiting for a future packet.
                    foreach (var chunk in segmenters[source].Push([], AudioRecorder.SampleRate, last, true)) Enqueue(source, chunk with { BoundaryReason = "naturalPause" });
                    segmenters[source].Reset();
                }
            }
        }, null, TimeSpan.FromMilliseconds(250), TimeSpan.FromMilliseconds(250));
    }
    public void Start() { Recorder.Start(Session, repository, settings.Configuration.MicrophoneDeviceId); Session.RecordingStatus = "recording"; repository.Save(Session); }
    private void ConfigurationChanged() { lock (processingGate) { silence = new SilenceGuard(TimeSpan.FromMinutes(settings.Configuration.SilenceMinutes)); silence.Reset(TimeSpan.FromSeconds(Recorder.Elapsed)); } }
    private void OnSamples(string source, float[] samples, double start)
    {
        lock (processingGate)
        {
            if (stopping || IsPaused) return;
            finalizedSilentSources.Remove(source);
            var energy = WavePcm.Rms(samples);
            if (source == "system") { SystemLevel = energy; SystemPeak = Math.Max(SystemPeak, energy); LastSystemSample = start + (double)samples.Length / AudioRecorder.SampleRate; }
            else { MicrophoneLevel = energy; MicrophonePeak = Math.Max(MicrophonePeak, energy); LastMicrophoneSample = start + (double)samples.Length / AudioRecorder.SampleRate; }
            silence.Observe(energy, TimeSpan.FromSeconds(start + (double)samples.Length / AudioRecorder.SampleRate));
            foreach (var chunk in segmenters[source].Push(samples, AudioRecorder.SampleRate, start)) Enqueue(source, chunk);
        }
    }
    private void Enqueue(string source, SpeechChunk chunk)
    {
        if (!settings.Configuration.AsrEnabled) return;
        if (!queue.Enqueue(new(source, chunk)) && !chunk.IsPreview) Notice?.Invoke("识别服务较慢，完整录音已保留；结束后可补全逐字稿。");
    }
    private async Task ProcessQueueAsync()
    {
        try
        {
            while (await queue.TakeAsync(cancellation.Token) is { } item)
            {
                try {
                var configuration = settings.Configuration;
                if (!configuration.AsrEnabled) continue;
                if (!configuration.IsConfigured) { if (!item.Chunk.IsPreview) Notice?.Invoke("录音正常保存，AI 配置未就绪；保存配置后会自动开始识别，遗漏内容可事后补全。"); continue; }
                try
                {
                    var wav = WavePcm.Encode16Bit(item.Chunk.Samples, item.Chunk.SampleRate);
                    var text = await client.TranscribeLiveAsync(wav, configuration, text =>
                    {
                        lock (processingGate)
                        {
                            if (cancellation.IsCancellationRequested || (stopping && item.Chunk.IsPreview) ||
                                item.Chunk.EndTime <= finalizedEnd.GetValueOrDefault(item.Source) ||
                                item.Chunk.EndTime < latestPartialEnd.GetValueOrDefault(item.Source)) return;
                            latestPartialEnd[item.Source] = item.Chunk.EndTime;
                            Recognized?.Invoke(new TranscriptSegment { StartTime = item.Chunk.StartTime, EndTime = item.Chunk.EndTime,
                                Text = text, OriginalText = text, Source = item.Source, IsFinal = false });
                        }
                    }, cancellation.Token);
                    if (string.IsNullOrWhiteSpace(text)) continue;
                    string? speaker = null;
                    if (!item.Chunk.IsPreview)
                    {
                        lock (processingGate) speaker = speakers[item.Source].Analyze(item.Chunk.Samples, item.Chunk.SampleRate);
                        // Separate source-scoped clusters prevent incidental identical
                        // pitch from collapsing participants from different tracks.
                        if (item.Source == "system") speaker = "system-" + speaker;
                    }
                    var fragment = new TranscriptRecognitionFragment { StartTime = item.Chunk.StartTime, EndTime = item.Chunk.EndTime, OriginalText = text, BoundaryReason = item.Chunk.BoundaryReason, OverlapBefore = item.Chunk.OverlapBefore, SpeakerID = speaker };
                    lock (processingGate)
                    {
                        if (!item.Chunk.IsPreview) finalizedEnd[item.Source] = Math.Max(finalizedEnd.GetValueOrDefault(item.Source), item.Chunk.EndTime);
                        if (!item.Chunk.IsPreview || (!stopping && item.Chunk.EndTime > finalizedEnd.GetValueOrDefault(item.Source) && item.Chunk.EndTime >= latestPartialEnd.GetValueOrDefault(item.Source)))
                            Recognized?.Invoke(new TranscriptSegment { StartTime = item.Chunk.StartTime, EndTime = item.Chunk.EndTime, Text = text, OriginalText = text, Source = item.Source, IsFinal = !item.Chunk.IsPreview, SpeakerID = speaker, BoundaryReason = item.Chunk.BoundaryReason, RecognitionFragments = item.Chunk.IsPreview ? null : [fragment] });
                    }
                }
                catch (OperationCanceledException) when (cancellation.IsCancellationRequested) { break; }
                catch (Exception e) { if (!item.Chunk.IsPreview) Notice?.Invoke("实时转写暂不可用：" + SafeError(e, configuration.Token) + "。录音继续保存，可更正配置或事后补全。"); }
                } finally { queue.Finished(item); }
            }
        }
        catch (OperationCanceledException) { }
    }
    public void Pause()
    {
        IsPaused = true;
        try { Recorder.Pause(); } catch (Exception error) { Notice?.Invoke("暂停时写入失败，请结束并检查磁盘：" + error.Message); }
        lock (processingGate)
        {
            IsPaused = true;
            foreach (var (source, segmenter) in segmenters) foreach (var chunk in segmenter.Push([], AudioRecorder.SampleRate, Recorder.Elapsed, true)) Enqueue(source, chunk);
        }
        Session.Duration = Recorder.Elapsed; Session.RecordingStatus = "paused"; Session.UpdatedAt = DateTimeOffset.Now; try { repository.Save(Session); } catch (Exception error) { Notice?.Invoke("状态保存失败：" + error.Message); }
    }
    public void Resume()
    {
        Recorder.Resume();
        lock (processingGate) { silence.Reset(TimeSpan.FromSeconds(Recorder.Elapsed)); IsPaused = false; foreach (var s in segmenters.Values) s.Reset(); }
        Session.RecordingStatus = "recording"; Session.UpdatedAt = DateTimeOffset.Now; repository.Save(Session);
    }
    public async Task StopAsync()
    {
        silenceFinalizer.Dispose();
        Recorder.Stop();
        lock (processingGate)
        {
            stopping = true;
            foreach (var (source, segmenter) in segmenters) foreach (var chunk in segmenter.Push([], AudioRecorder.SampleRate, Recorder.Elapsed, true)) Enqueue(source, chunk);
        }
        queue.Complete();
        // Complete recent requests, but never make the Stop button wait for a
        // lengthy remote backlog. Durable source audio enables later backfill.
        if (await Task.WhenAny(worker, Task.Delay(TimeSpan.FromSeconds(12))) != worker) cancellation.Cancel();
        await worker;
        Session.Duration = Recorder.Elapsed; Session.EndTime = DateTimeOffset.Now; Session.RecordingStatus = "saving"; Session.UpdatedAt = DateTimeOffset.Now;
        repository.Save(Session);
        var output = Path.Combine(repository.DirectoryFor(Session.Id), "完整回放.wav");
        await Task.Run(() => AudioFiles.Mix(Session.SystemAudioURL is null ? null : repository.ResolvePath(Session.Id, Session.SystemAudioURL), Session.MicrophoneAudioURL is null ? null : repository.ResolvePath(Session.Id, Session.MicrophoneAudioURL), output, Session.Duration));
        Session.MixedAudioURL = Path.GetFileName(output); Session.MixState = "ready"; Session.RecordingStatus = "completed"; Session.UpdatedAt = DateTimeOffset.Now;
        repository.SaveDocument(Session.Id, "混音时间轴.json", JsonSerializer.Serialize(new { version = 1, timelineSampleRate = AudioRecorder.SampleRate, logicalDurationFrames = (long)(Session.Duration * AudioRecorder.SampleRate), tracks = new[] { ("system", Session.SystemAudioURL), ("microphone", Session.MicrophoneAudioURL) }.Where(t => t.Item2 is not null).Select(t => new { source = t.Item1, relativePath = t.Item2, channelCount = 1, epochs = new[] { new { sourceStartFrame = 0L, frameCount = (long)(Session.Duration * AudioRecorder.SampleRate), logicalStartFrame = 0L, timestampQuality = "callbackClock" } } }) }, MeetingRepository.Json));
        repository.Save(Session);
    }
    public async ValueTask DisposeAsync()
    {
        silenceFinalizer.Dispose(); settings.Changed -= ConfigurationChanged; cancellation.Cancel(); queue.Complete(); Recorder.Dispose();
        await worker; cancellation.Dispose();
    }
    public static string SafeError(Exception error, string token) => string.IsNullOrEmpty(token) ? error.Message : error.Message.Replace(token, "[Token]");
}

public static class PostTranscriber
{
    public static async Task RunAsync(MeetingSession session, MeetingRepository repository, SettingsStore settings, ModelClient client, List<TranscriptSegment> transcript, Action<double, string> progress, Action changed, CancellationToken token)
    {
        var reference = session.MixedAudioURL ?? session.MicrophoneAudioURL ?? session.SystemAudioURL;
        using var reader = new AudioFileReader(repository.ResolvePath(session.Id, reference));
        var provider = AudioFiles.Mono48(reader);
        // Mixed audio has safety headroom and may be quieter than either raw
        // track. Use a lower offline floor so backfill does not discard it.
        var segmenter = new SpeechSegmenter(0.0015); var clusterer = new SpeakerClusterer();
        var buffer = new float[AudioRecorder.SampleRate]; long frames = 0; var recognized = 0;
        var total = Math.Max(session.Duration, reader.TotalTime.TotalSeconds);
        async Task HandleChunk(SpeechChunk chunk)
        {
            if (chunk.IsPreview) return;
            token.ThrowIfCancellationRequested();
            // Keep all existing manual edits. Only fill intervals not represented
            // in the existing transcript, rather than replacing the entire file.
            var gaps = new List<(double Start, double End)>(); var cursor = chunk.StartTime;
            foreach (var covered in transcript.Where(s => s.IsFinal && s.StartTime < chunk.EndTime && s.EndTime > chunk.StartTime).OrderBy(s => s.StartTime))
            {
                if (covered.StartTime > cursor) gaps.Add((cursor, Math.Min(covered.StartTime, chunk.EndTime)));
                cursor = Math.Max(cursor, covered.EndTime);
            }
            if (cursor < chunk.EndTime) gaps.Add((cursor, chunk.EndTime));
            foreach (var gap in gaps.Where(g => g.End - g.Start >= 0.1))
            {
                token.ThrowIfCancellationRequested();
                var offset = Math.Clamp((int)((gap.Start - chunk.StartTime) * chunk.SampleRate), 0, chunk.Samples.Length);
                var length = Math.Clamp((int)((gap.End - gap.Start) * chunk.SampleRate), 0, chunk.Samples.Length - offset);
                var audio = chunk.Samples.AsSpan(offset, length).ToArray();
                var text = await client.TranscribeAsync(WavePcm.Encode16Bit(audio, chunk.SampleRate), settings.Configuration, token);
                token.ThrowIfCancellationRequested(); if (string.IsNullOrWhiteSpace(text)) continue;
                var speaker = clusterer.Analyze(audio, chunk.SampleRate);
                var segment = new TranscriptSegment { StartTime = gap.Start, EndTime = gap.End, Text = text, OriginalText = text, Source = reference == session.MixedAudioURL ? "mixed" : reference == session.MicrophoneAudioURL ? "microphone" : "system", SpeakerID = speaker, BoundaryReason = chunk.BoundaryReason, RecognitionFragments = [new TranscriptRecognitionFragment { StartTime = gap.Start, EndTime = gap.End, OriginalText = text, BoundaryReason = chunk.BoundaryReason, OverlapBefore = chunk.OverlapBefore, SpeakerID = speaker }] };
                // Append exact uncovered intervals without merging into existing
                // manually edited entries. Restart will skip only completed gaps.
                transcript.Add(segment); transcript.Sort((a, b) => a.StartTime.CompareTo(b.StartTime)); recognized++;
                repository.SaveTranscript(session.Id, transcript); session.TranscriptFileURL = "逐字稿.json"; session.UpdatedAt = DateTimeOffset.Now; repository.Save(session); changed();
            }
        }
        int read;
        while ((read = provider.Read(buffer, 0, buffer.Length)) > 0)
        {
            token.ThrowIfCancellationRequested();
            foreach (var chunk in segmenter.Push(buffer[..read], AudioRecorder.SampleRate, (double)frames / AudioRecorder.SampleRate)) await HandleChunk(chunk);
            frames += read;
            progress(Math.Min(1, frames / (AudioRecorder.SampleRate * Math.Max(1, total))), $"正在补全 {MeetingTime.Format((double)frames / AudioRecorder.SampleRate)} / {MeetingTime.Format(total)}");
            await Task.Yield();
        }
        foreach (var chunk in segmenter.Push([], AudioRecorder.SampleRate, (double)frames / AudioRecorder.SampleRate, true)) await HandleChunk(chunk);
        if (transcript.Count == 0 && recognized == 0) throw new InvalidDataException("录音中没有识别出有效发言，请先播放检查声音并测试 ASR 配置。");
        session.PostTranscriptionCompletedAt = DateTimeOffset.Now; session.PostTranscriptionCompletedDuration = total; session.UpdatedAt = DateTimeOffset.Now; repository.Save(session);
        var pending = Path.Combine(repository.DirectoryFor(session.Id), ".asr-pending");
        if (Directory.Exists(pending)) Directory.Delete(pending, true);
        progress(1, "整段录音已完成转写。");
    }
}
