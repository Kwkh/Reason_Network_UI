import Foundation
import SQLite3

// The Reason database is always opened read-only. Only the UI's existing cache is writable.
final class SQLiteStore {
    struct OpenFailure: LocalizedError {
        let url: URL
        let code: Int32
        var errorDescription: String? { L10n.format("暂时无法打开数据库（%@，SQLite %lld）。", url.lastPathComponent, Int(code)) }
    }
    private let url: URL
    private var db: OpaquePointer?
    init(_ url: URL, readOnly: Bool) throws {
        self.url = url
        let flags = readOnly ? SQLITE_OPEN_READONLY : SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE
        guard sqlite3_open_v2(url.path, &db, flags | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            let error = failure()
            if let db { sqlite3_close(db) }; db = nil
            throw error
        }
        sqlite3_busy_timeout(db, 3000)
    }
    deinit { sqlite3_close(db) }
    func rows(_ sql: String, _ values: [String] = []) throws -> [[String: String]] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { throw failure() }
        defer { sqlite3_finalize(statement) }
        for (index, value) in values.enumerated() {
            let code = value.withCString { sqlite3_bind_text(statement, Int32(index + 1), $0, Int32(value.utf8.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
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
                    let bytes = UnsafeBufferPointer(start: value, count: Int(sqlite3_column_bytes(statement, i)))
                    row[String(cString: sqlite3_column_name(statement, i))] = String(decoding: bytes, as: UTF8.self)
                }
            }
            result.append(row)
        }
    }
    private func failure() -> Error {
        guard let db else { return NetworkError("数据库不可用") }
        let code = sqlite3_extended_errcode(db)
        if (code & 0xff) == SQLITE_CANTOPEN { return OpenFailure(url: url, code: code) }
        return NetworkError(String(cString: sqlite3_errmsg(db)))
    }
    func sessionOrigins(network: String, directory: Directory) throws -> [String: Set<String>] {
        var origins: [String: Set<String>] = [:]
        for row in try rows("SELECT peer,endpoint FROM session_origins WHERE network=?", [network]) {
            if let peer = row["peer"], let endpoint = row["endpoint"] { origins[peer, default: []].insert(endpoint) }
        }
        for session in directory.sessions {
            for device in directory.machines where device.person == session.person && device.machine == session.machine {
                if origins[session.address, default: []].insert(device.endpoint).inserted {
                    _ = try rows("INSERT OR IGNORE INTO session_origins VALUES(?,?,?)", [network, session.address, device.endpoint])
                }
            }
        }
        return origins
    }

    func prepareArchiveDeletion() throws {
        _ = try rows("CREATE TABLE IF NOT EXISTS deleted_archives(network TEXT PRIMARY KEY)")
        if !(try rows("SELECT 1 FROM sqlite_master WHERE type='table' AND name='network_events'")).isEmpty {
            _ = try rows("""
                CREATE TRIGGER IF NOT EXISTS skip_deleted_archive BEFORE INSERT ON network_events
                WHEN EXISTS (SELECT 1 FROM deleted_archives WHERE network=NEW.network)
                BEGIN SELECT RAISE(IGNORE); END
                """)
        }
    }

    func prepareHistoryDeletion() throws {
        try transaction {
            try prepareArchiveDeletion()
            _ = try rows("CREATE TABLE IF NOT EXISTS session_origins(network TEXT,peer TEXT,endpoint TEXT,PRIMARY KEY(network,peer,endpoint))")
            _ = try rows("CREATE TABLE IF NOT EXISTS history_clears(network TEXT,local_session TEXT,peer TEXT,through REAL NOT NULL,PRIMARY KEY(network,local_session,peer))")
            _ = try rows("CREATE TABLE IF NOT EXISTS cleared_event_ids(network TEXT,local_session TEXT,direction TEXT,id TEXT,PRIMARY KEY(network,local_session,direction,id))")
            _ = try rows("CREATE TABLE IF NOT EXISTS sender_history_clears(network TEXT,local_session TEXT,native_key TEXT,through REAL NOT NULL,PRIMARY KEY(network,local_session,native_key))")
            _ = try rows("""
                CREATE TRIGGER IF NOT EXISTS skip_cleared_sender BEFORE INSERT ON network_events
                WHEN EXISTS (SELECT 1 FROM sender_history_clears WHERE network=NEW.network AND local_session=NEW.local_session AND through>=NEW.at)
                BEGIN SELECT RAISE(IGNORE); END
                """)
            // Also match the immutable event key if a later mirror changes its timestamp or routing alias.
            let suppressed = """
                EXISTS(SELECT 1 FROM history_clears WHERE network=NEW.network AND local_session=NEW.local_session AND peer=NEW.peer AND through>=NEW.at)
                OR EXISTS(SELECT 1 FROM cleared_event_ids WHERE network=NEW.network AND local_session=NEW.local_session AND direction=NEW.direction AND id=NEW.id)
                """
            _ = try rows("CREATE TRIGGER IF NOT EXISTS skip_cleared_event BEFORE INSERT ON network_events WHEN " + suppressed + " BEGIN SELECT RAISE(IGNORE); END")
            _ = try rows("CREATE TRIGGER IF NOT EXISTS prune_cleared_event AFTER UPDATE OF peer,at ON network_events WHEN " + suppressed + " BEGIN DELETE FROM network_events WHERE rowid=NEW.rowid; END")
        }
    }

    func clearHistory(network: String, local: String, peer: String) throws {
        let scope = [network, local, peer]
        try transaction {
            _ = try rows("INSERT INTO history_clears VALUES(?,?,?,?) ON CONFLICT(network,local_session,peer) DO UPDATE SET through=MAX(through,excluded.through)", scope + [String(Date().timeIntervalSince1970)])
            _ = try rows("INSERT OR IGNORE INTO cleared_event_ids SELECT network,local_session,direction,id FROM network_events WHERE network=? AND local_session=? AND peer=?", scope)
            _ = try rows("DELETE FROM network_events WHERE network=? AND local_session=? AND peer=?", scope)
        }
    }
    func clearSenderHistory(network: String, sender: LocalSession) throws {
        let scope = [network, sender.name]
        try transaction {
            _ = try rows("INSERT OR REPLACE INTO sender_history_clears VALUES(?,?,?,?)",
                         scope + [sender.key, String(Date().timeIntervalSince1970)])
            _ = try rows("INSERT OR IGNORE INTO cleared_event_ids SELECT network,local_session,direction,id FROM network_events WHERE network=? AND local_session=?", scope)
            _ = try rows("DELETE FROM network_events WHERE network=? AND local_session=?", scope)
        }
    }

    func insert(_ event: Message, network: String? = nil) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let files = event.attachments.isEmpty ? "" : String(decoding: try encoder.encode(event.attachments), as: UTF8.self)
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
    func insertMirrored(_ event: Message, network: String) throws {
        // Older clients filed Codex sends under their typed, machine-qualified routing address.
        // Only coalesce an exact qualification of the resolved peer in this sender's mailbox.
        _ = try rows("""
            UPDATE network_events SET peer=? WHERE network=? AND id=? AND local_session=? AND direction='out'
              AND receipt_stage IS NULL AND substr(peer,1,instr(peer,'@')-1)=? AND instr(peer,'@')>0
            """, [event.peer, network, event.id, event.local, event.peer])
        try insert(event, network: network)
    }

    // Called only for payloads read from the daemon. Keep the original transport note
    // and preserve attachment metadata when an older daemon cannot supply it.
    func reconcileEnvelope(_ event: Message, network: String, knowsFiles: Bool) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let files = event.attachments.isEmpty ? "" : String(decoding: try encoder.encode(event.attachments), as: UTF8.self)
        _ = try rows("""
            INSERT INTO network_events(network,id,local_session,direction,peer,at,body,result,reply_to,attachments,receipt_stage)
            VALUES(?,?,?,?,?,?,?,'',?,?,NULLIF(?,''))
            ON CONFLICT(network,id,local_session,direction) DO UPDATE SET peer=excluded.peer,at=excluded.at,
              body=excluded.body,reply_to=excluded.reply_to,receipt_stage=excluded.receipt_stage,
              attachments=CASE WHEN ?='1' THEN excluded.attachments ELSE attachments END
            WHERE peer IS NOT excluded.peer OR at IS NOT excluded.at OR body IS NOT excluded.body OR
              reply_to IS NOT excluded.reply_to OR receipt_stage IS NOT excluded.receipt_stage OR
              (?='1' AND attachments IS NOT excluded.attachments)
            """, [network, event.id, event.local, event.direction, event.peer, String(event.at), event.body,
                  event.replyTo ?? "", files, event.receiptStage ?? "", knowsFiles ? "1" : "0", knowsFiles ? "1" : "0"])
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

    struct SessionLabel: Equatable {
        var title: String?
        var activity: String?
    }

    func sessionLabels(network: String, sessions: inout [NetworkSession]) throws -> [String: SessionLabel] {
        var labels: [String: SessionLabel] = [:]
        for row in try rows("SELECT address,title,activity FROM session_labels WHERE network=?", [network]) {
            if let address = row["address"] {
                labels[address] = SessionLabel(title: row["title"], activity: row["activity"])
            }
        }
        let counts = Dictionary(grouping: sessions, by: \.address)
        var changes: [String: SessionLabel] = [:]
        for i in sessions.indices {
            let session = sessions[i]
            var addresses: [String] = []
            if counts[session.address]?.count == 1 { addresses.append(session.address) }
            if let target = session.target?.nonEmpty, target != session.address { addresses.append(target) }
            guard let address = addresses.last else { continue }
            let title = session.clientTitle?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
            let activity = session.doing?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
            for key in addresses {
                let previous = labels[key]
                let label = SessionLabel(title: title ?? previous?.title, activity: activity ?? previous?.activity)
                if (title != nil || activity != nil) && previous != label {
                    // Persist only observed fields. Another client may have learned the other field since our read.
                    changes[key] = SessionLabel(title: title, activity: activity)
                    labels[key] = label
                }
            }
            sessions[i].clientTitle = labels[address]?.title
            sessions[i].doing = labels[address]?.activity
        }
        if !changes.isEmpty {
            try transaction {
                for (address, label) in changes {
                    _ = try rows("""
                        INSERT INTO session_labels(network,address,title,activity) VALUES(?,?,NULLIF(?,''),NULLIF(?,''))
                        ON CONFLICT(network,address) DO UPDATE SET title=COALESCE(excluded.title,title),
                            activity=COALESCE(excluded.activity,activity)
                        """, [network, address, label.title ?? "", label.activity ?? ""])
                }
            }
        }
        return labels
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
        Message(id: row["id"] ?? "", at: Double(row["at"] ?? "") ?? 0, local: row["local_session"] ?? "", peer: row["peer"] ?? "", direction: row["direction"] ?? "", body: row["body"] ?? "", result: row["result"] ?? "", replyTo: row["reply_to"], attachments: row["attachments"].flatMap { try? JSONDecoder().decode([MessageAttachment].self, from: Data($0.utf8)) } ?? [], receiptStage: row["receipt_stage"])
    }
}
