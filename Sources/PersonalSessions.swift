import Foundation

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
    var archived = false
    var transcript: URL?
    var nativeID: String?
    var canManageParticipation = false
    var connection: Connection = .notJoined
    var agentName: String { NetworkSession.agentDisplayName(agent) }
    var supportsImmediateJoin: Bool {
        id == LocalSession.console.key || (nativeID != nil && cwd?.hasPrefix("/") == true)
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
        let metadata = [title, id, agentName, cwd ?? ""].joined(separator: " ")
        return query.split(whereSeparator: \.isWhitespace).allSatisfy {
            metadata.localizedCaseInsensitiveContains(String($0))
        }
    }
}

struct PersonalSessionCatalog {
    let home: URL
    private var fm: FileManager { .default }

    func discover() throws -> [PersonalSession] {
        try codex() + claude() + otherLocalSessions()
    }

    private func codex() throws -> [PersonalSession] {
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
        return try db.rows("SELECT id, \(title), cwd, rollout_path, updated_at, \(archived) FROM threads").compactMap { row in
            guard let id = row["id"], UUID(uuidString: id) != nil else { return nil }
            return PersonalSession(id: "codex:" + id, agent: "codex", title: row["title"]?.nonEmpty ?? "未命名对话",
                                   cwd: row["cwd"], updated: Date(timeIntervalSince1970: Double(row["updated_at"] ?? "") ?? 0),
                                   archived: row["archived"] == "1", transcript: codexTranscript(row["rollout_path"], under: root),
                                   nativeID: id)
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
