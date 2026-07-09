import Foundation
import Testing
import VivariumCore
@testable import VivariumDetect

@Suite("OpenCodeParser")
struct OpenCodeParserTests {
    private static let sessionID = "ses_test0001"
    private static let key = SessionKey(provider: .opencode, sessionID: sessionID)
    private static let baseReceivedAt = Date(timeIntervalSince1970: 1_750_000_000)

    private func fixtureURL(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures")
            .appendingPathComponent(name)
    }

    private func runFixture(_ name: String, context: inout OpenCodeParseContext) throws -> [AgentEvent] {
        let text = try String(contentsOf: fixtureURL(name), encoding: .utf8)
        var events: [AgentEvent] = []
        for (index, line) in text.components(separatedBy: "\n").enumerated() {
            events += OpenCodeEventParser.parse(
                line: line,
                context: &context,
                receivedAt: Self.baseReceivedAt.addingTimeInterval(Double(index))
            )
        }
        return events
    }

    @Test("Golden session fixture maps to the exact ordered event sequence")
    func goldenSessionSequence() throws {
        var context = OpenCodeParseContext(sessionID: Self.sessionID)
        let events = try runFixture("opencode-session.jsonl", context: &context)

        let key = Self.key
        let started = Date(timeIntervalSince1970: 1_783_576_311.218)
        let d0 = SessionDescriptor(
            key: key,
            projectPath: "/Users/dev/Reef",
            projectKey: "/Users/dev/Reef",
            projectDisplayName: "Reef",
            title: nil, // "New session - …" placeholder is dropped
            model: "gpt-5.4",
            startedAt: started
        )
        var d1 = d0
        d1.title = "Fix the failing Reef test"

        let expected: [AgentEvent] = [
            .sessionStarted(d0),
            .statusChanged(key, .planning),
            .thought(key, message: "Reading the request…"),
            .statusChanged(key, .searching),
            .thought(key, message: "Reading Package.swift"),
            .statusChanged(key, .testing),
            .thought(key, message: "Running: npm"),
            .taskFailed(key, reason: nil),
            .bugDetected(key, evidence: "Tests failed"),
            .statusChanged(key, .coding),
            .thought(key, message: "Editing Fix.swift"),
            .thought(key, message: "Fixed the failing test and re-ran the suite."),
            .sessionUpdated(d1),
            .taskCompleted(key, domain: .swift, summary: nil),
        ]

        #expect(events.count == expected.count)
        for (index, pair) in zip(events, expected).enumerated() {
            #expect(pair.0 == pair.1, "event #\(index): got \(pair.0), expected \(pair.1)")
        }

        #expect(context.descriptor == d1)
        #expect(context.turnEnded)
        #expect(context.lastStatus == .coding)
        #expect(context.lastDomain == .swift)
        #expect(context.skipped == 1) // the unknown "sparkle.burst.1" record
        #expect(context.hasPending == false)
        #expect(context.seenUserMessages.contains("msg_u1"))
        #expect(context.completedMessages.contains("msg_a2"))
    }

    @Test("Only the final assistant round (finish == stop) completes the turn")
    func onlyStopCompletesTurn() {
        var context = OpenCodeParseContext(sessionID: Self.sessionID)
        let toolCalls = OpenCodeEventParser.parse(
            line: #"{"type":"message.updated.1","data":{"info":{"id":"m1","role":"assistant","time":{"created":1,"completed":2},"finish":"tool-calls"}}}"#,
            context: &context,
            receivedAt: Self.baseReceivedAt
        )
        #expect(toolCalls.isEmpty)
        #expect(context.turnEnded == false)

        let stop = OpenCodeEventParser.parse(
            line: #"{"type":"message.updated.1","data":{"info":{"id":"m2","role":"assistant","time":{"created":3,"completed":4},"finish":"stop"}}}"#,
            context: &context,
            receivedAt: Self.baseReceivedAt
        )
        #expect(stop == [.taskCompleted(Self.key, domain: nil, summary: nil)])
        #expect(context.turnEnded)
    }

    @Test("Classification is deferred until an input-bearing row (the pending row is empty)")
    func pendingRowDefersClassification() {
        var context = OpenCodeParseContext(sessionID: Self.sessionID)
        context.descriptor = OpenCodeEventParser.makeDescriptor(
            sessionID: Self.sessionID, directory: "/Users/dev/Reef", title: nil, model: nil, startedAt: Self.baseReceivedAt
        )
        // OpenCode's first row for a tool is pending with an empty input object.
        let pending = OpenCodeEventParser.parse(
            line: #"{"type":"message.part.updated.1","data":{"part":{"id":"p1","type":"tool","tool":"bash","state":{"status":"pending","input":{}}}}}"#,
            context: &context,
            receivedAt: Self.baseReceivedAt
        )
        #expect(pending.isEmpty) // nothing emitted yet — input not available
        // The running row carries the real command; classification and bubble happen here.
        let running = OpenCodeEventParser.parse(
            line: #"{"type":"message.part.updated.1","data":{"part":{"id":"p1","type":"tool","tool":"bash","state":{"status":"running","input":{"command":"swift test"}}}}}"#,
            context: &context,
            receivedAt: Self.baseReceivedAt
        )
        #expect(running == [
            .statusChanged(Self.key, .testing),
            .thought(Self.key, message: "Running: swift"),
        ])
        // A passing test on completion raises the bug-resolved signal (isTest was captured at running).
        let completed = OpenCodeEventParser.parse(
            line: #"{"type":"message.part.updated.1","data":{"part":{"id":"p1","type":"tool","tool":"bash","state":{"status":"completed","input":{"command":"swift test"},"metadata":{"exit":0}}}}}"#,
            context: &context,
            receivedAt: Self.baseReceivedAt
        )
        #expect(completed == [.bugResolved(Self.key)])
    }

    @Test("A text part owned by a user message is not surfaced as the agent's thought")
    func userMessageTextIsNotAThought() {
        var context = OpenCodeParseContext(sessionID: Self.sessionID)
        context.descriptor = OpenCodeEventParser.makeDescriptor(
            sessionID: Self.sessionID, directory: "/Users/dev/Reef", title: nil, model: nil, startedAt: Self.baseReceivedAt
        )
        _ = OpenCodeEventParser.parse(
            line: #"{"type":"message.updated.1","data":{"info":{"id":"msg_u1","role":"user","time":{"created":1}}}}"#,
            context: &context,
            receivedAt: Self.baseReceivedAt
        )
        let userText = OpenCodeEventParser.parse(
            line: #"{"type":"message.part.updated.1","data":{"part":{"id":"pu","messageID":"msg_u1","type":"text","text":"Please fix the bug."}}}"#,
            context: &context,
            receivedAt: Self.baseReceivedAt
        )
        #expect(userText.isEmpty)
        // An assistant-owned text part IS surfaced.
        let assistantText = OpenCodeEventParser.parse(
            line: #"{"type":"message.part.updated.1","data":{"part":{"id":"pa","messageID":"msg_a1","type":"text","text":"Done."}}}"#,
            context: &context,
            receivedAt: Self.baseReceivedAt
        )
        #expect(assistantText == [.thought(Self.key, message: "Done.")])
    }

    @Test("A subagent (parent_id) descriptor is marked isSubagent for engine suppression")
    func subagentDescriptorMarked() {
        let child = OpenCodeEventParser.makeDescriptor(
            sessionID: "ses_child", directory: "/Users/dev/Reef", title: nil, model: nil,
            parentID: "ses_parent", startedAt: Self.baseReceivedAt
        )
        #expect(child.isSubagent)
        #expect(child.parentSessionID == "ses_parent")
    }

    @Test("A tool part first seen already completed emits both its start bubble and result")
    func coalescedToolCompletion() {
        var context = OpenCodeParseContext(sessionID: Self.sessionID)
        context.descriptor = OpenCodeEventParser.makeDescriptor(
            sessionID: Self.sessionID, directory: "/Users/dev/Reef", title: nil, model: nil, startedAt: Self.baseReceivedAt
        )
        let events = OpenCodeEventParser.parse(
            line: #"{"type":"message.part.updated.1","data":{"part":{"id":"p1","type":"tool","tool":"bash","state":{"status":"completed","input":{"command":"swift test"},"metadata":{"exit":0}}}}}"#,
            context: &context,
            receivedAt: Self.baseReceivedAt
        )
        #expect(events == [
            .statusChanged(Self.key, .testing),
            .thought(Self.key, message: "Running: swift"),
            .bugResolved(Self.key),
        ])
        #expect(context.hasPending == false)
    }

    @Test("A task tool opens a handoff pearl and closes it on completion")
    func taskToolHandoff() {
        var context = OpenCodeParseContext(sessionID: Self.sessionID)
        context.descriptor = OpenCodeEventParser.makeDescriptor(
            sessionID: Self.sessionID, directory: "/Users/dev/Reef", title: nil, model: nil, startedAt: Self.baseReceivedAt
        )
        let start = OpenCodeEventParser.parse(
            line: #"{"type":"message.part.updated.1","data":{"part":{"id":"t1","type":"tool","tool":"task","state":{"status":"running","input":{"description":"Explore the codebase"}}}}}"#,
            context: &context,
            receivedAt: Self.baseReceivedAt
        )
        #expect(start == [
            .statusChanged(Self.key, .handingOff),
            .handoff(Self.key, subagentType: "Explore the codebase", description: "Reef"),
        ])
        let end = OpenCodeEventParser.parse(
            line: #"{"type":"message.part.updated.1","data":{"part":{"id":"t1","type":"tool","tool":"task","state":{"status":"completed","input":{"description":"Explore the codebase"}}}}}"#,
            context: &context,
            receivedAt: Self.baseReceivedAt
        )
        #expect(end == [.handoffReturned(Self.key, success: true)])
    }

    @Test("Reasoning parts surface a de-emphasized bubble, once per part id")
    func reasoningBubble() {
        var context = OpenCodeParseContext(sessionID: Self.sessionID)
        context.descriptor = OpenCodeEventParser.makeDescriptor(
            sessionID: Self.sessionID, directory: "/Users/dev/Reef", title: nil, model: nil, startedAt: Self.baseReceivedAt
        )
        let first = OpenCodeEventParser.parse(
            line: #"{"type":"message.part.updated.1","data":{"part":{"id":"r1","type":"reasoning","text":"**Planning the fix**\nI will edit Fix.swift."}}}"#,
            context: &context,
            receivedAt: Self.baseReceivedAt
        )
        #expect(first == [.thought(Self.key, message: "Planning the fix")])
        // The same reasoning part streaming again is not re-emitted.
        let again = OpenCodeEventParser.parse(
            line: #"{"type":"message.part.updated.1","data":{"part":{"id":"r1","type":"reasoning","text":"**Planning the fix**\nI will edit Fix.swift now, carefully."}}}"#,
            context: &context,
            receivedAt: Self.baseReceivedAt
        )
        #expect(again.isEmpty)
    }

    @Test("Garbage fixture yields zero events and counts skipped lines without crashing")
    func garbageResilience() throws {
        var context = OpenCodeParseContext(sessionID: Self.sessionID)
        let events = try runFixture("opencode-garbage.jsonl", context: &context)
        #expect(events.isEmpty)
        #expect(context.skipped == 5)
        #expect(context.descriptor == nil)
        #expect(context.hasPending == false)
    }
}
