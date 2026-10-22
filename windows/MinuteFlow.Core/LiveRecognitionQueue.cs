namespace MinuteFlow.Core;

public sealed record LiveRecognitionJob(string Source, SpeechChunk Chunk);

/// Final audio is FIFO and bounded; previews coalesce to the newest window.
/// One in-flight preview per source prevents slow servers accumulating drafts.
public sealed class LiveRecognitionQueue
{
    private readonly object gate = new();
    private readonly Queue<LiveRecognitionJob> finals = new();
    private readonly Dictionary<string, LiveRecognitionJob> previews = new();
    private readonly HashSet<string> activePreviews = [];
    private readonly SemaphoreSlim signal = new(0);
    private bool completed;
    public bool Enqueue(LiveRecognitionJob job)
    {
        lock (gate)
        {
            if (completed) return false;
            if (job.Chunk.IsPreview) previews[job.Source] = job;
            else
            {
                previews.Remove(job.Source);
                if (finals.Count >= 48) return false;
                finals.Enqueue(job);
            }
        }
        signal.Release(); return true;
    }
    public async Task<LiveRecognitionJob?> TakeAsync(CancellationToken token)
    {
        while (true)
        {
            lock (gate)
            {
                if (finals.TryDequeue(out var final)) return final;
                foreach (var (source, preview) in previews)
                {
                    if (activePreviews.Contains(source)) continue;
                    previews.Remove(source); activePreviews.Add(source); return preview;
                }
                if (completed) return null;
            }
            await signal.WaitAsync(token);
        }
    }
    public void Finished(LiveRecognitionJob job)
    {
        lock (gate) { if (job.Chunk.IsPreview) activePreviews.Remove(job.Source); }
        signal.Release(3);
    }
    public void Complete()
    {
        lock (gate) { completed = true; previews.Clear(); }
        signal.Release(3);
    }
}
