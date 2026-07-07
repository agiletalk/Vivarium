import Foundation

/// Phase-one probe: only the record type. Any line whose type is missing or unknown is skipped,
/// never failed, because the Claude CLI adds new record types between releases.
struct ClaudeRecordProbe: Decodable {
    let type: String?
}

/// Conversation-record envelope (`user`/`assistant`/`system`/`attachment`).
/// Every field is optional so schema drift degrades to "less information", not a parse failure.
struct ClaudeConversationRecord: Decodable {
    let type: String?
    let uuid: String?
    let parentUuid: String?
    let isSidechain: Bool?
    let isMeta: Bool?
    let timestamp: String?
    let sessionId: String?
    let cwd: String?
    let gitBranch: String?
    let version: String?
    let message: ClaudeMessage?
}

struct ClaudeMessage: Decodable {
    let role: String?
    let model: String?
    let stopReason: String?
    /// Plain string for typed user prompts, or an array of content blocks.
    let content: JSONValue?

    enum CodingKeys: String, CodingKey {
        case role
        case model
        case stopReason = "stop_reason"
        case content
    }
}

struct ClaudeAITitleRecord: Decodable {
    let aiTitle: String?
}

/// `permission-mode` records carry the value under `permissionMode` (verified against CLI 2.1.20x);
/// `mode` is accepted as a fallback spelling.
struct ClaudePermissionModeRecord: Decodable {
    let permissionMode: String?
    let mode: String?

    var effectiveMode: String? { permissionMode ?? mode }
}
