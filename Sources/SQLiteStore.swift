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
    func insert(_ event: Message, network: String? = nil) throws {
        let files = event.attachments.isEmpty ? "" : String(decoding: try JSONEncoder().encode(event.attachments), as: UTF8.self)
        let table = network == nil ? "events" : "network_events"
        let networkColumn = network == nil ? "" : "network,"
        let networkParameter = network == nil ? "" : "?,"
        let scope = network.map { [$0] } ?? []
        _ = try rows("""
            INSERT INTO \(table)(\(networkColumn)id,at,local_session,peer,direction,body,result,reply_to,attachments)
            VALUES(\(networkParameter)?,?,?,?,?,?,?,?,?)
            ON CONFLICT DO UPDATE SET attachments=excluded.attachments
            WHERE id=excluded.id AND local_session=excluded.local_session
              AND direction=excluded.direction AND peer=excluded.peer
              AND attachments='' AND excluded.attachments!=''
            """, scope + [event.id, String(event.at), event.local, event.peer, event.direction, event.body,
                  event.result, event.replyTo ?? "", files])
    }
    func transaction<T>(_ body: () throws -> T) throws -> T {
        _ = try rows("BEGIN IMMEDIATE")
        do {
            let result = try body()
            _ = try rows("COMMIT")
            return result
        } catch {
            _ = try? rows("ROLLBACK")
            throw error
        }
    }
    func prepareNetworkMetadata() throws {
        _ = try rows("CREATE TABLE IF NOT EXISTS network_periods(network TEXT NOT NULL,since REAL NOT NULL)")
        _ = try rows("CREATE TABLE IF NOT EXISTS network_inbox(id TEXT PRIMARY KEY,network TEXT NOT NULL)")
    }

    func recordInboxOwnership(_ network: String, engine: SQLiteStore) throws {
        let known = Set(try rows("SELECT id FROM network_inbox").compactMap { $0["id"] })
        let new = try engine.rows("SELECT id FROM messages").compactMap { $0["id"] }.filter { !known.contains($0) }
        guard !new.isEmpty else { return }
        try transaction {
            for id in new {
                _ = try rows("INSERT OR IGNORE INTO network_inbox(id,network) VALUES(?,?)", [id, network])
            }
        }
    }

    static func prepareNetworkJoin(home: URL) throws {
        let root = home.appendingPathComponent(".reason/network")
        let path = root.appendingPathComponent("network.db")
        guard FileManager.default.fileExists(atPath: path.path) else { return }
        let engine = try SQLiteStore(path, readOnly: true)
        guard try engine.rows("SELECT 1 FROM kv WHERE key='team'").isEmpty else {
            throw NetworkError("这台 Mac 已加入 Network，请刷新状态。")
        }
        let folder = root.appendingPathComponent("local-ui")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let url = folder.appendingPathComponent("messages.sqlite3")
        let cache = try SQLiteStore(url, readOnly: false)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        try cache.prepareNetworkMetadata()
        // Mail already on disk before a join cannot belong to the incoming team.
        let previous = try cache.rows("SELECT network FROM network_periods WHERE network!='' ORDER BY rowid DESC LIMIT 1").first?["network"]
        try cache.recordInboxOwnership(previous ?? "", engine: engine)
        _ = try cache.rows("INSERT INTO network_periods(network,since) VALUES('',?)", [String(Date().timeIntervalSince1970)])
    }

    static func event(_ row: [String: String]) -> Message {
        Message(id: row["id"] ?? "", at: Double(row["at"] ?? "") ?? 0, local: row["local_session"] ?? "", peer: row["peer"] ?? "", direction: row["direction"] ?? "", body: row["body"] ?? "", result: row["result"] ?? "", replyTo: row["reply_to"], attachments: row["attachments"].flatMap { try? JSONDecoder().decode([MessageAttachment].self, from: Data($0.utf8)) } ?? [])
    }
}
