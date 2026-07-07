import Foundation
import VivariumCore

/// Adapts a provider-specific pure parser (Claude, Codex) to the generic session monitor.
public protocol TranscriptParsing: Sendable {
    associatedtype Context: Sendable
    static var provider: AgentProvider { get }
    static func makeContext(sessionID: String) -> Context
    static func parse(line: String, context: inout Context, receivedAt: Date) -> [AgentEvent]
    static func descriptor(from context: Context) -> SessionDescriptor?
    static func turnEnded(_ context: Context) -> Bool
    static func hasPending(_ context: Context) -> Bool
    /// Derives a stable session id from the transcript file URL (used before the first record).
    static func sessionID(from url: URL) -> String
}

public enum ClaudeParsing: TranscriptParsing {
    public static let provider: AgentProvider = .claude
    public static func makeContext(sessionID: String) -> ClaudeParseContext {
        ClaudeParseContext(sessionID: sessionID)
    }
    public static func parse(line: String, context: inout ClaudeParseContext, receivedAt: Date) -> [AgentEvent] {
        ClaudeTranscriptParser.parse(line: line, context: &context, receivedAt: receivedAt)
    }
    public static func descriptor(from context: ClaudeParseContext) -> SessionDescriptor? { context.descriptor }
    public static func turnEnded(_ context: ClaudeParseContext) -> Bool { context.turnEnded }
    public static func hasPending(_ context: ClaudeParseContext) -> Bool { context.hasPendingToolUse }
    public static func sessionID(from url: URL) -> String {
        url.deletingPathExtension().lastPathComponent
    }
}

public enum CodexParsing: TranscriptParsing {
    public static let provider: AgentProvider = .codex
    public static func makeContext(sessionID: String) -> CodexParseContext {
        CodexParseContext(fallbackSessionID: sessionID)
    }
    public static func parse(line: String, context: inout CodexParseContext, receivedAt: Date) -> [AgentEvent] {
        CodexRolloutParser.parse(line: line, context: &context, receivedAt: receivedAt)
    }
    public static func descriptor(from context: CodexParseContext) -> SessionDescriptor? { context.descriptor }
    public static func turnEnded(_ context: CodexParseContext) -> Bool { context.turnEnded }
    public static func hasPending(_ context: CodexParseContext) -> Bool { context.hasPendingCall }
    public static func sessionID(from url: URL) -> String {
        // rollout-<stamp>-<uuid>.jsonl → last uuid-ish segment; fall back to filename.
        let stem = url.deletingPathExtension().lastPathComponent
        return stem
    }
}
