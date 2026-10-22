using System.Text.Json;

namespace MinuteFlow.Core;

public sealed class ASRStreamDecoder
{
    private readonly List<string> data = [];
    private int eventLength;
    public string Text { get; private set; } = "";
    public bool Completed { get; private set; }
    public string? Consume(string line)
    {
        if (Completed) return null;
        if (line.Length == 0)
        {
            if (data.Count == 0) return null;
            var payload = string.Join("\n", data); data.Clear(); eventLength = 0;
            if (payload == "[DONE]") { Completed = true; return Text; }
            using var json = JsonDocument.Parse(payload);
            var root = json.RootElement;
            if (root.TryGetProperty("error", out _)) throw new InvalidDataException("识别流返回错误，未将临时文字定稿。");
            if (!root.TryGetProperty("choices", out var choices) || choices.GetArrayLength() == 0) return null;
            var first = choices[0];
            if (first.TryGetProperty("finish_reason", out var reason) && reason.ValueKind == JsonValueKind.String)
            {
                if (reason.GetString() != "stop") throw new InvalidDataException("识别流未正常完成，原音频保留供补全。");
                Completed = true;
            }
            if (first.TryGetProperty("delta", out var delta) && delta.TryGetProperty("content", out var content) && content.ValueKind == JsonValueKind.String) Text += content.GetString();
            if (Text.Length > 1_000_000) throw new InvalidDataException("识别流超过安全长度。");
            return Text.Length == 0 ? null : Text;
        }
        if (line.StartsWith("data:", StringComparison.Ordinal))
        {
            var value = line[5..]; if (value.StartsWith(' ')) value = value[1..];
            eventLength += value.Length;
            if (eventLength > 500_000) throw new InvalidDataException("识别流事件超过安全长度。");
            data.Add(value);
        }
        return null;
    }
}
