import Foundation
import VivariumCore

/// Mutable per-file parse state threaded through `CodexRolloutParser.parse`.
public struct CodexParseContext: Sendable, Equatable {
    public struct PendingCall: Sendable, Equatable {
        public var isTest: Bool

        public init(isTest: Bool) {
            self.isTest = isTest
        }
    }

    /// Session id derived from the rollout filename, used until `session_meta` arrives.
    public var fallbackSessionID: String
    public var descriptor: SessionDescriptor?
    public var isSubagentThread: Bool
    public var parentThreadID: String?
    public var turnEnded: Bool
    /// In-flight `function_call`s awaiting their `function_call_output`, keyed by `call_id`.
    public var pendingCalls: [String: PendingCall]
    public var lastStatus: AgentStatus?
    public var lastDomain: MemoryDomain?
    public var skippedLines: Int
    /// Last time any valid record was parsed; drives liveness even for silent records.
    public var lastEventAt: Date?

    public var hasPendingCall: Bool { !pendingCalls.isEmpty }

    public var sessionID: String { descriptor?.key.sessionID ?? fallbackSessionID }

    public var sessionKey: SessionKey { SessionKey(provider: .codex, sessionID: sessionID) }

    public init(fallbackSessionID: String) {
        self.fallbackSessionID = fallbackSessionID
        self.descriptor = nil
        self.isSubagentThread = false
        self.parentThreadID = nil
        self.turnEnded = false
        self.pendingCalls = [:]
        self.lastStatus = nil
        self.lastDomain = nil
        self.skippedLines = 0
        self.lastEventAt = nil
    }
}

/// Pure line → `[AgentEvent]` mapping for Codex CLI rollout files (`~/.codex/sessions/**.jsonl`).
public enum CodexRolloutParser {
    public static func parse(line: String, context: inout CodexParseContext, receivedAt: Date) -> [AgentEvent] {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        guard let record = CodexRecord.decode(line: trimmed), let type = record.type else {
            context.skippedLines += 1
            return []
        }
        context.lastEventAt = receivedAt
        switch type {
        case "session_meta":
            return handleSessionMeta(record, context: &context, receivedAt: receivedAt)
        case "turn_context":
            return handleTurnContext(record, context: &context)
        case "event_msg":
            return handleEventMessage(record, context: &context)
        case "response_item":
            return handleResponseItem(record, context: &context)
        case "compacted":
            return []
        default:
            context.skippedLines += 1
            return []
        }
    }

    // MARK: - Record handlers

    private static func handleSessionMeta(
        _ record: CodexRecord,
        context: inout CodexParseContext,
        receivedAt: Date
    ) -> [AgentEvent] {
        let payload = record.payload
        let sessionID = jsonString(member(payload, "id")) ?? context.fallbackSessionID
        let cwd = jsonString(member(payload, "cwd"))
        let subagentSource = member(member(payload, "source"), "subagent")
        let threadSpawn = member(subagentSource, "thread_spawn")
        let isSubagent = subagentSource != nil
            || jsonString(member(payload, "thread_source")) == "subagent"
        let parentThreadID = jsonString(member(threadSpawn, "parent_thread_id"))
            ?? jsonString(member(payload, "parent_thread_id"))
        let identity = SessionDescriptor.projectIdentity(fromCwd: cwd, provider: .codex)
        let startedAt = parseTimestamp(jsonString(member(payload, "timestamp")))
            ?? parseTimestamp(record.timestamp)
            ?? receivedAt
        let descriptor = SessionDescriptor(
            key: SessionKey(provider: .codex, sessionID: sessionID),
            projectPath: cwd,
            projectKey: identity.key,
            projectDisplayName: identity.displayName,
            isSubagent: isSubagent,
            parentSessionID: parentThreadID,
            startedAt: startedAt
        )
        context.descriptor = descriptor
        context.isSubagentThread = isSubagent
        context.parentThreadID = parentThreadID
        return [.sessionStarted(descriptor)]
    }

    private static func handleTurnContext(_ record: CodexRecord, context: inout CodexParseContext) -> [AgentEvent] {
        guard var descriptor = context.descriptor,
              let model = jsonString(member(record.payload, "model")),
              model != descriptor.model
        else { return [] }
        descriptor.model = model
        context.descriptor = descriptor
        return [.sessionUpdated(descriptor)]
    }

    private static func handleEventMessage(_ record: CodexRecord, context: inout CodexParseContext) -> [AgentEvent] {
        let payload = record.payload
        guard let subtype = jsonString(member(payload, "type")) else {
            context.skippedLines += 1
            return []
        }
        let key = context.sessionKey
        switch subtype {
        case "task_started":
            context.turnEnded = false
            return statusEvents(.planning, context: &context)
        case "user_message":
            return statusEvents(.planning, context: &context)
                + [.thought(key, message: "Reading the request…")]
        case "agent_message":
            guard let message = jsonString(member(payload, "message")) else { return [] }
            return [.thought(key, message: vivariumBubbleText(message))]
        case "patch_apply_end":
            return statusEvents(.coding, context: &context)
                + [.thought(key, message: "Applying patch…")]
        case "task_complete":
            context.turnEnded = true
            let last = jsonString(member(payload, "last_agent_message")) ?? ""
            return [.taskCompleted(key, domain: context.lastDomain, summary: vivariumBubbleText(last))]
        case "turn_aborted":
            context.turnEnded = true
            return [.taskFailed(key, reason: "interrupted")]
        case "token_count", "context_compacted", "web_search_end", "mcp_tool_call_end":
            return []
        default:
            context.skippedLines += 1
            return []
        }
    }

    private static func handleResponseItem(_ record: CodexRecord, context: inout CodexParseContext) -> [AgentEvent] {
        let payload = record.payload
        guard let subtype = jsonString(member(payload, "type")) else {
            context.skippedLines += 1
            return []
        }
        let key = context.sessionKey
        switch subtype {
        case "reasoning":
            return statusEvents(.planning, context: &context)
                + [.thought(key, message: "Thinking…")]
        case "function_call":
            return handleFunctionCall(payload, context: &context)
        case "function_call_output":
            return handleFunctionCallOutput(payload, context: &context)
        case "custom_tool_call":
            return statusEvents(.coding, context: &context)
                + [.thought(key, message: "Applying patch…")]
        case "web_search_call", "tool_search_call":
            return statusEvents(.searching, context: &context)
                + [.thought(key, message: "Searching the web…")]
        case "message", "custom_tool_call_output", "tool_search_output":
            return []
        default:
            context.skippedLines += 1
            return []
        }
    }

    private static func handleFunctionCall(_ payload: JSONValue?, context: inout CodexParseContext) -> [AgentEvent] {
        guard jsonString(member(payload, "name")) == "exec_command",
              let argumentsJSON = jsonString(member(payload, "arguments")),
              let arguments = try? JSONDecoder().decode(JSONValue.self, from: Data(argumentsJSON.utf8)),
              let command = commandString(from: member(arguments, "cmd"))
        else { return [] }
        if let callID = jsonString(member(payload, "call_id")) {
            context.pendingCalls[callID] = CodexParseContext.PendingCall(isTest: CommandClassifier.isTestCommand(command))
        }
        let status = CommandClassifier.status(forCommand: command)
        return statusEvents(status, context: &context)
            + [.thought(context.sessionKey, message: vivariumBubbleText("Running: \(CommandClassifier.firstToken(of: command))"))]
    }

    private static func handleFunctionCallOutput(_ payload: JSONValue?, context: inout CodexParseContext) -> [AgentEvent] {
        guard let callID = jsonString(member(payload, "call_id")),
              let pending = context.pendingCalls.removeValue(forKey: callID)
        else { return [] }
        let key = context.sessionKey
        let output = jsonString(member(payload, "output")) ?? ""
        if let code = exitCode(fromOutput: output) {
            var events: [AgentEvent] = [.taskFailed(key, reason: "exit \(code)")]
            if pending.isTest {
                events.append(.bugDetected(key, evidence: "Tests failed (exit \(code))"))
            }
            return events
        }
        if pending.isTest {
            return [.bugResolved(key)]
        }
        return []
    }

    // MARK: - Helpers

    /// Emits `.statusChanged` only when the status actually changes (dedup, mirroring the Claude parser).
    private static func statusEvents(_ status: AgentStatus, context: inout CodexParseContext) -> [AgentEvent] {
        guard context.lastStatus != status else { return [] }
        context.lastStatus = status
        return [.statusChanged(context.sessionKey, status)]
    }

    /// Nonzero exit code from an `exec_command` output blob; `code 0` and unrelated text return nil.
    static func exitCode(fromOutput output: String) -> Int? {
        guard let match = output.firstMatch(of: /Process exited with code ([1-9][0-9]*)/) else { return nil }
        return Int(match.1)
    }

    private static func parseTimestamp(_ raw: String?) -> Date? {
        guard let raw else { return nil }
        if let date = try? Date(raw, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)) {
            return date
        }
        return try? Date(raw, strategy: .iso8601)
    }
}

// File-private JSONValue accessors that depend only on the enum's case shape.

private func member(_ value: JSONValue?, _ key: String) -> JSONValue? {
    guard case .object(let dictionary)? = value else { return nil }
    return dictionary[key]
}

private func jsonString(_ value: JSONValue?) -> String? {
    guard case .string(let string)? = value else { return nil }
    return string
}

/// `exec_command` cmd is either one shell string or an argv array of strings.
private func commandString(from value: JSONValue?) -> String? {
    switch value {
    case .string(let string):
        return string
    case .array(let items):
        let parts = items.compactMap { item -> String? in
            guard case .string(let part) = item else { return nil }
            return part
        }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    default:
        return nil
    }
}
