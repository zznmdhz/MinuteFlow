import Foundation

protocol MeetingRepository {
    func createSession(title: String, sourceSelection: AudioSourceSelection) throws -> MeetingSession
    func save(_ session: MeetingSession) throws
    func loadRecentSessions() throws -> [MeetingSession]
    func deleteSession(id: UUID) throws
    func saveTranscript(_ segments: [TranscriptSegment], sessionID: UUID) throws -> URL
    func loadTranscript(sessionID: UUID) throws -> [TranscriptSegment]
    func saveSummary(_ markdown: String, sessionID: UUID) throws -> URL
    func loadSummary(sessionID: UUID) throws -> String?
    func sessionDirectory(for id: UUID) -> URL
}

struct LocalMeetingRepository: MeetingRepository {
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
                ? legacySandboxDirectory
                : standardDirectory
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
        let id = UUID()
        let directory = sessionDirectory(for: id)
        let audioDirectory = directory.appending(path: "audio", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: audioDirectory, withIntermediateDirectories: true)

        let now = Date()
        var session = MeetingSession(
            id: id,
            title: title,
            sourceSelection: sourceSelection,
            startTime: now,
            duration: 0,
            recordingStatus: .preparing,
            createdAt: now,
            updatedAt: now
        )

        let filePrefix = "\(Self.fileDateFormatter.string(from: now))_\(Self.safeFileName(title))"

        if sourceSelection.systemAudioEnabled {
            session.systemAudioURL = audioDirectory.appending(path: "\(filePrefix)_系统声.m4a")
        }
        if sourceSelection.microphoneEnabled {
            session.microphoneAudioURL = audioDirectory.appending(path: "\(filePrefix)_麦克风.m4a")
        }
        try save(session)
        return session
    }

    func save(_ session: MeetingSession) throws {
        let directory = sessionDirectory(for: session.id)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try encoder.encode(session)
        try data.write(to: directory.appending(path: "metadata.json"), options: .atomic)
    }

    func loadRecentSessions() throws -> [MeetingSession] {
        guard fileManager.fileExists(atPath: rootDirectory.path) else { return [] }
        let directories = try fileManager.contentsOfDirectory(
            at: rootDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        return directories.compactMap { directory in
            let metadataURL = directory.appending(path: "metadata.json")
            guard let data = try? Data(contentsOf: metadataURL) else { return nil }
            guard var session = try? decoder.decode(MeetingSession.self, from: data) else { return nil }
            if session.recordingStatus.isActive {
                session.recordingStatus = .interrupted
                session.endTime = session.endTime ?? session.updatedAt
                session.updatedAt = Date()
                try? save(session)
            }
            return session
        }
        .sorted { $0.startTime > $1.startTime }
    }

    func deleteSession(id: UUID) throws {
        let directory = sessionDirectory(for: id)
        guard fileManager.fileExists(atPath: directory.path) else { return }
        try fileManager.removeItem(at: directory)
    }

    func saveTranscript(_ segments: [TranscriptSegment], sessionID: UUID) throws -> URL {
        let directory = sessionDirectory(for: sessionID)
            .appending(path: "transcript", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "segments.json")
        let data = try encoder.encode(segments)
        try data.write(to: url, options: .atomic)

        let markdown = segments.map { segment in
            "### \(Self.timestamp(segment.startTime)) · \(segment.source.title)\n\n\(segment.normalizedText ?? segment.text)"
        }.joined(separator: "\n\n")
        try markdown.write(
            to: directory.appending(path: "transcript.md"),
            atomically: true,
            encoding: .utf8
        )
        return url
    }

    func loadTranscript(sessionID: UUID) throws -> [TranscriptSegment] {
        let url = sessionDirectory(for: sessionID)
            .appending(path: "transcript/segments.json")
        guard fileManager.fileExists(atPath: url.path) else { return [] }
        return try decoder.decode([TranscriptSegment].self, from: Data(contentsOf: url))
    }

    func saveSummary(_ markdown: String, sessionID: UUID) throws -> URL {
        let directory = sessionDirectory(for: sessionID)
            .appending(path: "summary", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "summary.md")
        try markdown.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func loadSummary(sessionID: UUID) throws -> String? {
        let url = sessionDirectory(for: sessionID).appending(path: "summary/summary.md")
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        return try String(contentsOf: url, encoding: .utf8)
    }

    func sessionDirectory(for id: UUID) -> URL {
        rootDirectory.appending(path: id.uuidString, directoryHint: .isDirectory)
    }

    private static func timestamp(_ interval: TimeInterval) -> String {
        let seconds = max(0, Int(interval))
        return String(format: "%02d:%02d:%02d", seconds / 3_600, (seconds % 3_600) / 60, seconds % 60)
    }

    private static func safeFileName(_ value: String) -> String {
        let invalid = CharacterSet(charactersIn: "/:\\?%*|\"<>")
        let components = value.components(separatedBy: invalid)
        let result = components.joined(separator: "-")
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
