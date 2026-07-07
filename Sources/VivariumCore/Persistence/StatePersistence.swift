import Foundation

/// On-disk envelope so future versions can detect incompatible state files before decoding them.
public struct StateFile: Codable, Sendable {
    public var schemaVersion: Int
    public var state: EcosystemState

    public init(schemaVersion: Int, state: EcosystemState) {
        self.schemaVersion = schemaVersion
        self.state = state
    }
}

public struct StatePersistence: Sendable {
    public static let currentSchemaVersion = 1

    public let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public static func defaultFileURL(appName: String = "Vivarium") -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        return support
            .appendingPathComponent(appName, isDirectory: true)
            .appendingPathComponent("vivarium-state.json", isDirectory: false)
    }

    /// Loads persisted state, re-deriving the ambient phase for `now`. Returns nil when the file
    /// is missing, corrupt (renamed to `<name>.corrupt.json` best-effort), or written by a newer
    /// schema version (renamed to `<name>.v<N>.backup.json` so the newer app's data survives).
    public func load(now: Date, calendar: Calendar = .current) -> EcosystemState? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        let decoder = JSONDecoder()
        guard let probe = try? decoder.decode(SchemaProbe.self, from: data) else {
            quarantine(suffix: "corrupt")
            return nil
        }
        guard probe.schemaVersion <= Self.currentSchemaVersion else {
            quarantine(suffix: "v\(probe.schemaVersion).backup")
            return nil
        }
        guard let file = try? decoder.decode(StateFile.self, from: data) else {
            quarantine(suffix: "corrupt")
            return nil
        }
        var state = file.state
        state.ambient.phase = AmbientPhase.phase(forHour: calendar.component(.hour, from: now))
        return state
    }

    public func save(_ state: EcosystemState) throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(StateFile(schemaVersion: Self.currentSchemaVersion, state: state))
        try data.write(to: fileURL, options: .atomic)
    }

    private func quarantine(suffix: String) {
        let stem = fileURL.deletingPathExtension().lastPathComponent
        let destination = fileURL.deletingLastPathComponent()
            .appendingPathComponent("\(stem).\(suffix).json", isDirectory: false)
        let manager = FileManager.default
        try? manager.removeItem(at: destination)
        try? manager.moveItem(at: fileURL, to: destination)
    }
}

private struct SchemaProbe: Decodable {
    var schemaVersion: Int
}

public extension EcosystemState {
    /// Strips transient/non-persistable content before saving: demo fish (projectKey "demo/…"),
    /// ephemeral fish, sessions, food, pearls, shark, rareVisitor, thoughts, eventLog; residents
    /// keep growth/memory/counters but status becomes .resting, activityLevel .sleeping.
    func sanitizedForPersistence() -> EcosystemState {
        var sanitized = self
        sanitized.fish = fish.compactMap { fish in
            guard fish.isResident, !fish.id.isDemo, fish.projectKey?.hasPrefix("demo/") != true else {
                return nil
            }
            var resident = fish
            resident.status = .resting
            resident.activityLevel = .sleeping
            resident.thought = nil
            resident.currentSessionTitle = nil
            return resident
        }
        sanitized.sessions = []
        sanitized.food = []
        sanitized.pearls = []
        sanitized.shark = SharkThreat()
        sanitized.rareVisitor = nil
        sanitized.eventLog = []
        return sanitized
    }
}
