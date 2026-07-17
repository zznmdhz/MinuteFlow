@preconcurrency import AVFoundation
import Foundation

enum TestAudioFactoryError: LocalizedError {
    case unsupportedBuffer
    case emptyAudio

    var errorDescription: String? {
        switch self {
        case .unsupportedBuffer: "系统无法生成模型测试音频。"
        case .emptyAudio: "系统生成的模型测试音频为空。"
        }
    }
}

enum TestAudioFactory {
    static func makeSpeechWAV() async throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "MinuteFlow-ASR-Test-\(UUID().uuidString).wav")

        return try await withCheckedThrowingContinuation { continuation in
            let box = SpeechGenerationBox(url: url, continuation: continuation)
            let utterance = AVSpeechUtterance(string: "这是 MinuteFlow 语音识别连接测试")
            utterance.voice = AVSpeechSynthesisVoice(language: "zh-CN")
            utterance.rate = 0.48
            box.synthesizer.write(utterance) { buffer in
                box.consume(buffer)
            }
        }
    }
}

private final class SpeechGenerationBox: @unchecked Sendable {
    let synthesizer = AVSpeechSynthesizer()
    private let url: URL
    private var file: AVAudioFile?
    private var continuation: CheckedContinuation<URL, any Error>?
    private var wroteFrames = false

    init(url: URL, continuation: CheckedContinuation<URL, any Error>) {
        self.url = url
        self.continuation = continuation
    }

    func consume(_ audioBuffer: AVAudioBuffer) {
        guard let buffer = audioBuffer as? AVAudioPCMBuffer else {
            finish(.failure(TestAudioFactoryError.unsupportedBuffer))
            return
        }
        guard buffer.frameLength > 0 else {
            file = nil
            finish(wroteFrames ? .success(url) : .failure(TestAudioFactoryError.emptyAudio))
            return
        }
        do {
            if file == nil {
                file = try AVAudioFile(forWriting: url, settings: buffer.format.settings)
            }
            try file?.write(from: buffer)
            wroteFrames = true
        } catch {
            file = nil
            finish(.failure(error))
        }
    }

    private func finish(_ result: Result<URL, any Error>) {
        guard let continuation else { return }
        self.continuation = nil
        continuation.resume(with: result)
    }
}

