import Foundation
import VivariumCore

/// Mutable per-session parse state threaded through `OpenCodeEventParser.parse`.
/// Value type so the monitor can snapshot/replay it freely. Unlike the transcript providers,
/// OpenCode's session id (`ses_…`) is known up front (it is the event log's `aggregate_id`),
/// so `sessionID` is populated at init and never derived from a file name.
public struct OpenCodeParseContext: Sendable, Equatable {
    /// A tool part awaiting its terminal (`completed`/`error`) state, keyed by part id. OpenCode
    /// streams each tool part as several event rows (`pending` → `running` → `completed`); we emit
    /// the "start" bubble once on first sight and map the result to semantics on completion.
    public struct PendingTool: Sendable, Equatable {
        public var tool: String
        public var isTest: Bool
        /// Whether the "start" bubble/status has been emitted. Deferred until an input-bearing row
        /// arrives, because OpenCode's first (`pending`) row for a tool carries an empty input.
        public var emittedStart: Bool

        public init(tool: String, isTest: Bool, emittedStart: Bool = false) {
            self.tool = tool
            self.isTest = isTest
            self.emittedStart = emittedStart
        }
    }

    /// The `ses_…` aggregate id — authoritative session id for the whole log.
    public var sessionID: String
    public var descriptor: SessionDescriptor?
    public var lastStatus: AgentStatus?
    public var lastDomain: MemoryDomain?
    /// True after the assistant's final response (`finish == "stop"`); the monitor's watchdog
    /// promotes this to `waitingForUser` after a quiet period.
    public var turnEnded: Bool
    /// User message ids already turned into a "new turn" so re-emitted metadata updates are ignored.
    public var seenUserMessages: Set<String>
    /// Assistant message ids already celebrated, so a re-emitted `stop` update never double-fires.
    public var completedMessages: Set<String>
    /// In-flight tool parts awaiting a terminal state, keyed by part id.
    public var pendingTools: [String: PendingTool]
    /// Text/reasoning part ids already surfaced as a bubble (they can stream across several rows).
    public var seenTextParts: Set<String>
    public var skipped: Int

    /// Permission-prompt heuristic input: a tool started but never reported completion.
    public var hasPending: Bool { !pendingTools.isEmpty }

    public var sessionKey: SessionKey {
        SessionKey(provider: .opencode, sessionID: descriptor?.key.sessionID ?? sessionID)
    }

    public init(sessionID: String) {
        self.sessionID = sessionID
        self.descriptor = nil
        self.lastStatus = nil
        self.lastDomain = nil
        self.turnEnded = false
        self.seenUserMessages = []
        self.completedMessages = []
        self.pendingTools = [:]
        self.seenTextParts = []
        self.skipped = 0
    }
}

/// One decoded row of the OpenCode event log (`event` table), or one fixture line
/// (`{"type": …, "data": {…}}`). Every field is optional so schema drift never fails a session.
struct OpenCodeEventRecord: Decodable {
    var type: String?
    var data: JSONValue?

    static func decode(line: String) -> OpenCodeEventRecord? {
        try? JSONDecoder().decode(OpenCodeEventRecord.self, from: Data(line.utf8))
    }
}

/// Pure `(event type, event data) → [AgentEvent]` mapping for OpenCode's SQLite event log
/// (`~/.local/share/opencode/opencode.db`, table `event`, one monotonic `seq` per session).
///
/// OpenCode is event-sourced: `session.created`/`session.updated` carry the descriptor, an assistant
/// `message.updated` with `finish == "stop"` ends the turn, and `message.part.updated` streams the
/// work (tool calls, text, reasoning). Unknown record types and malformed data degrade to skips,
/// never a failure.
public enum OpenCodeEventParser {
    private static let searchTools: Set<String> = ["read", "grep", "glob", "list", "webfetch", "fetch"]
    private static let editTools: Set<String> = ["edit", "write", "multiedit", "patch", "apply_patch"]

    // MARK: - Entry points

    /// Fixture/test convenience: parse a `{"type": …, "data": …}` line.
    public static func parse(line: String, context: inout OpenCodeParseContext, receivedAt: Date) -> [AgentEvent] {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        guard let record = OpenCodeEventRecord.decode(line: trimmed), let type = record.type else {
            context.skipped += 1
            return []
        }
        return parse(type: type, data: record.data, context: &context, receivedAt: receivedAt)
    }

    /// Primary entry point used by the monitor, which reads `type` and `data` as separate columns.
    public static func parse(
        type: String,
        data: JSONValue?,
        context: inout OpenCodeParseContext,
        receivedAt: Date
    ) -> [AgentEvent] {
        switch type {
        case "session.created.1", "session.updated.1":
            return handleSession(data, context: &context, receivedAt: receivedAt)
        case "message.updated.1":
            return handleMessage(data, context: &context)
        case "message.part.updated.1":
            return handlePart(data, context: &context, receivedAt: receivedAt)
        default:
            context.skipped += 1
            return []
        }
    }

    // MARK: - Session records

    private static func handleSession(
        _ data: JSONValue?,
        context: inout OpenCodeParseContext,
        receivedAt: Date
    ) -> [AgentEvent] {
        guard let info = data?["info"] else { context.skipped += 1; return [] }
        let sessionID = info["id"]?.stringValue ?? context.sessionID
        let createdMs = info["time"]?["created"]?.numberValue
        let started = createdMs.map { Date(timeIntervalSince1970: $0 / 1000) } ?? receivedAt
        let descriptor = makeDescriptor(
            sessionID: sessionID,
            directory: info["directory"]?.stringValue,
            title: info["title"]?.stringValue,
            model: info["model"]?["id"]?.stringValue,
            parentID: info["parentID"]?.stringValue,
            startedAt: context.descriptor?.startedAt ?? started
        )
        if context.descriptor == nil {
            context.descriptor = descriptor
            return [.sessionStarted(descriptor)]
        }
        guard descriptor != context.descriptor else { return [] }
        context.descriptor = descriptor
        return [.sessionUpdated(descriptor)]
    }

    // MARK: - Message records

    private static func handleMessage(_ data: JSONValue?, context: inout OpenCodeParseContext) -> [AgentEvent] {
        guard let info = data?["info"] else { context.skipped += 1; return [] }
        let key = context.sessionKey
        switch info["role"]?.stringValue {
        case "user":
            guard let id = info["id"]?.stringValue, !context.seenUserMessages.contains(id) else { return [] }
            context.seenUserMessages.insert(id)
            context.turnEnded = false
            var events = statusEvents(.planning, context: &context)
            events.append(.thought(key, message: "Reading the request…"))
            return events
        case "assistant":
            let completed = isPresent(info["time"]?["completed"])
            let finish = info["finish"]?.stringValue
            // OpenCode emits one assistant message per model round; only the final round finishes
            // with "stop" (intermediate rounds are "tool-calls"). Celebrate the turn once, on stop.
            guard completed, finish == "stop" else {
                context.turnEnded = false
                return []
            }
            guard let id = info["id"]?.stringValue, !context.completedMessages.contains(id) else { return [] }
            context.completedMessages.insert(id)
            context.turnEnded = true
            return [.taskCompleted(key, domain: context.lastDomain, summary: nil)]
        default:
            return []
        }
    }

    // MARK: - Part records (the streaming work)

    private static func handlePart(
        _ data: JSONValue?,
        context: inout OpenCodeParseContext,
        receivedAt: Date
    ) -> [AgentEvent] {
        guard let part = data?["part"] else { context.skipped += 1; return [] }
        switch part["type"]?.stringValue {
        case "tool":
            return handleToolPart(part, context: &context)
        case "text":
            return handleTextPart(part, context: &context)
        case "reasoning":
            return handleReasoningPart(part, context: &context)
        case "step-start", "step-finish", "patch", "snapshot":
            // Known lifecycle markers with no independent bubble — the tool/message records cover them.
            return []
        default:
            context.skipped += 1
            return []
        }
    }

    private static func handleToolPart(_ part: JSONValue, context: inout OpenCodeParseContext) -> [AgentEvent] {
        guard let partID = part["id"]?.stringValue else { context.skipped += 1; return [] }
        let tool = part["tool"]?.stringValue ?? "tool"
        let status = part["state"]?["status"]?.stringValue ?? "running"
        let input = part["state"]?["input"]
        let key = context.sessionKey
        let terminal = status == "completed" || status == "error"
        var events: [AgentEvent] = []

        // Track the part on first sight. Classification is DEFERRED until we actually have input:
        // OpenCode streams tool parts pending(input={}) → running(input=…) → completed, so reading
        // input on the pending row would see nothing (wrong status, no test/domain detection).
        if context.pendingTools[partID] == nil {
            context.pendingTools[partID] = OpenCodeParseContext.PendingTool(tool: tool, isTest: false)
        }
        var pending = context.pendingTools[partID]!

        if !pending.emittedStart, hasInput(input) || terminal {
            let plan = classify(tool: tool, input: input)
            events += statusEvents(plan.status, context: &context)
            if tool == "task" {
                events.append(.handoff(key, subagentType: plan.bubble, description: context.descriptor?.projectDisplayName))
            } else {
                events.append(.thought(key, message: vivariumBubbleText(plan.bubble)))
            }
            if let domain = plan.domain { context.lastDomain = domain }
            pending.isTest = plan.isTest
            pending.emittedStart = true
            context.pendingTools[partID] = pending
        }

        if terminal, let done = context.pendingTools.removeValue(forKey: partID) {
            let failed = status == "error" || bashFailed(tool: tool, part: part)
            if done.tool == "task" {
                events.append(.handoffReturned(key, success: !failed))
            } else if failed {
                events.append(.taskFailed(key, reason: nil))
                if done.isTest { events.append(.bugDetected(key, evidence: "Tests failed")) }
            } else if done.isTest {
                events.append(.bugResolved(key))
            }
        }
        return events
    }

    private static func handleTextPart(_ part: JSONValue, context: inout OpenCodeParseContext) -> [AgentEvent] {
        guard let partID = part["id"]?.stringValue, !context.seenTextParts.contains(partID),
              let text = part["text"]?.stringValue, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return [] }
        // A text part owned by a user message is the human's prompt echoed back, not the agent's
        // output — never surface it as the fish's thought.
        if let messageID = part["messageID"]?.stringValue, context.seenUserMessages.contains(messageID) {
            return []
        }
        context.seenTextParts.insert(partID)
        return [.thought(context.sessionKey, message: vivariumBubbleText(text))]
    }

    private static func handleReasoningPart(_ part: JSONValue, context: inout OpenCodeParseContext) -> [AgentEvent] {
        guard let partID = part["id"]?.stringValue, !context.seenTextParts.contains(partID),
              let raw = part["text"]?.stringValue else { return [] }
        let cleaned = stripMarkdown(raw)
        guard !cleaned.isEmpty else { return [] }
        context.seenTextParts.insert(partID)
        return [.thought(context.sessionKey, message: vivariumBubbleText(cleaned))]
    }

    // MARK: - Classification

    private struct ToolPlan {
        var status: AgentStatus
        var bubble: String
        var isTest: Bool = false
        var domain: MemoryDomain?
    }

    private static func classify(tool: String, input: JSONValue?) -> ToolPlan {
        switch tool {
        case "bash":
            let command = input?["command"]?.stringValue ?? ""
            return ToolPlan(
                status: CommandClassifier.status(forCommand: command),
                bubble: "Running: \(CommandClassifier.firstToken(of: command))",
                isTest: CommandClassifier.isTestCommand(command)
            )
        case "read":
            let name = baseName(input?["filePath"]?.stringValue ?? input?["path"]?.stringValue)
            return ToolPlan(status: .searching, bubble: "Reading \(name ?? "file")")
        case "grep":
            let pattern = input?["pattern"]?.stringValue ?? ""
            return ToolPlan(status: .searching, bubble: pattern.isEmpty ? "Searching…" : "Searching \(pattern)")
        case "glob", "list":
            let pattern = input?["pattern"]?.stringValue
            return ToolPlan(status: .searching, bubble: pattern.map { "Finding \($0)" } ?? "Listing files")
        case "webfetch", "fetch":
            let host = URL(string: input?["url"]?.stringValue ?? "")?.host
            return ToolPlan(status: .searching, bubble: host.map { "Fetching \($0)" } ?? "Fetching…")
        case "task":
            let desc = input?["description"]?.stringValue ?? input?["subagent_type"]?.stringValue ?? "subagent"
            return ToolPlan(status: .handingOff, bubble: desc)
        case "todowrite", "todoread":
            return ToolPlan(status: .planning, bubble: "Planning tasks…")
        case let name where editTools.contains(name):
            let path = input?["filePath"]?.stringValue ?? firstPatchPath(input?["patchText"]?.stringValue)
            let verb = name == "write" ? "Creating" : "Editing"
            return ToolPlan(
                status: .coding,
                bubble: "\(verb) \(baseName(path) ?? "files")",
                domain: domain(forPath: path)
            )
        default:
            let display = tool.contains("_") ? (tool.components(separatedBy: "_").last ?? tool) : tool
            return ToolPlan(status: .coding, bubble: "Using \(display)")
        }
    }

    // MARK: - Helpers

    /// Builds a descriptor from raw session fields. Ignores the auto-generated "New session - …"
    /// placeholder title so a fish is never labelled with a timestamp.
    public static func makeDescriptor(
        sessionID: String,
        directory: String?,
        title: String?,
        model: String?,
        parentID: String? = nil,
        startedAt: Date
    ) -> SessionDescriptor {
        let identity = SessionDescriptor.projectIdentity(fromCwd: directory, provider: .opencode)
        let cleanTitle: String?
        if let title, !title.isEmpty, !title.hasPrefix("New session") {
            cleanTitle = title
        } else {
            cleanTitle = nil
        }
        let parent = (parentID?.isEmpty ?? true) ? nil : parentID
        return SessionDescriptor(
            key: SessionKey(provider: .opencode, sessionID: sessionID),
            projectPath: directory,
            projectKey: identity.key,
            projectDisplayName: identity.displayName,
            gitBranch: nil,
            title: cleanTitle,
            model: (model?.isEmpty ?? true) ? nil : model,
            isSubagent: parent != nil,
            parentSessionID: parent,
            startedAt: startedAt
        )
    }

    /// Emits `.statusChanged` only on a real transition (self-dedup via `lastStatus`).
    private static func statusEvents(_ status: AgentStatus, context: inout OpenCodeParseContext) -> [AgentEvent] {
        guard context.lastStatus != status else { return [] }
        context.lastStatus = status
        return [.statusChanged(context.sessionKey, status)]
    }

    /// A `bash` tool that finished with a non-zero exit is a failure even when `status == "completed"`.
    private static func bashFailed(tool: String, part: JSONValue) -> Bool {
        guard tool == "bash", let exit = part["state"]?["metadata"]?["exit"]?.numberValue else { return false }
        return exit != 0
    }

    private static func isPresent(_ value: JSONValue?) -> Bool {
        guard let value else { return false }
        return value != .null
    }

    /// A non-empty input object. OpenCode's pending row carries `input == {}`; the real arguments
    /// only arrive on the running/completed rows.
    private static func hasInput(_ value: JSONValue?) -> Bool {
        guard case .object(let object) = value else { return false }
        return !object.isEmpty
    }

    private static func baseName(_ path: String?) -> String? {
        guard let path, !path.isEmpty else { return nil }
        return (path as NSString).lastPathComponent
    }

    /// Pulls the first target path out of an apply_patch `patchText`
    /// ("*** Add File: /a/b.md" / "*** Update File: …").
    private static func firstPatchPath(_ patchText: String?) -> String? {
        guard let patchText,
              let match = patchText.firstMatch(of: /\*\*\* (?:Add|Update|Delete) File: (.+)/) else { return nil }
        let path = String(match.1).trimmingCharacters(in: .whitespaces)
        return path.isEmpty ? nil : path
    }

    private static func stripMarkdown(_ raw: String) -> String {
        let firstLine = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .newlines)
            .first ?? ""
        return firstLine
            .trimmingCharacters(in: CharacterSet(charactersIn: "*#`_ "))
    }

    /// Domain guess for an edited file; test-looking paths win over the language extension.
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
