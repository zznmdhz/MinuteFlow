using System.Net;
using System.Net.Http.Headers;
using System.Text;
using System.Text.Json;

namespace MinuteFlow.Core;

public sealed class ModelClient
{
    private readonly HttpClient http;
    public ModelClient(HttpClient http) { this.http = http; }
    public static Uri Endpoint(string baseUrl, string suffix)
    {
        var value = baseUrl.Trim().TrimEnd('/');
        foreach (var ending in new[] { "/audio/transcriptions", "/chat/completions", "/models" })
            if (value.EndsWith(ending, StringComparison.OrdinalIgnoreCase)) value = value[..^ending.Length];
        if (!Uri.TryCreate(value + "/" + suffix, UriKind.Absolute, out var endpoint) || endpoint.Scheme != "https") throw new ArgumentException("请输入 HTTPS 服务地址。");
        return endpoint;
    }
    public Task<string> TranscribeLiveAsync(byte[] wav, ModelConfiguration configuration, Action<string> onPartial, CancellationToken cancellationToken = default)
        => TranscribeAsync(wav, configuration, cancellationToken, onPartial);

    public async Task<string> TranscribeAsync(byte[] wav, ModelConfiguration configuration, CancellationToken cancellationToken = default, Action<string>? onPartial = null)
    {
        if (!configuration.IsConfigured) throw new InvalidOperationException("请先保存服务地址、Token 和语音模型名称。");
        using var request = new HttpRequestMessage(HttpMethod.Post, Endpoint(configuration.BaseUrl, configuration.UsesMiMo ? "chat/completions" : "audio/transcriptions"));
        Authenticate(request, configuration.Token);
        if (configuration.UsesMiMo)
        {
            var payload = new { model = configuration.AsrModel, messages = new[] { new { role = "user", content = new[] { new { type = "input_audio", input_audio = new { data = "data:audio/wav;base64," + Convert.ToBase64String(wav) } } } } }, asr_options = new { language = NormalizeLanguage(configuration.Language) }, stream = onPartial is not null };
            request.Content = new StringContent(JsonSerializer.Serialize(payload), Encoding.UTF8, "application/json");
        }
        else
        {
            var multipart = new MultipartFormDataContent();
            multipart.Add(new StringContent(configuration.AsrModel), "model");
            if (configuration.Language != "auto") multipart.Add(new StringContent(NormalizeLanguage(configuration.Language)), "language");
            var audio = new ByteArrayContent(wav);
            audio.Headers.ContentType = new MediaTypeHeaderValue("audio/wav");
            multipart.Add(audio, "file", "speech.wav");
            request.Content = multipart;
        }
        if (configuration.UsesMiMo && onPartial is not null)
        {
            try { return await PerformStreamingAsync(request, onPartial, cancellationToken); }
            catch (HttpRequestException error) when (error.StatusCode is HttpStatusCode.BadRequest or HttpStatusCode.NotFound or HttpStatusCode.UnsupportedMediaType or HttpStatusCode.UnprocessableEntity or HttpStatusCode.NotImplemented)
            {
                // Compatible gateways may not implement streaming. Never retry
                // 401/403/429 or dropped streams as a silent protocol downgrade.
                return await TranscribeAsync(wav, configuration, cancellationToken);
            }
        }
        return await PerformAsync(request, configuration.Token, cancellationToken);
    }
    private async Task<string> PerformStreamingAsync(HttpRequestMessage request, Action<string> onPartial, CancellationToken token)
    {
        using var response = await http.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, token);
        if (!response.IsSuccessStatusCode) throw new HttpRequestException($"识别流请求失败（{(int)response.StatusCode}），请检查模型、权限或额度。", null, response.StatusCode);
        if (!string.Equals(response.Content.Headers.ContentType?.MediaType, "text/event-stream", StringComparison.OrdinalIgnoreCase))
        {
            var text = ParseText(await response.Content.ReadAsStringAsync(token));
            if (text.Length == 0) throw new InvalidDataException("识别服务未返回文字。");
            onPartial(text); return text;
        }
        using var stream = await response.Content.ReadAsStreamAsync(token);
        using var reader = new StreamReader(stream, Encoding.UTF8);
        var parser = new ASRStreamDecoder();
        var watch = System.Diagnostics.Stopwatch.StartNew(); long last = -1000;
        while (await reader.ReadLineAsync(token) is { } line)
        {
            token.ThrowIfCancellationRequested();
            if (parser.Consume(line) is { Length: > 0 } text && watch.ElapsedMilliseconds - last >= 60)
            {
                onPartial(text); last = watch.ElapsedMilliseconds;
            }
            if (parser.Completed) break;
        }
        if (!parser.Completed) throw new InvalidDataException("识别流意外中断，临时文字未定稿，可事后补全。");
        if (parser.Text.Length == 0) throw new InvalidDataException("识别服务未返回文字。");
        onPartial(parser.Text); return parser.Text;
    }
    public async Task<string> CompleteAsync(string system, string text, ModelConfiguration configuration, CancellationToken cancellationToken = default)
    {
        if (string.IsNullOrWhiteSpace(configuration.Token) || string.IsNullOrWhiteSpace(configuration.TextModel)) throw new InvalidOperationException("请先设置文本模型和 Token。");
        using var request = new HttpRequestMessage(HttpMethod.Post, Endpoint(configuration.BaseUrl, "chat/completions"));
        Authenticate(request, configuration.Token);
        request.Content = new StringContent(JsonSerializer.Serialize(new { model = configuration.TextModel, messages = new[] { new { role = "system", content = system }, new { role = "user", content = text } }, stream = false }), Encoding.UTF8, "application/json");
        return await PerformAsync(request, configuration.Token, cancellationToken);
    }
    public async Task<string> SummarizeLongAsync(string transcript, ModelConfiguration configuration, bool formatDocument, CancellationToken cancellationToken = default)
    {
        var prompt = formatDocument
            ? "将逐字稿整理成完整 Markdown 文稿：按主题分章节、补充标点、保留信息与事实。不增加原文未明确的结论，不将未确认事项写成事实。"
            : "根据逐字稿生成 Markdown 会议纪要，含概述、议题、讨论、已确认结论、待办表格、风险与待确认事项。不得编造负责人和截止日期，未明确写待确认。";
        const int chunkSize = 16000;
        if (transcript.Length <= chunkSize) return await CompleteAsync(prompt, transcript, configuration, cancellationToken);
        var parts = new List<string>();
        for (var offset = 0; offset < transcript.Length; offset += chunkSize)
        {
            cancellationToken.ThrowIfCancellationRequested();
            var piece = transcript.Substring(offset, Math.Min(chunkSize, transcript.Length - offset));
            parts.Add(await CompleteAsync(prompt + "这是较长会议的一部分，请保留这部分全部关键内容。", piece, configuration, cancellationToken));
        }
        var joined = string.Join("\n\n", parts);
        // Never send a second unbounded request. Large results remain an ordered
        // full document rather than silently dropping late meeting content.
        return joined.Length <= 24000 ? await CompleteAsync(prompt + "整合下列各部分，去除重复，保持事实及待确认标记。", joined, configuration, cancellationToken) : joined;
    }
    public static string ParseText(string json)
    {
        using var document = JsonDocument.Parse(json);
        var root = document.RootElement;
        if (root.TryGetProperty("text", out var direct) && direct.ValueKind == JsonValueKind.String) return direct.GetString()?.Trim() ?? "";
        if (root.TryGetProperty("choices", out var choices) && choices.GetArrayLength() > 0 && choices[0].TryGetProperty("message", out var message) && message.TryGetProperty("content", out var content))
        {
            if (content.ValueKind == JsonValueKind.String) return content.GetString()?.Trim() ?? "";
            if (content.ValueKind == JsonValueKind.Array) return string.Join("", content.EnumerateArray().Where(x => x.TryGetProperty("text", out _)).Select(x => x.GetProperty("text").GetString())).Trim();
        }
        throw new InvalidDataException("服务返回了无法识别的文字响应。");
    }
    private static void Authenticate(HttpRequestMessage request, string token)
    {
        if (request.RequestUri!.Host.Equals("xiaomimimo.com", StringComparison.OrdinalIgnoreCase) || request.RequestUri.Host.EndsWith(".xiaomimimo.com", StringComparison.OrdinalIgnoreCase)) request.Headers.TryAddWithoutValidation("api-key", token);
        else request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);
    }
    private static string NormalizeLanguage(string language) => language.ToLowerInvariant() switch { "zh-cn" or "zh" => "zh", "en-us" or "en" => "en", _ => "auto" };
    private async Task<string> PerformAsync(HttpRequestMessage request, string token, CancellationToken cancellationToken)
    {
        var payload = request.Content is null ? null : await request.Content.ReadAsByteArrayAsync(cancellationToken);
        for (var attempt = 0; ; attempt++)
        {
            cancellationToken.ThrowIfCancellationRequested();
            using var outgoing = new HttpRequestMessage(request.Method, request.RequestUri);
            foreach (var header in request.Headers) outgoing.Headers.TryAddWithoutValidation(header.Key, header.Value);
            if (payload is not null)
            {
                outgoing.Content = new ByteArrayContent(payload);
                foreach (var header in request.Content!.Headers) outgoing.Content.Headers.TryAddWithoutValidation(header.Key, header.Value);
            }
            using var response = await http.SendAsync(outgoing, HttpCompletionOption.ResponseHeadersRead, cancellationToken);
            var body = await response.Content.ReadAsStringAsync(cancellationToken);
            if (((int)response.StatusCode == 429 || (int)response.StatusCode >= 500) && attempt < 2)
            {
                await Task.Delay(TimeSpan.FromSeconds(attempt + 1), cancellationToken); continue;
            }
            if (!response.IsSuccessStatusCode)
            {
                string message;
                try { using var d = JsonDocument.Parse(body); message = d.RootElement.GetProperty("error").GetProperty("message").GetString() ?? ""; }
                catch { message = "模型服务拒绝请求，请检查地址、模型、权限和额度。"; }
                message = message.Replace(token, "[Token]");
                if (message.Length > 240) message = message[..240];
                throw new HttpRequestException($"模型调用失败（{(int)response.StatusCode}）：{message}", null, response.StatusCode);
            }
            return ParseText(body);
        }
    }
}
