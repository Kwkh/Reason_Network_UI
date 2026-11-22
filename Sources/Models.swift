import Foundation

struct NetworkSession: Decodable, Identifiable, Equatable {
    let address: String
    let name: String
    let person: String
    var machine: String?
    var agent: String?
    var repo: String?
    var branch: String?
    var cwd: String?
    var doing: String?
    var tier: String?
    var status: String?
    var offline: Bool { status == "offline" }
    var acceptsMessages: Bool { tier != "none" && (!offline || tier != nil) }
    var target: String?
    var id: String { target ?? address }
    var title: String { doing?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty ?? name }
    var agentName: String {
        let names = ["codex": "Codex", "claude-code": "Claude Code", "cursor": "Cursor",
                     "gemini": "Gemini CLI", "cli": "终端与控制台", "reason": "Reason",
                     "dsh": "DeepSeek Harness", "deepseek": "DeepSeek Harness", "copilot": "Copilot CLI"]
        return agent.map { names[$0] ?? $0 } ?? "其他会话"
    }
    var statusText: String {
        if tier == "none" { return "未接入" }
        return ["busy": "工作中", "idle": "空闲", "live": "在线", "offline": "离线"][status ?? ""] ?? "状态未知"
    }
    var deliveryText: String {
        ["push": "即时推送", "turn": "下次操作时接收", "pull": "主动读取", "none": "未接入"][tier ?? ""] ?? "状态未知"
    }
    func matches(_ query: String) -> Bool {
        let terms = [title, name, id, agent, agentName, repo, branch, machine, cwd].compactMap { $0 }.joined(separator: " ")
        return query.split(whereSeparator: \.isWhitespace).allSatisfy { terms.localizedCaseInsensitiveContains(String($0)) }
    }
    enum CodingKeys: String, CodingKey { case address, name, person, machine, agent, repo, branch, cwd, doing, tier, status }
}
struct Device: Decodable, Identifiable, Equatable {
    let person: String
    let machine: String
    let endpoint: String
    let isMe: Bool
    let online: Bool
    var verified: Bool?
    let link: String?
    let rttMs: Double?
    var id: String { endpoint }
    var state: String {
        guard isMe || online else { return "离线" }
        let route = link == "direct" ? "直连" : link == "relay" ? "中继" : nil
        guard let route, !isMe else { return "在线" }
        return "在线 · " + route + (rttMs.map { " \(Int($0)) ms" } ?? "")
    }
}
struct Directory: Decodable {
    let team: String?
    let person: String
    let machine: String
    var sessions: [NetworkSession]
    let machines: [Device]
}
struct LocalSession: Identifiable, Equatable {
    static let console = LocalSession(name: "console", key: "cli:reason-network-console", doing: "独立控制台")
    let name: String
    let key: String
    var doing: String?
    var id: String { key }
    var title: String { doing?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty ?? name }
}
struct MessageAttachment: Codable, Equatable {
    let name: String
    var path: String?
}
struct Message: Identifiable, Equatable {
    let id: String
    let at: Double
    let local: String
    let peer: String
    let direction: String
    let body: String
    let result: String
    var replyTo: String? = nil
    var attachments: [MessageAttachment] = []
    var unread = false
    var outgoing: Bool { direction == "out" }
    var delivery: String {
        if result.isEmpty || ["已排队", "已投递", "已发送", "已送达收件箱", "等待对方上线"].contains(result) { return result }
        let receipt = result.lowercased()
        if receipt.contains("held until") { return "等待对方批准" }
        if receipt.contains("refused:") || receipt.contains("doesn't accept messages") ||
           receipt.contains("no session called") || receipt.contains("needs to update reason network") { return "未送出" }
        if receipt.contains("queued") { return "已排队" }
        if receipt.contains("delivered") { return "已投递" }
        return "投递状态待确认"
    }
}
struct ConversationSummary {
    let address: String
    let preview: String
    let unread: Int
}
struct Snapshot {
    let directory: Directory
    let localSessions: [LocalSession]
    let conversations: [ConversationSummary]
    let messages: [Message]
    let hasEarlierMessages: Bool
    let consoleUnread: Int
    let consoleAddress: String?
    let team: ConsoleMailbox.Team?
    let mirrorWarning: String?
}
struct NetworkError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
    init(_ message: String) { self.message = message }
}
extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
