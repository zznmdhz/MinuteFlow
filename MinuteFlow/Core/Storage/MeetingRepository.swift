import Foundation

protocol MeetingRepository {
    func createSession(title: String, sourceSelection: AudioSourceSelection) throws -> MeetingSession
    func save(_ session: MeetingSession) throws
    func renameSession(_ session: MeetingSession, to title: String) throws -> MeetingSession
    func loadRecentSessions() throws -> [MeetingSession]
    func deleteSession(id: UUID) throws
    func saveTranscript(_ segments: [TranscriptSegment], sessionID: UUID) throws -> URL
    func loadTranscript(sessionID: UUID) throws -> [TranscriptSegment]
    func saveSummary(_ markdown: String, sessionID: UUID) throws -> URL
    func loadSummary(sessionID: UUID) throws -> String?
    func saveFormattedDocument(_ markdown: String, sessionID: UUID) throws -> URL
    func loadFormattedDocument(sessionID: UUID) throws -> String?
    func saveDiarization(_ result: SpeakerDiarizationResult, sessionID: UUID) throws -> URL
    func loadDiarization(sessionID: UUID) throws -> SpeakerDiarizationResult?
    func sessionDirectory(for id: UUID) -> URL
    func transcriptMarkdownURL(for id: UUID) -> URL
    func summaryMarkdownURL(for id: UUID) -> URL
    func formattedDocumentURL(for id: UUID) -> URL
    func diarizationURL(for id: UUID) -> URL
    func mixedAudioURL(for id: UUID) -> URL
    func mixManifestURL(for id: UUID) -> URL
    func saveMixManifest(_ manifest: AudioMixTimelineManifest, sessionID: UUID) throws -> URL
    func loadMixManifest(sessionID: UUID) throws -> AudioMixTimelineManifest?
}

/// One meeting equals one readable, flat folder. UUID folders from earlier
/// versions are migrated on load while hidden metadata preserves the stable ID.
struct LocalMeetingRepository: MeetingRepository {
    private static let metadataName = ".minuteflow-session.json"
    private static let legacyMetadataName = "metadata.json"

    private let rootDirectory: URL
    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(rootDirectory: URL? = nil, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        if let rootDirectory {
            self.rootDirectory = rootDirectory
        } else {
            let applicationSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            let standardDirectory = applicationSupport.appending(path: "MinuteFlow/Sessions", directoryHint: .isDirectory)
            let legacySandboxDirectory = fileManager.homeDirectoryForCurrentUser.appending(
                path: "Library/Containers/com.minuteflow.app/Data/Library/Application Support/MinuteFlow/Sessions",
                directoryHint: .isDirectory
            )
            self.rootDirectory = fileManager.fileExists(atPath: legacySandboxDirectory.path)
                ? legacySandboxDirectory : standardDirectory
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    func createSession(title: String, sourceSelection: AudioSourceSelection) throws -> MeetingSession {
        try fileManager.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
        let directory = uniqueDirectory(for: title)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let now = Date()
        var session = MeetingSession(
            id: UUID(), title: directory.lastPathComponent, sourceSelection: sourceSelection,
            startTime: now, duration: 0, recordingStatus: .preparing,
            createdAt: now, updatedAt: now
        )
        let prefix = Self.fileDateFormatter.string(from: now)
        if sourceSelection.systemAudioEnabled {
            session.systemAudioURL = directory.appending(path: "\(prefix)_系统声音.m4a")
        }
        if sourceSelection.microphoneEnabled {
            session.microphoneAudioURL = directory.appending(path: "\(prefix)_麦克风.m4a")
        }
        try writeMetadata(session, in: directory)
        return session
    }

    func save(_ session: MeetingSession) throws {
        try writeMetadata(session, in: sessionDirectory(for: session.id))
    }

    func renameSession(_ original: MeetingSession, to title: String) throws -> MeetingSession {
        let oldDirectory = sessionDirectory(for: original.id)
        let newDirectory = uniqueDirectory(for: title, excluding: oldDirectory)
        var session = original
        if newDirectory.standardizedFileURL != oldDirectory.standardizedFileURL {
            try fileManager.moveItem(at: oldDirectory, to: newDirectory)
            session = relocatingURLs(in: session, from: oldDirectory, to: newDirectory)
        }
        session.title = newDirectory.lastPathComponent
        session.updatedAt = Date()
        try writeMetadata(session, in: newDirectory)
        return session
    }

    func loadRecentSessions() throws -> [MeetingSession] {
        guard fileManager.fileExists(atPath: rootDirectory.path) else { return [] }
        let entries = try fileManager.contentsOfDirectory(
            at: rootDirectory, includingPropertiesForKeys: [.isDirectoryKey], options: []
        )
        var sessions: [MeetingSession] = []
        for entry in entries where (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            guard var session = decodeSession(in: entry) else { continue }
            session = (try? migrateToReadableFlatLayout(session, from: entry)) ?? session
            if session.recordingStatus.isActive {
                session.recordingStatus = .interrupted
                session.endTime = session.endTime ?? session.updatedAt
                session.updatedAt = Date()
                try? save(session)
            }
            if session.mixState == .queued || session.mixState == .processing {
                let recovered = mixedAudioURL(for: session.id)
                let attributes = try? fileManager.attributesOfItem(atPath: recovered.path)
                let size = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
                if size > 0 {
                    session.mixedAudioURL = recovered
                    session.mixState = .ready
                    session.mixMessage = "已恢复上次完成但尚未来得及登记的完整回放。"
                } else {
                    session.mixedAudioURL = nil
                    session.mixState = .failed
                    session.mixMessage = "上次生成完整回放时应用退出，原始分轨仍然安全，可重新生成。"
                }
                session.mixUpdatedAt = Date()
                session.updatedAt = Date()
                try? save(session)
            }
            sessions.append(session)
        }
        return sessions.sorted { $0.startTime > $1.startTime }
    }

    func deleteSession(id: UUID) throws {
        let directory = sessionDirectory(for: id)
        guard fileManager.fileExists(atPath: directory.path) else { return }
        try fileManager.removeItem(at: directory)
    }

    func saveTranscript(_ segments: [TranscriptSegment], sessionID: UUID) throws -> URL {
        let url = sessionDirectory(for: sessionID).appending(path: "逐字稿.json")
        try encoder.encode(segments).write(to: url, options: .atomic)
        let markdown = segments.map { segment in
            let label = segment.speakerID ?? segment.source.title
            return "### \(Self.timestamp(segment.startTime)) · \(label)\n\n\(segment.normalizedText ?? segment.text)"
        }.joined(separator: "\n\n")
        try markdown.write(to: transcriptMarkdownURL(for: sessionID), atomically: true, encoding: .utf8)
        return url
    }

    func loadTranscript(sessionID: UUID) throws -> [TranscriptSegment] {
        let url = sessionDirectory(for: sessionID).appending(path: "逐字稿.json")
        guard fileManager.fileExists(atPath: url.path) else { return [] }
        return try decoder.decode([TranscriptSegment].self, from: Data(contentsOf: url))
    }

    func saveSummary(_ markdown: String, sessionID: UUID) throws -> URL {
        let url = summaryMarkdownURL(for: sessionID)
        try markdown.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func loadSummary(sessionID: UUID) throws -> String? {
        let url = summaryMarkdownURL(for: sessionID)
        return fileManager.fileExists(atPath: url.path) ? try String(contentsOf: url, encoding: .utf8) : nil
    }

    func saveFormattedDocument(_ markdown: String, sessionID: UUID) throws -> URL {
        let url = formattedDocumentURL(for: sessionID)
        try markdown.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func loadFormattedDocument(sessionID: UUID) throws -> String? {
        let url = formattedDocumentURL(for: sessionID)
        return fileManager.fileExists(atPath: url.path) ? try String(contentsOf: url, encoding: .utf8) : nil
    }

    func saveDiarization(_ result: SpeakerDiarizationResult, sessionID: UUID) throws -> URL {
        let url = diarizationURL(for: sessionID)
        try encoder.encode(result).write(to: url, options: .atomic)
        return url
    }

    func loadDiarization(sessionID: UUID) throws -> SpeakerDiarizationResult? {
        let url = diarizationURL(for: sessionID)
        return fileManager.fileExists(atPath: url.path)
            ? try decoder.decode(SpeakerDiarizationResult.self, from: Data(contentsOf: url)) : nil
    }

    func sessionDirectory(for id: UUID) -> URL {
        locateSessionDirectory(id: id) ?? rootDirectory.appending(path: id.uuidString, directoryHint: .isDirectory)
    }

    func transcriptMarkdownURL(for id: UUID) -> URL { sessionDirectory(for: id).appending(path: "逐字稿.md") }
    func summaryMarkdownURL(for id: UUID) -> URL { sessionDirectory(for: id).appending(path: "会议纪要.md") }
    func formattedDocumentURL(for id: UUID) -> URL { sessionDirectory(for: id).appending(path: "AI排版文稿.md") }
    func diarizationURL(for id: UUID) -> URL { sessionDirectory(for: id).appending(path: "说话人时间轴.json") }
    func mixedAudioURL(for id: UUID) -> URL { sessionDirectory(for: id).appending(path: "完整回放.m4a") }
    func mixManifestURL(for id: UUID) -> URL { sessionDirectory(for: id).appending(path: "混音时间轴.json") }

    func saveMixManifest(_ manifest: AudioMixTimelineManifest, sessionID: UUID) throws -> URL {
        let url = mixManifestURL(for: sessionID)
        try encoder.encode(manifest).write(to: url, options: .atomic)
        return url
    }

    func loadMixManifest(sessionID: UUID) throws -> AudioMixTimelineManifest? {
        let url = mixManifestURL(for: sessionID)
        return fileManager.fileExists(atPath: url.path)
            ? try decoder.decode(AudioMixTimelineManifest.self, from: Data(contentsOf: url)) : nil
    }

    private func migrateToReadableFlatLayout(_ original: MeetingSession, from initial: URL) throws -> MeetingSession {
        var session = original
        var directory = initial
        let readable = uniqueDirectory(for: session.title, excluding: directory)
        if readable.standardizedFileURL != directory.standardizedFileURL {
            try fileManager.moveItem(at: directory, to: readable)
            session = relocatingURLs(in: session, from: directory, to: readable)
            directory = readable
        }
        session.title = directory.lastPathComponent
        let audio = directory.appending(path: "audio")
        session.systemAudioURL = try moveKnownFile(
            session.systemAudioURL, fallbacks: matchingFiles(in: audio, suffix: "_系统声.m4a"),
            to: directory.appending(path: "系统声音.m4a")
        )
        session.microphoneAudioURL = try moveKnownFile(
            session.microphoneAudioURL, fallbacks: matchingFiles(in: audio, suffix: "_麦克风.m4a"),
            to: directory.appending(path: "麦克风.m4a")
        )
        session.mixedAudioURL = try moveKnownFile(
            session.mixedAudioURL, fallbacks: [directory.appending(path: "audio/mixed.m4a")],
            to: directory.appending(path: "完整回放.m4a")
        )
        session.transcriptFileURL = try moveKnownFile(
            session.transcriptFileURL, fallbacks: [directory.appending(path: "transcript/segments.json")],
            to: directory.appending(path: "逐字稿.json")
        )
        session.summaryFileURL = try moveKnownFile(
            session.summaryFileURL, fallbacks: [directory.appending(path: "summary/summary.md")],
            to: directory.appending(path: "会议纪要.md")
        )
        session.formattedDocumentFileURL = try moveKnownFile(
            session.formattedDocumentFileURL, fallbacks: [directory.appending(path: "document/meeting-document.md")],
            to: directory.appending(path: "AI排版文稿.md")
        )
        session.diarizationFileURL = try moveKnownFile(
            session.diarizationFileURL, fallbacks: [directory.appending(path: "transcript/diarization.json")],
            to: directory.appending(path: "说话人时间轴.json")
        )
        _ = try moveKnownFile(directory.appending(path: "transcript/transcript.md"), fallbacks: [], to: directory.appending(path: "逐字稿.md"))
        _ = try moveKnownFile(directory.appending(path: "audio/mix-manifest.json"), fallbacks: [], to: directory.appending(path: "混音时间轴.json"))
        for name in ["audio", "summary", "transcript", "document"] {
            removeDirectoryIfEmpty(directory.appending(path: name))
        }
        try writeMetadata(session, in: directory)
        return session
    }

    private func moveKnownFile(_ primary: URL?, fallbacks: [URL], to destination: URL) throws -> URL? {
        if fileManager.fileExists(atPath: destination.path) { return destination }
        let source = ([primary].compactMap { $0 } + fallbacks).first {
            $0.standardizedFileURL != destination.standardizedFileURL && fileManager.fileExists(atPath: $0.path)
        }
        guard let source else { return primary.flatMap { fileManager.fileExists(atPath: $0.path) ? $0 : nil } }
        try fileManager.moveItem(at: source, to: destination)
        return destination
    }

    private func matchingFiles(in directory: URL, suffix: String) -> [URL] {
        (try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil))?
            .filter { $0.lastPathComponent.hasSuffix(suffix) } ?? []
    }

    private func removeDirectoryIfEmpty(_ directory: URL) {
        let finderMetadata = directory.appending(path: ".DS_Store")
        if fileManager.fileExists(atPath: finderMetadata.path) { try? fileManager.removeItem(at: finderMetadata) }
        guard let contents = try? fileManager.contentsOfDirectory(atPath: directory.path), contents.isEmpty else { return }
        try? fileManager.removeItem(at: directory)
    }

    private func relocatingURLs(in original: MeetingSession, from old: URL, to new: URL) -> MeetingSession {
        var session = original
        session.systemAudioURL = relocated(session.systemAudioURL, from: old, to: new)
        session.microphoneAudioURL = relocated(session.microphoneAudioURL, from: old, to: new)
        session.mixedAudioURL = relocated(session.mixedAudioURL, from: old, to: new)
        session.transcriptFileURL = relocated(session.transcriptFileURL, from: old, to: new)
        session.summaryFileURL = relocated(session.summaryFileURL, from: old, to: new)
        session.formattedDocumentFileURL = relocated(session.formattedDocumentFileURL, from: old, to: new)
        session.diarizationFileURL = relocated(session.diarizationFileURL, from: old, to: new)
        return session
    }

    private func relocated(_ url: URL?, from old: URL, to new: URL) -> URL? {
        guard let url else { return nil }
        let prefix = old.path.hasSuffix("/") ? old.path : old.path + "/"
        return url.path.hasPrefix(prefix) ? new.appending(path: String(url.path.dropFirst(prefix.count))) : url
    }

    private func locateSessionDirectory(id: UUID) -> URL? {
        let legacy = rootDirectory.appending(path: id.uuidString, directoryHint: .isDirectory)
        if fileManager.fileExists(atPath: legacy.path) { return legacy }
        guard let entries = try? fileManager.contentsOfDirectory(at: rootDirectory, includingPropertiesForKeys: [.isDirectoryKey]) else { return nil }
        return entries.first {
            (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true && decodeSession(in: $0)?.id == id
        }
    }

    private func decodeSession(in directory: URL) -> MeetingSession? {
        for name in [Self.metadataName, Self.legacyMetadataName] {
            if let data = try? Data(contentsOf: directory.appending(path: name)),
               let session = try? decoder.decode(MeetingSession.self, from: data) { return session }
        }
        return nil
    }

    private func writeMetadata(_ session: MeetingSession, in directory: URL) throws {
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try encoder.encode(session).write(to: directory.appending(path: Self.metadataName), options: .atomic)
        let legacy = directory.appending(path: Self.legacyMetadataName)
        if fileManager.fileExists(atPath: legacy.path) { try? fileManager.removeItem(at: legacy) }
    }

    private func uniqueDirectory(for title: String, excluding excluded: URL? = nil) -> URL {
        let base = Self.safeFileName(title)
        var candidate = rootDirectory.appending(path: base, directoryHint: .isDirectory)
        var index = 2
        while fileManager.fileExists(atPath: candidate.path) && candidate.standardizedFileURL != excluded?.standardizedFileURL {
            candidate = rootDirectory.appending(path: "\(base) (\(index))", directoryHint: .isDirectory)
            index += 1
        }
        return candidate
    }

    private static func timestamp(_ interval: TimeInterval) -> String {
        let seconds = max(0, Int(interval))
        return String(format: "%02d:%02d:%02d", seconds / 3_600, (seconds % 3_600) / 60, seconds % 60)
    }

    private static func safeFileName(_ value: String) -> String {
        let invalid = CharacterSet(charactersIn: "/:\\?%*|\"<>")
        let result = value.components(separatedBy: invalid).joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return String((result.isEmpty ? "未命名会议" : result).prefix(80))
    }

    private static let fileDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy-MM-dd_HHmm"
        return formatter
    }()
}
