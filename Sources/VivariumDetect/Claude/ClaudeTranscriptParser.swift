import Foundation
import VivariumCore

/// A tool_use awaiting its tool_result, so results can be mapped back to semantics
/// (handoff return, test pass/fail) by `tool_use_id`.
public struct PendingToolUse: Sendable, Equatable {
    public var name: String
    public var isTest: Bool
    public var isTask: Bool
    public var domain: MemoryDomain?

    public init(name: String, isTest: Bool = false, isTask: Bool = false, domain: MemoryDomain? = nil) {
        self.name = name
        self.isTest = isTest
        self.isTask = isTask
        self.domain = domain
    }
}

/// Per-session accumulator threaded through `ClaudeTranscriptParser.parse`.
/// Value type so the session monitor can snapshot/replay it freely.
public struct ClaudeParseContext: Sendable, Equatable {
    public let sessionID: String
    public fileprivate(set) var cwd: String?
    public fileprivate(set) var gitBranch: String?
    public fileprivate(set) var model: String?
    public fileprivate(set) var title: String?
    public fileprivate(set) var descriptorEmitted = false
    public fileprivate(set) var pendingToolUses: [String: PendingToolUse] = [:]
    public fileprivate(set) var lastStopReason: String?
    public fileprivate(set) var lastEventAt: Date?
    public fileprivate(set) var lastDomain: MemoryDomain?
    public fileprivate(set) var lastStatus: AgentStatus?
    public fileprivate(set) var skippedLines = 0
    public fileprivate(set) var startedAt: Date?
    /// True after the last assistant record ended with stop_reason "end_turn";
    /// the coordinator's waiting-watchdog reads this.
    public fileprivate(set) var turnEnded = false
    /// Available once the first conversation record carrying a cwd has been parsed.
    public fileprivate(set) var descriptor: SessionDescriptor?

    /// Permission-prompt heuristic input: a tool_use was issued but no result has arrived yet.
    public var hasPendingToolUse: Bool { !pendingToolUses.isEmpty }

    public init(sessionID: String) {
        self.sessionID = sessionID
    }

    fileprivate mutating func rebuildDescriptor(key: SessionKey, fallbackStartedAt: Date) {
        let identity = SessionDescriptor.projectIdentity(fromCwd: cwd, provider: .claude)
        descriptor = SessionDescriptor(
            key: key,
            projectPath: cwd,
            projectKey: identity.key,
            projectDisplayName: identity.displayName,
            gitBranch: gitBranch,
            title: title,
            model: model,
            isSubagent: false,
            parentSessionID: nil,
            startedAt: startedAt ?? fallbackStartedAt
        )
    }
}

/// Pure line → `AgentEvent` mapping for Claude Code JSONL transcripts.
/// Never throws and never fails a session on malformed input: unknown record types,
/// truncated JSON, and schema drift all degrade to skipped lines.
public enum ClaudeTranscriptParser {
    /// Record types that are recognized but carry no semantics for the aquarium.
    private static let ignoredRecordTypes: Set<String> = [
        "mode", "file-history-snapshot", "last-prompt", "queue-operation", "bridge-session",
    ]

    private static let searchToolNames: Set<String> = [
        "Read", "Grep", "Glob", "ToolSearch", "WebSearch", "WebFetch", "LS", "List", "ls",
    ]

    private static let editToolNames: Set<String> = [
        "Edit", "Write", "MultiEdit", "NotebookEdit",
    ]

    /// Parses one JSONL line, mutating `context`, and returns the semantic events it implies.
    public static func parse(line: String, context: inout ClaudeParseContext, receivedAt: Date) -> [AgentEvent] {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            context.skippedLines += 1
            return []
        }
        let data = Data(trimmed.utf8)
        let decoder = JSONDecoder()
        guard let probe = try? decoder.decode(ClaudeRecordProbe.self, from: data), let type = probe.type else {
            context.skippedLines += 1
            return []
        }

        let key = SessionKey(provider: .claude, sessionID: context.sessionID)
        var events: [AgentEvent] = []
        switch type {
        case "user", "assistant", "system", "attachment":
            guard let record = try? decoder.decode(ClaudeConversationRecord.self, from: data) else {
                context.skippedLines += 1
                return []
            }
            events = handleConversation(record, key: key, context: &context, receivedAt: receivedAt)
        case "ai-title":
            guard let record = try? decoder.decode(ClaudeAITitleRecord.self, from: data) else {
                context.skippedLines += 1
                return []
            }
            events = handleAITitle(record, key: key, context: &context, receivedAt: receivedAt)
        case "permission-mode":
            guard let record = try? decoder.decode(ClaudePermissionModeRecord.self, from: data) else {
                context.skippedLines += 1
                return []
            }
            if record.effectiveMode == "plan" {
                events = statusChange(to: .planning, key: key, context: &context)
            }
        case _ where ignoredRecordTypes.contains(type):
            break
        default:
            context.skippedLines += 1
        }

        if !events.isEmpty {
            context.lastEventAt = receivedAt
        }
        return events
    }

    // MARK: - Record handlers

    private static func handleConversation(
        _ record: ClaudeConversationRecord,
        key: SessionKey,
        context: inout ClaudeParseContext,
        receivedAt: Date
    ) -> [AgentEvent] {
        if record.isSidechain == true { return [] }

        if context.cwd == nil, let cwd = record.cwd, !cwd.isEmpty {
            context.cwd = cwd
        }
        if let branch = record.gitBranch, !branch.isEmpty {
            context.gitBranch = branch
        }
        if let model = record.message?.model, !model.isEmpty {
            context.model = model
        }
        if context.startedAt == nil {
            context.startedAt = parseTimestamp(record.timestamp) ?? receivedAt
        }

        var events: [AgentEvent] = []
        if context.descriptorEmitted {
            context.rebuildDescriptor(key: key, fallbackStartedAt: receivedAt)
        } else if context.cwd != nil {
            context.rebuildDescriptor(key: key, fallbackStartedAt: receivedAt)
            context.descriptorEmitted = true
            if let descriptor = context.descriptor {
                events.append(.sessionStarted(descriptor))
            }
        }

        switch record.type {
        case "user":
            events += handleUser(record, key: key, context: &context)
        case "assistant":
            events += handleAssistant(record, key: key, context: &context)
        default:
            break
        }
        return events
    }

    private static func handleAITitle(
        _ record: ClaudeAITitleRecord,
        key: SessionKey,
        context: inout ClaudeParseContext,
        receivedAt: Date
    ) -> [AgentEvent] {
        guard let title = record.aiTitle, !title.isEmpty else { return [] }
        context.title = title
        guard context.descriptorEmitted else { return [] }
        context.rebuildDescriptor(key: key, fallbackStartedAt: receivedAt)
        guard let descriptor = context.descriptor else { return [] }
        return [.sessionUpdated(descriptor)]
    }

    private static func handleUser(
        _ record: ClaudeConversationRecord,
        key: SessionKey,
        context: inout ClaudeParseContext
    ) -> [AgentEvent] {
        guard let content = record.message?.content else { return [] }
        switch content {
        case .string(let text):
            guard record.isMeta != true, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return []
            }
            return promptEvents(key: key, context: &context)
        case .array(let blocks):
            var events: [AgentEvent] = []
            var sawToolResult = false
            for block in blocks where block["type"]?.stringValue == "tool_result" {
                sawToolResult = true
                events += handleToolResult(block, key: key, context: &context)
            }
            if !sawToolResult,
               record.isMeta != true,
               blocks.contains(where: { $0["type"]?.stringValue == "text" }) {
                events += promptEvents(key: key, context: &context)
            }
            return events
        default:
            return []
        }
    }

    private static func promptEvents(key: SessionKey, context: inout ClaudeParseContext) -> [AgentEvent] {
        context.turnEnded = false
        var events = statusChange(to: .planning, key: key, context: &context)
        events.append(.thought(key, message: "Reading the request…"))
        return events
    }

    private static func handleAssistant(
        _ record: ClaudeConversationRecord,
        key: SessionKey,
        context: inout ClaudeParseContext
    ) -> [AgentEvent] {
        var events: [AgentEvent] = []
        if let blocks = record.message?.content?.arrayValue {
            for block in blocks {
                switch block["type"]?.stringValue {
                case "thinking":
                    // Thinking text is encrypted — never surface it. Emit the pair only on a
                    // real status transition so consecutive thinking blocks don't spam bubbles.
                    if context.lastStatus != .planning {
                        events += statusChange(to: .planning, key: key, context: &context)
                        events.append(.thought(key, message: "Thinking…"))
                    }
                case "text":
                    if let text = block["text"]?.stringValue {
                        let bubble = vivariumBubbleText(text)
                        if !bubble.isEmpty {
                            events.append(.thought(key, message: bubble))
                        }
                    }
                case "tool_use":
                    events += handleToolUse(block, key: key, context: &context)
                default:
                    break
                }
            }
        }
        if let stopReason = record.message?.stopReason {
            context.lastStopReason = stopReason
            switch stopReason {
            case "end_turn":
                context.turnEnded = true
                events.append(.taskCompleted(key, domain: context.lastDomain, summary: nil))
            case "tool_use":
                context.turnEnded = false
            default:
                break
            }
        }
        return events
    }

    // MARK: - Tool dispatch

    private static func handleToolUse(
        _ block: JSONValue,
        key: SessionKey,
        context: inout ClaudeParseContext
    ) -> [AgentEvent] {
        guard let name = block["name"]?.stringValue else { return [] }
        let input = block["input"]
        var pending = PendingToolUse(name: name)
        var events: [AgentEvent] = []

        if searchToolNames.contains(name) {
            events += statusChange(to: .searching, key: key, context: &context)
            events.append(.thought(key, message: vivariumBubbleText(searchBubble(name: name, input: input))))
        } else if editToolNames.contains(name) {
            events += statusChange(to: .coding, key: key, context: &context)
            let path = input?["file_path"]?.stringValue ?? input?["notebook_path"]?.stringValue
            let fileName = path.map { ($0 as NSString).lastPathComponent }
            events.append(.thought(key, message: vivariumBubbleText("Editing \(fileName ?? "files")")))
            if let path, let domain = domain(forPath: path) {
                context.lastDomain = domain
                pending.domain = domain
            }
        } else {
            switch name {
            case "Bash":
                let command = input?["command"]?.stringValue ?? ""
                events += statusChange(to: CommandClassifier.status(forCommand: command), key: key, context: &context)
                let bubble = input?["description"]?.stringValue
                    ?? "Running: \(CommandClassifier.firstToken(of: command))"
                events.append(.thought(key, message: vivariumBubbleText(bubble)))
                pending.isTest = CommandClassifier.isTestCommand(command)
            case "Task":
                pending.isTask = true
                events.append(.handoff(
                    key,
                    subagentType: input?["subagent_type"]?.stringValue ?? "agent",
                    description: input?["description"]?.stringValue
                ))
            case "TaskUpdate":
                if input?["status"]?.stringValue == "completed" {
                    events.append(.taskCompleted(key, domain: context.lastDomain, summary: nil))
                }
            case "TodoWrite":
                if let todos = input?["todos"]?.arrayValue, !todos.isEmpty,
                   todos.allSatisfy({ $0["status"]?.stringValue == "completed" }) {
                    events.append(.taskCompleted(key, domain: context.lastDomain, summary: nil))
                }
            case "AskUserQuestion":
                events.append(.waitingForUser(key, kind: .question))
            default:
                if name.hasPrefix("mcp__") {
                    events += statusChange(to: .coding, key: key, context: &context)
                    let toolName = name.components(separatedBy: "__").last ?? name
                    events.append(.thought(key, message: vivariumBubbleText("Using \(toolName)")))
                }
            }
        }

        if let id = block["id"]?.stringValue {
            context.pendingToolUses[id] = pending
        }
        return events
    }

    private static func handleToolResult(
        _ block: JSONValue,
        key: SessionKey,
        context: inout ClaudeParseContext
    ) -> [AgentEvent] {
        guard let id = block["tool_use_id"]?.stringValue,
              let pending = context.pendingToolUses.removeValue(forKey: id) else {
            return []
        }
        let isError = block["is_error"]?.boolValue ?? false
        if pending.isTask {
            return [.handoffReturned(key, success: !isError)]
        }
        if isError {
            var events: [AgentEvent] = [.taskFailed(key, reason: nil)]
            if pending.isTest {
                events.append(.bugDetected(key, evidence: "Tests failed"))
            }
            return events
        }
        if pending.isTest {
            return [.bugResolved(key)]
        }
        return []
    }

    // MARK: - Helpers

    /// Emits a statusChanged only on a real transition (self-dedup via `lastStatus`).
    private static func statusChange(
        to status: AgentStatus,
        key: SessionKey,
        context: inout ClaudeParseContext
    ) -> [AgentEvent] {
        guard context.lastStatus != status else { return [] }
        context.lastStatus = status
        return [.statusChanged(key, status)]
    }

    private static func searchBubble(name: String, input: JSONValue?) -> String {
        switch name {
        case "Read", "LS", "List", "ls":
            if let path = input?["file_path"]?.stringValue ?? input?["path"]?.stringValue {
                return "Reading \((path as NSString).lastPathComponent)"
            }
            return "Reading files"
        case "Grep", "Glob":
            if let pattern = input?["pattern"]?.stringValue {
                return "Searching: \(pattern)"
            }
        case "WebSearch", "ToolSearch":
            if let query = input?["query"]?.stringValue {
                return "Searching: \(query)"
            }
        case "WebFetch":
            if let url = input?["url"]?.stringValue {
                return "Reading \(url)"
            }
        default:
            break
        }
        return "Searching…"
    }

    /// Domain guess for an edited file. Test-looking paths win over the language extension,
    /// since nearly every test file also carries a code extension.
    private static func domain(forPath path: String) -> MemoryDomain? {
        let lowered = path.lowercased()
        if lowered.contains("test") || lowered.contains("spec") {
            return .testing
        }
        switch (path as NSString).pathExtension.lowercased() {
        case "swift":
            return .swift
        case "ts", "tsx", "jsx", "vue", "css", "html":
            return .ui
        case "py", "go", "rb", "java", "sql", "rs":
            return .backend
        default:
            return nil
        }
    }

    private static func parseTimestamp(_ raw: String?) -> Date? {
        guard let raw else { return nil }
        if let date = try? Date(raw, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)) {
            return date
        }
        return try? Date(raw, strategy: .iso8601)
    }
}
