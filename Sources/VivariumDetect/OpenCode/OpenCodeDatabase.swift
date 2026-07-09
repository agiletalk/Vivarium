import Foundation
import SQLite3

/// Read-only view over OpenCode's SQLite store (`~/.local/share/opencode/opencode.db`).
///
/// OpenCode has no tailable transcript: it persists an event-sourced log in `event` with one
/// monotonically increasing `seq` per session (mirrored in `event_sequence`). This wrapper opens
/// the database read-only — safe to run while the OpenCode CLI holds the WAL — and exposes just the
/// three reads the monitor needs: the per-session cursor, new events past a cursor, and the session
/// row (for seeding a descriptor without replaying history).
///
/// Not `Sendable`: instances are confined to `OpenCodeSessionMonitor`'s actor executor.
final class OpenCodeDatabase {
    struct SessionRow {
        var directory: String?
        var title: String?
        var model: String?
        /// Non-nil for subagent sessions spawned by a parent's `task` tool; such sessions are
        /// suppressed by the monitor (the parent shows a handoff pearl instead).
        var parentID: String?
        var timeCreatedMs: Int64
        var timeUpdatedMs: Int64
    }

    struct EventRow {
        var seq: Int64
        var type: String
        var data: String
    }

    private var handle: OpaquePointer?

    /// Opens the database read-only. Returns nil if the file is missing or cannot be opened.
    init?(path: String) {
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY
        guard sqlite3_open_v2(path, &db, flags, nil) == SQLITE_OK, let db else {
            if let db { sqlite3_close(db) }
            return nil
        }
        sqlite3_busy_timeout(db, 2_000)
        handle = db
    }

    deinit {
        if let handle { sqlite3_close(handle) }
    }

    /// The current max `seq` for every session that has events. Authoritative "what's new" cursor.
    func sessionSequences() -> [(sessionID: String, seq: Int64)] {
        var result: [(String, Int64)] = []
        prepared("SELECT aggregate_id, seq FROM event_sequence") { stmt in
            while sqlite3_step(stmt) == SQLITE_ROW {
                guard let id = text(stmt, 0) else { continue }
                result.append((id, sqlite3_column_int64(stmt, 1)))
            }
        }
        return result
    }

    /// Events for one session with `seq` strictly greater than `afterSeq`, in order.
    func events(sessionID: String, afterSeq: Int64) -> [EventRow] {
        var rows: [EventRow] = []
        prepared("SELECT seq, type, data FROM event WHERE aggregate_id = ?1 AND seq > ?2 ORDER BY seq") { stmt in
            bindText(stmt, 1, sessionID)
            sqlite3_bind_int64(stmt, 2, afterSeq)
            while sqlite3_step(stmt) == SQLITE_ROW {
                guard let type = text(stmt, 1), let data = text(stmt, 2) else { continue }
                rows.append(EventRow(seq: sqlite3_column_int64(stmt, 0), type: type, data: data))
            }
        }
        return rows
    }

    /// The session's descriptor fields, for seeding without replaying the event history.
    func session(id: String) -> SessionRow? {
        var row: SessionRow?
        // json_valid guard: a malformed (but non-NULL) model JSON would otherwise raise a step-time
        // error and abort the whole row read, dropping an otherwise-valid session.
        prepared("""
            SELECT directory, title,
                   CASE WHEN json_valid(model) THEN json_extract(model, '$.id') END,
                   parent_id, time_created, time_updated
            FROM session WHERE id = ?1
            """) { stmt in
            bindText(stmt, 1, id)
            if sqlite3_step(stmt) == SQLITE_ROW {
                row = SessionRow(
                    directory: text(stmt, 0),
                    title: text(stmt, 1),
                    model: text(stmt, 2),
                    parentID: text(stmt, 3),
                    timeCreatedMs: sqlite3_column_int64(stmt, 4),
                    timeUpdatedMs: sqlite3_column_int64(stmt, 5)
                )
            }
        }
        return row
    }

    /// The latest assistant message's completion state, used to seed `turnEnded` for a live session.
    func latestAssistantFinish(sessionID: String) -> (completed: Bool, finish: String?)? {
        var result: (Bool, String?)?
        prepared("""
            SELECT json_extract(data, '$.time.completed'), json_extract(data, '$.finish')
            FROM message
            WHERE session_id = ?1 AND json_valid(data) AND json_extract(data, '$.role') = 'assistant'
            ORDER BY time_created DESC LIMIT 1
            """) { stmt in
            bindText(stmt, 1, sessionID)
            if sqlite3_step(stmt) == SQLITE_ROW {
                let completed = sqlite3_column_type(stmt, 0) != SQLITE_NULL
                result = (completed, text(stmt, 1))
            }
        }
        return result
    }

    // MARK: - Low-level helpers

    private func prepared(_ sql: String, _ body: (OpaquePointer) -> Void) {
        guard let handle else { return }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return }
        defer { sqlite3_finalize(stmt) }
        body(stmt)
    }

    private func text(_ stmt: OpaquePointer, _ column: Int32) -> String? {
        guard let cString = sqlite3_column_text(stmt, column) else { return nil }
        return String(cString: cString)
    }

    private func bindText(_ stmt: OpaquePointer, _ index: Int32, _ value: String) {
        // SQLITE_TRANSIENT: SQLite copies the bytes, so the Swift string may be freed after binding.
        sqlite3_bind_text(stmt, index, value, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
    }
}
