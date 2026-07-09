import Foundation
import VivariumCore

/// Mutable per-file parse state threaded through `CopilotSessionParser.parse`.
/// Value type so the session monitor can snapshot/replay it freely.
public struct CopilotParseContext: Sendable, Equatable {
    /// A `tool.execution_start` awaiting its `tool.execution_complete`, so the result can be
    /// mapped back to semantics (test pass/fail) by `toolCallId`.
    public struct PendingTool: Sendable, Equatable {
        public var isTest: Bool

        public init(isTest: Bool) {
            self.isTest = isTest
        }
    }

    /// Session id derived from the file name, used until `session.start` supplies the real one.
    public var fallbackSessionID: String
    public var descriptor: SessionDescriptor?
    public var cwd: String?
    public var model: String?
    public var startedAt: Date?
    /// In-flight tool executions awaiting their completion, keyed by `toolCallId`.
    public var pendingTools: [String: PendingTool]
    public var lastStatus: AgentStatus?
    public var lastDomain: MemoryDomain?
    /// True after the last assistant turn ended with no tool requests (final response) or an abort;
    /// the monitor's waiting-watchdog reads this.
    public var turnEnded: Bool
    public var skippedLines: Int
    /// Last time any valid record was parsed; drives liveness even for silent records.
    public var lastEventAt: Date?

    /// Permission-prompt heuristic input: a tool was started but its completion has not arrived.
    public var hasPendingTool: Bool { !pendingTools.isEmpty }

    public var sessionID: String { descriptor?.key.sessionID ?? fallbackSessionID }

    public var sessionKey: SessionKey { SessionKey(provider: .copilot, sessionID: sessionID) }

    public init(fallbackSessionID: String) {
        self.fallbackSessionID = fallbackSessionID
        self.descriptor = nil
        self.cwd = nil
        self.model = nil
        self.startedAt = nil
        self.pendingTools = [:]
        self.lastStatus = nil
        self.lastDomain = nil
        self.turnEnded = false
        self.skippedLines = 0
        self.lastEventAt = nil
    }
}

/// Pure line → `[AgentEvent]` mapping for GitHub Copilot CLI session-state files
/// (`~/.copilot/session-state/*.jsonl`). Never throws and never fails a session on malformed
/// input: unknown record types, truncated JSON, and schema drift all degrade to skipped lines.
public enum CopilotSessionParser {
    /// Tool names that mean "reading/looking around" → `.searching`.
    private static let searchTools: Set<String> = ["view", "read_bash", "grep", "glob", "fetch", "search"]
    /// Tool names that mutate files → `.coding`.
    private static let editTools: Set<String> = ["edit", "create", "str_replace", "write", "insert", "delete"]

    public static func parse(line: String, context: inout CopilotParseContext, receivedAt: Date) -> [AgentEvent] {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        guard let record = CopilotRecord.decode(line: trimmed), let type = record.type else {
            context.skippedLines += 1
            return []
        }
        context.lastEventAt = receivedAt
        let data = record.data
        switch type {
        case "session.start":
            return handleSessionStart(data, context: &context, receivedAt: receivedAt)
        case "session.info":
            return handleSessionInfo(data, context: &context)
        case "session.model_change":
            return handleModelChange(data, context: &context)
        case "user.message":
            return handleUserMessage(context: &context, receivedAt: receivedAt)
        case "assistant.message":
            return handleAssistantMessage(data, context: &context, receivedAt: receivedAt)
        case "tool.execution_start":
            return handleToolStart(data, context: &context, receivedAt: receivedAt)
        case "tool.execution_complete":
            return handleToolComplete(data, context: &context)
        case "abort":
            return handleAbort(context: &context, receivedAt: receivedAt)
        default:
            context.skippedLines += 1
            return []
        }
    }

    // MARK: - Record handlers

    private static func handleSessionStart(
        _ data: JSONValue?,
        context: inout CopilotParseContext,
        receivedAt: Date
    ) -> [AgentEvent] {
        if let sessionID = data?["sessionId"]?.stringValue, !sessionID.isEmpty {
            context.fallbackSessionID = sessionID
        }
        context.startedAt = parseTimestamp(data?["startTime"]?.stringValue) ?? receivedAt
        // A session.start replaces any provisional descriptor synthesized mid-file.
        let descriptor = makeDescriptor(context: context, fallbackStartedAt: receivedAt)
        context.descriptor = descriptor
        return [.sessionStarted(descriptor)]
    }

    private static func handleSessionInfo(_ data: JSONValue?, context: inout CopilotParseContext) -> [AgentEvent] {
        // Only `folder_trust` carries a working directory ("Folder <path> has been added …").
        guard data?["infoType"]?.stringValue == "folder_trust",
              let message = data?["message"]?.stringValue,
              let path = trustedFolderPath(from: message),
              path != context.cwd
        else { return [] }
        context.cwd = path
        guard var descriptor = context.descriptor else { return [] }
        let identity = SessionDescriptor.projectIdentity(fromCwd: path, provider: .copilot)
        descriptor.projectPath = path
        descriptor.projectKey = identity.key
        descriptor.projectDisplayName = identity.displayName
        context.descriptor = descriptor
        return [.sessionUpdated(descriptor)]
    }

    private static func handleModelChange(_ data: JSONValue?, context: inout CopilotParseContext) -> [AgentEvent] {
        guard let model = data?["newModel"]?.stringValue, !model.isEmpty, model != context.model else { return [] }
        context.model = model
        guard var descriptor = context.descriptor else { return [] }
        descriptor.model = model
        context.descriptor = descriptor
        return [.sessionUpdated(descriptor)]
    }

    private static func handleUserMessage(context: inout CopilotParseContext, receivedAt: Date) -> [AgentEvent] {
        var events = ensureStarted(&context, receivedAt: receivedAt)
        context.turnEnded = false
        events += statusEvents(.planning, context: &context)
        events.append(.thought(context.sessionKey, message: "Reading the request…"))
        return events
    }

    private static func handleAssistantMessage(
        _ data: JSONValue?,
        context: inout CopilotParseContext,
        receivedAt: Date
    ) -> [AgentEvent] {
        var events = ensureStarted(&context, receivedAt: receivedAt)
        let key = context.sessionKey
        if let content = data?["content"]?.stringValue {
            let bubble = vivariumBubbleText(content)
            if !bubble.isEmpty { events.append(.thought(key, message: bubble)) }
        }
        // An assistant message with no tool requests is the model's final response → turn complete.
        let toolRequestCount = data?["toolRequests"]?.arrayValue?.count ?? 0
        if toolRequestCount == 0 {
            context.turnEnded = true
            events.append(.taskCompleted(key, domain: context.lastDomain, summary: nil))
        } else {
            context.turnEnded = false
        }
        return events
    }

    private static func handleToolStart(
        _ data: JSONValue?,
        context: inout CopilotParseContext,
        receivedAt: Date
    ) -> [AgentEvent] {
        guard let toolName = data?["toolName"]?.stringValue else {
            context.skippedLines += 1
            return []
        }
        var events = ensureStarted(&context, receivedAt: receivedAt)
        let key = context.sessionKey
        let arguments = data?["arguments"]
        var pending = CopilotParseContext.PendingTool(isTest: false)

        switch toolName {
        case "report_intent":
            if let intent = arguments?["intent"]?.stringValue, !intent.isEmpty {
                events += statusEvents(status(forIntent: intent), context: &context)
                events.append(.thought(key, message: vivariumBubbleText(intent)))
            }
        case "bash":
            let command = arguments?["command"]?.stringValue ?? ""
            events += statusEvents(CommandClassifier.status(forCommand: command), context: &context)
            let bubble = arguments?["description"]?.stringValue
                ?? "Running: \(CommandClassifier.firstToken(of: command))"
            events.append(.thought(key, message: vivariumBubbleText(bubble)))
            pending.isTest = CommandClassifier.isTestCommand(command)
        case let name where editTools.contains(name):
            events += statusEvents(.coding, context: &context)
            let path = arguments?["path"]?.stringValue
            let fileName = path.map { ($0 as NSString).lastPathComponent }
            let verb = name == "create" ? "Creating" : "Editing"
            events.append(.thought(key, message: vivariumBubbleText("\(verb) \(fileName ?? "files")")))
            if let path, let domain = domain(forPath: path) {
                context.lastDomain = domain
            }
        case let name where searchTools.contains(name):
            events += statusEvents(.searching, context: &context)
            if let path = arguments?["path"]?.stringValue {
                events.append(.thought(key, message: vivariumBubbleText("Reading \((path as NSString).lastPathComponent)")))
            } else {
                events.append(.thought(key, message: "Searching…"))
            }
        default:
            events += statusEvents(.coding, context: &context)
            let display = toolName.contains("__") ? (toolName.components(separatedBy: "__").last ?? toolName) : toolName
            events.append(.thought(key, message: vivariumBubbleText("Using \(display)")))
        }

        if let toolCallId = data?["toolCallId"]?.stringValue {
            context.pendingTools[toolCallId] = pending
        }
        return events
    }

    private static func handleToolComplete(_ data: JSONValue?, context: inout CopilotParseContext) -> [AgentEvent] {
        guard let toolCallId = data?["toolCallId"]?.stringValue,
              let pending = context.pendingTools.removeValue(forKey: toolCallId)
        else { return [] }
        let key = context.sessionKey
        let success = data?["success"]?.boolValue ?? true
        if !success {
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

    private static func handleAbort(context: inout CopilotParseContext, receivedAt: Date) -> [AgentEvent] {
        var events = ensureStarted(&context, receivedAt: receivedAt)
        context.turnEnded = true
        // Copilot aborts are user-initiated (Esc/Ctrl-C), not work failures — surface as a
        // turn end so the watchdog treats it as waiting, without penalizing the fish.
        events.append(.waitingForUser(context.sessionKey, kind: .endOfTurn))
        return events
    }

    // MARK: - Helpers

    /// Emits the initial `sessionStarted` if the session's descriptor has not been built yet
    /// (e.g. the file was seeded near EOF and its `session.start` line was never read). No-op once
    /// a descriptor exists, so it never double-emits after a real `session.start`.
    private static func ensureStarted(_ context: inout CopilotParseContext, receivedAt: Date) -> [AgentEvent] {
        guard context.descriptor == nil else { return [] }
        context.startedAt = context.startedAt ?? receivedAt
        let descriptor = makeDescriptor(context: context, fallbackStartedAt: receivedAt)
        context.descriptor = descriptor
        return [.sessionStarted(descriptor)]
    }

    private static func makeDescriptor(context: CopilotParseContext, fallbackStartedAt: Date) -> SessionDescriptor {
        let identity = SessionDescriptor.projectIdentity(fromCwd: context.cwd, provider: .copilot)
        return SessionDescriptor(
            key: SessionKey(provider: .copilot, sessionID: context.sessionID),
            projectPath: context.cwd,
            projectKey: identity.key,
            projectDisplayName: identity.displayName,
            gitBranch: nil,
            title: nil,
            model: context.model,
            isSubagent: false,
            parentSessionID: nil,
            startedAt: context.startedAt ?? fallbackStartedAt
        )
    }

    /// Emits `.statusChanged` only on a real transition (self-dedup via `lastStatus`).
    private static func statusEvents(_ status: AgentStatus, context: inout CopilotParseContext) -> [AgentEvent] {
        guard context.lastStatus != status else { return [] }
        context.lastStatus = status
        return [.statusChanged(context.sessionKey, status)]
    }

    /// Coarse status inference from a `report_intent` string; the concrete tool that follows
    /// refines it. Order matters — test/review beat the generic edit/search verbs.
    private static func status(forIntent intent: String) -> AgentStatus {
        let lowered = intent.lowercased()
        if lowered.contains("test") { return .testing }
        if lowered.contains("review") || lowered.contains("commit") || lowered.contains("diff") { return .reviewing }
        if lowered.contains("plan") { return .planning }
        if lowered.contains("explor") || lowered.contains("search") || lowered.contains("read")
            || lowered.contains("investigat") || lowered.contains("look") || lowered.contains("find")
            || lowered.contains("inspect") { return .searching }
        return .coding
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

    /// Extracts the path from a folder-trust info message:
    /// "Folder /Users/dev/Reef has been added to trusted folders."
    private static func trustedFolderPath(from message: String) -> String? {
        guard let match = message.firstMatch(of: /Folder (.+) has been added to trusted folders/) else {
            return nil
        }
        let path = String(match.1).trimmingCharacters(in: .whitespaces)
        return path.isEmpty ? nil : path
    }

    private static func parseTimestamp(_ raw: String?) -> Date? {
        guard let raw else { return nil }
        if let date = try? Date(raw, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)) {
            return date
        }
        return try? Date(raw, strategy: .iso8601)
    }
}
