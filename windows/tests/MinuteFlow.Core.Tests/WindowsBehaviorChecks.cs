#if WINDOWS_VALIDATION
using System.Security.Cryptography;
using System.Text;
using MinuteFlow.Core;
using MinuteFlow.Windows;
using NAudio.Wave;

static class WindowsBehaviorChecks
{
    public static IEnumerable<(string Name, Func<Task> Run)> Create()
    {
        yield return Sync("Windows DPAPI saves and reloads Token without plaintext settings", () =>
        {
            using var temp = new Scratch();
            var store = new SettingsStore(temp.Path);
            var config = new ModelConfiguration { BaseUrl = "https://models.example.com/v1", AsrModel = "asr-test", TextModel = "text-test" };
            const string token = "synthetic-windows-credential-test";
            store.Save(config, token);
            var settings = File.ReadAllText(Path.Combine(temp.Path, "settings.json"));
            True(!settings.Contains(token), "Token leaked to settings.");
            var encrypted = File.ReadAllBytes(Path.Combine(temp.Path, "credential.dpapi"));
            True(!Encoding.UTF8.GetString(encrypted).Contains(token), "Credential file is plaintext.");
            var reopened = new SettingsStore(temp.Path);
            Equal(token, reopened.Configuration.Token);
            Equal("", reopened.CredentialError);
            reopened.Save(new ModelConfiguration { AsrModel = "asr-changed" }, "");
            Equal(token, new SettingsStore(temp.Path).Configuration.Token);
            True(encrypted.AsSpan().SequenceEqual(File.ReadAllBytes(Path.Combine(temp.Path, "credential.dpapi"))), "Blank replacement needlessly replaced saved credential.");
            reopened.ClearToken();
            Equal("", new SettingsStore(temp.Path).Configuration.Token);
        });
        yield return Sync("Windows corrupted protected credential gives a recoverable configuration error", () =>
        {
            using var temp = new Scratch();
            File.WriteAllBytes(Path.Combine(temp.Path, "credential.dpapi"), [1, 2, 3, 4]);
            var store = new SettingsStore(temp.Path);
            True(store.CredentialError.Length > 0, "Corrupted Token was silently ignored.");
            Equal("", store.Configuration.Token);
            store.Save(new ModelConfiguration(), "replacement-synthetic-token");
            Equal("replacement-synthetic-token", new SettingsStore(temp.Path).Configuration.Token);
        });
        yield return Sync("Windows mixer retains two sources and known pulse alignment without changing originals", () =>
        {
            using var temp = new Scratch();
            var mic = Path.Combine(temp.Path, "mic.wav");
            var system = Path.Combine(temp.Path, "system.wav");
            var output = Path.Combine(temp.Path, "mixed.wav");
            var one = new float[48000]; one[2400] = 0.5f;
            var two = new float[48000]; two[12000] = 0.5f;
            File.WriteAllBytes(mic, WavePcm.Encode16Bit(one, 48000));
            File.WriteAllBytes(system, WavePcm.Encode16Bit(two, 48000));
            var originalMic = SHA256.HashData(File.ReadAllBytes(mic));
            var originalSystem = SHA256.HashData(File.ReadAllBytes(system));
            AudioFiles.Mix(system, mic, output, 1);
            using var reader = new AudioFileReader(output);
            Equal(48000, reader.WaveFormat.SampleRate);
            True(Math.Abs(reader.TotalTime.TotalSeconds - 1) < 0.001, "Mixed duration incorrect.");
            var samples = new float[48000];
            Equal(48000, reader.Read(samples, 0, samples.Length));
            True(samples[2400] > 0.15 && samples[12000] > 0.15, "Known source pulses missing or misaligned after headroom scaling.");
            True(samples[4800] == 0, "Unexpected audio between pulses.");
            True(originalMic.AsSpan().SequenceEqual(SHA256.HashData(File.ReadAllBytes(mic))), "Microphone original changed.");
            True(originalSystem.AsSpan().SequenceEqual(SHA256.HashData(File.ReadAllBytes(system))), "System original changed.");
        });
        yield return Sync("Windows mix cancellation retains existing playback and removes temporary output", () =>
        {
            using var temp = new Scratch();
            var original = Path.Combine(temp.Path, "source.wav");
            var playback = Path.Combine(temp.Path, "mixed.wav");
            File.WriteAllBytes(original, WavePcm.Encode16Bit(new float[48000], 48000));
            File.WriteAllBytes(playback, [5, 6, 7]);
            using var cts = new CancellationTokenSource(); cts.Cancel();
            Throws<OperationCanceledException>(() => AudioFiles.Mix(original, null, playback, 1, cts.Token));
            True(File.ReadAllBytes(playback).AsSpan().SequenceEqual(new byte[] { 5, 6, 7 }), "Cancelled mix replaced previous playback.");
            True(!File.Exists(playback + ".tmp.wav"), "Cancelled mix left temporary WAV.");
        });
        yield return Sync("Windows mixer rejects overwriting an original audio file", () =>
        {
            using var temp = new Scratch();
            var original = Path.Combine(temp.Path, "source.wav");
            File.WriteAllBytes(original, WavePcm.Encode16Bit(new float[48000], 48000));
            var before = SHA256.HashData(File.ReadAllBytes(original));
            Throws<IOException>(() => AudioFiles.Mix(original, null, original, 1));
            True(before.AsSpan().SequenceEqual(SHA256.HashData(File.ReadAllBytes(original))), "Mix overwrote the source.");
        });
        yield return Sync("Windows mixed playback keeps headroom for two simultaneous loud sources", () =>
        {
            using var temp = new Scratch();
            var mic = Path.Combine(temp.Path, "mic.wav"); var system = Path.Combine(temp.Path, "system.wav"); var output = Path.Combine(temp.Path, "mixed.wav");
            var samples = Enumerable.Repeat(0.9f, 4800).ToArray();
            File.WriteAllBytes(mic, WavePcm.Encode16Bit(samples, 48000));
            File.WriteAllBytes(system, WavePcm.Encode16Bit(samples, 48000));
            AudioFiles.Mix(system, mic, output, 0.1);
            using var reader = new AudioFileReader(output);
            var mixed = new float[4800]; Equal(4800, reader.Read(mixed, 0, mixed.Length));
            True(mixed.Max(Math.Abs) <= 0.8f, "Two voices clipped: output must preserve -2 dB headroom like Mac.");
        });
        yield return Sync("Windows source timeline removes overlapping delayed packets and pads genuine gaps", () =>
        {
            using var temp = new Scratch();
            var path = Path.Combine(temp.Path, "timeline.wav");
            // Invoke the actual source writer using known timestamped sample packets.
            // This tests stored audio alignment without pretending to test a WASAPI device.
            var type = typeof(AudioRecorder).GetNestedType("TimelineTrack", System.Reflection.BindingFlags.NonPublic)!;
            using (var track = (IDisposable)Activator.CreateInstance(type, path)!)
            {
                var write = type.GetMethod("Write")!;
                var pad = type.GetMethod("PadTo")!;
                write.Invoke(track, [Enumerable.Repeat(0.1f, 48000 * 8 / 10).ToArray(), 0d]);
                write.Invoke(track, [Enumerable.Repeat(0.2f, 48000 / 2).ToArray(), 0.5d]);
                write.Invoke(track, [Enumerable.Repeat(0.3f, 48000 / 10).ToArray(), 2d]);
                pad.Invoke(track, [2.2d]);
            }
            using var reader = new AudioFileReader(path);
            True(Math.Abs(reader.TotalTime.TotalSeconds - 2.2) < 0.001, "Timeline duration expanded due to overlap.");
            var samples = new float[48000 * 22 / 10]; Equal(samples.Length, reader.Read(samples, 0, samples.Length));
            True(samples[48000 * 7 / 10] > 0.09 && samples[48000 * 7 / 10] < 0.11, "Existing samples were overwritten by overlap.");
            True(samples[48000 * 9 / 10] > 0.19 && samples[48000 * 9 / 10] < 0.21, "Uncovered part of late packet was lost.");
            True(samples[48000 * 12 / 10] == 0, "A genuine timeline gap must be silent.");
            True(samples[48000 * 205 / 100] > 0.29, "Post-gap packet was not placed on its timestamp.");
        });
        yield return ("Windows post-transcription fills partial gaps and preserves existing manual edits", async () =>
        {
            using var temp = new Scratch();
            var repo = new MeetingRepository(Path.Combine(temp.Path, "Sessions"));
            var meeting = repo.Create("补全已有片段", "microphone");
            meeting.Duration = 9; meeting.RecordingStatus = "completed";
            var audio = new float[48000 * 9]; Array.Fill(audio, 0.1f, 0, 48000 * 8);
            File.WriteAllBytes(repo.ResolvePath(meeting.Id, meeting.MicrophoneAudioURL), WavePcm.Encode16Bit(audio, 48000));
            var edited = new TranscriptSegment { StartTime = 0, EndTime = 2, Text = "用户已手工更正这段", OriginalText = "原始识别", Source = "microphone" };
            var transcript = new List<TranscriptSegment> { edited };
            repo.SaveTranscript(meeting.Id, transcript);
            var settings = new SettingsStore(Path.Combine(temp.Path, "settings")); settings.Configuration.Token = "synthetic-token";
            var calls = 0;
            using var http = new HttpClient(new Handler((_, _) => { calls++; return Task.FromResult(new System.Net.Http.HttpResponseMessage(System.Net.HttpStatusCode.OK) { Content = new StringContent("{\"text\":\"补全剩余发言\"}") }); }));
            await PostTranscriber.RunAsync(meeting, repo, settings, new ModelClient(http), transcript, (_, _) => { }, () => { }, CancellationToken.None);
            True(calls > 0, "A partially-covered speech chunk was entirely skipped.");
            Equal("用户已手工更正这段", transcript.Single(x => x.Id == edited.Id).Text);
            True(transcript.Any(x => x.Id != edited.Id && x.StartTime >= 2 && x.Text.Contains("补全剩余发言")), "Missing interval did not get its own transcript.");
            Equal(9d, meeting.PostTranscriptionCompletedDuration!.Value);
        });
        yield return ("Windows post-transcription failure persists earlier results and cancellation never marks complete", async () =>
        {
            using var temp = new Scratch();
            var repo = new MeetingRepository(Path.Combine(temp.Path, "Sessions"));
            var meeting = repo.Create("中途停止", "microphone"); meeting.Duration = 34;
            File.WriteAllBytes(repo.ResolvePath(meeting.Id, meeting.MicrophoneAudioURL), WavePcm.Encode16Bit(Enumerable.Repeat(0.1f, 48000 * 34).ToArray(), 48000));
            var settings = new SettingsStore(Path.Combine(temp.Path, "settings")); settings.Configuration.Token = "synthetic-token";
            var calls = 0;
            using var cts = new CancellationTokenSource();
            using var http = new HttpClient(new Handler((_, ct) =>
            {
                calls++;
                if (calls == 2) { cts.Cancel(); ct.ThrowIfCancellationRequested(); }
                return Task.FromResult(new System.Net.Http.HttpResponseMessage(System.Net.HttpStatusCode.OK) { Content = new StringContent("{\"text\":\"第一段已经保存\"}") });
            }));
            var transcript = new List<TranscriptSegment>();
            try { await PostTranscriber.RunAsync(meeting, repo, settings, new ModelClient(http), transcript, (_, _) => { }, () => { }, cts.Token); throw new Exception("Expected cancellation."); }
            catch (OperationCanceledException) { }
            True(repo.LoadTranscript(meeting.Id).Any(x => x.Text.Contains("第一段已经保存")), "Earlier successful text was lost on cancellation.");
            True(meeting.PostTranscriptionCompletedAt is null, "Cancelled job falsely marked complete.");
            True(File.Exists(repo.ResolvePath(meeting.Id, meeting.MicrophoneAudioURL)), "Source recording removed by cancellation.");
        });
        yield return ("Windows failed resume leaves recording paused until explicit successful recovery", async () =>
        {
            using var temp = new Scratch();
            var repo = new MeetingRepository(Path.Combine(temp.Path, "Sessions"));
            var meeting = repo.Create("恢复失败保护", "microphone");
            var settings = new SettingsStore(Path.Combine(temp.Path, "settings"));
            using var http = new HttpClient(new Handler((_, _) => Task.FromResult(new System.Net.Http.HttpResponseMessage(System.Net.HttpStatusCode.OK))));
            // No hardware was started: this emulates all capture sources being
            // unavailable and checks the public state machine's failure path.
            await using var engine = new RecordingEngine(meeting, repo, settings, new ModelClient(http));
            engine.Pause(); True(engine.IsPaused, "Pause state not entered.");
            Throws<InvalidOperationException>(() => engine.Resume());
            True(engine.IsPaused, "Failed resume falsely changed UI to recording.");
            Equal("paused", meeting.RecordingStatus);
        });
    }
    static (string Name, Func<Task> Run) Sync(string name, Action action) => (name, () => { action(); return Task.CompletedTask; });
    static void True(bool condition, string reason) { if (!condition) throw new Exception(reason); }
    static void Equal<T>(T expected, T actual) { if (!EqualityComparer<T>.Default.Equals(expected, actual)) throw new Exception($"Expected {expected}, received {actual}."); }
    static void Throws<T>(Action action) where T : Exception { try { action(); } catch (T) { return; } throw new Exception($"Expected {typeof(T).Name}."); }
}
#endif
