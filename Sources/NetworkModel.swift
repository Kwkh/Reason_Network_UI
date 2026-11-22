import SwiftUI

@MainActor
final class NetworkModel: ObservableObject {
    @Published var directory: Directory?
    @Published var locals: [LocalSession] = []
    @Published var messages: [Message] = []
    @Published var conversations: [String] = []
    @Published var selectedLocal: String { didSet { UserDefaults.standard.set(selectedLocal, forKey: "selectedLocal"); changedConversation() } }
    @Published var selectedPeer: String { didSet { UserDefaults.standard.set(selectedPeer, forKey: "selectedPeer"); changedConversation() } }
    @Published var drafts: [String: String] = [:]
    @Published var sending = false
    @Published var refreshing = false
    @Published var notice = ""
    @Published var error: String?
    @Published var mirrorWarning: String?
    @Published var doctor = ""
    @Published var diagnosing = false
    private let service: ReasonService
    private var running = false
    private var requestAgain = false
    private var messageCache: [String: [Message]] = [:]
    init(service: ReasonService = ReasonService()) {
        self.service = service
        selectedLocal = UserDefaults.standard.string(forKey: "selectedLocal") ?? "websites-codex"
        selectedPeer = UserDefaults.standard.string(forKey: "selectedPeer") ?? ""
    }
    var conversationKey: String { selectedLocal + "/" + selectedPeer }
    var draft: String {
        get { drafts[conversationKey] ?? "" }
        set {
            let value = String(newValue.prefix(10_000))
            if drafts[conversationKey] != value { drafts[conversationKey] = value }
        }
    }
    var peers: [NetworkSession] {
        var result = directory?.sessions.filter { $0.person != directory?.person } ?? []
        for address in conversations where !result.contains(where: { $0.address == address }) {
            let parts = address.split(separator: "/", maxSplits: 1).map(String.init)
            result.append(NetworkSession(address: address, name: parts.last ?? address, person: parts.first ?? "", agent: "离线", offline: true))
        }
        return result
    }
    var peer: NetworkSession? { peers.first { $0.address == selectedPeer } }
    var own: LocalSession? { locals.first { $0.name == selectedLocal } }
    var canSend: Bool {
        !sending && error == nil && own != nil && peer?.offline == false && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    var online: Bool { directory != nil && error == nil }
    var tier: String? { directory?.sessions.first { $0.person == directory?.person && $0.name == selectedLocal }?.tier }
    func start() async {
        guard !running else { return }; running = true
        defer { running = false }
        while !Task.isCancelled {
            await refresh()
            do { try await Task.sleep(for: .seconds(3)) } catch { break }
        }
    }
    private func changedConversation() {
        messages = messageCache[conversationKey] ?? []
        notice = ""
        Task { await refresh() }
    }
    func refresh() async {
        guard !refreshing else { requestAgain = true; return }
        refreshing = true
        repeat {
            requestAgain = false
            let local = selectedLocal, peer = selectedPeer
            do {
                let snapshot = try await service.snapshot(local: local, peer: peer)
                directory = snapshot.directory
                locals = snapshot.localSessions
                error = nil; mirrorWarning = snapshot.mirrorWarning
                guard local == selectedLocal, peer == selectedPeer else { requestAgain = true; continue }
                conversations = snapshot.conversations
                messageCache[conversationKey] = snapshot.messages
                if messages != snapshot.messages { messages = snapshot.messages }
                if selectedPeer.isEmpty, let first = peers.first { selectedPeer = first.address; requestAgain = true }
            } catch { self.error = error.localizedDescription }
        } while requestAgain && !Task.isCancelled
        refreshing = false
    }
    func send() async {
        guard canSend else { return }
        let local = selectedLocal, peer = selectedPeer, body = draft, key = conversationKey
        sending = true; notice = "发送中…"
        do {
            let status = try await service.send(local: local, to: peer, body: body)
            if drafts[key] == body { drafts[key] = "" }
            if key == conversationKey { notice = status }
            await refresh()
        } catch {
            if key == conversationKey { notice = error.localizedDescription + "；请确认投递状态后再重试。" }
        }
        sending = false
    }
    func diagnose() async {
        guard !diagnosing else { return }; diagnosing = true
        defer { diagnosing = false }
        do { doctor = try await service.diagnose() }
        catch { doctor = error.localizedDescription }
    }
}
