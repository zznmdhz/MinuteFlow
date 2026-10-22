@preconcurrency import AVFoundation
import Foundation

enum IncrementalTranscriptionChecks {
    @MainActor static func run() async throws -> Int {
        var count = 0
        func check(_ condition: Bool, _ message: String) {
            precondition(condition, message); count += 1; print("PASS: \(message)")
        }
        var decoder = ASRStreamDecoder()
        for line in [": keepalive", "event: message", "data: {\"choices\":[{\"delta\":{\"content\":\"你好\"}}]}", ""] {
            _ = try decoder.consume(line)
        }
        check(decoder.text == "你好" && !decoder.completed, "SSE exposes Chinese text before completion")
        for line in ["data: {\"choices\":[{\"delta\":{\"content\":\"，开会。\"}}]}", "", "data: [DONE]", ""] {
            _ = try decoder.consume(line)
        }
        check(decoder.text == "你好，开会。" && decoder.completed, "SSE assembles deltas without duplicate prefixes")
        var invalid = ASRStreamDecoder()
        var rejected = false
        do {
            _ = try invalid.consume("data: {\"choices\":[{\"finish_reason\":\"length\"}]}")
            _ = try invalid.consume("")
        } catch { rejected = true }
        check(rejected, "Truncated generation cannot become a completed sentence")

        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appending(path: ".build/incremental-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let writer = try WAVChunkWriter(directory: root)
        try writer.append(buffer(1.3)); writer.close()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StreamingCheckProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let client = RemoteASRClient(session: session)
        let received = LockedCheckValues<String>()
        let streamResult = try await client.transcribe(wavURL: writer.url, configuration: configuration("/sse")) { received.append($0) }
        check(streamResult == "我们开会。", "URLSession receives real incremental SSE bytes")
        check(received.values.contains("我") && received.values.last == "我们开会。", "First token reaches callback before later network chunks")
        let fallback = try await client.transcribe(wavURL: writer.url, configuration: configuration("/unsupported")) { _ in }
        check(fallback == "兼容结果", "Gateway rejecting stream falls back to existing audio request")
        let json = try await client.transcribe(wavURL: writer.url, configuration: configuration("/json")) { _ in }
        check(json == "兼容结果", "Gateway returning JSON to stream request remains supported")
        var streamFailed = false
        do { _ = try await client.transcribe(wavURL: writer.url, configuration: configuration("/truncated")) { _ in } }
        catch { streamFailed = true }
        check(streamFailed, "Dropped network stream never returns partial text as final")
        var authFailed = false
        do { _ = try await client.transcribe(wavURL: writer.url, configuration: configuration("/401")) { _ in } }
        catch RemoteModelError.server(let status, _) { authFailed = status == 401 }
        check(authFailed, "Authentication error is not disguised as unsupported streaming")

        let previews = LockedCheckValues<TranscriptSegment>()
        let finals = LockedCheckValues<TranscriptSegment>()
        let service = RemoteRealtimeTranscriptionService(client: PreviewCheckClient(), pendingDirectory: root.appending(path: "pending"))
        service.onPreview = { previews.append($0) }; service.onSegment = { finals.append($0) }
        try service.start(sessionID: UUID(), sources: [.microphone], configuration: configuration("/sse"), maximumChunkDuration: 10)
        service.append(CapturedAudioBuffer(buffer: try buffer(1.3), source: .microphone))
        try await Task.sleep(for: .milliseconds(150))
        check(!previews.values.isEmpty && finals.values.isEmpty, "1.2 second window starts replaceable text without finalizing")
        let firstEnd = previews.values.last!.endTime
        service.append(CapturedAudioBuffer(buffer: try buffer(1.6), source: .microphone))
        try await Task.sleep(for: .milliseconds(150))
        check(previews.values.last!.endTime > firstEnd, "Continuous speech refreshes preview more than once")
        check(Set(previews.values.map(\.id)).count == 1, "Growing previews replace the same paragraph rather than append duplicates")
        let completed = await service.finish()
        check(completed.count == 1 && completed.allSatisfy(\.isFinal), "Stop finalizes one sentence; previews never enter final results")
        let finalID = completed[0].id
        check(finalID == previews.values[0].id, "Final sentence keeps preview identity for in-place replacement")

        // Hold the first preview until after the final response. It must never
        // resurrect a completed draft or overwrite its corrected sentence.
        let latePreviews = LockedCheckValues<TranscriptSegment>()
        let lateFinals = LockedCheckValues<TranscriptSegment>()
        let late = RemoteRealtimeTranscriptionService(client: PreviewCheckClient(slowPreview: true))
        late.onPreview = { latePreviews.append($0) }; late.onSegment = { lateFinals.append($0) }
        try late.start(sessionID: UUID(), sources: [.microphone], configuration: configuration("/sse"), maximumChunkDuration: 10)
        late.append(CapturedAudioBuffer(buffer: try buffer(1.3), source: .microphone))
        try await Task.sleep(for: .milliseconds(30))
        late.append(CapturedAudioBuffer(buffer: try buffer(0.8, amplitude: 0), source: .microphone))
        try await Task.sleep(for: .milliseconds(180))
        check(lateFinals.values.count == 1, "Natural pause finalizes while older preview is still in flight")
        let draftsBefore = latePreviews.values.count
        try await Task.sleep(for: .milliseconds(300))
        check(latePreviews.values.count == draftsBefore, "Late preview cannot revive an already finalized sentence")
        _ = await late.finish()
        return count
    }

    private static func configuration(_ path: String) -> ASRConfiguration {
        ASRConfiguration(transport: .miMoChatAudio, endpoint: URL(string: "https://stream.synthetic.invalid\(path)")!, model: "synthetic-asr", apiKey: "synthetic-token", language: "zh")
    }
    static func buffer(_ duration: Double, amplitude: Float = 0.4) throws -> AVAudioPCMBuffer {
        let format = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
        let frames = AVAudioFrameCount(duration * 16000)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        for i in 0..<Int(frames) { buffer.floatChannelData![0][i] = amplitude * sin(Float(i) * 0.08) }
        return buffer
    }
}

private final class LockedCheckValues<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock(); private var storage: [T] = []
    func append(_ value: T) { lock.withLock { storage.append(value) } }
    var values: [T] { lock.withLock { storage } }
}

private struct PreviewCheckClient: ASRClient {
    var slowPreview = false
    func transcribe(wavURL: URL, configuration: ASRConfiguration) async throws -> String { "最终结果" }
    func transcribe(wavURL: URL, configuration: ASRConfiguration, onPartial: @escaping @Sendable (String) -> Void) async throws -> String {
        let file = try AVAudioFile(forReading: wavURL)
        let duration = Double(file.length) / file.processingFormat.sampleRate
        if slowPreview && duration < 1.5 { try await Task.sleep(for: .milliseconds(400)) }
        onPartial("我")
        try await Task.sleep(for: .milliseconds(10))
        let text = "我们正在开会。\(Int(duration * 10))"
        onPartial(text); return text
    }
}

private final class StreamingCheckProtocol: URLProtocol, @unchecked Sendable {
    private let state = NSLock()
    private var stopped = false
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "stream.synthetic.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() { state.withLock { stopped = true } }
    override func startLoading() {
        let path = request.url!.path
        let wantsStream = (try? JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any])?["stream"] as? Bool ?? false
        let status = path == "/401" ? 401 : (path == "/unsupported" && wantsStream ? 400 : 200)
        let isJSON = path == "/json" || path == "/unsupported" || status != 200
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": isJSON ? "application/json" : "text/event-stream"])!, cacheStoragePolicy: .notAllowed)
        if isJSON {
            client?.urlProtocol(self, didLoad: Data(#"{"text":"兼容结果"}"#.utf8)); client?.urlProtocolDidFinishLoading(self); return
        }
        send("data: {\"choices\":[{\"delta\":{\"content\":\"我\"}}]}\n\n")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.15) { [self] in
            guard !state.withLock({ stopped }) else { return }
            send("data: {\"choices\":[{\"delta\":{\"content\":\"们开会。\"}}]}\n\n")
            if path != "/truncated" { send("data: [DONE]\n\n") }
            client?.urlProtocolDidFinishLoading(self)
        }
    }
    private func send(_ text: String) { client?.urlProtocol(self, didLoad: Data(text.utf8)) }
}
