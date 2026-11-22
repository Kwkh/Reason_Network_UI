import SwiftUI

@MainActor
final class NetworkModel: ObservableObject {
    @Published var directory: Directory?
    @Published var locals: [LocalSession] = []
    @Published var messages: [Message] = []
    @Published private(set) var waitingForHistory = true
    @Published var conversations: [String] = []
    @Published var selectedLocal: String { didSet { guard oldValue != selectedLocal else { return }; UserDefaults.standard.set(selectedLocal, forKey: "selectedLocal"); changedConversation() } }
    @Published var selectedPeer: String { didSet { guard oldValue != selectedPeer else { return }; UserDefaults.standard.set(selectedPeer, forKey: "selectedPeer"); changedConversation() } }
    @Published var drafts: [String: String] = [:]
    @Published var sending = false
    @Published private(set) var sentCount = 0
    private var refreshing = false
    private var refreshWaiters: [CheckedContinuation<Void, Never>] = []
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
        selectedLocal = UserDefaults.standard.string(forKey: "selectedLocal") ?? ""
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
        let cached = messageCache[conversationKey]
        waitingForHistory = cached == nil
        messages = cached ?? []
        notice = ""
        Task { await refresh() }
    }
    func refresh() async {
        guard !refreshing else {
            requestAgain = true
            await withCheckedContinuation { refreshWaiters.append($0) }
            return
        }
        refreshing = true
        defer {
            refreshing = false
            let waiters = refreshWaiters
            refreshWaiters.removeAll(keepingCapacity: true)
            for waiter in waiters { waiter.resume() }
        }
        repeat {
            requestAgain = false
            let local = selectedLocal, peer = selectedPeer
            do {
                let snapshot = try await service.snapshot(local: local, peer: peer)
                guard local == selectedLocal, peer == selectedPeer else { requestAgain = true; continue }
                if directory != snapshot.directory { directory = snapshot.directory }
                if locals != snapshot.localSessions { locals = snapshot.localSessions }
                if selectedLocal.isEmpty, let first = snapshot.localSessions.first {
                    selectedLocal = first.name
                    requestAgain = true
                    continue
                }
                if error != nil { error = nil }
                if mirrorWarning != snapshot.mirrorWarning { mirrorWarning = snapshot.mirrorWarning }
                if waitingForHistory { waitingForHistory = false }
                if conversations != snapshot.conversations { conversations = snapshot.conversations }
                messageCache[conversationKey] = snapshot.messages
                if messages != snapshot.messages { messages = snapshot.messages }
                if selectedPeer.isEmpty, let first = peers.first { selectedPeer = first.address; requestAgain = true }
            } catch {
                guard local == selectedLocal, peer == selectedPeer else { requestAgain = true; continue }
                self.error = error.localizedDescription
            }
        } while requestAgain && !Task.isCancelled
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
            if key == conversationKey { sentCount += 1 }
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
