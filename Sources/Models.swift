import Foundation

enum LocalThreadRestriction: String {
    case archived = "已归档"
    case missing = "本机未找到"
    case unverified = "待核实"
}

struct NetworkSession: Decodable, Identifiable, Equatable {
    let address: String
    let name: String
    let person: String
    var machine: String?
    var agent: String?
    var repo: String?
    var branch: String?
    var doing: String?
    var tier: String?
    var status: String?
    var cwd: String?
    var target: String?
    var clientTitle: String?
    var restriction: LocalThreadRestriction?
    var overviewID: [String] { [target ?? address, machine ?? ""] }
    var offline: Bool { restriction != nil || status == "offline" }
    var available: Bool { !offline && tier != "none" }
    var statusText: String {
        if let restriction { return restriction.rawValue }
        if offline { return "离线" }
        if tier == "none" { return "未接入" }
        return ["busy": "工作中", "idle": "空闲", "live": "在线"][status ?? ""] ?? "状态未知"
    }
    var id: String { address }
    var title: String { clientTitle?.nonEmpty ?? doing?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty ?? name }
    var titleHelp: String {
        if let clientTitle = clientTitle?.nonEmpty { return clientTitle + "\n" + address }
        if let description = doing?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty {
            return "Network 会话描述：" + description + "\n" + address
        }
        return "Network 会话地址：" + address
    }
    static func agentDisplayName(_ agent: String?) -> String {
        let names = ["codex": "Codex", "claude-code": "Claude Code", "cursor": "Cursor",
                     "gemini": "Gemini CLI", "cli": "终端与控制台", "reason": "Reason",
                     "dsh": "DeepSeek Harness", "deepseek": "DeepSeek Harness", "copilot": "Copilot CLI"]
        return agent.map { names[$0] ?? $0 } ?? "其他会话"
    }
    enum CodingKeys: String, CodingKey { case address, name, person, machine, agent, repo, branch, doing, tier, status, cwd, target; case clientTitle = "title" }
}
struct Device: Decodable, Identifiable, Equatable {
    let person: String
    let machine: String
    let endpoint: String
    var verified: Bool?
    let isMe: Bool
    let online: Bool
    let link: String?
    let rttMs: Double?
    var id: String { endpoint }
    var state: String {
        guard online else { return "离线" }
        let route = link == "direct" ? "直连" : link == "relay" ? "中继" : nil
        guard let route, !isMe else { return "在线" }
        return "在线 · " + route + (rttMs.map { " \(Int($0)) ms" } ?? "")
    }
}
struct Directory: Decodable, Equatable {
    var networkID: String?
    let team: String?
    let person: String
    let machine: String
    var sessions: [NetworkSession]
    let machines: [Device]

    func isRecipient(_ session: NetworkSession, sendingAs local: String) -> Bool {
        session.person != person || (session.machine == machine && session.agent == "codex" && session.name != local)
    }

    func liveLocalSession(named name: String, agent: String) -> NetworkSession? {
        guard !machines.contains(where: { $0.isMe && !$0.online }) else { return nil }
        return sessions.first {
            $0.person == person && $0.machine == machine && $0.name == name && $0.agent == agent &&
                $0.available && $0.tier != nil
        }
    }
}
enum ReceiveMode: String, CaseIterable, Decodable {
    case push, turn, pull

    var title: String {
        switch self {
        case .push: "即时推送"
        case .turn: "回合接收"
        case .pull: "手动接收"
        }
    }
}

struct LocalSession: Identifiable, Equatable {
    let name: String
    let key: String
    var doing: String?
    var historyOnly = false
    var hasRegistration: Bool { !key.hasPrefix("history:") }
    var restriction: LocalThreadRestriction?
    var id: String { key }
    var title: String { doing?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty ?? name }
}
struct MessageAttachment: Equatable, Codable {
    let name: String
    var directory: String?

    func readText(in inbox: URL) throws -> String {
        guard let directory, directory.range(of: #"^[0-9A-HJKMNP-TV-Z]{26}$"#, options: .regularExpression) != nil,
              !name.isEmpty, name != ".", name != "..", !name.contains("/") else {
            throw NetworkError("附件位置不可用。")
        }
        let root = inbox.resolvingSymlinksInPath().standardizedFileURL
        let file = root.appendingPathComponent(directory).appendingPathComponent(name)
        guard file.resolvingSymlinksInPath().standardizedFileURL == file.standardizedFileURL,
              (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
            throw NetworkError("附件已过期或无法读取。")
        }
        return try Self.text(at: file)
    }

    static func text(at url: URL) throws -> String {
        guard try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
            throw NetworkError("请选择普通文本文件。")
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: 256 * 1024 + 1) ?? Data()
        guard data.count <= 256 * 1024, let text = String(data: data, encoding: .utf8),
              !text.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) && $0.value < 160 && ![9,10,13].contains($0.value) }) else {
            throw NetworkError("每个附件须为不超过 256 KiB 的 UTF-8 文本。")
        }
        return text
    }
}

struct MessagePage {
    let messages: [Message]
    let hasEarlier: Bool
}

struct Message: Identifiable, Equatable {
    struct RowKey: Hashable {
        let id: String
        let local: String
        let direction: String
    }
    var rowKey: RowKey { RowKey(id: id, local: local, direction: direction) }

    let id: String
    let at: Double
    let local: String
    let peer: String
    let direction: String
    let body: String
    let result: String
    var replyTo: String? = nil
    var attachments: [MessageAttachment] = []
    var receiptStage: String? = nil
    var outgoing: Bool { direction == "out" }
    var delivery: String {
        switch receiptStage {
        case "queued": return "已排队"
        case "accepted": return "对方设备已接收"
        case "handed_to_agent": return "已交给对方会话"
        case "replied": return "已回复"
        case "held": return "待批准"
        case "rejected": return "已拒收"
        case "expired": return "已过期"
        default: break
        }
        if result.hasPrefix("refused:") || result.hasPrefix("rejected:") { return "已拒收" }
        if result.hasPrefix("held:") { return "待批准" }
        if result.contains("queued") { return "已排队" }
        if result.contains("delivered") { return "已投递" }
        return result.isEmpty ? "" : "已发送"
    }
}
enum TranscriptBottomProximity {
    case pinned, nearby, away

    init(distance: CGFloat, viewportHeight: CGFloat) {
        if distance <= 8 { self = .pinned }
        else if distance <= min(72, viewportHeight / 5) { self = .nearby }
        else { self = .away }
    }
}

// The service returns the latest 100 messages. While reading, replacing that window
// can move or evict the visible paragraph. Keep at most one displayed window.
struct ConversationReadingWindow {
    private(set) var messages: [Message] = []
    private(set) var hasPendingUpdate = false
    private(set) var expanded = false

    mutating func prepend(_ page: MessagePage, before key: Message.RowKey) {
        guard messages.first?.rowKey == key, !page.messages.isEmpty else { return }
        messages.insert(contentsOf: page.messages, at: 0)
        expanded = true
    }

    /// Returns true when the view should pin the new layout to its bottom edge.
    mutating func receive(_ latest: [Message], proximity: TranscriptBottomProximity) -> Bool {
        // Measure proximity against the old document. Only a new tail message should
        // pull a nearby reader down; receipt updates and historical inserts can wait in place.
        let follow: Bool
        if proximity == .nearby, let previous = messages.last, let next = latest.last {
            follow = (next.at, next.id, next.direction) > (previous.at, previous.id, previous.direction) &&
                !messages.contains { $0.rowKey == next.rowKey }
        } else {
            follow = proximity == .pinned
        }
        if expanded, let first = latest.first, let overlap = messages.firstIndex(where: { $0.rowKey == first.rowKey }) {
            let changed = !messages[overlap...].elementsEqual(latest)
            if changed { messages.replaceSubrange(overlap..., with: latest) }
            hasPendingUpdate = false
            return changed && follow
        }
        if latest == messages {
            hasPendingUpdate = false
            return false
        }
        if messages.isEmpty || latest.isEmpty || follow {
            show(latest)
            return !latest.isEmpty
        }
        if latest.starts(with: messages, by: { $0.rowKey == $1.rowKey }) {
            show(latest)
        } else {
            hasPendingUpdate = true
        }
        return false
    }

    mutating func show(_ latest: [Message]) {
        expanded = false
        messages = latest
        hasPendingUpdate = false
    }
}

struct Snapshot {
    let directory: Directory
    let localSessions: [LocalSession]
    let conversations: [NetworkSession]
    let messages: [Message]
    let hasEarlier: Bool
    let mirrorWarning: String?
}
struct LocalSenderOffline: LocalizedError {
    var errorDescription: String? { "本机会话已离线，消息未发送。" }
}

struct NetworkError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
    init(_ message: String) { self.message = message }
}
extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
