import Foundation
import Darwin

struct PersonalSession: Identifiable {
    enum Connection: Equatable {
        case notJoined
        case online(String)
        case offline(String)
        case paused(String)

        var label: String {
            switch self {
            case .notJoined: "未加入"
            case .online: "已加入 · 在线"
            case .offline: "离线 · 保留地址"
            case .paused: "已退出"
            }
        }
    }

    let id: String
    let agent: String
    let title: String
    let cwd: String?
    let updated: Date
    var project: SessionProject?
    var pinned = false
    var displayProject: SessionProject {
        if let project { return project }
        guard let cwd, !cwd.isEmpty else { return .unassigned }
        return SessionProject(id: cwd, name: URL(fileURLWithPath: cwd).lastPathComponent)
    }
    var transcript: URL?
    var nativeID: String?
    var canManageParticipation = false
    var connection: Connection = .notJoined
    var agentName: String { NetworkSession.agentDisplayName(agent) }
    var supportsImmediateJoin: Bool {
        (nativeID != nil && cwd?.hasPrefix("/") == true)
    }
    var canJoin: Bool {
        if case .online = connection { return false }
        if case .paused = connection { return canManageParticipation }
        return supportsImmediateJoin
    }
    var canLeave: Bool {
        guard canManageParticipation else { return false }
        switch connection {
        case .online, .offline: return true
        case .notJoined, .paused: return false
        }
    }
    func matches(_ query: String) -> Bool {
        let metadata = [title, id, agentName, displayProject.name, cwd ?? ""].joined(separator: " ")
        return query.split(whereSeparator: \.isWhitespace).allSatisfy {
            metadata.localizedCaseInsensitiveContains(String($0))
        }
    }
}

/// Codex can give one project multiple roots and can assign a thread independently of its cwd.
struct SessionProject: Hashable {
    let id: String
    let name: String
    var position: Int = .max
    static let unassigned = Self(id: "", name: "未指定项目")
}

private struct CodexProjects {
    private var projects = [String: SessionProject]()
    private var assignments = [String: [String: String]]()
    private var projectless = Set<String>()
    private var roots = [(path: String, id: String)]()

    init(root: URL, db: SQLiteStore) throws {
        let url = root.appendingPathComponent(".codex-global-state.json")
        let state = (try? Data(contentsOf: url)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        let local = state["local-projects"] as? [String: [String: Any]] ?? [:]
        let projectOrder = state["project-order"] as? [String] ?? []
        for (id, item) in local {
            guard let name = item["name"] as? String else { continue }
            projects[id] = SessionProject(id: id, name: name, position: projectOrder.firstIndex(of: id) ?? .max)
            for path in item["rootPaths"] as? [String] ?? [] { roots.append((path, id)) }
        }
        assignments = state["thread-project-assignments"] as? [String: [String: String]] ?? [:]
        projectless = Set(state["projectless-thread-ids"] as? [String] ?? [])
        let host = "local:" + root.path
        let aliases = (state["app-server-project-id-by-legacy-project-id-by-host"] as? [String: [String: String]])?[host] ?? [:]
        let legacy = Dictionary(aliases.map { ($0.value, $0.key) }, uniquingKeysWith: { first, _ in first })
        let tables = Set(try db.rows("SELECT name FROM sqlite_master WHERE type='table'").compactMap { $0["name"] })
        if tables.contains("projects") {
            for row in try db.rows("SELECT id,name,position FROM projects") {
                guard let id = row["id"], let name = row["name"] else { continue }
                let key = legacy[id] ?? id
                let project = SessionProject(id: key, name: name, position: Int(row["position"] ?? "") ?? .max)
                projects[key] = project
                projects[id] = project
            }
        }
        if tables.contains("project_roots") {
            for row in try db.rows("SELECT project_id,path FROM project_roots") {
                if let id = row["project_id"], let path = row["path"] { roots.append((path, legacy[id] ?? id)) }
            }
        }
        roots.sort {
            if $0.path.count != $1.path.count { return $0.path.count > $1.path.count }
            return (projects[$0.id]?.position ?? .max, $0.id) < (projects[$1.id]?.position ?? .max, $1.id)
        }
    }

    func group(thread: String, projectID: String?, cwd: String?) -> SessionProject? {
        if let projectID, let project = projects[projectID] { return project }
        if projectless.contains(thread) { return .unassigned }
        if let id = assignments[thread]?["projectId"], let project = projects[id] { return project }
        if let cwd, let root = roots.first(where: { cwd == $0.path || cwd.hasPrefix($0.path + "/") }) { return projects[root.id] }
        return projects.isEmpty ? nil : .unassigned
    }

}

struct PersonalSessionCatalog {
    let home: URL
    private var fm: FileManager { .default }

    func discover() throws -> (sessions: [PersonalSession], hidden: Set<String>) {
        // An archived rollout can outlive its index row and Network registration.
        let archive = home.appendingPathComponent(".codex/archived_sessions")
        let archivedKeys = contents(archive).compactMap { url -> String? in
            guard url.pathExtension == "jsonl" else { return nil }
            let suffix = String(url.deletingPathExtension().lastPathComponent.suffix(36))
            guard UUID(uuidString: suffix) != nil else { return nil }
            return "codex:" + suffix.lowercased()
        }
        var hidden = Set(archivedKeys)
        let sessions = try codex(excluding: &hidden) + claude() + otherLocalSessions()
        return (sessions, hidden)
    }

    private func codex(excluding hidden: inout Set<String>) throws -> [PersonalSession] {
        let root = home.appendingPathComponent(".codex", isDirectory: true)
        let states = contents(root).compactMap { url -> (Int, URL)? in
            let name = url.deletingPathExtension().lastPathComponent
            guard url.pathExtension == "sqlite", name.hasPrefix("state_"), let version = Int(name.dropFirst(6)) else { return nil }
            return (version, url)
        }.sorted { $0.0 > $1.0 }
        guard let (_, dbURL) = states.first else { return [] }
        let db = try SQLiteStore(dbURL, readOnly: true)
        let fields = Set(try db.rows("PRAGMA table_info(threads)").compactMap { $0["name"] })
        guard ["id", "title", "cwd", "rollout_path", "updated_at"].allSatisfy(fields.contains) else {
            throw NetworkError("当前 Codex 会话索引格式无法读取。")
        }
        let archived = fields.contains("archived") ? "archived" : "0 AS archived"
        let title = fields.contains("name") ? "COALESCE(NULLIF(name,''),title) AS title" : "title"
        let source = fields.contains("source") ? "source" : "NULL AS source"
        let kind = fields.contains("thread_source") ? "thread_source" : "NULL AS thread_source"
        let projects = try CodexProjects(root: root, db: db)
        let optional = ["project_id", "is_pinned", "attached_thread_parent_id", "archived_at", "updated_at_ms"].map {
            fields.contains($0) ? $0 : "NULL AS " + $0
        }.joined(separator: ",")
        let archivePrefix = root.appendingPathComponent("archived_sessions").path + "/"
        return try db.rows("SELECT \(optional), id, \(kind), \(source), \(title), cwd, rollout_path, updated_at, \(archived) FROM threads").compactMap { row in
            guard let id = row["id"], UUID(uuidString: id) != nil else { return nil }
            if row["archived"] == "1" || row["archived_at"] != nil || row["rollout_path"]?.hasPrefix(archivePrefix) == true ||
                row["attached_thread_parent_id"]?.nonEmpty != nil || isInternalThread(row) {
                hidden.insert("codex:" + id)
                return nil
            }
            hidden.remove("codex:" + id.lowercased())
            let group = projects.group(thread: id, projectID: row["project_id"], cwd: row["cwd"])
            let timestamp = row["updated_at_ms"].flatMap(Double.init).map { $0 / 1000 } ?? Double(row["updated_at"] ?? "") ?? 0
            return PersonalSession(id: "codex:" + id, agent: "codex", title: row["title"]?.nonEmpty ?? "未命名对话",
                                   cwd: row["cwd"], updated: Date(timeIntervalSince1970: timestamp),
                                   project: group, pinned: row["is_pinned"] == "1", transcript: codexTranscript(row["rollout_path"], under: root),
                                   nativeID: id)
        }
    }

    private func isInternalThread(_ row: [String: String]) -> Bool {
        switch row["thread_source"] {
        case "subagent", "guardian_review", "realtime_voice": return true
        case "user": return false
        default:
            guard let source = row["source"], source.trimmingCharacters(in: .whitespaces).hasPrefix("{"),
                  let metadata = try? JSONSerialization.jsonObject(with: Data(source.utf8)) as? [String: Any] else {
                return false
            }
            return metadata["subagent"] != nil
        }
    }

    private func codexTranscript(_ path: String?, under root: URL) -> URL? {
        guard let path, path.hasPrefix("/") else { return nil }
        let transcript = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        let allowed = ["sessions", "archived_sessions"].map { root.appendingPathComponent($0).resolvingSymlinksInPath().path + "/" }
        guard transcript.pathExtension == "jsonl", allowed.contains(where: { transcript.path.hasPrefix($0) }),
              fm.fileExists(atPath: transcript.path) else { return nil }
        return transcript
    }

    private func claude() -> [PersonalSession] {
        let root = home.appendingPathComponent(".claude/projects", isDirectory: true)
        return contents(root).flatMap { project in
            contents(project).compactMap { url in
                let id = url.deletingPathExtension().lastPathComponent
                guard url.pathExtension == "jsonl", UUID(uuidString: id) != nil else { return nil }
                let records = metadataRecords(in: url)
                let cwd = records.compactMap { $0["cwd"] as? String }.first
                let title = records.reversed().compactMap { $0["customTitle"] as? String ?? $0["summary"] as? String ?? $0["slug"] as? String }.first
                return PersonalSession(id: "claude-code:" + id, agent: "claude-code", title: title?.nonEmpty ?? fallbackTitle(cwd, id),
                                       cwd: cwd, updated: modified(url), nativeID: id)
            }
        }
    }

    private func otherLocalSessions() -> [PersonalSession] {
        let dsh = home.appendingPathComponent(".dsh/sessions", isDirectory: true)
        let gemini = home.appendingPathComponent(".gemini/tmp", isDirectory: true)
        let cursor = home.appendingPathComponent(".cursor/projects", isDirectory: true)
        let projectFile = home.appendingPathComponent(".gemini/projects.json")
        let projects = (try? JSONDecoder().decode(GeminiProjects.self, from: Data(contentsOf: projectFile)))?.projects ?? [:]
        let pathsBySlug = Dictionary(grouping: projects.keys.filter { $0.hasPrefix("/") }) { projects[$0] ?? "" }

        let deepseek = contents(dsh).compactMap { url -> PersonalSession? in
            let id = url.lastPathComponent
            guard (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { return nil }
            return PersonalSession(id: "dsh:" + id, agent: "dsh", title: "会话 " + id, cwd: nil, updated: modified(url))
        }
        let geminiChats = contents(gemini).flatMap { project in
            contents(project.appendingPathComponent("chats", isDirectory: true)).compactMap { url -> PersonalSession? in
                guard url.pathExtension == "jsonl", let metadata = metadataRecords(in: url, includeTail: false).first,
                      let id = metadata["sessionId"] as? String, !id.isEmpty else { return nil }
                let paths = pathsBySlug[project.lastPathComponent] ?? []
                let cwd = paths.count == 1 ? paths.first : nil
                return PersonalSession(id: "gemini:" + id, agent: "gemini",
                                       title: (metadata["title"] as? String)?.nonEmpty ?? fallbackTitle(cwd, id),
                                       cwd: cwd, updated: modified(url), nativeID: UUID(uuidString: id) == nil ? nil : id)
            }
        }
        let cursorChats = contents(cursor).flatMap { project in
            contents(project.appendingPathComponent("agent-transcripts", isDirectory: true)).compactMap { url -> PersonalSession? in
                let id = url.deletingPathExtension().lastPathComponent
                guard UUID(uuidString: id) != nil else { return nil }
                return PersonalSession(id: "cursor:" + id, agent: "cursor", title: fallbackTitle(nil, id), cwd: nil, updated: modified(url))
            }
        }
        return deepseek + geminiChats + cursorChats
    }

    private struct GeminiProjects: Decodable { let projects: [String: String] }

    private func metadataRecords(in url: URL, includeTail: Bool = true) -> [[String: Any]] {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }
        let limit = 64 * 1024
        func records() -> [[String: Any]] {
            guard let data = try? handle.read(upToCount: limit) else { return [] }
            return data.split(separator: 10).compactMap { (try? JSONSerialization.jsonObject(with: Data($0))) as? [String: Any] }
        }
        let first = records()
        if includeTail, let size = try? handle.seekToEnd(), size > UInt64(limit) {
            try? handle.seek(toOffset: size - UInt64(limit))
            return first + records()
        }
        return first
    }

    private func contents(_ url: URL) -> [URL] {
        (try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey],
                                     options: [.skipsHiddenFiles])) ?? []
    }

    private func modified(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }

    private func fallbackTitle(_ cwd: String?, _ id: String) -> String {
        let project = cwd.map { URL(fileURLWithPath: $0).lastPathComponent }.flatMap(\.nonEmpty)
        return (project.map { $0 + " · " } ?? "会话 ") + String(id.prefix(8))
    }
}

struct SessionSocket {
    let socketURL: URL
    func request(_ payload: [String: Any], timeout: Int = 5) throws -> Data {
        let path = socketURL.path
        guard path.utf8.count < 104 else { throw NetworkError("数据目录路径过长，无法连接本机服务。") }
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw NetworkError("无法创建本机连接。") }
        defer { Darwin.close(fd) }
        var time = timeval(tv_sec: timeout, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &time, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &time, socklen_t(MemoryLayout<timeval>.size))
        var noSignal: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { bytes in
            bytes.initializeMemory(as: UInt8.self, repeating: 0)
            path.utf8CString.withUnsafeBytes { bytes.copyBytes(from: $0) }
        }
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else { throw NetworkError("本机网络服务尚未就绪，请检查本机服务。") }
        var body = payload
        body["id"] = 1
        var encoded = try JSONSerialization.data(withJSONObject: body)
        encoded.append(10)
        try encoded.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let count = Darwin.write(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw NetworkError("本机服务连接中断，请重试。") }
                offset += count
            }
        }
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 8192)
        while buffer.count < 8 * 1024 * 1024 {
            let size = Darwin.read(fd, &chunk, chunk.count)
            if size < 0 && errno == EINTR { continue }
            guard size > 0 else { throw NetworkError("本机服务没有及时响应，请稍后重试。") }
            buffer.append(contentsOf: chunk.prefix(size))
            while let end = buffer.firstIndex(of: 10) {
                let line = buffer.prefix(upTo: end)
                buffer.removeSubrange(...end)
                guard let reply = try JSONSerialization.jsonObject(with: line) as? [String: Any],
                      reply["id"] as? Int == 1 else { continue }
                guard reply["ok"] as? Bool == true else {
                    throw NetworkError(reply["error"] as? String ?? "操作失败")
                }
                return try JSONSerialization.data(withJSONObject: reply["result"] ?? NSNull(), options: .fragmentsAllowed)
            }
        }
        throw NetworkError("服务返回的数据过大，已停止读取。")
    }

    func decode<T: Decodable>(_ payload: [String: Any], as type: T.Type) throws -> T {
        try JSONDecoder().decode(type, from: request(payload))
    }

}
