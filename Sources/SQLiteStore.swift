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
    func insert(_ event: Message) throws {
        _ = try rows("INSERT OR IGNORE INTO events(id,at,local_session,peer,direction,body,result,reply_to) VALUES(?,?,?,?,?,?,?,?)", [event.id, String(event.at), event.local, event.peer, event.direction, event.body, event.result, event.replyTo ?? ""])
    }
    static func event(_ row: [String: String]) -> Message {
        Message(id: row["id"] ?? "", at: Double(row["at"] ?? "") ?? 0, local: row["local_session"] ?? "", peer: row["peer"] ?? "", direction: row["direction"] ?? "", body: row["body"] ?? "", result: row["result"] ?? "", replyTo: row["reply_to"])
    }
}
