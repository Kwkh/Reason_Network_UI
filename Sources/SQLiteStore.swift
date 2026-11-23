import Foundation
import SQLite3

// The Reason database is always opened read-only. Only the UI's existing cache is writable.
final class SQLiteStore {
    private var db: OpaquePointer?
    init(_ url: URL, readOnly: Bool) throws {
        let flags = readOnly ? SQLITE_OPEN_READONLY : SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE
        guard sqlite3_open_v2(url.path, &db, flags | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            let error = db.map { String(cString: sqlite3_errmsg($0)) } ?? "数据库不可用"
            if let db { sqlite3_close(db) }; db = nil
            throw NetworkError(error)
        }
        sqlite3_busy_timeout(db, 3000)
    }
    deinit { sqlite3_close(db) }
    func rows(_ sql: String, _ values: [String] = []) throws -> [[String: String]] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { throw failure() }
        defer { sqlite3_finalize(statement) }
        for (index, value) in values.enumerated() {
            let code = value.withCString { sqlite3_bind_text(statement, Int32(index + 1), $0, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
            guard code == SQLITE_OK else { throw failure() }
        }
        var result: [[String: String]] = []
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { return result }
            guard step == SQLITE_ROW else { throw failure() }
            var row: [String: String] = [:]
            for i in 0..<sqlite3_column_count(statement) {
                if let value = sqlite3_column_text(statement, i) {
                    row[String(cString: sqlite3_column_name(statement, i))] = String(cString: value)
                }
            }
            result.append(row)
        }
    }
    private func failure() -> NetworkError { NetworkError(String(cString: sqlite3_errmsg(db))) }
    func prepareEvents() throws {
        let schema = """
            (id TEXT NOT NULL, at REAL, local_session TEXT NOT NULL, peer TEXT, direction TEXT NOT NULL,
             body TEXT, result TEXT, reply_to TEXT, attachments TEXT NOT NULL DEFAULT '', unread INTEGER,
             PRIMARY KEY(id,local_session,direction))
            """
        _ = try rows("BEGIN IMMEDIATE")
        do {
            let columns = try rows("PRAGMA table_info(events)")
            if columns.isEmpty {
                _ = try rows("CREATE TABLE events " + schema)
            } else if !columns.contains(where: { $0["name"] == "attachments" }) {
                _ = try rows("CREATE TABLE events_updated " + schema)
                _ = try rows("""
                    INSERT INTO events_updated(id,at,local_session,peer,direction,body,result,reply_to)
                    SELECT id,at,local_session,peer,direction,body,result,reply_to FROM events
                    """)
                _ = try rows("DROP TABLE events")
                _ = try rows("ALTER TABLE events_updated RENAME TO events")
            } else if !columns.contains(where: { $0["name"] == "unread" }) {
                _ = try rows("ALTER TABLE events ADD COLUMN unread INTEGER")
            }
            _ = try rows("CREATE INDEX IF NOT EXISTS events_conversation ON events(local_session,peer,at)")
            _ = try rows("COMMIT")
        } catch {
            _ = try? rows("ROLLBACK")
            throw error
        }
    }
    func insert(_ event: Message) throws {
        let files = event.attachments.isEmpty ? "" : String(decoding: try JSONEncoder().encode(event.attachments), as: UTF8.self)
        _ = try rows("""
            INSERT INTO events(id,at,local_session,peer,direction,body,result,reply_to,attachments,unread)
            VALUES(?,?,?,?,?,?,?,?,?,?)
            ON CONFLICT(id,local_session,direction) DO UPDATE SET
                attachments=CASE WHEN events.attachments='' THEN excluded.attachments ELSE events.attachments END,
                unread=COALESCE(events.unread,excluded.unread)
            WHERE (events.attachments='' AND excluded.attachments!='') OR events.unread IS NULL
            """, [event.id, String(event.at), event.local, event.peer, event.direction, event.body, event.result, event.replyTo ?? "", files,
                  event.unread ? "1" : "0"])
    }
    func conversations(in mailboxes: [String]) throws -> [ConversationSummary] {
        let placeholders = Array(repeating: "?", count: mailboxes.count).joined(separator: ",")
        return try rows("""
            SELECT peer, body, unread_count FROM (
                SELECT peer, body, at, id,
                       ROW_NUMBER() OVER (PARTITION BY peer ORDER BY at DESC,id DESC,local_session,direction) AS rank,
                       SUM(COALESCE(unread,0)) OVER (PARTITION BY peer) AS unread_count
                FROM events WHERE local_session IN (\(placeholders))
            ) WHERE rank=1 ORDER BY at DESC,id DESC,peer
            """, mailboxes).compactMap { row in
                guard let address = row["peer"] else { return nil }
                return ConversationSummary(address: address, preview: row["body"] ?? "", unread: Int(row["unread_count"] ?? "") ?? 0)
            }
    }
    func mostRecentConversation(in mailboxes: [String]) throws -> (mailbox: String, peer: String)? {
        guard !mailboxes.isEmpty else { return nil }
        let parameters = Array(repeating: "?", count: mailboxes.count).joined(separator: ",")
        guard let row = try rows("""
            SELECT local_session, peer FROM events WHERE local_session IN (\(parameters)) AND peer <> ''
            ORDER BY at DESC, id DESC LIMIT 1
            """, mailboxes).first, let mailbox = row["local_session"], let peer = row["peer"] else { return nil }
        return (mailbox, peer)
    }

    func markRead(mailbox: String, peer: String) throws {
        _ = try rows("UPDATE events SET unread=0 WHERE local_session=? AND peer=? AND unread=1", [mailbox, peer])
    }
    func unreadCount(in mailbox: String) throws -> Int {
        let value = try rows("SELECT COUNT(*) AS total FROM events WHERE local_session=? AND unread=1", [mailbox]).first?["total"]
        return Int(value ?? "") ?? 0
    }
    static func event(_ row: [String: String]) -> Message {
        Message(id: row["id"] ?? "", at: Double(row["at"] ?? "") ?? 0, local: row["local_session"] ?? "", peer: row["peer"] ?? "", direction: row["direction"] ?? "", body: row["body"] ?? "", result: row["result"] ?? "", replyTo: row["reply_to"], attachments: attachments(row["attachments"]), unread: row["unread"] == "1")
    }
    static func attachments(_ value: String?) -> [MessageAttachment] {
        guard let value, !value.isEmpty else { return [] }
        struct SavedFiles: Decodable { let files: [MessageAttachment] }
        let data = Data(value.utf8)
        let decoder = JSONDecoder()
        return (try? decoder.decode([MessageAttachment].self, from: data)) ??
            (try? decoder.decode(SavedFiles.self, from: data).files) ?? []
    }
}
