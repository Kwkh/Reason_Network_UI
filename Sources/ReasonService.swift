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
    func snapshot(local: String, peer: String) throws -> Snapshot {
        let directory = try directory()
        let engine = try SQLiteStore(home.appendingPathComponent(".reason/network/network.db"), readOnly: true)
        let locals = try engine.rows("SELECT name,key,doing FROM sessions WHERE agent='codex' AND attached=1 ORDER BY last_seen DESC").map { row in
            LocalSession(name: row["name"] ?? "", key: row["key"] ?? "", doing: directory.sessions.first { $0.person == directory.person && $0.name == row["name"] }?.doing ?? row["doing"])
        }
        let cache = try store()
        var warning: String?
        for session in locals {
            do {
                for row in try engine.rows("SELECT id,sent_at,sender,body,reply_to FROM messages WHERE recipient=? AND held=0 ORDER BY sent_at", [directory.person + "/" + session.name]) {
                    try cache.insert(Message(id: row["id"] ?? "", at: (Double(row["sent_at"] ?? "") ?? 0) / 1000, local: session.name, peer: row["sender"] ?? "", direction: "in", body: row["body"] ?? "", result: "", replyTo: row["reply_to"]))
                }
                for event in try mirror.events(for: session) { try cache.insert(event) }
            } catch { warning = "部分历史记录暂未同步：" + error.localizedDescription }
        }
        let conversations = try cache.rows("SELECT peer,MAX(at) AS recent FROM events WHERE local_session=? GROUP BY peer ORDER BY recent DESC", [local]).compactMap { $0["peer"] }
        let messages = try cache.rows("SELECT * FROM (SELECT * FROM events WHERE local_session=? AND peer=? ORDER BY at DESC,id DESC LIMIT 100) ORDER BY at,id", [local, peer]).map(SQLiteStore.event)
        return Snapshot(directory: directory, localSessions: locals, conversations: conversations, messages: messages, mirrorWarning: warning)
    }
    func send(local: String, to: String, body: String) throws -> String {
        let content = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty, content.count <= 10_000 else { throw NetworkError("请输入 1–10000 字的消息") }
        let engine = try SQLiteStore(home.appendingPathComponent(".reason/network/network.db"), readOnly: true)
        guard let key = try engine.rows("SELECT key FROM sessions WHERE name=? AND agent='codex' AND attached=1", [local]).first?["key"] else { throw NetworkError("本机 Codex 会话未连接") }
        let directory = try directory()
        guard directory.sessions.contains(where: { $0.person != directory.person && $0.address == to }) else { throw NetworkError("该队友会话已离线，请刷新后重新选择") }
        let result = try run(["send", "--from", key, to, "-"], input: content, timeout: 30)
        let id = TranscriptMirror.match(#"message id ([0-9A-Z]{26})"#, in: result) ?? UUID().uuidString
        do {
            try store().insert(Message(id: id, at: Date().timeIntervalSince1970, local: local, peer: to, direction: "out", body: content, result: result))
        } catch {
            // Sending has already succeeded: never turn a cache failure into an invitation to resend.
            return "已发送；本地记录保存失败，请勿重复发送。"
        }
        return result.contains("queued") ? "已排队" : "已发送"
    }
    func diagnose() throws -> String { try run(["doctor"]) }
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
