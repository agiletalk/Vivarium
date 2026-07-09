import Foundation
import SQLite3
import Testing
@testable import VivariumDetect

@Suite("OpenCodeDatabase")
struct OpenCodeDatabaseTests {
    /// Creates a throwaway SQLite file with OpenCode's relevant tables and returns its path.
    private func makeTempDB(_ statements: [String]) throws -> String {
        let path = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("opencode-db-test-\(UUID().uuidString).sqlite")
        var db: OpaquePointer?
        try #require(sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK)
        defer { sqlite3_close(db) }
        for sql in statements {
            var err: UnsafeMutablePointer<CChar>?
            let rc = sqlite3_exec(db, sql, nil, nil, &err)
            if rc != SQLITE_OK {
                let message = err.map { String(cString: $0) } ?? "unknown"
                Issue.record("exec failed (\(rc)): \(message)\nSQL: \(sql)")
                if let err { sqlite3_free(err) }
            }
        }
        return path
    }

    private static let ddl = [
        "CREATE TABLE event_sequence (aggregate_id TEXT PRIMARY KEY, seq INTEGER NOT NULL, owner_id TEXT)",
        "CREATE TABLE event (id TEXT PRIMARY KEY, aggregate_id TEXT NOT NULL, seq INTEGER NOT NULL, type TEXT NOT NULL, data TEXT NOT NULL)",
        "CREATE TABLE session (id TEXT PRIMARY KEY, directory TEXT, title TEXT, model TEXT, parent_id TEXT, time_created INTEGER NOT NULL, time_updated INTEGER NOT NULL)",
        "CREATE TABLE message (id TEXT PRIMARY KEY, session_id TEXT NOT NULL, time_created INTEGER NOT NULL, data TEXT NOT NULL)",
    ]

    @Test("Reads the per-session cursor, ordered new events, session row, and latest finish")
    func readsCoreShapes() throws {
        let path = try makeTempDB(Self.ddl + [
            "INSERT INTO event_sequence VALUES ('ses_x', 2, NULL)",
            "INSERT INTO event VALUES ('e0','ses_x',0,'session.created.1','{\"info\":{\"id\":\"ses_x\"}}')",
            "INSERT INTO event VALUES ('e1','ses_x',1,'message.part.updated.1','{\"part\":{\"id\":\"p\"}}')",
            "INSERT INTO event VALUES ('e2','ses_x',2,'message.updated.1','{\"info\":{\"role\":\"assistant\"}}')",
            "INSERT INTO session VALUES ('ses_x','/Users/dev/Reef','Fix the bug','{\"id\":\"gpt-5.4\",\"providerID\":\"github-copilot\"}',NULL,1783576311218,1783576400000)",
            "INSERT INTO session VALUES ('ses_child','/Users/dev/Reef','sub','{\"id\":\"gpt-5.4\"}','ses_x',1783576311218,1783576400000)",
            "INSERT INTO message VALUES ('m1','ses_x',10,'{\"role\":\"assistant\",\"time\":{\"created\":10,\"completed\":20},\"finish\":\"stop\"}')",
            "INSERT INTO message VALUES ('m0','ses_x',5,'{\"role\":\"user\"}')",
        ])
        defer { try? FileManager.default.removeItem(atPath: path) }

        let db = try #require(OpenCodeDatabase(path: path))

        let sequences = db.sessionSequences()
        #expect(sequences.count == 1)
        #expect(sequences.first?.sessionID == "ses_x")
        #expect(sequences.first?.seq == 2)

        // afterSeq: -1 → all rows, ordered by seq.
        let all = db.events(sessionID: "ses_x", afterSeq: -1)
        #expect(all.map(\.seq) == [0, 1, 2])
        #expect(all.first?.type == "session.created.1")

        // afterSeq cursor excludes already-seen rows.
        let tail = db.events(sessionID: "ses_x", afterSeq: 1)
        #expect(tail.map(\.seq) == [2])

        let session = try #require(db.session(id: "ses_x"))
        #expect(session.directory == "/Users/dev/Reef")
        #expect(session.title == "Fix the bug")
        #expect(session.model == "gpt-5.4") // extracted via json_extract(model, '$.id')
        #expect(session.parentID == nil)
        #expect(session.timeCreatedMs == 1783576311218)
        #expect(session.timeUpdatedMs == 1783576400000)

        // A subagent session exposes its parent_id so the monitor can suppress it.
        let child = try #require(db.session(id: "ses_child"))
        #expect(child.parentID == "ses_x")

        let finish = try #require(db.latestAssistantFinish(sessionID: "ses_x"))
        #expect(finish.completed)
        #expect(finish.finish == "stop")
    }

    @Test("Malformed JSON in one column degrades that field to nil without dropping the row")
    func malformedJSONDegradesGracefully() throws {
        let path = try makeTempDB(Self.ddl + [
            // model is present but not valid JSON.
            "INSERT INTO session VALUES ('ses_bad','/Users/dev/Reef','Title','not json',NULL,1,2)",
            // A malformed message row precedes the valid assistant row.
            "INSERT INTO message VALUES ('mbad','ses_bad',1,'{oops')",
            "INSERT INTO message VALUES ('mok','ses_bad',2,'{\"role\":\"assistant\",\"time\":{\"completed\":9},\"finish\":\"stop\"}')",
        ])
        defer { try? FileManager.default.removeItem(atPath: path) }
        let db = try #require(OpenCodeDatabase(path: path))

        // The row survives; only the bad JSON field is nil.
        let session = try #require(db.session(id: "ses_bad"))
        #expect(session.directory == "/Users/dev/Reef")
        #expect(session.title == "Title")
        #expect(session.model == nil)

        // The malformed message row does not abort the scan for the valid assistant row.
        let finish = try #require(db.latestAssistantFinish(sessionID: "ses_bad"))
        #expect(finish.completed)
        #expect(finish.finish == "stop")
    }

    @Test("A missing database file fails to open")
    func missingFileReturnsNil() {
        #expect(OpenCodeDatabase(path: "/nonexistent/path/opencode-\(UUID().uuidString).db") == nil)
    }
}
