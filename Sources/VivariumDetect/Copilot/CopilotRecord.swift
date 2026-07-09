import Foundation

/// One decoded line of a GitHub Copilot CLI session-state file
/// (`~/.copilot/session-state/<uuid>.jsonl`):
/// `{"type": "session.start" | "tool.execution_start" | …, "timestamp": …, "id": …, "parentId": …, "data": {…}}`.
///
/// Every field is optional so schema drift between Copilot CLI releases degrades to
/// "less information", never a parse failure.
struct CopilotRecord: Decodable {
    var type: String?
    var timestamp: String?
    var data: JSONValue?

    static func decode(line: String) -> CopilotRecord? {
        try? JSONDecoder().decode(CopilotRecord.self, from: Data(line.utf8))
    }
}
