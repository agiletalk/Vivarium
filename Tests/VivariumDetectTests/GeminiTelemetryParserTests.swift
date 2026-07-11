import Foundation
import Testing
import VivariumCore
@testable import VivariumDetect

@Suite("GeminiTelemetryParser")
struct GeminiTelemetryParserTests {
    private static let sessionID = "sess_abc"
    private static let key = SessionKey(provider: .gemini, sessionID: sessionID)
    private static let baseReceivedAt = Date(timeIntervalSince1970: 1_750_000_000)

    private func fixtureURL(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures")
            .appendingPathComponent(name)
    }

    // MARK: - Golden fixture (assembler + parser end to end)

    @Test("Golden telemetry log maps to the exact ordered event sequence")
    func goldenSequence() throws {
        let text = try String(contentsOf: fixtureURL("gemini-telemetry.log"), encoding: .utf8)
        var assembler = GeminiRecordAssembler()
        let records = assembler.push(text.components(separatedBy: "\n"))

        var context = GeminiParseContext(sessionID: Self.sessionID)
        var events: [AgentEvent] = []
        for record in records {
            events += GeminiTelemetryParser.parse(record: record, context: &context, receivedAt: Self.baseReceivedAt)
        }

        let key = Self.key
        let d0 = SessionDescriptor(
            key: key,
            projectKey: "gemini",
            projectDisplayName: "Gemini",
            model: nil,
            startedAt: Self.baseReceivedAt
        )
        var d1 = d0
        d1.model = "gemini-2.5-pro"

        let expected: [AgentEvent] = [
            .sessionStarted(d0),
            .statusChanged(key, .planning),
            .thought(key, message: "Reading the request…"),
            .sessionUpdated(d1),
            .statusChanged(key, .searching),
            .thought(key, message: "Reading Package.swift"),
            .statusChanged(key, .testing),
            .thought(key, message: "Running: swift"),
            .taskFailed(key, reason: "tests failed"),
            .bugDetected(key, evidence: "Tests failed"),
            .statusChanged(key, .coding),
            .thought(key, message: "Editing Fix.swift"),
            .statusChanged(key, .testing),
            .thought(key, message: "Running: swift"),
            .bugResolved(key),
            .taskCompleted(key, domain: .swift, summary: nil),
        ]

        #expect(events.count == expected.count)
        for (index, pair) in zip(events, expected).enumerated() {
            #expect(pair.0 == pair.1, "event #\(index): got \(pair.0), expected \(pair.1)")
        }

        #expect(context.descriptor == d1)
        #expect(context.turnEnded)
        #expect(context.lastStatus == .testing)
        #expect(context.lastDomain == .swift)
        #expect(context.bugOpen == false)
        #expect(context.skipped == 1) // the unknown flash_fallback record
    }

    // MARK: - Record assembler

    @Test("Assembler splits compact one-per-line records")
    func assemblerCompact() {
        var assembler = GeminiRecordAssembler()
        let records = assembler.push([#"{"a":1}"#, #"{"b":2}"#])
        #expect(records.count == 2)
    }

    @Test("Assembler reassembles a pretty-printed record split across pushes")
    func assemblerMultiLineIncremental() {
        var assembler = GeminiRecordAssembler()
        #expect(assembler.push(["{", #"  "a": 1,"#]).isEmpty) // still open
        let done = assembler.push([#"  "b": 2"#, "}"])
        #expect(done.count == 1)
        let decoded = GeminiTelemetryParser.decode(done[0])
        #expect(decoded?["a"]?.numberValue == 1)
        #expect(decoded?["b"]?.numberValue == 2)
    }

    @Test("Braces inside string values do not break record boundaries")
    func assemblerIgnoresBracesInStrings() {
        var assembler = GeminiRecordAssembler()
        let records = assembler.push([#"{"cmd":"echo }{ nested","n":1}"#])
        #expect(records.count == 1)
        #expect(GeminiTelemetryParser.decode(records[0])?["cmd"]?.stringValue == "echo }{ nested")
    }

    // MARK: - Envelope tolerance

    @Test("Flat top-level record (event_name + session.id) parses")
    func flatEnvelope() {
        var context = GeminiParseContext(sessionID: "s1")
        let events = GeminiTelemetryParser.parse(
            record: #"{"event_name":"gemini_cli.user_prompt","session.id":"s1"}"#,
            context: &context,
            receivedAt: Self.baseReceivedAt
        )
        #expect(events.contains(.statusChanged(SessionKey(provider: .gemini, sessionID: "s1"), .planning)))
        #expect(context.descriptor != nil)
    }

    @Test("OTLP-array attributes shape is flattened and parsed")
    func otlpArrayEnvelope() {
        var context = GeminiParseContext(sessionID: "s1")
        let record = #"""
        {"attributes":[{"key":"event.name","value":{"stringValue":"gemini_cli.tool_call"}},{"key":"session.id","value":{"stringValue":"s1"}},{"key":"function_name","value":{"stringValue":"read_file"}},{"key":"function_args","value":{"stringValue":"{\"absolute_path\":\"/a/b/Foo.swift\"}"}},{"key":"success","value":{"boolValue":true}}]}
        """#
        let events = GeminiTelemetryParser.parse(record: record, context: &context, receivedAt: Self.baseReceivedAt)
        let key = SessionKey(provider: .gemini, sessionID: "s1")
        #expect(events.contains(.statusChanged(key, .searching)))
        #expect(events.contains(.thought(key, message: "Reading Foo.swift")))
    }

    // MARK: - Turn completion & resilience

    @Test("next_speaker_check result=model does not complete the turn")
    func nextSpeakerModelDoesNotComplete() {
        var context = GeminiParseContext(sessionID: Self.sessionID)
        context.descriptor = SessionDescriptor(
            key: Self.key, projectKey: "gemini", projectDisplayName: "Gemini", startedAt: Self.baseReceivedAt
        )
        let events = GeminiTelemetryParser.parse(
            record: #"{"attributes":{"event.name":"gemini_cli.next_speaker_check","session.id":"sess_abc","result":"model"}}"#,
            context: &context,
            receivedAt: Self.baseReceivedAt
        )
        #expect(events.isEmpty)
        #expect(context.turnEnded == false)
    }

    @Test("A failing then passing test raises and clears the bug shark once")
    func testFailThenPass() {
        var context = GeminiParseContext(sessionID: Self.sessionID)
        context.descriptor = SessionDescriptor(
            key: Self.key, projectKey: "gemini", projectDisplayName: "Gemini", startedAt: Self.baseReceivedAt
        )
        let fail = GeminiTelemetryParser.parse(
            record: #"{"attributes":{"event.name":"gemini_cli.tool_call","session.id":"sess_abc","function_name":"run_shell_command","function_args":"{\"command\":\"swift test\"}","success":false}}"#,
            context: &context, receivedAt: Self.baseReceivedAt
        )
        #expect(fail.contains(.bugDetected(Self.key, evidence: "Tests failed")))
        #expect(context.bugOpen)
        let pass = GeminiTelemetryParser.parse(
            record: #"{"attributes":{"event.name":"gemini_cli.tool_call","session.id":"sess_abc","function_name":"run_shell_command","function_args":"{\"command\":\"swift test\"}","success":true}}"#,
            context: &context, receivedAt: Self.baseReceivedAt
        )
        #expect(pass.contains(.bugResolved(Self.key)))
        #expect(context.bugOpen == false)
    }

    @Test("session.id routing is exposed for the monitor's demux")
    func sessionIDRouting() {
        let sid = GeminiTelemetryParser.sessionID(
            ofRecord: #"{"attributes":{"event.name":"gemini_cli.user_prompt","session.id":"sess_xyz"}}"#
        )
        #expect(sid == "sess_xyz")
    }

    @Test("config event announces the session and adopts a concrete model")
    func configStartsSession() {
        var context = GeminiParseContext(sessionID: "sess_cfg")
        let key = SessionKey(provider: .gemini, sessionID: "sess_cfg")
        let events = GeminiTelemetryParser.parse(
            record: #"{"attributes":{"event.name":"gemini_cli.config","session.id":"sess_cfg","model":"gemini-2.5-flash"}}"#,
            context: &context, receivedAt: Self.baseReceivedAt
        )
        let d0 = SessionDescriptor(key: key, projectKey: "gemini", projectDisplayName: "Gemini", model: nil, startedAt: Self.baseReceivedAt)
        var d1 = d0
        d1.model = "gemini-2.5-flash"
        #expect(events == [.sessionStarted(d0), .sessionUpdated(d1)])
        #expect(context.descriptor == d1)
    }

    @Test("config model=auto announces the session but sets no model")
    func configAutoModel() {
        var context = GeminiParseContext(sessionID: "s")
        let events = GeminiTelemetryParser.parse(
            record: #"{"attributes":{"event.name":"gemini_cli.config","session.id":"s","model":"auto"}}"#,
            context: &context, receivedAt: Self.baseReceivedAt
        )
        #expect(events.count == 1) // sessionStarted only
        #expect(context.descriptor?.model == nil)
    }

    @Test("Garbage lines yield zero events and count skips without crashing")
    func garbageResilience() throws {
        let text = try String(contentsOf: fixtureURL("gemini-telemetry-garbage.log"), encoding: .utf8)
        var context = GeminiParseContext(sessionID: "g")
        var events: [AgentEvent] = []
        for line in text.components(separatedBy: "\n") {
            events += GeminiTelemetryParser.parse(record: line, context: &context, receivedAt: Self.baseReceivedAt)
        }
        #expect(events.isEmpty)
        #expect(context.skipped == 5)
        #expect(context.descriptor == nil)
    }
}
