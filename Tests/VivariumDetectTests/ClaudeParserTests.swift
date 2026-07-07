import Foundation
import Testing
import VivariumCore
import VivariumDetect

@Suite("ClaudeParser")
struct ClaudeParserTests {
    private static let sessionID = "fixture-session-0001"
    private static let receivedAt = Date(timeIntervalSince1970: 1_767_600_000)

    private var key: SessionKey { SessionKey(provider: .claude, sessionID: Self.sessionID) }

    private func fixtureLines(_ name: String) throws -> [String] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures")
            .appendingPathComponent(name)
        let contents = try String(contentsOf: url, encoding: .utf8)
        return contents.components(separatedBy: "\n")
    }

    private func parseAll(_ lines: [String], context: inout ClaudeParseContext) -> [AgentEvent] {
        var events: [AgentEvent] = []
        for line in lines {
            events += ClaudeTranscriptParser.parse(line: line, context: &context, receivedAt: Self.receivedAt)
        }
        return events
    }

    private func sessionStart() throws -> Date {
        try Date("2026-01-05T10:00:00.000Z", strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true))
    }

    private func startDescriptor() throws -> SessionDescriptor {
        SessionDescriptor(
            key: key,
            projectPath: "/Users/dev/Example",
            projectKey: "/Users/dev/Example",
            projectDisplayName: "Example",
            gitBranch: "main",
            title: nil,
            model: nil,
            isSubagent: false,
            parentSessionID: nil,
            startedAt: try sessionStart()
        )
    }

    private func updatedDescriptor() throws -> SessionDescriptor {
        var descriptor = try startDescriptor()
        descriptor.title = "Fix login bug"
        descriptor.model = "claude-fable-5"
        return descriptor
    }

    @Test("golden fixture produces the exact ordered event sequence")
    func goldenFixture() throws {
        var context = ClaudeParseContext(sessionID: Self.sessionID)
        let lines = try fixtureLines("claude-session.jsonl").filter { !$0.isEmpty }
        let events = parseAll(lines, context: &context)

        let expected: [AgentEvent] = [
            .sessionStarted(try startDescriptor()),
            .statusChanged(key, .planning),
            .thought(key, message: "Reading the request…"),
            .thought(key, message: "I'll look into the login flow."),
            .statusChanged(key, .coding),
            .thought(key, message: "Check Swift version"),
            .statusChanged(key, .searching),
            .thought(key, message: "Reading App.swift"),
            .thought(key, message: "Searching: loginToken"),
            .statusChanged(key, .coding),
            .thought(key, message: "Editing App.swift"),
            .handoff(key, subagentType: "Explore", description: "Survey auth modules"),
            .handoffReturned(key, success: true),
            .statusChanged(key, .testing),
            .thought(key, message: "Run the test suite"),
            .taskFailed(key, reason: nil),
            .bugDetected(key, evidence: "Tests failed"),
            .statusChanged(key, .coding),
            .thought(key, message: "Editing AppTests.swift"),
            .statusChanged(key, .testing),
            .thought(key, message: "Running: swift"),
            .bugResolved(key),
            .taskCompleted(key, domain: .testing, summary: nil),
            .statusChanged(key, .coding),
            .thought(key, message: "Using create_issue"),
            .statusChanged(key, .planning),
            .waitingForUser(key, kind: .question),
            .thought(key, message: "Reading the request…"),
            .statusChanged(key, .coding),
            .thought(key, message: "Editing Login.ts"),
            .taskCompleted(key, domain: .ui, summary: nil),
            .sessionUpdated(try updatedDescriptor()),
            .statusChanged(key, .planning),
            .thought(key, message: "Thinking…"),
            .thought(key, message: "The login bug is fixed."),
            .taskCompleted(key, domain: .ui, summary: nil),
        ]

        #expect(events.count == expected.count)
        for (index, pair) in zip(events, expected).enumerated() {
            #expect(pair.0 == pair.1, "event at index \(index)")
        }
        #expect(events == expected)
        #expect(context.turnEnded)
        #expect(context.skippedLines == 0)
        #expect(!context.hasPendingToolUse)
    }

    @Test("descriptor accumulates cwd, branch, model, and title")
    func descriptorFields() throws {
        var context = ClaudeParseContext(sessionID: Self.sessionID)
        let lines = try fixtureLines("claude-session.jsonl").filter { !$0.isEmpty }
        _ = parseAll(lines, context: &context)

        let descriptor = try #require(context.descriptor)
        #expect(descriptor.key == key)
        #expect(descriptor.projectPath == "/Users/dev/Example")
        #expect(descriptor.projectKey == "/Users/dev/Example")
        #expect(descriptor.projectDisplayName == "Example")
        #expect(descriptor.gitBranch == "main")
        #expect(descriptor.model == "claude-fable-5")
        #expect(descriptor.title == "Fix login bug")
        #expect(descriptor.isSubagent == false)
        #expect(descriptor.startedAt == (try sessionStart()))
    }

    @Test("garbage fixture yields zero events, counts skipped lines, and does not crash")
    func garbageFixture() throws {
        var context = ClaudeParseContext(sessionID: "garbage")
        let lines = try fixtureLines("claude-garbage.jsonl")
        let events = parseAll(lines, context: &context)

        #expect(events.isEmpty)
        #expect(context.skippedLines > 0)
        #expect(context.skippedLines == lines.count)
        #expect(context.descriptor == nil)
    }

    @Test("sidechain records are dropped entirely")
    func sidechainDropped() {
        var context = ClaudeParseContext(sessionID: "side")
        let line = #"{"type":"user","isSidechain":true,"cwd":"/Users/dev/Example","sessionId":"side","gitBranch":"main","timestamp":"2026-01-05T10:00:00.000Z","message":{"role":"user","content":"Explore the auth module"},"uuid":"uuid-s-1"}"#
        let events = ClaudeTranscriptParser.parse(line: line, context: &context, receivedAt: Self.receivedAt)

        #expect(events.isEmpty)
        #expect(context.descriptor == nil)
        #expect(context.skippedLines == 0)
    }

    @Test("consecutive search tool_uses emit a single statusChanged")
    func statusDedup() {
        let dedupKey = SessionKey(provider: .claude, sessionID: "dedup")
        var context = ClaudeParseContext(sessionID: "dedup")
        let first = #"{"type":"assistant","isSidechain":false,"sessionId":"dedup","timestamp":"2026-01-05T11:00:00.000Z","uuid":"uuid-d-1","message":{"model":"claude-fable-5","role":"assistant","stop_reason":"tool_use","content":[{"type":"tool_use","id":"da-1","name":"Read","input":{"file_path":"/Users/dev/Example/A.swift"}}]}}"#
        let second = #"{"type":"assistant","isSidechain":false,"sessionId":"dedup","timestamp":"2026-01-05T11:00:01.000Z","uuid":"uuid-d-2","message":{"model":"claude-fable-5","role":"assistant","stop_reason":"tool_use","content":[{"type":"tool_use","id":"da-2","name":"Read","input":{"file_path":"/Users/dev/Example/B.swift"}}]}}"#

        let firstEvents = ClaudeTranscriptParser.parse(line: first, context: &context, receivedAt: Self.receivedAt)
        let secondEvents = ClaudeTranscriptParser.parse(line: second, context: &context, receivedAt: Self.receivedAt)

        #expect(firstEvents == [
            .statusChanged(dedupKey, .searching),
            .thought(dedupKey, message: "Reading A.swift"),
        ])
        #expect(secondEvents == [
            .thought(dedupKey, message: "Reading B.swift"),
        ])
        #expect(context.hasPendingToolUse)
    }
}
