import Foundation
import Testing
import VivariumCore
@testable import VivariumDetect

@Suite("CopilotParser")
struct CopilotParserTests {
    private static let sessionID = "0f000000-aaaa-bbbb-cccc-0000000000c1"
    private static let key = SessionKey(provider: .copilot, sessionID: sessionID)
    private static let baseReceivedAt = Date(timeIntervalSince1970: 1_750_000_000)

    private func fixtureURL(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures")
            .appendingPathComponent(name)
    }

    private func runFixture(_ name: String, context: inout CopilotParseContext) throws -> [AgentEvent] {
        let text = try String(contentsOf: fixtureURL(name), encoding: .utf8)
        var events: [AgentEvent] = []
        for (index, line) in text.components(separatedBy: "\n").enumerated() {
            events += CopilotSessionParser.parse(
                line: line,
                context: &context,
                receivedAt: Self.baseReceivedAt.addingTimeInterval(Double(index))
            )
        }
        return events
    }

    @Test("Golden session fixture maps to the exact ordered event sequence")
    func goldenSessionSequence() throws {
        var context = CopilotParseContext(fallbackSessionID: "session-file-fallback")
        let events = try runFixture("copilot-session.jsonl", context: &context)

        let key = Self.key
        let start = Date(timeIntervalSince1970: 1_783_414_800) // 2026-07-07T09:00:00Z
        let d0 = SessionDescriptor(
            key: key,
            projectPath: nil,
            projectKey: "copilot",
            projectDisplayName: "Copilot",
            startedAt: start
        )
        var d1 = d0
        d1.projectPath = "/Users/dev/ReefProject"
        d1.projectKey = "/Users/dev/ReefProject"
        d1.projectDisplayName = "ReefProject"
        var d2 = d1
        d2.model = "gpt-5"

        let expected: [AgentEvent] = [
            .sessionStarted(d0),
            .sessionUpdated(d1),
            .statusChanged(key, .planning),
            .thought(key, message: "Reading the request…"),
            .statusChanged(key, .searching),
            .thought(key, message: "Exploring codebase"),
            .thought(key, message: "Reading Package.swift"),
            .statusChanged(key, .testing),
            .thought(key, message: "Run the tests"),
            .taskFailed(key, reason: nil),
            .bugDetected(key, evidence: "Tests failed"),
            .statusChanged(key, .coding),
            .thought(key, message: "Editing Fix.swift"),
            .thought(key, message: "Let me run the tests again."),
            .sessionUpdated(d2),
            .thought(key, message: "All done — tests pass."),
            .taskCompleted(key, domain: .swift, summary: nil),
            .waitingForUser(key, kind: .endOfTurn),
        ]

        #expect(events.count == expected.count)
        for (index, pair) in zip(events, expected).enumerated() {
            #expect(pair.0 == pair.1, "event #\(index): got \(pair.0), expected \(pair.1)")
        }

        #expect(context.descriptor == d2)
        #expect(context.sessionKey == key)
        #expect(context.turnEnded)
        #expect(context.lastStatus == .coding)
        #expect(context.lastDomain == .swift)
        #expect(context.skippedLines == 1) // the unknown "sparkle.burst" record
        #expect(context.hasPendingTool) // report_intent (t1) never received a completion
        #expect(context.pendingTools["t1"] == CopilotParseContext.PendingTool(isTest: false))
    }

    @Test("A tool start seen before session.start synthesizes a provider-identity fish")
    func midFileSeedSynthesizesStart() {
        var context = CopilotParseContext(fallbackSessionID: "seed-fallback")
        let line = """
        {"type":"tool.execution_start","data":{"toolName":"view","toolCallId":"v1","arguments":{"path":"/Users/dev/ReefProject/Sources/Reef.swift"}}}
        """
        let events = CopilotSessionParser.parse(line: line, context: &context, receivedAt: Self.baseReceivedAt)

        let key = SessionKey(provider: .copilot, sessionID: "seed-fallback")
        guard case .sessionStarted(let descriptor) = events.first else {
            Issue.record("expected a synthesized sessionStarted, got \(events)")
            return
        }
        #expect(descriptor.key == key)
        #expect(descriptor.projectKey == "copilot")
        #expect(descriptor.projectDisplayName == "Copilot")
        #expect(events.dropFirst() == [
            .statusChanged(key, .searching),
            .thought(key, message: "Reading Reef.swift"),
        ])
    }

    @Test("An assistant message with no tool requests completes the turn")
    func finalAssistantMessageCompletesTurn() {
        var context = CopilotParseContext(fallbackSessionID: "turn-fallback")
        _ = CopilotSessionParser.parse(
            line: #"{"type":"session.start","data":{"sessionId":"turn-fallback","startTime":"2026-07-07T09:00:00.000Z"}}"#,
            context: &context,
            receivedAt: Self.baseReceivedAt
        )
        let events = CopilotSessionParser.parse(
            line: #"{"type":"assistant.message","data":{"content":"Finished.","toolRequests":[]}}"#,
            context: &context,
            receivedAt: Self.baseReceivedAt
        )
        let key = SessionKey(provider: .copilot, sessionID: "turn-fallback")
        #expect(events == [
            .thought(key, message: "Finished."),
            .taskCompleted(key, domain: nil, summary: nil),
        ])
        #expect(context.turnEnded)
    }

    @Test("An assistant message that still requests tools does not complete the turn")
    func assistantWithToolRequestsKeepsWorking() {
        var context = CopilotParseContext(fallbackSessionID: "work-fallback")
        let events = CopilotSessionParser.parse(
            line: #"{"type":"assistant.message","data":{"content":"Working on it.","toolRequests":[{"id":"a"},{"id":"b"}]}}"#,
            context: &context,
            receivedAt: Self.baseReceivedAt
        )
        let key = SessionKey(provider: .copilot, sessionID: "work-fallback")
        // ensureStarted synthesizes the fish, then the content bubble — but no taskCompleted.
        #expect(events.contains(.thought(key, message: "Working on it.")))
        #expect(!events.contains(where: { if case .taskCompleted = $0 { return true } else { return false } }))
        #expect(context.turnEnded == false)
    }

    @Test("A failed test command completion raises the bug shark")
    func failedTestRaisesBugShark() {
        var context = CopilotParseContext(fallbackSessionID: "bug-fallback")
        _ = CopilotSessionParser.parse(
            line: #"{"type":"tool.execution_start","data":{"toolName":"bash","toolCallId":"b1","arguments":{"command":"npm test"}}}"#,
            context: &context,
            receivedAt: Self.baseReceivedAt
        )
        let events = CopilotSessionParser.parse(
            line: #"{"type":"tool.execution_complete","data":{"toolCallId":"b1","success":false}}"#,
            context: &context,
            receivedAt: Self.baseReceivedAt
        )
        let key = SessionKey(provider: .copilot, sessionID: "bug-fallback")
        #expect(events == [
            .taskFailed(key, reason: nil),
            .bugDetected(key, evidence: "Tests failed"),
        ])
        #expect(context.hasPendingTool == false)
    }

    @Test("An unmatched tool completion passes through silently")
    func unmatchedCompletionPassthrough() {
        var context = CopilotParseContext(fallbackSessionID: "orphan-fallback")
        let events = CopilotSessionParser.parse(
            line: #"{"type":"tool.execution_complete","data":{"toolCallId":"never-seen","success":true}}"#,
            context: &context,
            receivedAt: Self.baseReceivedAt
        )
        #expect(events.isEmpty)
        #expect(context.skippedLines == 0)
        #expect(context.descriptor == nil)
    }

    @Test("Garbage fixture yields zero events and counts skipped lines without crashing")
    func garbageResilience() throws {
        var context = CopilotParseContext(fallbackSessionID: "garbage-fallback")
        let events = try runFixture("copilot-garbage.jsonl", context: &context)

        #expect(events.isEmpty)
        #expect(context.skippedLines == 7)
        #expect(context.descriptor == nil)
        #expect(context.hasPendingTool == false)
    }
}
