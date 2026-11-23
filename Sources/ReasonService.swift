import Foundation
import Darwin

actor ReasonService {
    private let home: URL
    private var cache: SQLiteStore?
    private let mirror: TranscriptMirror
    private let console: ConsoleMailbox
    private var importedConsoleTeams = Set<String>()
    init(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.home = home
        mirror = TranscriptMirror(root: home.appendingPathComponent(".codex/sessions"))
        console = ConsoleMailbox(home: home)
    }
    func snapshot(local: String, peer: String, limit: Int = 100, viewingConversation: Bool = false,
                  restoreConversation: Bool = false, includeAllLocalIdentities: Bool = false) throws -> Snapshot {
        let directory = try directory()
        let engine = try SQLiteStore(home.appendingPathComponent(".reason/network/network.db"), readOnly: true)
        let codexLocals = try engine.rows("SELECT name,key,doing FROM sessions WHERE agent='codex' AND attached=1 ORDER BY last_seen DESC").map { row in
            LocalSession(name: row["name"] ?? "", key: row["key"] ?? "", doing: directory.sessions.first { $0.person == directory.person && $0.name == row["name"] }?.doing ?? row["doing"])
        }
        let paused = try pausedSessionKeys(engine)
        var locals = codexLocals.filter { !paused.contains($0.key) }
        if !paused.contains(LocalSession.console.key) { locals.append(.console) }
        let cache = try store()
        var warning: String?
        let hasFiles = try engine.rows("PRAGMA table_info(messages)").contains { $0["name"] == "files" }
        let incomingSQL = "SELECT id,sent_at,sender,body,reply_to" + (hasFiles ? ",files" : "") + " FROM messages WHERE recipient=? AND held=0 ORDER BY sent_at"
        for session in locals where session != .console {
            do {
                for row in try engine.rows(incomingSQL, [directory.person + "/" + session.name]) {
                    try cache.insert(Message(id: row["id"] ?? "", at: (Double(row["sent_at"] ?? "") ?? 0) / 1000, local: session.name, peer: row["sender"] ?? "", direction: "in", body: row["body"] ?? "", result: "", replyTo: row["reply_to"], attachments: SQLiteStore.attachments(row["files"])))
                }
                for event in try mirror.events(for: session) { try cache.insert(event) }
            } catch { warning = "部分历史记录暂未同步：" + error.localizedDescription }
        }
        let team = try? console.team()
        let consoleMailbox = consoleKey(teamID: team?.networkID, directory: directory)
        var address: String?
        if FileManager.default.fileExists(atPath: console.socketURL.path) || local == LocalSession.console.name {
            if let teamID = team?.networkID {
                do { try importConsoleHistory(teamID: teamID, mailbox: consoleMailbox, cache: cache) }
                catch { warning = "独立控制台旧记录暂未导入：" + error.localizedDescription }
            }
            if !paused.contains(LocalSession.console.key), try consoleIsEnabled() {
                do {
                    address = try console.register()
                    try console.sync(into: cache, mailbox: consoleMailbox)
                }
                catch { warning = "独立控制台收件箱暂未同步：" + error.localizedDescription }
            }
        }
        let mailbox = local == LocalSession.console.name ? consoleMailbox : local
        let mailboxes = includeAllLocalIdentities
            ? Set(codexLocals.map(\.name) + [consoleMailbox, mailbox]).sorted()
            : [mailbox]
        if (includeAllLocalIdentities || local == LocalSession.console.name) && viewingConversation && !peer.isEmpty {
            try cache.markRead(mailbox: consoleMailbox, peer: peer)
        }
        let conversations = try cache.conversations(in: mailboxes)
        let placeholders = Array(repeating: "?", count: mailboxes.count).joined(separator: ",")
        let messages = try cache.rows("""
            SELECT * FROM (
                SELECT * FROM events WHERE peer=? AND local_session IN (\(placeholders))
                ORDER BY at DESC,id DESC,local_session DESC,direction DESC LIMIT ?
            ) ORDER BY at,id,local_session,direction
            """, [peer] + mailboxes + [String(limit + 1)]).map(SQLiteStore.event)
        var restored: ConversationSelection?
        if try restoreConversation && messages.isEmpty && cache.mostRecentConversation(in: [mailbox]) == nil {
            restored = try recentConversation(local: local, locals: locals, directory: directory,
                                              consoleAddress: address, consoleMailbox: consoleMailbox, cache: cache)
        }
        return Snapshot(restoredConversation: restored, directory: directory, localSessions: locals,
                        conversations: conversations, messages: Array(messages.suffix(limit)),
                        hasEarlierMessages: messages.count > limit, consoleUnread: try cache.unreadCount(in: consoleMailbox),
                        consoleAddress: address, team: team, mirrorWarning: warning)
    }
    private func recentConversation(local: String, locals: [LocalSession], directory: Directory,
                                    consoleAddress: String?, consoleMailbox: String,
                                    cache: SQLiteStore) throws -> ConversationSelection? {
        var online = Set(directory.sessions.filter {
            $0.person == directory.person && $0.machine == directory.machine && !$0.offline && $0.tier != "none"
        }.map(\.name))
        if consoleAddress != nil { online.insert(LocalSession.console.name) }
        else { online.remove(LocalSession.console.name) }
        guard !online.contains(local) else { return nil }

        let available = locals.filter { $0 != .console || consoleAddress != nil }
        let mailbox: (LocalSession) -> String = { $0 == .console ? consoleMailbox : $0.name }
        let active = available.filter { online.contains($0.name) }.map(mailbox)
        let recent = try cache.mostRecentConversation(in: active)
            ?? cache.mostRecentConversation(in: available.map(mailbox))
        guard let recent, let identity = available.first(where: { mailbox($0) == recent.mailbox }) else { return nil }
        return ConversationSelection(local: identity.name, peer: recent.peer)
    }

    func send(local: String, to: String, body: String, files: [URL] = [], wake: Bool = true, notify: Bool = false) throws -> String {
        let content = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else { throw NetworkError("请先输入消息。") }
        guard content.utf8.count <= 64 * 1024 else { throw NetworkError("消息超过 64 KB，请使用文本附件。") }
        let directory = try directory()
        let peers = directory.sessions.filter { $0.id == to && $0.acceptsMessages }
        guard peers.count == 1, let peer = peers.first, !to.contains("*"), !to.hasPrefix("repo:"),
              !(peer.address == directory.person + "/" + local && peer.machine == directory.machine) else {
            throw NetworkError("所选会话不可用，请刷新后重新选择")
        }
        let key: String
        let mailbox: String
        if local == LocalSession.console.name {
            guard try consoleIsEnabled() else { throw NetworkError("请在「我的会话」中重新接入独立控制台。") }
            let teamID = try? console.team().networkID
            mailbox = consoleKey(teamID: teamID, directory: directory)
            _ = try console.register()
            key = LocalSession.console.key
        } else {
            let engine = try SQLiteStore(home.appendingPathComponent(".reason/network/network.db"), readOnly: true)
            guard let sessionKey = try engine.rows("SELECT key FROM sessions WHERE name=? AND agent='codex' AND attached=1", [local]).first?["key"] else { throw NetworkError("本机 Codex 会话未连接") }
            key = sessionKey
            mailbox = local
        }
        let scopedFiles = files.filter { $0.startAccessingSecurityScopedResource() }
        defer { for file in scopedFiles { file.stopAccessingSecurityScopedResource() } }
        try validateFiles(files)
        var arguments = ["send", "--from", key]
        if !wake { arguments.append("--fyi") }
        if notify { arguments.append("--notify") }
        for file in files { arguments += ["--file", file.path] }
        let result = try run(arguments + [to, "-"], input: content, timeout: 30)
        guard let id = TranscriptMirror.match(#"message id ([0-9A-Z]{26})"#, in: result) else {
            throw NetworkError("没有收到消息编号，投递状态未知：" + String(result.prefix(500)))
        }
        let event = Message(id: id, at: Date().timeIntervalSince1970, local: mailbox, peer: to, direction: "out", body: content,
                            result: result, attachments: files.map { MessageAttachment(name: $0.lastPathComponent) })
        guard event.delivery != "未送出" else {
            throw NetworkError("队友会话没有接收这条消息：" + String(result.prefix(500)))
        }
        do {
            try store().insert(event)
        } catch {
            // Sending has already succeeded: never turn a cache failure into an invitation to resend.
            return "已发送；本地记录保存失败，请勿重复发送。"
        }
        return event.delivery
    }
    func diagnose() throws -> String { try run(["doctor"]) }
    func engineVersion() throws -> String { try run(["--version"]) }
    func personalSessions() throws -> [PersonalSession] {
        let directory = try? directory()
        let participation = try? participationState()
        let discovered = try PersonalSessionCatalog(home: home).discover()
        var sessions = Dictionary(discovered.map { ($0.id, $0) },
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
            guard let key = row["key"], let agent = row["agent"], let name = row["name"] else { continue }
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
        if chosen.id == LocalSession.console.key {
            let address = try console.register()
            try setConsoleEnabled(true)
            return address
        }
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
        if key == LocalSession.console.key { try setConsoleEnabled(false) }
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

    private struct ParticipationState: Decodable { let version: Int; let paused: Set<String> }
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
    private func pausedSessionKeys(_ engine: SQLiteStore) throws -> Set<String> {
        guard !(try engine.rows("SELECT name FROM sqlite_master WHERE type='table' AND name='paused_sessions'")).isEmpty else {
            return []
        }
        return Set(try engine.rows("SELECT key FROM paused_sessions").compactMap { $0["key"] })
    }

    private func consoleIsEnabled() throws -> Bool {
        let setting = try store().rows("SELECT value FROM ui_settings WHERE key='console_enabled'").first
        return setting?["value"] != "0"
    }
    private func setConsoleEnabled(_ enabled: Bool) throws {
        _ = try store().rows("INSERT OR REPLACE INTO ui_settings(key,value) VALUES('console_enabled',?)",
                             [enabled ? "1" : "0"])
    }
    func selfTest() throws -> Data {
        let network = try directory()
        let team = try console.team()
        return try JSONSerialization.data(withJSONObject: [
            "ok": true, "team": network.team ?? "", "machines": network.machines.count,
            "sessions": network.sessions.filter { !$0.offline }.count,
            "relay_connected": team.relay_connected ?? false, "version": try engineVersion()
        ], options: .sortedKeys)
    }
    func restart() throws {
        _ = try run(["stop"], timeout: 30)
        _ = try directory()
    }
    func repair() throws {
        let args = (try? participationState()) == nil ? ["setup"] : ["setup", "--no-service"]
        _ = try run(args, timeout: 45)
    }
    func inviteLink() throws -> String {
        let output = try run(["link"])
        guard let link = TranscriptMirror.match(#"(https://reasonmachines\.com/network/join/[^\s]+)"#, in: output) else {
            throw NetworkError("未能取得邀请链接，请确认这台电脑已加入网络。")
        }
        return link
    }
    private func directory() throws -> Directory {
        let output = try run(["who", "--json", "--all"])
        guard let data = output.data(using: .utf8) else { throw NetworkError("无法读取 Network 目录") }
        let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
        var directory = try decoder.decode(Directory.self, from: data)
        let byAddress = Dictionary(grouping: directory.sessions, by: \.address)
        for index in directory.sessions.indices {
            let session = directory.sessions[index]
            let remoteTerminal = session.agent == "cli" && session.name == "terminal" && session.machine != directory.machine
            if let machine = session.machine, remoteTerminal || (byAddress[session.address]?.count ?? 0) > 1 {
                directory.sessions[index].target = session.address + "@" + machine
            }
        }
        return directory
    }
    private func consoleKey(teamID: String?, directory: Directory) -> String {
        "console:" + (teamID ?? directory.team ?? "local") + ":" + directory.person
    }
    private func importConsoleHistory(teamID: String, mailbox: String, cache: SQLiteStore) throws {
        guard !importedConsoleTeams.contains(mailbox) else { return }
        if FileManager.default.fileExists(atPath: console.legacyHistory.path) {
            let entries = try JSONDecoder().decode([ConsoleMailbox.Entry].self, from: Data(contentsOf: console.legacyHistory))
            for entry in entries where entry.teamID == teamID { try cache.insert(entry.event(in: mailbox)) }
        }
        importedConsoleTeams.insert(mailbox)
    }
    private func validateFiles(_ files: [URL]) throws {
        guard files.count <= 10 else { throw NetworkError("一次最多发送 10 个文本附件。") }
        var total = 0
        for file in files {
            let resolved = file.resolvingSymlinksInPath()
            guard !file.pathComponents.contains(where: { $0.hasPrefix(".") }),
                  !resolved.pathComponents.contains(where: { $0.hasPrefix(".") }) else {
                throw NetworkError("请选择不在隐藏目录中的普通文本文件。")
            }
            let values = try resolved.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard values.isRegularFile == true, let size = values.fileSize, size <= 256 * 1024 else {
                throw NetworkError("每个附件须为不超过 256 KB 的文本文件。")
            }
            let handle = try FileHandle(forReadingFrom: resolved)
            defer { try? handle.close() }
            let data = try handle.read(upToCount: 256 * 1024 + 1) ?? Data()
            guard data.count <= 256 * 1024, let content = String(data: data, encoding: .utf8), !content.contains("\0") else {
                throw NetworkError("请选择不超过 256 KB 的 UTF-8 文本文件。")
            }
            total += data.count
            guard total <= 512 * 1024 else { throw NetworkError("附件合计不能超过 512 KB。") }
        }
    }
    private func store() throws -> SQLiteStore {
        if let cache { return cache }
        let folder = home.appendingPathComponent(".reason/network/local-ui")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let file = folder.appendingPathComponent("messages.sqlite3")
        let database = try SQLiteStore(file, readOnly: false)
        try database.prepareEvents()
        _ = try database.rows("CREATE TABLE IF NOT EXISTS ui_settings(key TEXT PRIMARY KEY, value TEXT NOT NULL)")
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
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
        cache = database
        return database
    }
    // Files avoid pipe-capacity deadlocks; the private temporary directory is removed after every command.
    private func run(_ arguments: [String], input: String? = nil, timeout: TimeInterval = 15) throws -> String {
        let paths = [".local/bin/reason-network", ".reason/bin/reason-network"]
        guard let executable = paths.map({ home.appendingPathComponent($0) }).first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) else {
            throw NetworkError("未找到 Reason Network，请先完成官方安装。")
        }
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
        env["HOME"] = home.path
        process.environment = env
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        try process.run()
        if exited.wait(timeout: .now() + timeout) == .timedOut {
            if process.isRunning {
                process.terminate()
                if exited.wait(timeout: .now() + 1) == .timedOut, process.isRunning {
                    kill(process.processIdentifier, SIGKILL)
                    _ = exited.wait(timeout: .now() + 1)
                }
            }
            throw NetworkError(arguments.first == "send" ? "发送超时，投递状态未知；请确认对方是否收到后再重试。" : "连接超时，请检查 Network 服务。")
        }
        try output.seek(toOffset: 0); try error.seek(toOffset: 0)
        let out = String(decoding: try output.readToEnd() ?? Data(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        let err = String(decoding: try error.readToEnd() ?? Data(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard process.terminationStatus == 0 else { throw NetworkError(String((err.nonEmpty ?? out.nonEmpty ?? "操作失败").prefix(2000))) }
        return out
    }
}
