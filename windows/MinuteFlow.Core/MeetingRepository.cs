using System.Text;
using System.Text.Json;

namespace MinuteFlow.Core;

public sealed class MeetingRepository
{
    public const string MetadataName = ".minuteflow-session.json";
    public static readonly JsonSerializerOptions Json = new() { PropertyNamingPolicy = JsonNamingPolicy.CamelCase, PropertyNameCaseInsensitive = true, WriteIndented = true };
    private readonly string root;
    private readonly Dictionary<Guid, string> directories = [];
    private readonly object gate = new();
    public string Root => root;
    public MeetingRepository(string root) { this.root = Path.GetFullPath(root); Directory.CreateDirectory(this.root); }
    public MeetingSession Create(string title, string sources)
    {
        lock (gate)
        {
            var folder = UniqueDirectory(title);
            Directory.CreateDirectory(folder);
            var session = new MeetingSession { Title = Path.GetFileName(folder), SourceSelection = sources };
            directories[session.Id] = folder;
            if (sources is "both" or "system") session.SystemAudioURL = "系统声音.wav";
            if (sources is "both" or "microphone") session.MicrophoneAudioURL = "麦克风.wav";
            Save(session);
            return session;
        }
    }
    public List<MeetingSession> List()
    {
        lock (gate)
        {
            var meetings = new List<MeetingSession>();
            foreach (var folder in Directory.EnumerateDirectories(root))
            {
                var file = Path.Combine(folder, MetadataName);
                if (!File.Exists(file)) file = Path.Combine(folder, "metadata.json");
                try
                {
                    if (!File.Exists(file)) continue;
                    var session = JsonSerializer.Deserialize<MeetingSession>(File.ReadAllText(file), Json);
                    if (session is null || session.Id == Guid.Empty) continue;
                    directories[session.Id] = folder;
                    meetings.Add(session);
                }
                catch (Exception e) when (e is IOException or JsonException or UnauthorizedAccessException) { }
            }
            return meetings.OrderByDescending(x => x.StartTime).ToList();
        }
    }
    public string DirectoryFor(Guid id)
    {
        lock (gate)
        {
            if (!directories.ContainsKey(id)) List();
            if (!directories.TryGetValue(id, out var path)) throw new DirectoryNotFoundException("找不到会议目录。");
            return path;
        }
    }
    public string ResolvePath(Guid id, string? reference)
    {
        if (string.IsNullOrWhiteSpace(reference)) throw new FileNotFoundException("录音文件尚未生成。");
        var directory = DirectoryFor(id);
        // Imported Mac URLs are resolved within the imported meeting, never outside it.
        var decoded = Uri.TryCreate(reference, UriKind.Absolute, out var uri) && uri.IsFile ? uri.LocalPath : Uri.UnescapeDataString(reference);
        var portable = decoded.Replace('\\', '/');
        var name = portable.Split('/').Last();
        var candidate = Path.GetFullPath(Path.Combine(directory, name));
        if (!candidate.StartsWith(directory + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase)) throw new IOException("无效的会议文件路径。");
        return candidate;
    }
    public void Save(MeetingSession session)
    {
        lock (gate) WriteIfChanged(Path.Combine(DirectoryFor(session.Id), MetadataName), JsonSerializer.Serialize(session, Json));
    }
    public MeetingSession Rename(MeetingSession session, string title)
    {
        lock (gate)
        {
            title = title.Trim();
            if (title.Length == 0) throw new ArgumentException("会议名称不能为空。");
            var old = DirectoryFor(session.Id);
            var next = UniqueDirectory(title, old);
            if (string.Equals(next, old, StringComparison.Ordinal) && session.Title == Path.GetFileName(next)) return session;
            if (!string.Equals(next, old, StringComparison.Ordinal))
            {
                if (string.Equals(next, old, StringComparison.OrdinalIgnoreCase))
                {
                    var temporary = old + ".rename-" + Guid.NewGuid().ToString("N");
                    Directory.Move(old, temporary);
                    try { Directory.Move(temporary, next); } catch { Directory.Move(temporary, old); throw; }
                }
                else Directory.Move(old, next);
                directories[session.Id] = next;
            }
            session.Title = Path.GetFileName(next);
            // Keep relative references portable after directory changes.
            session.SystemAudioURL = Basename(session.SystemAudioURL);
            session.MicrophoneAudioURL = Basename(session.MicrophoneAudioURL);
            session.MixedAudioURL = Basename(session.MixedAudioURL);
            session.TranscriptFileURL = Basename(session.TranscriptFileURL);
            session.SummaryFileURL = Basename(session.SummaryFileURL);
            session.FormattedDocumentFileURL = Basename(session.FormattedDocumentFileURL);
            session.DiarizationFileURL = Basename(session.DiarizationFileURL);
            session.UpdatedAt = DateTimeOffset.Now;
            Save(session);
            return session;
        }
    }
    public string MoveToTrash(Guid id)
    {
        lock (gate)
        {
            var trash = Path.Combine(Path.GetDirectoryName(root)!, "Trash");
            Directory.CreateDirectory(trash);
            var old = DirectoryFor(id);
            var target = Path.Combine(trash, Path.GetFileName(old) + "-" + id.ToString("N"));
            if (Directory.Exists(target)) target += "-" + DateTimeOffset.Now.ToUnixTimeMilliseconds();
            Directory.Move(old, target);
            directories.Remove(id);
            return target;
        }
    }
    public void SaveTranscript(Guid id, IReadOnlyList<TranscriptSegment> segments)
    {
        lock (gate)
        {
            var ordered = segments.OrderBy(x => x.StartTime).ThenBy(x => x.EndTime).ToArray();
            SaveDocument(id, "逐字稿.json", JsonSerializer.Serialize(ordered, Json));
            SaveDocument(id, "逐字稿.md", string.Join("\n\n", ordered.Select(s => $"### {s.Label}\n\n{s.NormalizedText ?? s.Text}")));
        }
    }
    public List<TranscriptSegment> LoadTranscript(Guid id)
    {
        var text = LoadDocument(id, "逐字稿.json");
        return text is null ? [] : JsonSerializer.Deserialize<List<TranscriptSegment>>(text, Json) ?? [];
    }
    public void SaveDocument(Guid id, string filename, string markdown)
    {
        if (Path.GetFileName(filename) != filename) throw new ArgumentException("只允许会议目录内的文件。");
        lock (gate) WriteIfChanged(Path.Combine(DirectoryFor(id), filename), markdown);
    }
    public string? LoadDocument(Guid id, string filename)
    {
        if (Path.GetFileName(filename) != filename) throw new ArgumentException("无效文件名称。");
        lock (gate)
        {
            var path = Path.Combine(DirectoryFor(id), filename);
            return File.Exists(path) ? File.ReadAllText(path) : null;
        }
    }
    public static bool WriteIfChanged(string path, string text)
    {
        var bytes = new UTF8Encoding(false).GetBytes(text);
        if (File.Exists(path) && File.ReadAllBytes(path).AsSpan().SequenceEqual(bytes)) return false;
        var temporary = path + ".tmp-" + Guid.NewGuid().ToString("N");
        try { File.WriteAllBytes(temporary, bytes); File.Move(temporary, path, true); }
        finally { if (File.Exists(temporary)) File.Delete(temporary); }
        return true;
    }
    public static string SafeTitle(string title)
    {
        var forbidden = "<>:\"/\\|?*";
        var safe = new string(title.Trim().Select(c => c < 32 || forbidden.Contains(c) ? '_' : c).ToArray()).TrimEnd(' ', '.');
        if (safe.Length > 100) safe = safe[..100].TrimEnd(' ', '.');
        if (string.IsNullOrWhiteSpace(safe)) safe = "未命名会议";
        var stem = safe.Split('.')[0];
        if (new[] { "CON", "PRN", "AUX", "NUL", "COM1", "COM2", "COM3", "COM4", "COM5", "COM6", "COM7", "COM8", "COM9", "LPT1", "LPT2", "LPT3", "LPT4", "LPT5", "LPT6", "LPT7", "LPT8", "LPT9" }.Contains(stem, StringComparer.OrdinalIgnoreCase)) safe = "_" + safe;
        return safe;
    }
    private string UniqueDirectory(string title, string? excluding = null)
    {
        var safe = SafeTitle(title);
        var candidate = Path.Combine(root, safe);
        for (var n = 2; Directory.Exists(candidate) && !string.Equals(candidate, excluding, StringComparison.OrdinalIgnoreCase); n++) candidate = Path.Combine(root, $"{safe} ({n})");
        return candidate;
    }
    private static string? Basename(string? path) => path is null ? null : Uri.UnescapeDataString(path).Replace('\\', '/').Split('/').Last();
}
