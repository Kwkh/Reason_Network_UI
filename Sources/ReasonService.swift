import Foundation
import Darwin

actor ReasonService {
    private let home: URL
    private var cache: SQLiteStore?
    private let mirror: TranscriptMirror
    private var migrated = false
    init(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.home = home
        mirror = TranscriptMirror(root: home.appendingPathComponent(".codex/sessions"))
    }
    func snapshot(local: String, peer: String, readingFrom: Message.RowKey? = nil, readingNetwork: String? = nil) throws -> Snapshot {
        let engine = try SQLiteStore(home.appendingPathComponent(".reason/network/network.db"), readOnly: true)
        let expectedNetwork = try teamID(in: engine)
        var directory = try directory()
        _ = try engine.rows("BEGIN")
        guard let network = try teamID(in: engine), directory.team != nil else {
            throw NetworkError("本机尚未加入 Network。")
        }
        guard network == expectedNetwork else { throw NetworkError("Network 正在切换，稍后将重新同步。") }
        directory.networkID = network
        let cache = try store()
        try selectNetwork(network, in: cache)
        let paused = try pausedKeys(in: engine)
        let registrations = try engine.rows("SELECT name,key,doing,attached FROM sessions WHERE agent='codex' ORDER BY last_seen DESC")
            .filter { !paused.contains($0["key"] ?? "") }
        let catalog = PersonalSessionCatalog(home: home)
        // A missing or temporarily unavailable agent index must not interrupt messaging.
        let attached = registrations.filter { $0["attached"] == "1" }
        let titles = (try? catalog.codexTitles(for: attached.compactMap { $0["key"] })) ?? [:]
        var locals = attached.compactMap { row -> LocalSession? in
            guard let name = row["name"], let key = row["key"] else { return nil }
            let index = directory.sessions.firstIndex {
                $0.person == directory.person && $0.machine == directory.machine && $0.name == name && $0.agent == "codex"
            }
            if let index, let title = titles[key] { directory.sessions[index].clientTitle = title }
            let published = index.map { directory.sessions[$0] }
            return LocalSession(name: name, key: key, doing: titles[key] ?? published?.clientTitle ?? published?.doing ?? row["doing"])
        }
        try cache.recordInboxOwnership(network, engine: engine)
        let otherMail = Set(try cache.rows("SELECT id FROM network_inbox WHERE network<>?", [network]).compactMap { $0["id"] })
        var warning: String?
        let hasFiles = try engine.rows("PRAGMA table_info(messages)").contains { $0["name"] == "files" }
        let fileColumn = hasFiles ? ",files" : ""
        // A registered mailbox can receive mail just before detaching, between UI polls.
        for registration in registrations {
            guard let name = registration["name"], let key = registration["key"] else { continue }
            let session = LocalSession(name: name, key: key)
            do {
                for row in try engine.rows("SELECT id,sent_at,sender,body,reply_to\(fileColumn) FROM messages WHERE recipient=? AND held=0 ORDER BY sent_at", [directory.person + "/" + session.name]) {
                    guard let id = row["id"], !otherMail.contains(id) else { continue }
                    try cache.insert(Message(id: id, at: (Double(row["sent_at"] ?? "") ?? 0) / 1000, local: session.name, peer: row["sender"] ?? "", direction: "in", body: row["body"] ?? "", result: "", replyTo: row["reply_to"], attachments: receivedFiles(row["files"])), network: network)
                }
                try mirror.sync(for: session) { batch in
                    try cache.transaction {
                        for event in batch {
                            let origin = try cache.rows("SELECT network FROM network_periods WHERE since<=? ORDER BY since DESC, rowid DESC LIMIT 1", [String(event.at)]).first?["network"]
                            if let origin = origin?.nonEmpty { try cache.insert(event, network: origin) }
                        }
                    }
                }
            } catch { warning = "部分历史记录暂未同步：" + error.localizedDescription }
        }
        if try engine.rows("SELECT 1 FROM sqlite_master WHERE type='table' AND name='sent_receipts'").first != nil {
            let receipts = try engine.rows("SELECT id,sender,recipient,stage,sent_at FROM sent_receipts")
            try cache.transaction {
                for row in receipts {
                    guard let id = row["id"], let sender = row["sender"], sender.hasPrefix(directory.person + "/"),
                          let peer = row["recipient"], let stage = row["stage"], let at = row["sent_at"] else { continue }
                    _ = try cache.rows("""
                        UPDATE network_events SET receipt_stage=? WHERE network=? AND id=? AND direction='out'
                          AND local_session=? AND peer=? AND receipt_stage IS NOT ?
                          AND network=(SELECT network FROM network_periods WHERE since<=CAST(? AS REAL)/1000
                                       ORDER BY since DESC,rowid DESC LIMIT 1)
                        """, [stage, network, id, String(sender.dropFirst(directory.person.count + 1)), peer, stage, at])
                }
            }
        }
        let pausedNames = try engine.rows("SELECT key,name FROM sessions").filter { paused.contains($0["key"] ?? "") }.compactMap { $0["name"] }
        let knownNames = Set(locals.map(\.name) + pausedNames)
        for row in try cache.rows("SELECT DISTINCT local_session FROM network_events WHERE network=? ORDER BY local_session", [network]) {
            if let name = row["local_session"], !knownNames.contains(name) {
                locals.append(LocalSession(name: name, key: "history:" + name, historyOnly: true))
            }
        }
        let conversations = try cache.rows("SELECT peer,MAX(at) AS recent FROM network_events WHERE network=? AND local_session=? GROUP BY peer ORDER BY recent DESC", [network, local]).compactMap { $0["peer"] }
        let page: MessagePage
        if readingNetwork == network, let start = readingFrom, start.local == local {
            page = try visibleHistory(network: network, local: local, peer: peer, startingAt: start)
        } else {
            page = try history(network: network, local: local, peer: peer)
        }
        return Snapshot(directory: directory, localSessions: locals, conversations: conversations, messages: page.messages,
                        hasEarlier: page.hasEarlier, mirrorWarning: warning)
    }

    private func teamID(in engine: SQLiteStore) throws -> String? {
        // Extract only the public team ID, never the invitation or signed roster.
        try engine.rows("SELECT json_extract(value,'$.id') AS id FROM kv WHERE key='team'").first?["id"]?.nonEmpty
    }

    private func selectNetwork(_ network: String, in cache: SQLiteStore) throws {
        func previous() throws -> [String: String]? {
            try cache.rows("SELECT network,since FROM network_periods ORDER BY rowid DESC LIMIT 1").first
        }
        guard try previous()?["network"] != network else { return }
        try cache.transaction {
            let last = try previous()
            guard last?["network"] != network else { return }
            if last == nil {
                _ = try cache.rows("""
                    INSERT OR IGNORE INTO network_events(network,id,at,local_session,peer,direction,body,result,reply_to,attachments)
                    SELECT ?,id,at,local_session,peer,direction,body,result,reply_to,attachments FROM events
                    """, [network])
            }
            let since = last == nil ? "0" : (last?["network"] == "" ? last?["since"] : nil) ?? String(Date().timeIntervalSince1970)
            _ = try cache.rows("INSERT INTO network_periods(network,since) VALUES(?,?)", [network, since])
        }
    }

    func leaveNetwork(expected: String) throws {
        let engine = try SQLiteStore(home.appendingPathComponent(".reason/network/network.db"), readOnly: true)
        guard try teamID(in: engine) == expected else { throw NetworkError("当前 Network 已变化，请重新确认。") }
        let cache = try store()
        try selectNetwork(expected, in: cache)
        // Include held messages and mailboxes not currently selected by the UI.
        try cache.recordInboxOwnership(expected, engine: engine)
        let departure = String(Date().timeIntervalSince1970)
        do { _ = try run(["leave"], timeout: 35) }
        catch {
            if try teamID(in: engine) != nil {
                if error.localizedDescription.contains("no teammate is online") {
                    throw NetworkError("当前没有在线队友可以接收退出通知。请等一位队友上线后重试。")
                }
                throw error
            }
        }
        guard try teamID(in: engine) == nil else { throw NetworkError("后台尚未确认这台 Mac 已退出。") }
        // A final pass includes mail delivered while the daemon broadcast the departure.
        try cache.recordInboxOwnership(expected, engine: engine)
        _ = try cache.rows("INSERT INTO network_periods(network,since) VALUES('',?)", [departure])
    }

    private func receivedFiles(_ raw: String?) -> [MessageAttachment] {
        struct Kept: Decodable { let dir: String; let files: [MessageAttachment] }
        guard let raw, let kept = try? JSONDecoder().decode(Kept.self, from: Data(raw.utf8)) else { return [] }
        return kept.files.map { MessageAttachment(name: $0.name, directory: kept.dir) }
    }

    func attachmentText(_ file: MessageAttachment) throws -> String {
        try file.readText(in: home.appendingPathComponent(".reason/network/inbox"))
    }

    func history(network: String, local: String, peer: String, before: Message.RowKey? = nil) throws -> MessagePage {
        var sql = "SELECT * FROM network_events WHERE network=? AND local_session=? AND peer=?"
        var args = [network, local, peer]
        if let before {
            sql += " AND (at,id,direction) < (SELECT at,id,direction FROM network_events WHERE network=? AND id=? AND local_session=? AND direction=? AND peer=?)"
            args += [network, before.id, before.local, before.direction, peer]
        }
        let rows = try store().rows(sql + " ORDER BY at DESC,id DESC,direction DESC LIMIT 101", args)
        return MessagePage(messages: rows.prefix(100).reversed().map(SQLiteStore.event), hasEarlier: rows.count > 100)
    }

    // Refresh the entire range the user opened, including late backfills and updated receipts.
    private func visibleHistory(network: String, local: String, peer: String, startingAt key: Message.RowKey) throws -> MessagePage {
        let cache = try store()
        let scope = [network, local, peer]
        let filter = "FROM network_events WHERE network=? AND local_session=? AND peer=?"
        let boundary = "SELECT at,id,direction " + filter + " AND id=? AND direction=?"
        let args = scope + scope + [key.id, key.direction]
        let rows = try cache.rows("SELECT * " + filter + " AND (at,id,direction)>=(" + boundary + ") ORDER BY at,id,direction", args)
        guard !rows.isEmpty else { return try history(network: network, local: local, peer: peer) }
        let earlier = try cache.rows("SELECT 1 " + filter + " AND (at,id,direction)<(" + boundary + ") LIMIT 1", args)
        return MessagePage(messages: rows.map(SQLiteStore.event), hasEarlier: !earlier.isEmpty)
    }

    func send(network: String, local: String, to: String, body: String, files: [URL] = [], notify: Bool = false) throws -> String {
        let typed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        let content = typed.isEmpty && !files.isEmpty ? "附件" : typed
        guard !content.isEmpty, content.count <= 10_000 else { throw NetworkError("请输入 1–10000 字的消息") }
        guard files.count <= 10 else { throw NetworkError("每条消息最多添加 10 个附件。") }
        let scoped = files.filter { $0.startAccessingSecurityScopedResource() }
        defer { scoped.forEach { $0.stopAccessingSecurityScopedResource() } }
        var bytes = 0
        for file in files {
            bytes += try MessageAttachment.text(at: file).utf8.count
            guard bytes <= 512 * 1024 else { throw NetworkError("附件合计不能超过 512 KiB。") }
        }
        let engine = try SQLiteStore(home.appendingPathComponent(".reason/network/network.db"), readOnly: true)
        guard let key = try engine.rows("SELECT key FROM sessions WHERE name=? AND agent='codex' AND attached=1", [local]).first?["key"] else { throw NetworkError("本机 Codex 会话未连接") }
        guard try !pausedKeys(in: engine).contains(key) else { throw NetworkError("本机会话已退出 Network") }
        let directory = try directory()
        guard directory.liveLocalSession(named: local, agent: "codex") != nil else { throw LocalSenderOffline() }
        guard directory.sessions.contains(where: { $0.person != directory.person && $0.address == to }) else { throw NetworkError("该队友会话已离线，请刷新后重新选择") }
        guard try teamID(in: engine) == network else { throw NetworkError("当前 Network 已变化，请刷新后重试。") }
        var arguments = ["send", "--from", key]
        if notify { arguments.append("--notify") }
        for file in files { arguments += ["--file", file.path] }
        let result: String
        do {
            result = try run(arguments + [to, "-"], input: content, timeout: 30)
        } catch let error as NetworkError where error.message.hasPrefix("Error: this session isn't registered with Reason Network") {
            // The daemon lost the sender after the directory check and before dispatch.
            throw LocalSenderOffline()
        }
        guard let id = TranscriptMirror.match(#"message id ([0-9A-Z]{26})"#, in: result) else {
            throw NetworkError(result.nonEmpty ?? "后台没有返回消息编号，投递状态未知。")
        }
        do {
            try store().insert(Message(id: id, at: Date().timeIntervalSince1970, local: local, peer: to, direction: "out", body: content, result: result, attachments: files.map { MessageAttachment(name: $0.lastPathComponent) }), network: network)
        } catch {
            // Sending has already succeeded: never turn a cache failure into an invitation to resend.
            return "已发送；本地记录保存失败，请勿重复发送。"
        }
        let status = result.contains("queued") ? "已排队" : "已发送"
        if notify && result.contains("not popped up:") { return status + " · 对方设备未弹窗" }
        return status
    }
    private var console: SessionSocket { SessionSocket(socketURL: home.appendingPathComponent(".reason/network/network.sock")) }
    func personalSessions() throws -> [PersonalSession] {
        let directory = try? directory()
        let participation = try? participationState()
        let discovered = try PersonalSessionCatalog(home: home).discover()
        var sessions = Dictionary(discovered.sessions.map { ($0.id, $0) },
                                  uniquingKeysWith: { $0.updated > $1.updated ? $0 : $1 })
        let enginePath = home.appendingPathComponent(".reason/network/network.db")
        let knownRecords: [[String: String]]
        if FileManager.default.fileExists(atPath: enginePath.path) {
            let engine = try SQLiteStore(enginePath, readOnly: true)
            knownRecords = try engine.rows("SELECT key,agent,name,cwd,doing,last_seen FROM sessions WHERE attached=1 OR tier!='none'")
        } else {
            knownRecords = []
        }
        for row in knownRecords {
            guard let key = row["key"], !discovered.hidden.contains(key), !discovered.hidden.contains(key.lowercased()), let agent = row["agent"], let name = row["name"] else { continue }
            let current = directory?.sessions.first {
                $0.person == directory?.person && $0.machine == directory?.machine &&
                $0.name == name && $0.agent == agent && $0.tier != "none"
            }
            let address = current?.id ?? directory.map { $0.person + "/" + name } ?? name
            var item = sessions[key] ?? PersonalSession(id: key, agent: agent, title: row["doing"]?.nonEmpty ?? name,
                                                         cwd: row["cwd"], updated: Date(timeIntervalSince1970: (Double(row["last_seen"] ?? "") ?? 0) / 1000))
            item.canManageParticipation = participation != nil
            if participation?.paused.contains(key) == true {
                item.connection = .paused(address)
            } else if current?.offline == false {
                item.connection = .online(address)
            } else {
                item.connection = .offline(address)
            }
            sessions[key] = item
        }
        return sessions.values.sorted { ($0.updated, $0.id) > ($1.updated, $1.id) }
    }
    func reconnectLocal(_ local: LocalSession, network: String) throws {
        let engine = try SQLiteStore(home.appendingPathComponent(".reason/network/network.db"), readOnly: true)
        guard try teamID(in: engine) == network, !local.historyOnly,
              try engine.rows("SELECT key FROM sessions WHERE name=? AND agent='codex' AND attached=1", [local.name]).first?["key"] == local.key,
              try !pausedKeys(in: engine).contains(local.key) else {
            throw NetworkError("本机会话或 Network 已变化，请刷新后重新选择。")
        }
        if try directory().liveLocalSession(named: local.name, agent: "codex") != nil { return }
        guard let session = try PersonalSessionCatalog(home: home).discover().sessions.first(where: { $0.id == local.key }) else {
            throw NetworkError("找不到这个本机 Codex 对话，请在 Codex 中打开后重试。")
        }
        _ = try registerPersonalSession(session)
    }

    func joinPersonalSession(_ key: String) throws -> String {
        guard let chosen = try personalSessions().first(where: { $0.id == key }), chosen.canJoin else {
            throw NetworkError("这个会话还需要在原工具中打开，或已经在线。")
        }
        if case .paused = chosen.connection {
            return try resumePersonalSession(chosen)
        }
        return try registerPersonalSession(chosen)
    }
    private func registerPersonalSession(_ chosen: PersonalSession) throws -> String {
        guard let nativeID = chosen.nativeID, let cwd = chosen.cwd else {
            throw NetworkError("这个会话需要在原工具中打开。")
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: cwd, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw NetworkError("会话的项目目录已不存在，无法接入。")
        }
        var payload: [String: Any] = ["op": "hook", "event": "stop", "agent": chosen.agent,
                                      "session_id": nativeID, "cwd": cwd, "mail": false]
        if let transcript = chosen.transcript { payload["transcript"] = transcript.path }
        struct JoinReply: Decodable { let address: String? }
        let reply = try console.decode(payload, as: JoinReply.self)
        guard let address = reply.address?.nonEmpty else { throw NetworkError("引擎没有返回会话地址。") }
        return address
    }
    func leavePersonalSession(_ key: String) throws -> String {
        guard let chosen = try personalSessions().first(where: { $0.id == key }), chosen.canLeave else {
            throw NetworkError("当前后台服务不支持退出该会话。")
        }
        let address: String
        switch chosen.connection {
        case .online(let value), .offline(let value): address = value
        case .notJoined, .paused: throw NetworkError("该会话已经退出。")
        }
        try setParticipation(key, paused: true)
        return address
    }

    private func resumePersonalSession(_ session: PersonalSession) throws -> String {
        guard case .paused(let address) = session.connection else {
            throw NetworkError("该会话无需恢复接入。")
        }
        try setParticipation(session.id, paused: false)
        guard session.supportsImmediateJoin else { return address }
        do {
            return try registerPersonalSession(session)
        } catch {
            try setParticipation(session.id, paused: true)
            throw error
        }
    }

    private func pausedKeys(in database: SQLiteStore) throws -> Set<String> {
        guard !(try database.rows("SELECT 1 FROM sqlite_master WHERE type='table' AND name='paused_sessions'")).isEmpty else { return [] }
        return Set(try database.rows("SELECT key FROM paused_sessions").compactMap { $0["key"] })
    }

    func setReceiveMode(_ mode: ReceiveMode, local: LocalSession, network: String) throws -> ReceiveMode {
        struct Reply: Decodable { let effective: ReceiveMode }
        do {
            return try console.decode(["op": "set_receive_mode", "key": local.key, "network": network, "mode": mode.rawValue],
                                      as: Reply.self).effective
        } catch let error as NetworkError where error.message.contains("unknown variant") {
            throw NetworkError("当前后台未支持接收模式设置，请在「环境配置」中更新兼容后台。")
        }
    }

    func supportsSessionExit() throws -> Bool {
        do { _ = try participationState(); return true }
        catch where error.localizedDescription.contains("unknown variant") { return false }
    }

    private struct ParticipationState: Decodable {
        let version: Int
        let paused: Set<String>
        let resumePending: Set<String>?
        enum CodingKeys: String, CodingKey { case version, paused, resumePending = "resume_pending" }
    }
    private func participationState() throws -> ParticipationState {
        let state = try console.decode(["op": "session_participation"], as: ParticipationState.self)
        guard state.version == 1 else { throw NetworkError("后台服务的会话管理版本不兼容。") }
        return state
    }
    private func setParticipation(_ key: String, paused: Bool) throws {
        _ = try console.request(["op": "set_session_participation", "key": key, "paused": paused])
        guard try participationState().paused.contains(key) == paused else {
            throw NetworkError("后台服务没有确认会话状态，请刷新后重试。")
        }
    }
    func inviteLink() throws -> String {
        let output = try run(["link"])
        guard let link = TranscriptMirror.match(#"(https://reasonmachines\.com/network/join/[^\s]+)"#, in: output) else {
            throw NetworkError("未能取得邀请链接，请确认这台电脑已加入网络。")
        }
        return link
    }
    func diagnose(localKey: String?) throws -> String {
        let detail = try run(["doctor"])
        guard let localKey, let state = try? participationState(), state.resumePending?.contains(localKey) == true else { return detail }
        return "最近一次推送已进入 Codex 队列，但未能唤醒此会话。请在 Codex 打开该对话，无需重发。\n\n" + detail
    }
    private func directory() throws -> Directory {
        let output = try run(["who", "--json"])
        guard let data = output.data(using: .utf8) else { throw NetworkError("无法读取 Network 目录") }
        let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(Directory.self, from: data)
    }
    private func store() throws -> SQLiteStore {
        if let cache { return cache }
        let folder = home.appendingPathComponent(".reason/network/local-ui")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let file = folder.appendingPathComponent("messages.sqlite3")
        let database = try SQLiteStore(file, readOnly: false)
        _ = try database.rows("CREATE TABLE IF NOT EXISTS events (id TEXT PRIMARY KEY, at REAL, local_session TEXT, peer TEXT, direction TEXT, body TEXT, result TEXT, reply_to TEXT)")
        try database.transaction {
            if !(try database.rows("PRAGMA table_info(events)")).contains(where: { $0["name"] == "attachments" }) {
                _ = try database.rows("ALTER TABLE events ADD COLUMN attachments TEXT NOT NULL DEFAULT ''")
            }
        }
        _ = try database.rows("CREATE INDEX IF NOT EXISTS events_conversation_time ON events(local_session,peer,at,id)")
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        if !migrated {
            let hasLegacy = try database.rows("SELECT name FROM sqlite_master WHERE type='table' AND name='messages'")
            if !hasLegacy.isEmpty {
                for row in try database.rows("SELECT * FROM messages ORDER BY id") {
                    let result = row["result"] ?? ""
                    let id = TranscriptMirror.match(#"message id ([0-9A-Z]{26})"#, in: result) ?? "legacy:" + (row["id"] ?? "")
                    let body = row["body"] ?? ""
                    if row["direction"] == "out" {
                        try database.insert(Message(id: id, at: Double(row["at"] ?? "") ?? 0, local: "websites-codex", peer: row["recipient"] ?? "", direction: "out", body: body, result: result))
                    } else {
                        let pattern = #"<reason-message\b([^>]*)>\n?(.*?)\n?</reason-message>"#
                        let regex = try NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators])
                        let matches = regex.matches(in: body, range: NSRange(body.startIndex..., in: body))
                        for (index, match) in matches.enumerated() {
                            guard let attr = Range(match.range(at: 1), in: body), let text = Range(match.range(at: 2), in: body), let sender = TranscriptMirror.match(#"from="([^"]*)""#, in: String(body[attr])) else { continue }
                            try database.insert(Message(id: "legacy:" + (row["id"] ?? "") + ":\(index)", at: Double(row["at"] ?? "") ?? 0, local: "websites-codex", peer: sender, direction: "in", body: String(body[text]).trimmingCharacters(in: .whitespacesAndNewlines), result: ""))
                        }
                    }
                }
            }
            migrated = true
        }
        _ = try database.rows("""
            CREATE TABLE IF NOT EXISTS network_events(network TEXT NOT NULL,id TEXT NOT NULL,at REAL,local_session TEXT NOT NULL,
              peer TEXT,direction TEXT NOT NULL,body TEXT,result TEXT,reply_to TEXT,attachments TEXT NOT NULL DEFAULT '',
              PRIMARY KEY(network,id,local_session,direction))
            """)
        try database.transaction {
            if !(try database.rows("PRAGMA table_info(network_events)")).contains(where: { $0["name"] == "receipt_stage" }) {
                _ = try database.rows("ALTER TABLE network_events ADD COLUMN receipt_stage TEXT")
            }
        }
        _ = try database.rows("CREATE INDEX IF NOT EXISTS network_history ON network_events(network,local_session,peer,at,id)")
        try database.prepareNetworkMetadata()
        cache = database
        return database
    }
    // Files avoid pipe-capacity deadlocks; the private temporary directory is removed after every command.
    private func run(_ arguments: [String], input: String? = nil, timeout: TimeInterval = 15) throws -> String {
        guard let executable = NetworkPaths.executable(home: home) else { throw NetworkError("未找到 Reason Network。请打开环境配置安装后台。") }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("reason-native-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: folder) }
        func file(_ name: String, content: Data = Data()) throws -> FileHandle {
            let url = folder.appendingPathComponent(name)
            try content.write(to: url)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            return try FileHandle(forUpdating: url)
        }
        let output = try file("stdout"), error = try file("stderr"), stdin = try file("stdin", content: Data((input ?? "").utf8))
        defer { try? output.close(); try? error.close(); try? stdin.close() }
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.standardInput = stdin; process.standardOutput = output; process.standardError = error
        process.currentDirectoryURL = home
        var env = ProcessInfo.processInfo.environment.filter { key, _ in
            !["CODEX_", "CLAUDE", "TINCAN_", "REASON_NETWORK_"].contains(where: { key.hasPrefix($0) }) && !["COPILOT_SESSION_ID", "GEMINI_CLI", "CURSOR_TRACE_ID"].contains(key)
        }
        env["PATH"] = home.appendingPathComponent(".local/bin").path + ":/usr/bin:/bin:/usr/sbin:/sbin"
        process.environment = env
        let start = Date()
        try process.run()
        while process.isRunning {
            if Date().timeIntervalSince(start) > timeout {
                process.terminate()
                Thread.sleep(forTimeInterval: 0.1)
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                process.waitUntilExit()
                throw NetworkError(arguments.first == "send" ? "发送超时，投递状态未知；请确认对方是否收到后再重试。" : "连接超时，请检查 Network 服务。")
            }
            Thread.sleep(forTimeInterval: 0.025)
        }
        process.waitUntilExit()
        try output.seek(toOffset: 0); try error.seek(toOffset: 0)
        let out = String(decoding: try output.readToEnd() ?? Data(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        let err = String(decoding: try error.readToEnd() ?? Data(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard process.terminationStatus == 0 else { throw NetworkError(String((err.nonEmpty ?? out.nonEmpty ?? "操作失败").prefix(2000))) }
        return out
    }
}
