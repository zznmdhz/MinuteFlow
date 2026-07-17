import Combine
import Foundation

enum DiagnosticState: Equatable, Sendable {
    case idle(String)
    case testing(String)
    case success(String)
    case failure(String)

    var message: String {
        switch self {
        case .idle(let message), .testing(let message), .success(let message), .failure(let message): message
        }
    }
}

@MainActor
final class AIConnectionDiagnostics: ObservableObject {
    @Published private(set) var configurationState: DiagnosticState = .idle("尚未测试")
    @Published private(set) var asrState: DiagnosticState = .idle("尚未测试")
    @Published private(set) var summaryState: DiagnosticState = .idle("尚未测试")
    @Published private(set) var isRunning = false
    @Published private(set) var lastTestDate: Date?

    private let asrClient = RemoteASRClient()
    private let summaryClient = RemoteSummaryClient()

    func testAll(settings: ModelSettingsStore) async {
        guard !isRunning else { return }
        isRunning = true
        defer {
            isRunning = false
            lastTestDate = Date()
        }

        guard
            settings.connectionIsConfigured,
            let asrEndpoint = settings.resolvedASREndpoint,
            let summaryEndpoint = settings.resolvedSummaryEndpoint
        else {
            configurationState = .failure("Base URL 或 API Key 不完整")
            asrState = .idle("等待有效配置")
            summaryState = .idle("等待有效配置")
            return
        }

        configurationState = .success("\(settings.detectedASRTransport.title) · \(settings.resolvedBaseURL?.host ?? "")")

        if settings.asrEnabled {
            asrState = .testing("正在生成并识别测试语音…")
            let startedAt = ContinuousClock.now
            var testAudioURL: URL?
            do {
                let url = try await TestAudioFactory.makeSpeechWAV()
                testAudioURL = url
                let text = try await asrClient.transcribe(
                    wavURL: url,
                    configuration: ASRConfiguration(
                        transport: settings.detectedASRTransport,
                        endpoint: asrEndpoint,
                        model: settings.asrModel,
                        apiKey: settings.apiKey,
                        language: settings.transcriptionLanguage
                    )
                )
                let elapsed = startedAt.duration(to: .now)
                asrState = .success("\(text) · \(Self.durationText(elapsed))")
            } catch {
                asrState = .failure(error.localizedDescription)
            }
            if let testAudioURL { try? FileManager.default.removeItem(at: testAudioURL) }
        } else {
            asrState = .idle("语音识别已关闭")
        }

        if settings.summaryEnabled {
            guard settings.summaryIsConfigured else {
                summaryState = .failure("请填写总结模型名称")
                return
            }
            summaryState = .testing("正在调用总结模型…")
            let startedAt = ContinuousClock.now
            do {
                let result = try await summaryClient.summarize(
                    title: "连接测试",
                    segments: [
                        TranscriptSegment(
                            startTime: 0,
                            endTime: 1,
                            text: "这是一段用于测试模型连接的会议逐字稿。",
                            source: .mixed,
                            isFinal: true
                        )
                    ],
                    configuration: SummaryConfiguration(
                        endpoint: summaryEndpoint,
                        model: settings.summaryModel,
                        apiKey: settings.apiKey,
                        prompt: "只回复：总结模型连接成功"
                    )
                )
                let elapsed = startedAt.duration(to: .now)
                summaryState = .success("\(result.prefix(80)) · \(Self.durationText(elapsed))")
            } catch {
                summaryState = .failure(error.localizedDescription)
            }
        } else {
            summaryState = .idle("会议总结未启用")
        }
    }

    private static func durationText(_ duration: Duration) -> String {
        let components = duration.components
        let seconds = Double(components.seconds) + Double(components.attoseconds) / 1e18
        return String(format: "%.1f 秒", seconds)
    }
}

