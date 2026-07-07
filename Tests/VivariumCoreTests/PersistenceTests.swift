import Foundation
import Testing
@testable import VivariumCore

@Suite("State persistence")
struct PersistenceTests {
    private static let created = Date(timeIntervalSinceReferenceDate: 700_000_000)

    private func makeTempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("PersistenceTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func fullState() -> EcosystemState {
        let now = Self.created
        let resident = FishState(
            id: .resident(provider: .claude, projectKey: "/Users/dev/Vivarium"),
            provider: .claude,
            displayName: "Claude · Vivarium",
            projectKey: "/Users/dev/Vivarium",
            isResident: true,
            status: .coding,
            thought: ThoughtBubble(message: "Editing FishNode.swift", expiresAt: now.addingTimeInterval(6)),
            size: 1.2,
            fatigue: 0.4,
            tasksCompleted: 12,
            tasksFailed: 2,
            memory: [MemoryTrait(domain: .swift, level: 3)],
            activityLevel: .running,
            lastActiveAt: now,
            createdAt: now,
            sessionCount: 4,
            currentSessionTitle: "Refactor fins",
            gitBranch: "main",
            model: "opus"
        )
        let demoFish = FishState(
            id: .demo("claude"),
            provider: .claude,
            displayName: "Claude · Reef",
            projectKey: "demo/claude",
            isResident: true,
            status: .coding,
            activityLevel: .running,
            lastActiveAt: now,
            createdAt: now
        )
        let ephemeral = FishState(
            id: .ephemeral(provider: .codex, sessionID: "abc"),
            provider: .codex,
            displayName: "Codex · scratch",
            isResident: false,
            status: .testing,
            activityLevel: .walking,
            lastActiveAt: now,
            createdAt: now
        )
        let key = SessionKey(provider: .claude, sessionID: "s1")
        let binding = SessionBinding(
            key: key,
            fishID: resident.id,
            descriptor: SessionDescriptor(
                key: key,
                projectKey: "/Users/dev/Vivarium",
                projectDisplayName: "Vivarium",
                startedAt: now
            )
        )
        return EcosystemState(
            fish: [resident, demoFish, ephemeral],
            sessions: [binding],
            food: [FoodPellet(id: 1, fish: resident.id, createdAt: now)],
            pearls: [Pearl(id: 2, fish: resident.id, label: "Explore", createdAt: now)],
            shark: SharkThreat(isActive: true, label: "Tests failed", severity: 0.8, causeFish: resident.id, since: now),
            reefStage: .shells,
            ambient: AmbientState(phase: .night, weather: .drizzle),
            achievements: [Achievement(id: "first-task", title: "First Splash", detail: "Completed a task", unlockedAt: now)],
            rareVisitor: RareVisitor(kind: .goldenFish, appearedAt: now, until: now.addingTimeInterval(60)),
            totalTasksCompleted: 42,
            totalTasksFailed: 7,
            eventLog: [LogLine(id: 3, message: "Claude completed a task", at: now)],
            createdAt: now,
            nextEntityID: 4
        )
    }

    @Test("Sanitize strips transient content and resets residents")
    func sanitizeStripsTransientContent() throws {
        let sanitized = fullState().sanitizedForPersistence()

        #expect(sanitized.fish.count == 1)
        let resident = try #require(sanitized.fish.first)
        #expect(resident.id == .resident(provider: .claude, projectKey: "/Users/dev/Vivarium"))
        #expect(resident.status == .resting)
        #expect(resident.activityLevel == .sleeping)
        #expect(resident.thought == nil)
        #expect(resident.size == 1.2)
        #expect(resident.fatigue == 0.4)
        #expect(resident.memory == [MemoryTrait(domain: .swift, level: 3)])
        #expect(resident.tasksCompleted == 12)
        #expect(resident.tasksFailed == 2)
        #expect(resident.sessionCount == 4)

        #expect(sanitized.sessions.isEmpty)
        #expect(sanitized.food.isEmpty)
        #expect(sanitized.pearls.isEmpty)
        #expect(sanitized.shark == SharkThreat())
        #expect(sanitized.rareVisitor == nil)
        #expect(sanitized.eventLog.isEmpty)

        #expect(sanitized.reefStage == .shells)
        #expect(sanitized.achievements.count == 1)
        #expect(sanitized.totalTasksCompleted == 42)
        #expect(sanitized.totalTasksFailed == 7)
        #expect(sanitized.createdAt == Self.created)
        #expect(sanitized.nextEntityID == 4)
    }

    @Test("Round-trips sanitized state through disk, re-deriving ambient")
    func roundTrip() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fileURL = dir
            .appendingPathComponent("nested", isDirectory: true)
            .appendingPathComponent("vivarium-state.json", isDirectory: false)
        let persistence = StatePersistence(fileURL: fileURL)

        let sanitized = fullState().sanitizedForPersistence()
        try persistence.save(sanitized)

        let now = Date(timeIntervalSinceReferenceDate: 700_010_000)
        let loaded = try #require(persistence.load(now: now))

        var expected = sanitized
        expected.ambient.phase = AmbientPhase.phase(forHour: Calendar.current.component(.hour, from: now))
        #expect(loaded == expected)
    }

    @Test("Missing file loads as nil")
    func missingFile() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let persistence = StatePersistence(fileURL: dir.appendingPathComponent("vivarium-state.json"))
        #expect(persistence.load(now: Self.created) == nil)
    }

    @Test("Newer schema version is backed up and skipped")
    func newerSchemaVersion() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fileURL = dir.appendingPathComponent("vivarium-state.json")
        let persistence = StatePersistence(fileURL: fileURL)

        let data = try JSONEncoder().encode(StateFile(schemaVersion: 2, state: fullState().sanitizedForPersistence()))
        try data.write(to: fileURL)

        #expect(persistence.load(now: Self.created) == nil)
        #expect(!FileManager.default.fileExists(atPath: fileURL.path))
        let backup = dir.appendingPathComponent("vivarium-state.v2.backup.json")
        #expect(FileManager.default.fileExists(atPath: backup.path))
    }

    @Test("Corrupt file loads as nil and is quarantined")
    func corruptFile() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fileURL = dir.appendingPathComponent("vivarium-state.json")
        let persistence = StatePersistence(fileURL: fileURL)

        try Data("{not json at all".utf8).write(to: fileURL)

        #expect(persistence.load(now: Self.created) == nil)
        #expect(!FileManager.default.fileExists(atPath: fileURL.path))
        let quarantined = dir.appendingPathComponent("vivarium-state.corrupt.json")
        #expect(FileManager.default.fileExists(atPath: quarantined.path))
    }

    @Test("Default file URL points into Application Support")
    func defaultFileURL() {
        let url = StatePersistence.defaultFileURL()
        #expect(url.lastPathComponent == "vivarium-state.json")
        #expect(url.pathComponents.contains("Vivarium"))
        #expect(url.path.contains("Application Support"))
    }
}
