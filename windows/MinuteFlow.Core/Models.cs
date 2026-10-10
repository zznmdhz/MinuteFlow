using System.Text.Json;
using System.Text.Json.Serialization;

namespace MinuteFlow.Core;

public static class MeetingTime
{
    public static string Format(double seconds)
    {
        var total = (long)Math.Clamp(double.IsFinite(seconds) ? seconds : 0, 0, TimeSpan.MaxValue.TotalSeconds);
        return $"{total / 3600:00}:{total % 3600 / 60:00}:{total % 60:00}";
    }
}

public sealed class MeetingSession
{
    public Guid Id { get; set; } = Guid.NewGuid();
    public string Title { get; set; } = "";
    public string SourceSelection { get; set; } = "both";
    public DateTimeOffset StartTime { get; set; } = DateTimeOffset.Now;
    public DateTimeOffset? EndTime { get; set; }
    public double Duration { get; set; }
    public string RecordingStatus { get; set; } = "preparing";
    public string? SystemAudioURL { get; set; }
    public string? MicrophoneAudioURL { get; set; }
    public string? MixedAudioURL { get; set; }
    public string? MixState { get; set; }
    public string? MixMessage { get; set; }
    public string? TranscriptFileURL { get; set; }
    public string? SummaryFileURL { get; set; }
    public string? FormattedDocumentFileURL { get; set; }
    public string? DiarizationFileURL { get; set; }
    public Dictionary<string, string>? SpeakerNames { get; set; }
    public bool? TitleWasAutomaticallyGenerated { get; set; }
    public DateTimeOffset? PostTranscriptionCompletedAt { get; set; }
    public double? PostTranscriptionCompletedDuration { get; set; }
    public DateTimeOffset CreatedAt { get; set; } = DateTimeOffset.Now;
    public DateTimeOffset UpdatedAt { get; set; } = DateTimeOffset.Now;
    [JsonExtensionData] public Dictionary<string, JsonElement>? Extra { get; set; }
    [JsonIgnore] public string Description => $"{StartTime.LocalDateTime:yyyy-MM-dd HH:mm} · {MeetingTime.Format(Duration)}";
}

public sealed class TranscriptSegment
{
    public Guid Id { get; set; } = Guid.NewGuid();
    public double StartTime { get; set; }
    public double EndTime { get; set; }
    public string Text { get; set; } = "";
    public string? OriginalText { get; set; }
    public string? NormalizedText { get; set; }
    public string Source { get; set; } = "microphone";
    public bool IsFinal { get; set; } = true;
    public string? SpeakerID { get; set; }
    public string? BoundaryReason { get; set; }
    public List<TranscriptRecognitionFragment>? RecognitionFragments { get; set; }
    public bool UserEdited { get; set; }
    [JsonExtensionData] public Dictionary<string, JsonElement>? Extra { get; set; }
    [JsonIgnore] public string Label => $"{MeetingTime.Format(StartTime)}  ·  {SpeakerID ?? (Source == "system" ? "系统声音" : Source == "mixed" ? "完整录音" : "麦克风")}";
}

public sealed class TranscriptRecognitionFragment
{
    public Guid Id { get; set; } = Guid.NewGuid();
    public double StartTime { get; set; }
    public double EndTime { get; set; }
    public string OriginalText { get; set; } = "";
    public string BoundaryReason { get; set; } = "legacyUnknown";
    public double OverlapBefore { get; set; }
    public string? SpeakerID { get; set; }
    [JsonExtensionData] public Dictionary<string, JsonElement>? Extra { get; set; }
}

public enum ASRProtocol { Auto, MiMo, OpenAI }
public sealed class ModelConfiguration
{
    public string BaseUrl { get; set; } = "https://token-plan-cn.xiaomimimo.com/v1";
    [JsonIgnore] public string Token { get; set; } = "";
    public string AsrModel { get; set; } = "mimo-v2.5-asr";
    public string TextModel { get; set; } = "mimo-v2.5";
    public string Language { get; set; } = "auto";
    public ASRProtocol Protocol { get; set; }
    public bool AsrEnabled { get; set; } = true;
    public bool AutomaticTitle { get; set; } = true;
    public bool AutomaticSummary { get; set; }
    public int SilenceMinutes { get; set; } = 30;
    public string? MicrophoneDeviceId { get; set; }
    public bool IsConfigured => Uri.TryCreate(BaseUrl, UriKind.Absolute, out var url) && url.Scheme == "https" && !string.IsNullOrWhiteSpace(Token) && !string.IsNullOrWhiteSpace(AsrModel);
    public bool UsesMiMo => Protocol == ASRProtocol.MiMo || (Protocol == ASRProtocol.Auto && Uri.TryCreate(BaseUrl, UriKind.Absolute, out var u) && (u.Host.Equals("xiaomimimo.com", StringComparison.OrdinalIgnoreCase) || u.Host.EndsWith(".xiaomimimo.com", StringComparison.OrdinalIgnoreCase)));
}
