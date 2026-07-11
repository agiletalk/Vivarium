import Foundation
import VivariumCore

/// Mutable per-session parse state threaded through `GeminiTelemetryParser.parse`.
///
/// Unlike the transcript providers (one file == one session), Gemini writes *all* sessions to a
/// single OpenTelemetry `outfile`, tagged with a `session.id` common attribute. The monitor demuxes
/// records to one context per `session.id`; each context owns that session's descriptor and turn
/// state. Value type so the monitor can snapshot it freely.
public struct GeminiParseContext: Sendable, Equatable {
    /// The telemetry `session.id` — authoritative id for the whole session.
    public var sessionID: String
    public var descriptor: SessionDescriptor?
    public var lastStatus: AgentStatus?
    public var lastDomain: MemoryDomain?
    public var model: String?
    /// True after the model yielded the turn back to the user (`next_speaker_check == "user"`);
    /// the monitor's watchdog promotes this to `waitingForUser` after a quiet period.
    public var turnEnded: Bool
    /// A test tool has failed and no passing test has cleared it yet (drives the bug shark).
    public var bugOpen: Bool
    public var startedAt: Date?
    public var skipped: Int

    public var sessionKey: SessionKey {
        SessionKey(provider: .gemini, sessionID: descriptor?.key.sessionID ?? sessionID)
    }

    public init(sessionID: String) {
        self.sessionID = sessionID
        self.descriptor = nil
        self.lastStatus = nil
        self.lastDomain = nil
        self.model = nil
        self.turnEnded = false
        self.bugOpen = false
        self.startedAt = nil
        self.skipped = 0
    }
}

/// Reassembles whole JSON records from the byte-tailed lines of Gemini's telemetry outfile.
///
/// Gemini's file exporter serializes each OpenTelemetry record with `JSON.stringify(record, 2)` —
/// i.e. **pretty-printed** across many lines — then appends a newline. `TailReader` yields those
/// individual lines; this assembler re-joins them and slices out complete top-level `{…}` objects by
/// tracking brace depth (string- and escape-aware), so it works whether records are pretty-printed
/// multi-line or compact one-per-line.
public struct GeminiRecordAssembler: Sendable {
    private var carry: String = ""
    /// After an overflow, drop input until a fresh top-level record boundary is seen again.
    private var resyncing = false
    /// If the buffer grows past this without closing an object, the file is garbage — resync.
    private static let maxCarry = 4 * 1024 * 1024

    public init() {}

    /// Feeds newly-drained lines and returns any complete JSON record strings now available.
    public mutating func push(_ lines: [String]) -> [String] {
        guard !lines.isEmpty else { return [] }
        var lines = lines
        if resyncing {
            // Records are top-level objects; Gemini pretty-prints each with its `{` at column 0 and
            // compact records begin the line with `{`. Resume only at such a boundary.
            guard let start = lines.firstIndex(where: { $0.hasPrefix("{") }) else { return [] }
            lines = Array(lines[start...])
            carry = ""
            resyncing = false
        }
        if !carry.isEmpty { carry += "\n" }
        carry += lines.joined(separator: "\n")
        return extract()
    }

    private mutating func extract() -> [String] {
        var records: [String] = []
        var depth = 0
        var inString = false
        var escaped = false
        var start: String.Index?
        var lastComplete = carry.startIndex
        var idx = carry.startIndex
        while idx < carry.endIndex {
            let c = carry[idx]
            if inString {
                if escaped { escaped = false }
                else if c == "\\" { escaped = true }
                else if c == "\"" { inString = false }
            } else {
                switch c {
                case "\"": inString = true
                case "{":
                    if depth == 0 { start = idx }
                    depth += 1
                case "}":
                    if depth > 0 {
                        depth -= 1
                        if depth == 0, let s = start {
                            records.append(String(carry[s...idx]))
                            lastComplete = carry.index(after: idx)
                            start = nil
                        }
                    }
                default:
                    break
                }
            }
            idx = carry.index(after: idx)
        }
        carry = String(carry[lastComplete...])
        if carry.utf8.count > Self.maxCarry {
            carry = ""
            resyncing = true
        }
        return records
    }
}

/// Pure `(telemetry record) → [AgentEvent]` mapping for Gemini CLI's OpenTelemetry log stream.
///
/// Each record is one OTel log with an `event.name` (e.g. `gemini_cli.tool_call`) and a flat
/// `attributes` map that carries `session.id` plus event-specific fields. Gemini logs a `tool_call`
/// once per *completed* call (with `success`/`duration_ms`/`decision`), a `user_prompt` at the start
/// of each turn, and a `next_speaker_check` whose `result == "user"` marks the turn handed back.
/// The reader is deliberately lenient about the envelope (plain-object attributes, OTLP `{key,value}`
/// arrays, or flat top-level fields) so exporter/version drift degrades to a skip, never a failure.
public enum GeminiTelemetryParser {
    // MARK: - Envelope handling

    /// The `session.id` a record belongs to, for the monitor's demux. Nil if the record has none.
    public static func sessionID(ofRecord recordJSON: String) -> String? {
        guard let record = decode(recordJSON) else { return nil }
        return sessionID(of: attributes(of: record), record: record)
    }

    static func decode(_ json: String) -> JSONValue? {
        let trimmed = json.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return try? JSONDecoder().decode(JSONValue.self, from: Data(trimmed.utf8))
    }

    /// Normalizes a record's attributes to a plain object, handling all three shapes the exporter
    /// might produce: a plain `attributes` object (OTel SDK `ReadableLogRecord`), an OTLP-wire
    /// `attributes` array of `{key, value:{stringValue,…}}`, or flat fields on the record itself.
    static func attributes(of record: JSONValue) -> JSONValue {
        if let attrs = record["attributes"] {
            if case .object = attrs { return attrs }
            if let array = attrs.arrayValue {
                var dict: [String: JSONValue] = [:]
                for item in array {
                    if let key = item["key"]?.stringValue, let value = item["value"] {
                        dict[key] = unwrapAnyValue(value)
                    }
                }
                return .object(dict)
            }
        }
        return record
    }

    /// Unwraps an OTLP `AnyValue` (`{stringValue|intValue|doubleValue|boolValue: …}`) to a plain
    /// JSONValue; passes plain values through untouched.
    private static func unwrapAnyValue(_ value: JSONValue) -> JSONValue {
        if let s = value["stringValue"] { return s }
        if let b = value["boolValue"] { return b }
        if let d = value["doubleValue"] { return d }
        if let i = value["intValue"] {
            if let n = i.numberValue { return .number(n) }
            if let s = i.stringValue, let n = Double(s) { return .number(n) }
        }
        return value
    }

    static func eventName(of attrs: JSONValue, record: JSONValue) -> String? {
        attrs["event.name"]?.stringValue
            ?? attrs["event_name"]?.stringValue
            ?? record["event.name"]?.stringValue
            ?? record["event_name"]?.stringValue
            ?? bodyString(record).flatMap { $0.hasPrefix("gemini_cli.") ? $0 : nil }
    }

    static func sessionID(of attrs: JSONValue, record: JSONValue) -> String? {
        attrs["session.id"]?.stringValue
            ?? attrs["sessionId"]?.stringValue
            ?? attrs["session_id"]?.stringValue
            ?? record["session.id"]?.stringValue
            ?? record["sessionId"]?.stringValue
    }

    private static func bodyString(_ record: JSONValue) -> String? {
        if let s = record["body"]?.stringValue { return s }
        return record["body"]?["stringValue"]?.stringValue
    }

    // MARK: - Entry points

    /// Fixture/test convenience: parse one record's JSON text.
    public static func parse(record recordJSON: String, context: inout GeminiParseContext, receivedAt: Date) -> [AgentEvent] {
        guard !recordJSON.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        guard let record = decode(recordJSON) else { context.skipped += 1; return [] }
        let attrs = attributes(of: record)
        guard let event = eventName(of: attrs, record: record) else { context.skipped += 1; return [] }
        return parse(eventName: event, attrs: attrs, context: &context, receivedAt: receivedAt)
    }

    /// Primary mapping used by the monitor once the record is decoded and routed by `session.id`.
    public static func parse(
        eventName: String,
        attrs: JSONValue,
        context: inout GeminiParseContext,
        receivedAt: Date
    ) -> [AgentEvent] {
        switch eventName {
        case "gemini_cli.config":
            // Fires once at session startup (even with no tool use and prompts unlogged), so it is
            // the earliest reliable "a Gemini session is live" signal — announce the fish here.
            return handleConfig(attrs, context: &context, receivedAt: receivedAt)
        case "gemini_cli.user_prompt":
            return handleUserPrompt(attrs, context: &context, receivedAt: receivedAt)
        case "gemini_cli.tool_call":
            return handleToolCall(attrs, context: &context, receivedAt: receivedAt)
        case "gemini_cli.api_response", "gemini_cli.api_request":
            return handleModelInfo(attrs, context: &context, receivedAt: receivedAt)
        case "gemini_cli.next_speaker_check":
            return handleNextSpeaker(attrs, context: &context)
        default:
            context.skipped += 1
            return []
        }
    }

    // MARK: - Handlers

    /// Session startup: announce the fish and adopt the configured model (ignoring the "auto"
    /// placeholder, which is resolved to a concrete id later via `api_response`).
    private static func handleConfig(
        _ attrs: JSONValue,
        context: inout GeminiParseContext,
        receivedAt: Date
    ) -> [AgentEvent] {
        var events = ensureStarted(context: &context, receivedAt: receivedAt)
        if let model = attrs["model"]?.stringValue, !model.isEmpty, model != "auto", model != "none" {
            events += applyModel(model, context: &context)
        }
        return events
    }

    private static func handleUserPrompt(
        _ attrs: JSONValue,
        context: inout GeminiParseContext,
        receivedAt: Date
    ) -> [AgentEvent] {
        var events = ensureStarted(context: &context, receivedAt: receivedAt)
        context.turnEnded = false
        events += statusEvents(.planning, context: &context)
        events.append(.thought(context.sessionKey, message: "Reading the request…"))
        return events
    }

    private static func handleToolCall(
        _ attrs: JSONValue,
        context: inout GeminiParseContext,
        receivedAt: Date
    ) -> [AgentEvent] {
        let name = attrs["function_name"]?.stringValue ?? "tool"
        let args = decodeArgs(attrs["function_args"])
        let success = boolValue(attrs["success"]) ?? true
        let key = context.sessionKey

        var events = ensureStarted(context: &context, receivedAt: receivedAt)
        context.turnEnded = false

        let plan = classify(function: name, args: args)
        events += statusEvents(plan.status, context: &context)
        if plan.isHandoff {
            events.append(.handoff(key, subagentType: plan.bubble, description: context.descriptor?.projectDisplayName))
        } else {
            events.append(.thought(key, message: vivariumBubbleText(plan.bubble)))
        }
        if let domain = plan.domain { context.lastDomain = domain }

        if plan.isHandoff {
            events.append(.handoffReturned(key, success: success))
        } else if !success {
            events.append(.taskFailed(key, reason: attrs["error"]?.stringValue))
            if plan.isTest, !context.bugOpen {
                context.bugOpen = true
                events.append(.bugDetected(key, evidence: "Tests failed"))
            }
        } else if plan.isTest, context.bugOpen {
            context.bugOpen = false
            events.append(.bugResolved(key))
        }
        return events
    }

    /// `api_request`/`api_response` carry the model id; use them only to fill/refresh the descriptor.
    private static func handleModelInfo(
        _ attrs: JSONValue,
        context: inout GeminiParseContext,
        receivedAt: Date
    ) -> [AgentEvent] {
        guard let model = attrs["model"]?.stringValue, !model.isEmpty else { return [] }
        var events = ensureStarted(context: &context, receivedAt: receivedAt)
        events += applyModel(model, context: &context)
        return events
    }

    /// Adopts a model id into the descriptor, emitting `sessionUpdated` only on a real change.
    private static func applyModel(_ model: String, context: inout GeminiParseContext) -> [AgentEvent] {
        guard context.model != model else { return [] }
        context.model = model
        guard var descriptor = context.descriptor, descriptor.model != model else { return [] }
        descriptor.model = model
        context.descriptor = descriptor
        return [.sessionUpdated(descriptor)]
    }

    /// The model deciding the next speaker is the user means the turn is finished → celebrate once.
    private static func handleNextSpeaker(_ attrs: JSONValue, context: inout GeminiParseContext) -> [AgentEvent] {
        guard context.descriptor != nil else { return [] }
        guard attrs["result"]?.stringValue == "user" else { return [] }
        guard !context.turnEnded else { return [] }
        context.turnEnded = true
        return [.taskCompleted(context.sessionKey, domain: context.lastDomain, summary: nil)]
    }

    // MARK: - Session descriptor

    /// Emits `sessionStarted` the first time any record for this session is seen. Gemini's telemetry
    /// exposes no working directory, so the fish binds to a provider-level "Gemini" identity.
    private static func ensureStarted(context: inout GeminiParseContext, receivedAt: Date) -> [AgentEvent] {
        guard context.descriptor == nil else { return [] }
        let identity = SessionDescriptor.projectIdentity(fromCwd: nil, provider: .gemini)
        let descriptor = SessionDescriptor(
            key: SessionKey(provider: .gemini, sessionID: context.sessionID),
            projectKey: identity.key,
            projectDisplayName: identity.displayName,
            model: context.model,
            startedAt: context.startedAt ?? receivedAt
        )
        context.descriptor = descriptor
        return [.sessionStarted(descriptor)]
    }

    // MARK: - Classification

    private struct ToolPlan {
        var status: AgentStatus
        var bubble: String
        var isTest: Bool = false
        var isHandoff: Bool = false
        var domain: MemoryDomain?
    }

    /// Maps a Gemini built-in tool (or MCP tool) call to a status + thought bubble.
    private static func classify(function: String, args: JSONValue?) -> ToolPlan {
        switch function {
        case "run_shell_command":
            let command = args?["command"]?.stringValue ?? ""
            return ToolPlan(
                status: CommandClassifier.status(forCommand: command),
                bubble: "Running: \(CommandClassifier.firstToken(of: command))",
                isTest: CommandClassifier.isTestCommand(command)
            )
        case "read_file", "read_many_files":
            let name = baseName(args?["absolute_path"]?.stringValue ?? args?["file_path"]?.stringValue ?? args?["path"]?.stringValue)
            return ToolPlan(status: .searching, bubble: "Reading \(name ?? "files")")
        case "write_file":
            let path = args?["file_path"]?.stringValue ?? args?["absolute_path"]?.stringValue
            return ToolPlan(status: .coding, bubble: "Creating \(baseName(path) ?? "file")", domain: domain(forPath: path))
        case "replace", "edit":
            let path = args?["file_path"]?.stringValue ?? args?["absolute_path"]?.stringValue
            return ToolPlan(status: .coding, bubble: "Editing \(baseName(path) ?? "file")", domain: domain(forPath: path))
        case "search_file_content", "grep_search":
            let pattern = args?["pattern"]?.stringValue ?? ""
            return ToolPlan(status: .searching, bubble: pattern.isEmpty ? "Searching…" : "Searching \(pattern)")
        case "glob":
            let pattern = args?["pattern"]?.stringValue
            return ToolPlan(status: .searching, bubble: pattern.map { "Finding \($0)" } ?? "Finding files")
        case "list_directory":
            let dir = baseName(args?["dir_path"]?.stringValue ?? args?["path"]?.stringValue)
            return ToolPlan(status: .searching, bubble: dir.map { "Listing \($0)" } ?? "Listing files")
        case "web_fetch":
            let host = URL(string: args?["url"]?.stringValue ?? args?["prompt"]?.stringValue ?? "")?.host
            return ToolPlan(status: .searching, bubble: host.map { "Fetching \($0)" } ?? "Fetching…")
        case "google_web_search":
            let query = args?["query"]?.stringValue
            return ToolPlan(status: .searching, bubble: query.map { "Searching \($0)" } ?? "Searching the web…")
        case "save_memory":
            return ToolPlan(status: .planning, bubble: "Saving memory…")
        default:
            let display = function.contains("__") ? (function.components(separatedBy: "__").last ?? function) : function
            return ToolPlan(status: .coding, bubble: "Using \(display)")
        }
    }

    // MARK: - Helpers

    /// `function_args` arrives as a JSON *string*; decode it to an object. Also tolerates an
    /// already-decoded object (should the exporter ever inline it).
    private static func decodeArgs(_ value: JSONValue?) -> JSONValue? {
        guard let value else { return nil }
        if case .object = value { return value }
        guard let raw = value.stringValue, !raw.isEmpty else { return nil }
        return try? JSONDecoder().decode(JSONValue.self, from: Data(raw.utf8))
    }

    private static func boolValue(_ value: JSONValue?) -> Bool? {
        guard let value else { return nil }
        if let b = value.boolValue { return b }
        if let s = value.stringValue { return s == "true" }
        if let n = value.numberValue { return n != 0 }
        return nil
    }

    private static func statusEvents(_ status: AgentStatus, context: inout GeminiParseContext) -> [AgentEvent] {
        guard context.lastStatus != status else { return [] }
        context.lastStatus = status
        return [.statusChanged(context.sessionKey, status)]
    }

    private static func baseName(_ path: String?) -> String? {
        guard let path, !path.isEmpty else { return nil }
        return (path as NSString).lastPathComponent
    }

    private static func domain(forPath path: String?) -> MemoryDomain? {
        guard let path else { return nil }
        let lowered = path.lowercased()
        if lowered.contains("test") || lowered.contains("spec") { return .testing }
        switch (path as NSString).pathExtension.lowercased() {
        case "swift": return .swift
        case "ts", "tsx", "jsx", "vue", "css", "html": return .ui
        case "py", "go", "rb", "java", "sql", "rs": return .backend
        default: return nil
        }
    }
}
