import Foundation

enum LocalThreadRestriction: String {
    var title: String { L10n.text(rawValue) }

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
    var deletableLocalHistory = false
    var overviewID: [String] { [target ?? address, machine ?? ""] }
    var offline: Bool { restriction != nil || status == "offline" }
    var available: Bool { !offline && tier != "none" }
    var statusText: String {
        if let restriction { return restriction.title }
        if offline { return L10n.text("离线") }
        if tier == "none" { return L10n.text("未接入") }
        return ["busy": L10n.text("工作中"), "idle": L10n.text("空闲"), "live": L10n.text("在线")][status ?? ""] ?? L10n.text("状态未知")
    }
    var id: String { address }
    var title: String { clientTitle?.nonEmpty ?? doing?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty ?? name }
    var titleHelp: String {
        if let clientTitle = clientTitle?.nonEmpty { return clientTitle + "\n" + address }
        if let description = doing?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty {
            return L10n.text("Network 会话描述：") + description + "\n" + address
        }
        return L10n.text("Network 会话地址：") + address
    }
    static func agentGroupID(_ agent: String?) -> String { agent == "deepseek" ? "dsh" : agent ?? "" }

    static func agentDisplayName(_ agent: String?) -> String {
        if agent == "离线" || agent == "历史记录" { return L10n.text(agent ?? "") }
        let names = ["codex": "Codex", "claude-code": "Claude Code", "cursor": "Cursor",
                     "gemini": "Gemini CLI", "cli": L10n.text("终端与控制台"), "reason": "Reason",
                     "dsh": "DeepSeek Harness", "deepseek": "DeepSeek Harness", "copilot": "Copilot CLI"]
        return agent?.nonEmpty.map { names[$0] ?? $0 } ?? L10n.text("其他会话")
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
        guard online else { return L10n.text("离线") }
        let route = link == "direct" ? L10n.text("直连") : link == "relay" ? L10n.text("中继") : nil
        guard let route, !isMe else { return L10n.text("在线") }
        return L10n.text("在线 · ") + route + (rttMs.map { " \(Int($0)) ms" } ?? "")
    }
}
struct Directory: Decodable, Equatable {
    var managesNetwork: Bool?
    func removableDevices(for person: String) -> [Device] {
        guard managesNetwork == true else { return [] }
        return machines.filter { $0.person == person && !$0.isMe }.sorted { ($0.machine, $0.endpoint) < ($1.machine, $1.endpoint) }
    }
    var networkID: String?
    let team: String?
    let person: String
    let machine: String
    var sessions: [NetworkSession]
    let machines: [Device]

    func isOnlyLocalHistory(_ address: String, origins: [String: Set<String>], registered: Set<String>, listed: Set<String>) -> Bool {
        let route = address.components(separatedBy: "@")
        let base = route[0]
        let parts = base.components(separatedBy: "/")
        guard parts.count == 2, parts.allSatisfy({ !$0.isEmpty && $0 != "*" }), route.count <= 2,
              !listed.contains(base), machines.contains(where: { $0.isMe }) else { return false }
        if parts[0] == person && registered.contains(parts[1]) { return false }
        let members = machines.filter { $0.person == parts[0] && !$0.isMe }
        if members.isEmpty { return true }
        if route.count == 2 { return !members.contains { $0.machine == route[1] } }
        // A live machine may omit a paused chat. Require evidence that its known hosting devices left.
        guard let hosts = origins[base], !hosts.isEmpty else { return false }
        return hosts.isDisjoint(with: members.map(\.endpoint))
    }

    func isRecipient(_ session: NetworkSession, sendingAs local: String) -> Bool {
        session.person != person || (session.machine == machine && LocalSession.supportedAgents.contains(session.agent ?? "") && session.name != local)
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
        case .push: L10n.text("即时推送")
        case .turn: L10n.text("回合接收")
        case .pull: L10n.text("手动接收")
        }
    }
}

struct LocalSession: Identifiable, Equatable {
    let name: String
    let key: String
    var doing: String?
    var historyOnly = false
    static let supportedAgents = ["codex", "claude-code", "gemini", "dsh"]
    static func agent(for key: String) -> String? {
        guard let colon = key.firstIndex(of: ":"), key.index(after: colon) != key.endIndex else { return nil }
        let agent = String(key[..<colon])
        return supportedAgents.contains(agent) ? agent : nil
    }
    var agent: String { Self.agent(for: key) ?? "" }
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
        case "queued": return L10n.text("已排队")
        case "accepted": return L10n.text("对方设备已接收")
        case "handed_to_agent": return L10n.text("已交给对方会话")
        case "replied": return L10n.text("已回复")
        case "held": return L10n.text("待批准")
        case "rejected": return L10n.text("已拒收")
        case "expired": return L10n.text("已过期")
        default: break
        }
        if result.hasPrefix("refused:") || result.hasPrefix("rejected:") { return L10n.text("已拒收") }
        if result.hasPrefix("held:") { return L10n.text("待批准") }
        if result.contains("queued") { return L10n.text("已排队") }
        if result.contains("delivered") { return L10n.text("已投递") }
        return result.isEmpty ? "" : L10n.text("已发送")
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
    let mirrorWarning: InterfaceMessage?
}
struct LocalSenderOffline: LocalizedError {
    var errorDescription: String? { L10n.text("本机会话已离线，消息未发送。") }
}

struct NetworkError: LocalizedError {
    private let detail: InterfaceMessage
    var message: String { detail.chinese }
    var errorDescription: String? { detail.text }
    init(_ message: String) { detail = InterfaceMessage { L10n.text(message) } }
    init(localizing render: () -> String) { detail = InterfaceMessage(render) }
}
extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
