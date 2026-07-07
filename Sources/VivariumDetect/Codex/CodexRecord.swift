import Foundation

/// One decoded line of a Codex CLI rollout file:
/// `{"timestamp": "ISO8601", "type": "session_meta" | "event_msg" | …, "payload": {…}}`.
struct CodexRecord: Decodable {
    var timestamp: String?
    var type: String?
    var payload: JSONValue?

    static func decode(line: String) -> CodexRecord? {
        try? JSONDecoder().decode(CodexRecord.self, from: Data(line.utf8))
    }
}
