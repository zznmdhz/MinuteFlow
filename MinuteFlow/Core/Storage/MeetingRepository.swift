import Foundation

protocol MeetingRepository {
    func createSession(title: String, sourceSelection: AudioSourceSelection) throws -> MeetingSession
    func save(_ session: MeetingSession) throws
    func loadRecentSessions() throws -> [MeetingSession]
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
            self.rootDirectory = applicationSupport.appending(path: "MinuteFlow/Sessions", directoryHint: .isDirectory)
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

        if sourceSelection.systemAudioEnabled {
            session.systemAudioURL = audioDirectory.appending(path: "system.m4a")
        }
        if sourceSelection.microphoneEnabled {
            session.microphoneAudioURL = audioDirectory.appending(path: "microphone.m4a")
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
            return try? decoder.decode(MeetingSession.self, from: data)
        }
        .sorted { $0.startTime > $1.startTime }
    }

    func sessionDirectory(for id: UUID) -> URL {
        rootDirectory.appending(path: id.uuidString, directoryHint: .isDirectory)
    }
}
