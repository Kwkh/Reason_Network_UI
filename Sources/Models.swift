import Foundation

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
    var offline: Bool = false
    var id: String { address }
    var title: String { doing?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty ?? name }
    enum CodingKeys: String, CodingKey { case address, name, person, machine, agent, repo, branch, doing, tier, status }
}
struct Device: Decodable, Identifiable, Equatable {
    let person: String
    let machine: String
    let endpoint: String
    let isMe: Bool
    let online: Bool
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
    let sessions: [NetworkSession]
    let machines: [Device]
}
struct LocalSession: Identifiable, Equatable {
    let name: String
    let key: String
    var doing: String?
    var id: String { key }
    var title: String { doing?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty ?? name }
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
    var outgoing: Bool { direction == "out" }
    var delivery: String {
        if result.contains("queued") { return "已排队" }
        if result.contains("delivered") { return "已投递" }
        return result.isEmpty ? "" : "已发送"
    }
}
struct Snapshot {
    let directory: Directory
    let localSessions: [LocalSession]
    let conversations: [String]
    let messages: [Message]
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
