import Foundation
import Testing
import VivariumCore
@testable import VivariumDetect

@Suite("CodexParser")
struct CodexParserTests {
    private static let sessionID = "0f000000-aaaa-bbbb-cccc-000000000001"
    private static let key = SessionKey(provider: .codex, sessionID: sessionID)
    private static let baseReceivedAt = Date(timeIntervalSince1970: 1_750_000_000)

    private func fixtureURL(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures")
            .appendingPathComponent(name)
    }

    private func runFixture(_ name: String, context: inout CodexParseContext) throws -> [AgentEvent] {
        let text = try String(contentsOf: fixtureURL(name), encoding: .utf8)
        var events: [AgentEvent] = []
        for (index, line) in text.components(separatedBy: "\n").enumerated() {
            events += CodexRolloutParser.parse(
                line: line,
                context: &context,
                receivedAt: Self.baseReceivedAt.addingTimeInterval(Double(index))
            )
        }
        return events
    }

    @Test("Golden rollout fixture maps to the exact ordered event sequence")
    func goldenRolloutSequence() throws {
        var context = CodexParseContext(fallbackSessionID: "rollout-file-fallback")
        let events = try runFixture("codex-rollout.jsonl", context: &context)

        let key = Self.key
        let started = SessionDescriptor(
            key: key,
            projectPath: "/Users/dev/ReefProject",
            projectKey: "/Users/dev/ReefProject",
            projectDisplayName: "ReefProject",
            startedAt: Date(timeIntervalSince1970: 1_783_414_800) // 2026-07-07T09:00:00Z
        )
        var updated = started
        updated.model = "gpt-5.5"

        let expected: [AgentEvent] = [
            .sessionStarted(started),
            .sessionUpdated(updated),
            .statusChanged(key, .planning),
            .thought(key, message: "Reading the request…"),
            .thought(key, message: "Thinking…"),
            .thought(key, message: "Thinking…"),
            .statusChanged(key, .searching),
            .thought(key, message: "Running: ls"),
            .statusChanged(key, .testing),
            .thought(key, message: "Running: swift"),
            .taskFailed(key, reason: "exit 1"),
            .bugDetected(key, evidence: "Tests failed (exit 1)"),
            .statusChanged(key, .planning),
            .thought(key, message: "Thinking…"),
            .statusChanged(key, .coding),
            .thought(key, message: "Applying patch…"),
            .thought(key, message: "Applying patch…"),
            .statusChanged(key, .testing),
            .thought(key, message: "Running: swift"),
            .bugResolved(key),
            .thought(key, message: "All tests green — wrapping up."),
            .statusChanged(key, .searching),
            .thought(key, message: "Searching the web…"),
            .taskCompleted(key, domain: nil, summary: "Implemented the rollout parser."),
            .statusChanged(key, .planning),
            .thought(key, message: "Reading the request…"),
            .statusChanged(key, .reviewing),
            .thought(key, message: "Running: git"),
            .taskFailed(key, reason: "interrupted"),
        ]

        #expect(events.count == expected.count)
        for (index, pair) in zip(events, expected).enumerated() {
            #expect(pair.0 == pair.1, "event #\(index)")
        }

        #expect(context.descriptor == updated)
        #expect(context.sessionKey == key)
        #expect(context.isSubagentThread == false)
        #expect(context.turnEnded)
        #expect(context.hasPendingCall) // call_4 (git diff) never got an output
        #expect(context.pendingCalls["call_4"] == CodexParseContext.PendingCall(isTest: false))
        #expect(context.skippedLines == 1) // the unknown "sparkle_burst" event_msg
        #expect(context.lastStatus == .reviewing)
        #expect(context.lastDomain == nil)
    }

    @Test("Subagent session_meta reports isSubagent and parentSessionID")
    func subagentSessionMeta() throws {
        let line = """
        {"timestamp":"2026-07-07T04:39:34.678Z","type":"session_meta","payload":{"session_id":"0f000000-aaaa-bbbb-cccc-0000000000pp","id":"0f000000-aaaa-bbbb-cccc-0000000000cc","parent_thread_id":"0f000000-aaaa-bbbb-cccc-0000000000pp","timestamp":"2026-07-07T04:39:32.596Z","cwd":"/Users/dev/ReefProject","originator":"Codex Desktop","cli_version":"0.142.5","source":{"subagent":{"thread_spawn":{"parent_thread_id":"0f000000-aaaa-bbbb-cccc-0000000000pp","depth":1,"agent_path":null,"agent_nickname":"Pearl","agent_role":"worker"}}},"thread_source":"subagent","agent_nickname":"Pearl","agent_role":"worker","model_provider":"openai"}}
        """
        var context = CodexParseContext(fallbackSessionID: "fallback")
        let events = CodexRolloutParser.parse(line: line, context: &context, receivedAt: Self.baseReceivedAt)

        #expect(events.count == 1)
        guard case .sessionStarted(let descriptor) = try #require(events.first) else {
            Issue.record("expected sessionStarted, got \(events)")
            return
        }
        #expect(descriptor.key == SessionKey(provider: .codex, sessionID: "0f000000-aaaa-bbbb-cccc-0000000000cc"))
        #expect(descriptor.isSubagent)
        #expect(descriptor.parentSessionID == "0f000000-aaaa-bbbb-cccc-0000000000pp")
        #expect(descriptor.projectDisplayName == "ReefProject")
        #expect(context.isSubagentThread)
        #expect(context.parentThreadID == "0f000000-aaaa-bbbb-cccc-0000000000pp")
    }

    @Test("exec_command with argv-array cmd classifies and tracks the pending test call")
    func argvArrayCommand() {
        let line = """
        {"timestamp":"2026-07-07T09:00:12.000Z","type":"response_item","payload":{"type":"function_call","id":"fc_x","name":"exec_command","arguments":"{\\"cmd\\":[\\"cargo\\",\\"test\\",\\"--workspace\\"],\\"workdir\\":\\"/Users/dev/ReefProject\\"}","call_id":"call_argv"}}
        """
        var context = CodexParseContext(fallbackSessionID: "argv-fallback")
        let events = CodexRolloutParser.parse(line: line, context: &context, receivedAt: Self.baseReceivedAt)

        let key = SessionKey(provider: .codex, sessionID: "argv-fallback")
        #expect(events == [
            .statusChanged(key, .testing),
            .thought(key, message: "Running: cargo"),
        ])
        #expect(context.pendingCalls["call_argv"] == CodexParseContext.PendingCall(isTest: true))
        #expect(context.hasPendingCall)
    }

    @Test("Exit-code regex matches only nonzero codes", arguments: [
        ("Chunk ID: x\nProcess exited with code 128\nOutput:\nfatal", 128),
        ("Process exited with code 1\nOutput:\n1 test failed", 1),
        ("Process exited with code 0\nOutput:\nall good", nil),
        ("no exit marker anywhere in this output", nil),
    ] as [(String, Int?)])
    func exitCodeRegex(output: String, code: Int?) {
        #expect(CodexRolloutParser.exitCode(fromOutput: output) == code)
    }

    @Test("token_count is silent but refreshes liveness")
    func tokenCountLiveness() {
        let line = """
        {"timestamp":"2026-07-07T09:00:01.100Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":5}}}}
        """
        var context = CodexParseContext(fallbackSessionID: "tc-fallback")
        let receivedAt = Date(timeIntervalSince1970: 1_234_567)
        let events = CodexRolloutParser.parse(line: line, context: &context, receivedAt: receivedAt)

        #expect(events.isEmpty)
        #expect(context.lastEventAt == receivedAt)
        #expect(context.skippedLines == 0)
    }

    @Test("Garbage fixture yields zero events and counts skipped lines without crashing")
    func garbageResilience() throws {
        var context = CodexParseContext(fallbackSessionID: "garbage-fallback")
        let events = try runFixture("codex-garbage.jsonl", context: &context)

        #expect(events.isEmpty)
        #expect(context.skippedLines == 7)
        #expect(context.descriptor == nil)
        #expect(context.hasPendingCall == false)
    }

    @Test("Unmatched function_call_output passes through silently")
    func unmatchedOutputPassthrough() {
        let line = """
        {"timestamp":"2026-07-07T09:00:20.000Z","type":"response_item","payload":{"type":"function_call_output","call_id":"call_never_seen","output":"Process exited with code 3\\n"}}
        """
        var context = CodexParseContext(fallbackSessionID: "orphan-fallback")
        let events = CodexRolloutParser.parse(line: line, context: &context, receivedAt: Self.baseReceivedAt)

        #expect(events.isEmpty)
        #expect(context.skippedLines == 0)
    }
}
