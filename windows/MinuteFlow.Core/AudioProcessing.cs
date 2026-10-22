using System.Text;

namespace MinuteFlow.Core;

public static class WavePcm
{
    public static byte[] Encode16Bit(float[] mono, int sampleRate)
    {
        if (sampleRate <= 0) throw new ArgumentOutOfRangeException(nameof(sampleRate));
        using var stream = new MemoryStream(44 + mono.Length * 2);
        using var writer = new BinaryWriter(stream, Encoding.ASCII, true);
        writer.Write(Encoding.ASCII.GetBytes("RIFF")); writer.Write(36 + mono.Length * 2); writer.Write(Encoding.ASCII.GetBytes("WAVEfmt "));
        writer.Write(16); writer.Write((short)1); writer.Write((short)1); writer.Write(sampleRate); writer.Write(sampleRate * 2); writer.Write((short)2); writer.Write((short)16);
        writer.Write(Encoding.ASCII.GetBytes("data")); writer.Write(mono.Length * 2);
        foreach (var sample in mono) writer.Write((short)(Math.Clamp(sample, -1f, 1f) * 32767));
        return stream.ToArray();
    }
    public static double Rms(ReadOnlySpan<float> samples)
    {
        if (samples.IsEmpty) return 0;
        double sum = 0; foreach (var value in samples) sum += value * value;
        return Math.Sqrt(sum / samples.Length);
    }
}

public sealed class SilenceGuard
{
    private readonly TimeSpan timeout;
    private TimeSpan lastSound;
    public SilenceGuard(TimeSpan timeout) { this.timeout = timeout; }
    public void Observe(double rms, TimeSpan elapsed) { if (double.IsFinite(rms) && rms >= 0.007 && elapsed > lastSound) lastSound = elapsed; }
    public bool ShouldPause(TimeSpan elapsed) => timeout > TimeSpan.Zero && elapsed - lastSound >= timeout;
    public void Reset(TimeSpan elapsed) { lastSound = elapsed; }
}

public sealed record SpeechChunk(float[] Samples, int SampleRate, double StartTime, double EndTime, bool IsPreview = false, string BoundaryReason = "naturalPause", double OverlapBefore = 0);

/// A bounded, pause-sensitive window. Only speech and 450 ms context are retained;
/// prolonged silence does not grow the buffer or generate empty API requests.
public sealed class SpeechSegmenter
{
    private readonly List<float> samples = [];
    private readonly Queue<float> preRoll = new();
    private int rate;
    private double start;
    private double silence;
    private double previewAt;
    private double noiseFloor;
    private readonly double minimumSpeechEnergy;
    private double overlapBefore;
    public SpeechSegmenter(double minimumSpeechEnergy = 0.006) { this.minimumSpeechEnergy = minimumSpeechEnergy; noiseFloor = minimumSpeechEnergy / 3; }
    public IReadOnlyList<SpeechChunk> Push(float[] mono, int sampleRate, double startTime, bool flush = false)
    {
        if (sampleRate <= 0) throw new ArgumentOutOfRangeException(nameof(sampleRate));
        if (rate != 0 && rate != sampleRate) throw new ArgumentException("切片采样率必须保持一致。");
        rate = sampleRate;
        var output = new List<SpeechChunk>();
        const double blockSeconds = 0.02;
        var blockLength = Math.Max(1, (int)(sampleRate * blockSeconds));
        for (var offset = 0; offset < mono.Length; offset += blockLength)
        {
            var count = Math.Min(blockLength, mono.Length - offset);
            var block = mono.AsSpan(offset, count);
            var energy = WavePcm.Rms(block);
            var speaking = energy > Math.Max(minimumSpeechEnergy, noiseFloor * 2.8);
            if (!speaking) noiseFloor = Math.Clamp(noiseFloor * 0.997 + energy * 0.003, 0.0003, 0.012);
            var currentTime = startTime + (double)offset / sampleRate;
            if (samples.Count == 0)
            {
                if (!speaking)
                {
                    foreach (var sample in block) preRoll.Enqueue(sample);
                    while (preRoll.Count > sampleRate * 0.45) preRoll.Dequeue();
                    continue;
                }
                start = Math.Max(0, currentTime - (double)preRoll.Count / sampleRate);
                samples.AddRange(preRoll); preRoll.Clear(); previewAt = 1.2; silence = 0; overlapBefore = 0;
            }
            foreach (var sample in block) samples.Add(sample);
            silence = speaking ? 0 : silence + (double)count / sampleRate;
            var duration = (double)samples.Count / sampleRate;
            if (silence >= 0.7 || duration >= 15)
            {
                if (duration >= 0.35) output.Add(new SpeechChunk(samples.ToArray(), rate, start, start + duration, false, silence >= 0.7 ? "naturalPause" : "forcedHardLimit", overlapBefore));
                var overlap = silence < 0.7 ? samples.TakeLast((int)(rate * 0.45)).ToArray() : [];
                samples.Clear(); samples.AddRange(overlap); start = currentTime + (double)count / sampleRate - (double)overlap.Length / rate; overlapBefore = (double)overlap.Length / rate; silence = 0; previewAt = 1.2;
            }
            else if (duration >= previewAt)
            {
                output.Add(new SpeechChunk(samples.ToArray(), rate, start, start + duration, true));
                previewAt += 1.5;
            }
        }
        if (flush && samples.Count > 0)
        {
            if (samples.Count > rate * overlapBefore + rate * 0.1) output.Add(new SpeechChunk(samples.ToArray(), rate, start, start + (double)samples.Count / rate, false, "recordingStopped", overlapBefore));
            samples.Clear(); silence = 0;
        }
        return output;
    }
    public void Reset() { samples.Clear(); preRoll.Clear(); rate = 0; silence = 0; overlapBefore = 0; }
}

public static class TranscriptEditing
{
    public static string Normalize(string text) => System.Text.RegularExpressions.Regex.Replace(text.Trim(), @"[ \t]+", " ").Replace(" ,", ",").Replace(" .", ".").Replace(" ，", "，").Replace(" 。", "。");
    public static string RemoveOverlap(string previous, string next)
    {
        for (var n = Math.Min(120, Math.Min(previous.Length, next.Length)); n >= 4; n--)
            if (previous.EndsWith(next[..n], StringComparison.Ordinal)) return next[n..].TrimStart();
        return next;
    }
    public static void AppendOrMerge(List<TranscriptSegment> segments, TranscriptSegment next)
    {
        var previous = segments.LastOrDefault(s => s.Source == next.Source && s.IsFinal && s.EndTime <= next.StartTime + 0.6);
        if (previous is not null && next.StartTime - previous.EndTime < 1 && previous.SpeakerID == next.SpeakerID && previous.Text.Length < 1200 && next.EndTime - previous.StartTime < 40 && !previous.UserEdited && previous.Text == previous.OriginalText)
        {
            var remainder = RemoveOverlap(previous.Text, next.Text);
            if (remainder.Length > 0) previous.Text += (char.IsAsciiLetterOrDigit(previous.Text.LastOrDefault()) && char.IsAsciiLetterOrDigit(remainder[0]) ? " " : "") + remainder;
            previous.EndTime = Math.Max(previous.EndTime, next.EndTime);
            previous.OriginalText = previous.Text;
            previous.RecognitionFragments ??= []; if (next.RecognitionFragments is not null) previous.RecognitionFragments.AddRange(next.RecognitionFragments);
        }
        else segments.Add(next);
        segments.Sort((a, b) => a.StartTime.CompareTo(b.StartTime));
    }
}

public sealed record SpeakerTurn(double StartTime, double EndTime, string SpeakerID, string Source)
{
    public Guid Id { get; init; } = Guid.NewGuid();
    public float Confidence { get; init; } = 0.55f;
}
/// Local acoustic clustering, not voice identity recognition. Source tracks have
/// independent clusters; labels are approximate and remain editable by the user.
public sealed class SpeakerClusterer
{
    private readonly List<double[]> centroids = [];
    public string Analyze(ReadOnlySpan<float> audio, int rate)
    {
        var feature = Feature(audio, rate);
        if (feature is null) return "speaker-1";
        var distances = centroids.Select(c => Math.Sqrt(c.Zip(feature, (x, y) => (x - y) * (x - y)).Sum())).ToArray();
        var best = distances.Length == 0 ? -1 : Array.IndexOf(distances, distances.Min());
        if (best == -1 || distances[best] > 0.75 && centroids.Count < 8) { centroids.Add(feature); best = centroids.Count - 1; }
        else for (var i = 0; i < feature.Length; i++) centroids[best][i] = centroids[best][i] * 0.9 + feature[i] * 0.1;
        return "speaker-" + (best + 1);
    }
    private static double[]? Feature(ReadOnlySpan<float> audio, int rate)
    {
        if (audio.Length < rate / 3 || WavePcm.Rms(audio) < 0.0015) return null;
        var n = Math.Min(audio.Length, rate * 3);
        double crossing = 0, rms = 0;
        for (var i = 1; i < n; i++) { if ((audio[i] >= 0) != (audio[i - 1] >= 0)) crossing++; rms += audio[i] * audio[i]; }
        // Autocorrelation pitch plus spectral band balance, amplitude normalized.
        var step = Math.Max(1, rate / 8000);
        double best = 0; var lagAt = rate / 180;
        for (var lag = rate / 350; lag < rate / 70; lag += step)
        {
            double corr = 0, energy = 0;
            for (var i = lag; i < n; i += step) { corr += audio[i] * audio[i - lag]; energy += audio[i] * audio[i]; }
            var normalized = energy > 0 ? corr / energy : 0;
            if (normalized > best) { best = normalized; lagAt = lag; }
        }
        var bands = new[] { 250d, 500, 1000, 2000, 3000 };
        var powers = new double[bands.Length];
        for (var b = 0; b < bands.Length; b++)
        {
            var coefficient = 2 * Math.Cos(2 * Math.PI * bands[b] / rate); double q1 = 0, q2 = 0;
            for (var i = 0; i < Math.Min(n, 2048); i++) { var q = audio[i] + coefficient * q1 - q2; q2 = q1; q1 = q; }
            powers[b] = Math.Log(1 + Math.Max(0, q1 * q1 + q2 * q2 - coefficient * q1 * q2) / Math.Max(0.0000001, rms / n));
        }
        var sum = Math.Max(0.001, powers.Sum());
        return new[] { Math.Log((double)rate / lagAt / 100), crossing / n * 4, best }.Concat(powers.Select(p => p / sum * 2)).ToArray();
    }
}
