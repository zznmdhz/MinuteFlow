using System.Diagnostics;
using MinuteFlow.Core;
using NAudio.CoreAudioApi;
using NAudio.Wave;
using NAudio.Wave.SampleProviders;

namespace MinuteFlow.Windows;

public sealed class AudioRecorder : IDisposable
{
    public const int SampleRate = 48000;
    private readonly object gate = new();
    private readonly Stopwatch clock = new();
    private readonly List<(WasapiCapture Capture, TimelineTrack Track, string Source)> captures = [];
    private bool paused, disposed;
    private bool writeFailed;
    private readonly HashSet<string> activeSources = [];
    private System.Threading.Timer? silencePadding;
    public double Elapsed => clock.Elapsed.TotalSeconds;
    public event Action<string, float[], double>? Samples;
    public event Action<string>? Faulted;
    public event Action<string>? AllSourcesInterrupted;
    public string MicrophoneName { get; private set; } = "默认麦克风";
    public static IReadOnlyList<(string Id, string Name)> Microphones()
    {
        using var enumerator = new MMDeviceEnumerator();
        var devices = enumerator.EnumerateAudioEndPoints(DataFlow.Capture, DeviceState.Active);
        var result = new List<(string Id, string Name)>();
        foreach (var device in devices) { using (device) result.Add((device.ID, device.FriendlyName)); }
        return result;
    }
    public void Start(MeetingSession session, MeetingRepository repository, string? microphoneDeviceId)
    {
        lock (gate)
        {
            if (captures.Count != 0) throw new InvalidOperationException("录音已经开始。");
            try
            {
                using var enumerator = new MMDeviceEnumerator();
                var errors = new List<string>();
                if (session.SourceSelection is "both" or "system")
                {
                    try
                    {
                        var device = enumerator.GetDefaultAudioEndpoint(DataFlow.Render, Role.Multimedia);
                        Add(new WasapiLoopbackCapture(device), repository.ResolvePath(session.Id, session.SystemAudioURL), "system");
                    }
                    catch (Exception error) { session.SystemAudioURL = null; errors.Add("系统声音：" + error.Message); }
                }
                if (session.SourceSelection is "both" or "microphone")
                {
                    try
                    {
                        var device = string.IsNullOrWhiteSpace(microphoneDeviceId) ? enumerator.GetDefaultAudioEndpoint(DataFlow.Capture, Role.Multimedia) : enumerator.GetDevice(microphoneDeviceId);
                        MicrophoneName = device.FriendlyName;
                        Add(new WasapiCapture(device), repository.ResolvePath(session.Id, session.MicrophoneAudioURL), "microphone");
                    }
                    catch (Exception error) { session.MicrophoneAudioURL = null; errors.Add("麦克风：" + error.Message); }
                }
                clock.Restart(); paused = false;
                foreach (var item in captures.ToArray())
                {
                    try { item.Capture.StartRecording(); }
                    catch (Exception error)
                    {
                        activeSources.Remove(item.Source); captures.Remove(item); item.Capture.Dispose(); item.Track.Dispose();
                        if (item.Source == "system") session.SystemAudioURL = null; else session.MicrophoneAudioURL = null;
                        errors.Add((item.Source == "system" ? "系统声音" : "麦克风") + "：" + error.Message);
                    }
                }
                if (captures.Count == 0) throw new InvalidOperationException("没有可用的录音设备。" + string.Join("；", errors));
                session.SourceSelection = captures.Count > 1 ? "both" : captures[0].Source;
                if (errors.Count > 0) Faulted?.Invoke("部分录音设备不可用，已使用可用音轨继续录音。" + string.Join("；", errors));
                silencePadding = new System.Threading.Timer(_ =>
                {
                    try
                    {
                        lock (gate)
                        {
                            if (disposed || paused || !clock.IsRunning) return;
                            foreach (var item in captures) item.Track.PadSilenceIfBehind(clock.Elapsed.TotalSeconds);
                        }
                    }
                    catch (Exception error) { HandleWriteFailure(error); }
                }, null, TimeSpan.FromSeconds(1), TimeSpan.FromSeconds(1));
            }
            catch { Dispose(); throw; }
        }
    }
    private void Add(WasapiCapture capture, string file, string source)
    {
        var track = new TimelineTrack(file);
        capture.DataAvailable += (_, e) =>
        {
            float[] mono; double timestamp;
            try
            {
                lock (gate)
                {
                    if (paused || disposed || !clock.IsRunning) return;
                    if (e.BytesRecorded == 0) return;
                    mono = ConvertToMono(e.Buffer, e.BytesRecorded, capture.WaveFormat);
                    timestamp = Math.Max(0, clock.Elapsed.TotalSeconds - (double)mono.Length / SampleRate);
                    var skipped = track.Write(mono, timestamp);
                    if (skipped == mono.Length) return;
                    if (skipped > 0) { mono = mono[skipped..]; timestamp += (double)skipped / SampleRate; }
                }
            }
            catch (Exception error) { HandleWriteFailure(error); return; }
            Samples?.Invoke(source, mono, timestamp);
        };
        activeSources.Add(source);
        capture.RecordingStopped += (_, e) =>
        {
            if (e.Exception is null || disposed) return;
            bool none;
            lock (gate) { activeSources.Remove(source); none = activeSources.Count == 0; if (none) { clock.Stop(); paused = true; } }
            var message = $"{(source == "system" ? "系统声音" : "麦克风")}中断：{e.Exception.Message}";
            Faulted?.Invoke(message); if (none) AllSourcesInterrupted?.Invoke("全部音频设备已中断，录音已暂停，请结束保存并检查设备后重新开始。");
        };
        captures.Add((capture, track, source));
    }
    public void Pause() { lock (gate) { clock.Stop(); paused = true; foreach (var item in captures) item.Track.PadTo(clock.Elapsed.TotalSeconds); } }
    public void Resume() { lock (gate) { if (writeFailed) throw new InvalidOperationException("录音写入已中断，请检查磁盘后结束保存并新建录音。"); if (clock.Elapsed.TotalHours >= 10) throw new InvalidOperationException("本次录音已达到 WAV 容量保护上限，请结束保存并新建录音。"); if (activeSources.Count == 0) throw new InvalidOperationException("音频设备已中断，请结束当前录音并重新开始。"); paused = false; clock.Start(); } }
    private void HandleWriteFailure(Exception error)
    {
        lock (gate) { if (paused || disposed) return; clock.Stop(); paused = true; writeFailed = true; }
        AllSourcesInterrupted?.Invoke("录音写入失败，已暂停：" + error.Message + "。请检查磁盘空间并结束保存已有录音。");
    }
    public void Stop()
    {
        try { lock (gate) { clock.Stop(); paused = true; foreach (var item in captures) item.Track.PadTo(clock.Elapsed.TotalSeconds); } }
        finally { Dispose(); }
    }
    public void Dispose()
    {
        List<(WasapiCapture Capture, TimelineTrack Track, string Source)> remaining;
        lock (gate) { if (disposed) return; disposed = true; clock.Stop(); silencePadding?.Dispose(); silencePadding = null; remaining = [.. captures]; captures.Clear(); }
        foreach (var item in remaining) { try { item.Capture.StopRecording(); } catch { } try { item.Capture.Dispose(); } catch { } try { item.Track.Dispose(); } catch { } }
    }
    private static float[] ConvertToMono(byte[] bytes, int count, WaveFormat format)
    {
        var bytesPerSample = format.BitsPerSample / 8;
        var inputFrames = count / format.BlockAlign;
        var input = new float[inputFrames];
        var floating = format.Encoding == WaveFormatEncoding.IeeeFloat || format is WaveFormatExtensible extensible && extensible.SubFormat == new Guid("00000003-0000-0010-8000-00aa00389b71");
        for (var frame = 0; frame < inputFrames; frame++)
        {
            double sum = 0;
            for (var channel = 0; channel < format.Channels; channel++)
            {
                var position = frame * format.BlockAlign + channel * bytesPerSample;
                sum += floating ? BitConverter.ToSingle(bytes, position) : bytesPerSample switch
                {
                    2 => BitConverter.ToInt16(bytes, position) / 32768f,
                    3 => ((bytes[position] | bytes[position + 1] << 8 | bytes[position + 2] << 16) << 8 >> 8) / 8388608f,
                    4 => BitConverter.ToInt32(bytes, position) / 2147483648f,
                    _ => (bytes[position] - 128) / 128f
                };
            }
            input[frame] = (float)(sum / format.Channels);
        }
        if (format.SampleRate == SampleRate) return input;
        var length = (int)Math.Round((double)inputFrames * SampleRate / format.SampleRate);
        var output = new float[length];
        for (var i = 0; i < length; i++)
        {
            var at = (double)i * format.SampleRate / SampleRate; var low = Math.Min((int)at, input.Length - 1);
            if (low < 0) break;
            output[i] = input[low] + (input[Math.Min(low + 1, input.Length - 1)] - input[low]) * (float)(at - low);
        }
        return output;
    }
    private sealed class TimelineTrack : IDisposable
    {
        private readonly WaveFileWriter writer;
        private long frames;
        private readonly float[] zeros = new float[SampleRate];
        public TimelineTrack(string file) { writer = new WaveFileWriter(file, new WaveFormat(SampleRate, 16, 1)); }
        public void PadTo(double seconds)
        {
            var missing = (long)(seconds * SampleRate) - frames;
            var flush = missing > SampleRate / 2;
            while (missing > 0) { var n = (int)Math.Min(missing, zeros.Length); writer.WriteSamples(zeros, 0, n); frames += n; missing -= n; }
            if (flush) writer.Flush();
        }
        public int Write(float[] samples, double start)
        {
            var target = (long)(start * SampleRate);
            if (target > frames) PadTo(start);
            var skip = (int)Math.Min(samples.Length, Math.Max(0, frames - target));
            var length = samples.Length - skip;
            if (length <= 0) return skip;
            writer.WriteSamples(samples, skip, length); frames += length;
            if (frames % (SampleRate * 5) < length) writer.Flush();
            return skip;
        }
        public void PadSilenceIfBehind(double seconds) { if (seconds - (double)frames / SampleRate > 1) PadTo(Math.Max(0, seconds - 0.5)); }
        public void Dispose() { writer.Dispose(); }
    }
}

public static class AudioFiles
{
    public static void Mix(string? system, string? microphone, string output, double logicalDuration, CancellationToken token = default)
    {
        var files = new[] { system, microphone }.Where(p => p is not null && File.Exists(p)).Cast<string>().ToArray();
        if (files.Length == 0) throw new FileNotFoundException("没有可用的录音文件。");
        if (files.Any(p => string.Equals(Path.GetFullPath(p), Path.GetFullPath(output), StringComparison.OrdinalIgnoreCase))) throw new IOException("完整回放不能覆盖原始音轨。");
        if (!double.IsFinite(logicalDuration) || logicalDuration > TimeSpan.FromHours(10).TotalSeconds) throw new InvalidDataException("录音超过经典 WAV 的安全容量范围（10 小时），不能生成此格式的完整回放；原始音频仍可直接播放。");
        var temporary = output + ".tmp.wav";
        var readers = new List<AudioFileReader>();
        try
        {
            foreach (var file in files) readers.Add(new AudioFileReader(file));
            var duration = logicalDuration > 0 ? logicalDuration : readers.Max(r => r.TotalTime.TotalSeconds);
            if (duration > TimeSpan.FromHours(10).TotalSeconds) throw new InvalidDataException("录音超过经典 WAV 的安全容量范围（10 小时），请直接播放原始音频。");
            var providers = readers.Select(r => Mono48(r)).ToArray();
            using (var writer = new WaveFileWriter(temporary, new WaveFormat(AudioRecorder.SampleRate, 16, 1)))
            {
                var buffer = new float[AudioRecorder.SampleRate]; var buffers = providers.Select(_ => new float[buffer.Length]).ToArray();
                var pcm = new byte[buffer.Length * 2];
                long remaining = (long)(duration * AudioRecorder.SampleRate);
                while (remaining > 0)
                {
                    token.ThrowIfCancellationRequested(); var wanted = (int)Math.Min(remaining, buffer.Length); Array.Clear(buffer);
                    for (var track = 0; track < providers.Length; track++)
                    {
                        var read = providers[track].Read(buffers[track], 0, wanted);
                        for (var i = 0; i < read; i++) buffer[i] += buffers[track][i] * (providers.Length > 1 ? 0.79f / providers.Length : 1f);
                    }
                    for (var i = 0; i < wanted; i++) { var value = (short)(Math.Clamp(buffer[i], -1, 1) * 32767); pcm[i * 2] = (byte)(value & 255); pcm[i * 2 + 1] = (byte)(value >> 8); }
                    writer.Write(pcm, 0, wanted * 2);
                    remaining -= wanted;
                }
            }
            File.Move(temporary, output, true);
        }
        finally { foreach (var reader in readers) reader.Dispose(); if (File.Exists(temporary)) File.Delete(temporary); }
    }
    public static ISampleProvider Mono48(AudioFileReader reader)
    {
        ISampleProvider provider = reader;
        if (provider.WaveFormat.Channels == 2) provider = new StereoToMonoSampleProvider(provider) { LeftVolume = 0.5f, RightVolume = 0.5f };
        if (provider.WaveFormat.Channels != 1) throw new InvalidDataException("暂不支持多于两声道的导入音频。");
        return provider.WaveFormat.SampleRate == AudioRecorder.SampleRate ? provider : new WdlResamplingSampleProvider(provider, AudioRecorder.SampleRate);
    }
}
