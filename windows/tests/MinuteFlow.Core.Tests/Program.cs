using System.Net;
using System.Text;
using System.Text.Json;
using MinuteFlow.Core;

var checks = new List<(string Name, Func<Task> Run)>();
void Check(string name, Action action) => checks.Add((name, () => { action(); return Task.CompletedTask; }));
void AsyncCheck(string name, Func<Task> action) => checks.Add((name, action));

Check("Swift metadata and transcript keep unknown fields and speaker IDs", () =>
{
    var session = JsonSerializer.Deserialize<MeetingSession>(Fixture("swift-session.json"), MeetingRepository.Json)!;
    Equal("项目目标与供应商选择方案讨论", session.Title);
    Equal("both", session.SourceSelection);
    Equal(TimeSpan.Zero, session.StartTime.Offset);
    Equal(2788d, session.PostTranscriptionCompletedDuration!.Value);
    var segments = JsonSerializer.Deserialize<List<TranscriptSegment>>(Fixture("swift-transcript.json"), MeetingRepository.Json)!;
    Equal("speaker-1", segments[0].SpeakerID);
    Equal("先确认供应商范围，再讨论实施时间。", segments[0].NormalizedText);
    using var roundTrip = JsonDocument.Parse(JsonSerializer.Serialize(segments, MeetingRepository.Json));
    Equal("speaker-1", roundTrip.RootElement[0].GetProperty("speakerID").GetString());
    Equal("naturalPause", roundTrip.RootElement[0].GetProperty("recognitionFragments")[0].GetProperty("boundaryReason").GetString());
    Equal(0d, roundTrip.RootElement[0].GetProperty("recognitionFragments")[0].GetProperty("overlapBefore").GetDouble());
});

Check("Viewing old transcript and summary leaves file modification dates unchanged", () =>
{
    using var temp = new Scratch();
    var repo = new MeetingRepository(temp.Path);
    var meeting = repo.Create("前天的会议", "microphone");
    var folder = repo.DirectoryFor(meeting.Id);
    File.WriteAllText(System.IO.Path.Combine(folder, "逐字稿.json"), Fixture("swift-transcript.json"));
    File.WriteAllText(System.IO.Path.Combine(folder, "会议纪要.md"), Fixture("会议纪要.md"));
    var files = Directory.GetFiles(folder);
    var date = new DateTime(2026, 8, 17, 6, 45, 28, DateTimeKind.Utc);
    foreach (var file in files) File.SetLastWriteTimeUtc(file, date);
    _ = repo.List();
    _ = repo.LoadTranscript(meeting.Id);
    _ = repo.LoadDocument(meeting.Id, "会议纪要.md");
    foreach (var file in files) Equal(date, File.GetLastWriteTimeUtc(file));
});

Check("Saving the same transcript, summary and metadata does not change modification dates", () =>
{
    using var temp = new Scratch();
    var repo = new MeetingRepository(temp.Path);
    var meeting = repo.Create("内容未改", "both");
    var segments = JsonSerializer.Deserialize<List<TranscriptSegment>>(Fixture("swift-transcript.json"), MeetingRepository.Json)!;
    repo.SaveTranscript(meeting.Id, segments);
    repo.SaveDocument(meeting.Id, "会议纪要.md", Fixture("会议纪要.md"));
    var files = Directory.GetFiles(repo.DirectoryFor(meeting.Id));
    var date = new DateTime(2026, 8, 17, 6, 45, 28, DateTimeKind.Utc);
    foreach (var file in files) File.SetLastWriteTimeUtc(file, date);
    repo.Save(meeting);
    repo.SaveTranscript(meeting.Id, segments);
    repo.SaveDocument(meeting.Id, "会议纪要.md", Fixture("会议纪要.md"));
    foreach (var file in files) Equal(date, File.GetLastWriteTimeUtc(file));
});

Check("Rename moves all files, keeps meeting identity and resolves imported Mac file URLs", () =>
{
    using var temp = new Scratch();
    var oldFolder = System.IO.Path.Combine(temp.Path, "旧会议");
    Directory.CreateDirectory(oldFolder);
    File.WriteAllText(System.IO.Path.Combine(oldFolder, MeetingRepository.MetadataName), Fixture("swift-session.json"));
    File.WriteAllText(System.IO.Path.Combine(oldFolder, "麦克风.m4a"), "source-audio-fixture");
    File.WriteAllText(System.IO.Path.Combine(oldFolder, "逐字稿.json"), Fixture("swift-transcript.json"));
    var repo = new MeetingRepository(temp.Path);
    var meeting = repo.List().Single();
    Equal(System.IO.Path.Combine(oldFolder, "麦克风.m4a"), repo.ResolvePath(meeting.Id, meeting.MicrophoneAudioURL));
    var id = meeting.Id;
    var renamed = repo.Rename(meeting, "讨论结论");
    Equal(id, renamed.Id);
    Equal("讨论结论", renamed.Title);
    Equal("讨论结论", System.IO.Path.GetFileName(repo.DirectoryFor(id)));
    True(!Directory.Exists(oldFolder), "Old directory must have moved.");
    Equal("source-audio-fixture", File.ReadAllText(repo.ResolvePath(id, renamed.MicrophoneAudioURL)));
    Equal("麦克风.m4a", renamed.MicrophoneAudioURL);
    var reopened = new MeetingRepository(temp.Path).List().Single();
    Equal(id, reopened.Id);
    Equal("讨论结论", reopened.Title);
    Equal(2, repo.LoadTranscript(id).Count);
});

Check("Name collisions preserve both meetings and Windows reserved names are safe", () =>
{
    using var temp = new Scratch();
    var repo = new MeetingRepository(temp.Path);
    var first = repo.Create("同名会议", "both");
    var second = repo.Create("另一个会议", "microphone");
    File.WriteAllText(System.IO.Path.Combine(repo.DirectoryFor(first.Id), "keep.txt"), "original");
    repo.Rename(second, "同名会议");
    True(first.Title != second.Title, "Collision must be disambiguated.");
    Equal(2, repo.List().Count);
    Equal("original", File.ReadAllText(System.IO.Path.Combine(repo.DirectoryFor(first.Id), "keep.txt")));
    Equal("_CON", MeetingRepository.SafeTitle("CON"));
    Equal("_LPT1.txt", MeetingRepository.SafeTitle("LPT1.txt"));
    True(!MeetingRepository.SafeTitle("../A:B/C?").Contains('/'), "Unsafe path chars must not be used.");
});

Check("Same-title rename does not rewrite unedited meeting metadata", () =>
{
    using var temp = new Scratch();
    var repo = new MeetingRepository(temp.Path);
    var meeting = repo.Create("没有改动", "microphone");
    var path = System.IO.Path.Combine(repo.DirectoryFor(meeting.Id), MeetingRepository.MetadataName);
    var date = new DateTime(2026, 8, 17, 6, 45, 28, DateTimeKind.Utc);
    File.SetLastWriteTimeUtc(path, date);
    repo.Rename(meeting, "  没有改动  ");
    Equal(date, File.GetLastWriteTimeUtc(path));
});

Check("Out-of-order ASR completion is saved in chronological order without losing edited text", () =>
{
    using var temp = new Scratch();
    var repo = new MeetingRepository(temp.Path);
    var meeting = repo.Create("时间轴", "both");
    var early = new TranscriptSegment { StartTime = 3, EndTime = 8, Text = "已编辑的早期文字", OriginalText = "原始文字", Source = "microphone" };
    var late = new TranscriptSegment { StartTime = 12, EndTime = 19, Text = "后来的回复", Source = "system" };
    repo.SaveTranscript(meeting.Id, [late, early]);
    var saved = repo.LoadTranscript(meeting.Id);
    Equal(early.Id, saved[0].Id);
    Equal("已编辑的早期文字", saved[0].Text);
    Equal("原始文字", saved[0].OriginalText);
    Equal(late.Id, saved[1].Id);
});

Check("Realtime paragraph merge preserves imported Mac manual edits and original evidence", () =>
{
    var imported = JsonSerializer.Deserialize<List<TranscriptSegment>>(Fixture("swift-transcript.json"), MeetingRepository.Json)!;
    var existing = imported[0]; existing.Text = "人工确认的修改，不允许自动改写。";
    var beforeOriginal = existing.OriginalText;
    var upcoming = new TranscriptSegment { StartTime = existing.EndTime, EndTime = existing.EndTime + 5, Source = existing.Source, SpeakerID = existing.SpeakerID, Text = "后续发言。", OriginalText = "后续发言。" };
    var segments = new List<TranscriptSegment> { existing };
    TranscriptEditing.AppendOrMerge(segments, upcoming);
    Equal("人工确认的修改，不允许自动改写。", existing.Text);
    Equal(beforeOriginal, existing.OriginalText);
    Equal(2, segments.Count);
});

Check("Transcript and document paths cannot escape the meeting folder", () =>
{
    using var temp = new Scratch();
    var repo = new MeetingRepository(temp.Path);
    var meeting = repo.Create("安全路径", "both");
    Throws<ArgumentException>(() => repo.SaveDocument(meeting.Id, "../outside.md", "bad"));
    Throws<ArgumentException>(() => repo.LoadDocument(meeting.Id, "../outside.md"));
    var relocated = repo.ResolvePath(meeting.Id, "file:///Users/elsewhere/private.wav");
    Equal(System.IO.Path.Combine(repo.DirectoryFor(meeting.Id), "private.wav"), relocated);
    Throws<IOException>(() => repo.ResolvePath(meeting.Id, ".."));
});

Check("Deleting a meeting keeps a recoverable copy outside the active list", () =>
{
    using var temp = new Scratch();
    var repo = new MeetingRepository(System.IO.Path.Combine(temp.Path, "Sessions"));
    var meeting = repo.Create("可恢复", "both");
    repo.SaveDocument(meeting.Id, "会议纪要.md", "recover me");
    var trash = repo.MoveToTrash(meeting.Id);
    Equal(0, repo.List().Count);
    Equal("recover me", File.ReadAllText(System.IO.Path.Combine(trash, "会议纪要.md")));
});

Check("Settings JSON never exposes Token", () =>
{
    var config = new ModelConfiguration { Token = "synthetic-secret-do-not-persist" };
    var json = JsonSerializer.Serialize(config, MeetingRepository.Json);
    True(!json.Contains(config.Token), "Token leaked to ordinary JSON.");
    True(!json.Contains("\"token\"", StringComparison.OrdinalIgnoreCase), "Token key must be excluded.");
});

Check("Both platform dates and relative audio paths deserialize without time zone drift", () =>
{
    var session = JsonSerializer.Deserialize<MeetingSession>(Fixture("windows-session.json"), MeetingRepository.Json)!;
    Equal(new DateTimeOffset(2026, 10, 10, 0, 15, 32, TimeSpan.Zero).AddTicks(1234567), session.StartTime.ToUniversalTime());
    Equal("完整回放.wav", session.MixedAudioURL);
});

Check("PCM WAV header and amplitude clipping produce a valid mono 16-bit audio file", () =>
{
    var wav = WavePcm.Encode16Bit([-2, -1, 0, 1, 2], 16000);
    Equal(54, wav.Length);
    Equal("RIFF", Encoding.ASCII.GetString(wav, 0, 4));
    Equal("WAVE", Encoding.ASCII.GetString(wav, 8, 4));
    Equal(46, BitConverter.ToInt32(wav, 4));
    Equal(16000, BitConverter.ToInt32(wav, 24));
    Equal((short)1, BitConverter.ToInt16(wav, 22));
    Equal((short)16, BitConverter.ToInt16(wav, 34));
    Equal(10, BitConverter.ToInt32(wav, 40));
    Equal((short)-32767, BitConverter.ToInt16(wav, 44));
    Equal((short)32767, BitConverter.ToInt16(wav, 52));
    Throws<ArgumentOutOfRangeException>(() => WavePcm.Encode16Bit([], 0));
});

Check("Silence guard pauses exactly at 30 minutes, resets on real sound, supports disabled mode", () =>
{
    var guard = new SilenceGuard(TimeSpan.FromMinutes(30));
    guard.Reset(TimeSpan.Zero);
    True(!guard.ShouldPause(TimeSpan.FromMinutes(30) - TimeSpan.FromTicks(1)), "Paused before threshold.");
    True(guard.ShouldPause(TimeSpan.FromMinutes(30)), "Did not pause at threshold.");
    guard.Observe(0.03, TimeSpan.FromMinutes(29));
    True(!guard.ShouldPause(TimeSpan.FromMinutes(30)), "Audible sound must reset timer.");
    True(guard.ShouldPause(TimeSpan.FromMinutes(59)), "Continuous silence after sound must trigger.");
    var disabled = new SilenceGuard(TimeSpan.Zero);
    True(!disabled.ShouldPause(TimeSpan.FromDays(7)), "Disabled mode must never trigger.");
});

Check("Sixty-minute silence guard ignores invalid samples and late callbacks", () =>
{
    var guard = new SilenceGuard(TimeSpan.FromMinutes(60));
    guard.Reset(TimeSpan.Zero);
    guard.Observe(0.03, TimeSpan.FromMinutes(20));
    guard.Observe(0.03, TimeSpan.FromMinutes(1));
    True(!guard.ShouldPause(TimeSpan.FromMinutes(70)), "Late callbacks cannot move last activity backwards.");
    guard.Observe(double.PositiveInfinity, TimeSpan.FromMinutes(79));
    guard.Observe(double.NaN, TimeSpan.FromMinutes(79));
    True(guard.ShouldPause(TimeSpan.FromMinutes(80)), "Invalid audio samples must not suppress forgotten-recording protection.");
});

Check("Long pure silence makes no transcription chunks; speech gets preview then pause final", () =>
{
    var segmenter = new SpeechSegmenter();
    var silence = new float[16000];
    for (var seconds = 0; seconds < 3600; seconds++) Equal(0, segmenter.Push(silence, 16000, seconds).Count);
    var previews = segmenter.Push(Enumerable.Repeat(0.1f, 16000 * 4).ToArray(), 16000, 3600);
    True(previews.Any(x => x.IsPreview), "Four seconds of audible speech must have preview.");
    True(!previews.Any(x => !x.IsPreview), "Short continuous speech should not prematurely finalize.");
    var ended = segmenter.Push(silence, 16000, 3604);
    var final = ended.Single(x => !x.IsPreview);
    True(final.StartTime >= 3599.5 && final.StartTime <= 3600, "Pre-roll should retain at most 450 ms.");
    True(final.EndTime >= 3604.6 && final.EndTime <= 3604.8, "Natural pause should finalize after about 700 ms.");
});

Check("Continuous speech is bounded by hard limit and pause flush preserves pending speech", () =>
{
    var segmenter = new SpeechSegmenter();
    var all = segmenter.Push(Enumerable.Repeat(0.1f, 16000 * 33).ToArray(), 16000, 0).ToList();
    all.AddRange(segmenter.Push([], 16000, 33, flush: true));
    var finals = all.Where(x => !x.IsPreview).ToArray();
    Equal(3, finals.Length);
    Equal(0d, finals[0].StartTime);
    True(finals.All(x => x.EndTime - x.StartTime <= 15.1), "Chunk size must be bounded for API calls.");
    Equal(33d, finals[^1].EndTime);
    Equal(0, segmenter.Push([], 16000, 33, flush: true).Count);
});

AsyncCheck("MiMo Token Plan uses its audio chat protocol and only api-key authentication", async () =>
{
    var called = 0;
    using var http = new HttpClient(new Handler(async (request, ct) =>
    {
        called++;
        Equal("https://token-plan-cn.xiaomimimo.com/v1/chat/completions", request.RequestUri!.ToString());
        Equal("synthetic-token", request.Headers.GetValues("api-key").Single());
        True(request.Headers.Authorization is null, "MiMo api-key calls must not add a second Bearer credential.");
        using var body = JsonDocument.Parse(await request.Content!.ReadAsStringAsync(ct));
        Equal("mimo-v2.5-asr", body.RootElement.GetProperty("model").GetString());
        Equal(false, body.RootElement.GetProperty("stream").GetBoolean());
        Equal("input_audio", body.RootElement.GetProperty("messages")[0].GetProperty("content")[0].GetProperty("type").GetString());
        var data = body.RootElement.GetProperty("messages")[0].GetProperty("content")[0].GetProperty("input_audio").GetProperty("data").GetString()!;
        True(data.StartsWith("data:audio/wav;base64,"), "Audio must be a data URL.");
        Equal("zh", body.RootElement.GetProperty("asr_options").GetProperty("language").GetString());
        return Response(HttpStatusCode.OK, "{\"choices\":[{\"message\":{\"content\":\"识别成功\"}}]}");
    }));
    var text = await new ModelClient(http).TranscribeAsync(WavePcm.Encode16Bit([0, 0.1f], 16000), Configuration("https://token-plan-cn.xiaomimimo.com/v1", "zh-CN"));
    Equal("识别成功", text);
    Equal(1, called);
});

AsyncCheck("Custom multipart ASR uses Bearer and includes the WAV file", async () =>
{
    using var http = new HttpClient(new Handler(async (request, ct) =>
    {
        Equal("https://models.example.com/v1/audio/transcriptions", request.RequestUri!.ToString());
        Equal("Bearer", request.Headers.Authorization!.Scheme);
        Equal("synthetic-token", request.Headers.Authorization.Parameter);
        True(!request.Headers.Contains("api-key"), "Generic endpoint must not receive MiMo key header.");
        True(request.Content!.Headers.ContentType!.MediaType == "multipart/form-data", "Must upload multipart file.");
        var body = Encoding.UTF8.GetString(await request.Content.ReadAsByteArrayAsync(ct));
        True(body.Contains("speech.wav") && body.Contains("audio/wav") && body.Contains("RIFF"), "Actual WAV file missing.");
        True(body.Contains("mimo-v2.5-asr"), "Model field missing.");
        return Response(HttpStatusCode.OK, "{\"text\":\"自定义成功\"}");
    }));
    Equal("自定义成功", await new ModelClient(http).TranscribeAsync(WavePcm.Encode16Bit([0], 16000), Configuration("https://models.example.com/v1")));
});

AsyncCheck("Authentication failures redact secrets and do not retry invalid credentials", async () =>
{
    var calls = 0;
    using var http = new HttpClient(new Handler((_, _) =>
    {
        calls++;
        return Task.FromResult(Response(HttpStatusCode.Unauthorized, "{\"error\":{\"message\":\"bad synthetic-token\"}}"));
    }));
    try { await new ModelClient(http).TranscribeAsync([1], Configuration("https://models.example.com/v1")); throw new Exception("Expected credential rejection."); }
    catch (HttpRequestException e)
    {
        Equal(HttpStatusCode.Unauthorized, e.StatusCode!.Value);
        True(!e.Message.Contains("synthetic-token"), "Failure message exposed Token.");
    }
    Equal(1, calls);
});

AsyncCheck("Cancellation interrupts an in-flight ASR call", async () =>
{
    using var cts = new CancellationTokenSource();
    using var http = new HttpClient(new Handler(async (_, ct) =>
    {
        cts.Cancel();
        await Task.Delay(Timeout.Infinite, ct);
        return Response(HttpStatusCode.OK, "{\"text\":\"must not appear\"}");
    }));
    try { await new ModelClient(http).TranscribeAsync([1], Configuration("https://models.example.com/v1"), cts.Token); throw new Exception("Expected cancellation."); }
    catch (OperationCanceledException) { }
});

AsyncCheck("Transient ASR server failures retry the same audio within a bounded budget", async () =>
{
    var bodies = new List<string>();
    using var http = new HttpClient(new Handler(async (request, ct) =>
    {
        bodies.Add(await request.Content!.ReadAsStringAsync(ct));
        return bodies.Count < 3
            ? Response(HttpStatusCode.ServiceUnavailable, "{\"error\":{\"message\":\"temporarily unavailable\"}}")
            : Response(HttpStatusCode.OK, "{\"text\":\"重试成功\"}");
    }));
    var result = await new ModelClient(http).TranscribeAsync([1, 2, 3], Configuration("https://token-plan-cn.xiaomimimo.com/v1"));
    Equal("重试成功", result); Equal(3, bodies.Count);
    True(bodies.All(b => b == bodies[0]), "Retry changed uploaded audio or model parameters.");
});

AsyncCheck("Repeated rate limiting stops after three requests", async () =>
{
    var calls = 0;
    using var http = new HttpClient(new Handler((_, _) => { calls++; return Task.FromResult(Response(HttpStatusCode.TooManyRequests, "{\"error\":{\"message\":\"rate limited\"}}")); }));
    try { await new ModelClient(http).TranscribeAsync([1], Configuration("https://models.example.com/v1")); throw new Exception("Expected bounded retry failure."); }
    catch (HttpRequestException e) { Equal(HttpStatusCode.TooManyRequests, e.StatusCode!.Value); }
    Equal(3, calls);
});

Check("MiMo detection rejects look-alike host names; malformed service URLs fail early", () =>
{
    True(!Configuration("https://xiaomimimo.com.attacker.example/v1").UsesMiMo, "Lookalike host treated as MiMo.");
    True(!Configuration("https://evilxiaomimimo.com/v1").UsesMiMo, "Suffix lookalike host treated as MiMo.");
    True(Configuration("https://api.xiaomimimo.com/v1").UsesMiMo, "Real MiMo subdomain should be recognized.");
    Throws<ArgumentException>(() => ModelClient.Endpoint("http://models.example.com/v1", "models"));
    Equal("https://models.example.com/v1/chat/completions", ModelClient.Endpoint("https://models.example.com/v1/audio/transcriptions/", "chat/completions").ToString());
});

#if WINDOWS_VALIDATION
foreach (var check in WindowsBehaviorChecks.Create()) checks.Add(check);
#else
Console.WriteLine("SKIP Windows DPAPI and NAudio file mixer checks: Windows runtime is required.");
#endif

var failures = 0;
foreach (var (name, run) in checks)
{
    try { await run(); Console.WriteLine($"PASS {name}"); }
    catch (Exception e) { failures++; Console.Error.WriteLine($"FAIL {name}: {e.Message}"); }
}
Console.WriteLine($"{checks.Count - failures}/{checks.Count} behavioral checks passed.");
return failures == 0 ? 0 : 1;

static string Fixture(string name) => File.ReadAllText(System.IO.Path.Combine(AppContext.BaseDirectory, "Fixtures", name));
static ModelConfiguration Configuration(string url, string language = "auto") => new() { BaseUrl = url, Token = "synthetic-token", AsrModel = "mimo-v2.5-asr", TextModel = "text-model", Language = language };
static HttpResponseMessage Response(HttpStatusCode status, string body) => new(status) { Content = new StringContent(body, Encoding.UTF8, "application/json") };
static void True(bool condition, string reason) { if (!condition) throw new Exception(reason); }
static void Equal<T>(T expected, T actual) { if (!EqualityComparer<T>.Default.Equals(expected, actual)) throw new Exception($"Expected {expected}, received {actual}."); }
static void Throws<T>(Action action) where T : Exception
{
    try { action(); } catch (T) { return; }
    throw new Exception($"Expected {typeof(T).Name}.");
}

sealed class Scratch : IDisposable
{
    public string Path { get; } = System.IO.Path.Combine(System.IO.Path.GetTempPath(), "MinuteFlow-behavior-tests-" + Guid.NewGuid().ToString("N"));
    public Scratch() => Directory.CreateDirectory(Path);
    public void Dispose() => Directory.Delete(Path, true);
}

sealed class Handler(Func<HttpRequestMessage, CancellationToken, Task<HttpResponseMessage>> callback) : HttpMessageHandler
{
    protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken) => callback(request, cancellationToken);
}
