import SwiftUI

@MainActor
final class NetworkModel: ObservableObject {
    @Published var directory: Directory?
    @Published var locals: [LocalSession] = []
    @Published private(set) var unjoinedCodexSessions: [PersonalSession] = []
    @Published var messages: [Message] = []
    @Published private(set) var waitingForHistory = true
    @Published var conversations: [String] = []
    @Published var selectedLocal: String {
        didSet {
            guard oldValue != selectedLocal else { return }
            UserDefaults.standard.set(selectedLocal, forKey: "selectedLocal")
            notice = ""
            Task { await refresh() }
        }
    }
    @Published var selectedPeer: String { didSet { guard oldValue != selectedPeer else { return }; UserDefaults.standard.set(selectedPeer, forKey: "selectedPeer"); changedConversation() } }
    struct Draft: Equatable {
        var text = ""
        var files: [URL] = []
        var notify = false
    }
    @Published private var drafts: [String: Draft] = [:]
    @Published private(set) var hasEarlier = false
    var options: Draft {
        get { drafts[conversationKey] ?? Draft() }
        set { drafts[conversationKey] = newValue }
    }
    func attach(_ urls: [URL], to key: String) {
        var item = drafts[key] ?? Draft()
        for url in urls where !item.files.contains(url) { item.files.append(url) }
        guard item.files.count <= 10 else { notice = "每条消息最多添加 10 个附件。"; return }
        drafts[key] = item
    }
    func loadEarlier(before message: Message) async throws -> MessagePage {
        guard let network = directory?.networkID else { throw NetworkError("本机尚未加入 Network。") }
        let page = try await service.history(network: network, local: message.local, peer: message.peer,
                                             before: message.rowKey, acrossLocalIdentities: true)
        return MessagePage(messages: displayTitles(in: page.messages), hasEarlier: page.hasEarlier)
    }
    func readAttachment(_ attachment: MessageAttachment) async throws -> String {
        try await service.attachmentText(attachment)
    }
    @Published private(set) var leavingNetwork = false
    @Published private(set) var departureCount = 0
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
    @Published private(set) var mySessions: [PersonalSession] = []
    @Published private(set) var loadingMySessions = false
    @Published private(set) var changingSession: String?
    @Published private(set) var mySessionsNotice: String?
    @Published private(set) var mySessionsError: String?
    private var running = false
    private var requestAgain = false
    private var messageCache: [String: [Message]] = [:]
    init(service: ReasonService = ReasonService()) {
        self.service = service
        selectedLocal = UserDefaults.standard.string(forKey: "selectedLocal") ?? ""
        selectedPeer = UserDefaults.standard.string(forKey: "selectedPeer") ?? ""
    }
    var conversationKey: String { (directory?.networkID ?? "") + "/" + selectedLocal + "/" + selectedPeer }
    var historyKey: String { (directory?.networkID ?? "") + "/" + selectedPeer }
    var draft: String {
        get { options.text }
        set {
            let value = String(newValue.prefix(10_000))
            if options.text != value { options.text = value }
        }
    }
    var peers: [NetworkSession] {
        var result = directory?.sessions.filter { session in
            session.person != directory?.person ||
                (session.machine == directory?.machine && session.agent == "codex" &&
                 session.clientTitle != nil && session.name != selectedLocal)
        } ?? []
        for address in conversations where !result.contains(where: { $0.address == address }) {
            let parts = address.split(separator: "/", maxSplits: 1).map(String.init)
            result.append(NetworkSession(address: address, name: parts.last ?? address, person: parts.first ?? "", agent: "离线", status: "offline"))
        }
        return result
    }
    var peer: NetworkSession? { peers.first { $0.address == selectedPeer } }
    var own: LocalSession? { locals.first { $0.name == selectedLocal } }
    var canSend: Bool {
        !leavingNetwork && !sending && error == nil && own?.historyOnly == false && peer?.offline == false && (!draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !options.files.isEmpty)
    }
    var localServiceConnected: Bool { directory != nil && error == nil }
    var localServiceStatus: String {
        if error != nil { return "本机连接异常" }
        return localServiceConnected ? "本机已连接" : "本机连接中"
    }
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
        let cached = messageCache[historyKey]
        waitingForHistory = cached == nil
        messages = cached ?? []
        hasEarlier = false
        notice = ""
        Task { await refresh() }
    }
    func refresh() async {
        guard !leavingNetwork else { return }
        let departure = departureCount
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
                let snapshot = try await service.snapshot(local: local, peer: peer, acrossLocalIdentities: true)
                guard !leavingNetwork, departure == departureCount else { return }
                guard local == selectedLocal, peer == selectedPeer else { requestAgain = true; continue }
                if directory?.networkID != snapshot.directory.networkID { messageCache.removeAll() }
                if directory != snapshot.directory { directory = snapshot.directory }
                if locals != snapshot.localSessions { locals = snapshot.localSessions }
                if unjoinedCodexSessions != snapshot.unjoinedCodexSessions {
                    unjoinedCodexSessions = snapshot.unjoinedCodexSessions
                }
                if !locals.contains(where: { $0.name == selectedLocal }), selectedLocal != (locals.first?.name ?? "") {
                    selectedLocal = locals.first?.name ?? ""
                    requestAgain = true
                    continue
                }
                if error != nil { error = nil }
                if mirrorWarning != snapshot.mirrorWarning { mirrorWarning = snapshot.mirrorWarning }
                if waitingForHistory { waitingForHistory = false }
                if conversations != snapshot.conversations { conversations = snapshot.conversations }
                if hasEarlier != snapshot.hasEarlier { hasEarlier = snapshot.hasEarlier }
                let namedMessages = displayTitles(in: snapshot.messages)
                messageCache[historyKey] = namedMessages
                if messages != namedMessages { messages = namedMessages }
                if !peers.contains(where: { $0.address == selectedPeer }), selectedPeer != (peers.first?.address ?? "") {
                    selectedPeer = peers.first?.address ?? ""
                    requestAgain = true
                }
            } catch {
                guard !leavingNetwork, departure == departureCount else { return }
                guard local == selectedLocal, peer == selectedPeer else { requestAgain = true; continue }
                self.error = error.localizedDescription
            }
        } while requestAgain && !Task.isCancelled
    }
    private func displayTitles(in messages: [Message]) -> [Message] {
        let titles = Dictionary(locals.map { ($0.name, $0.title) }, uniquingKeysWith: { first, _ in first })
        return messages.map { original in
            var message = original
            message.localTitle = titles[message.local]
            return message
        }
    }

    func send() async {
        guard canSend, let network = directory?.networkID else { return }
        let local = selectedLocal, peer = selectedPeer, item = options, key = conversationKey
        sending = true; notice = "发送中…"
        do {
            let status = try await service.send(network: network, local: local, to: peer, body: item.text, files: item.files, notify: item.notify)
            if drafts[key] == item { drafts.removeValue(forKey: key) }
            if key == conversationKey { notice = status }
            await refresh()
            if key == conversationKey { sentCount += 1 }
        } catch {
            if key == conversationKey { notice = error.localizedDescription + "；请确认投递状态后再重试。" }
        }
        sending = false
    }
    func refreshMySessions() async {
        guard !loadingMySessions else { return }
        loadingMySessions = true
        defer { loadingMySessions = false }
        do {
            mySessions = try await service.personalSessions()
            mySessionsError = nil
        } catch {
            mySessionsError = error.localizedDescription
        }
    }
    func joinMySession(_ session: PersonalSession) async {
        guard session.canJoin else { return }
        await changeMySession(session, joining: true)
    }
    func leaveMySession(_ session: PersonalSession) async {
        guard session.canLeave else { return }
        await changeMySession(session, joining: false)
    }
    private func changeMySession(_ session: PersonalSession, joining: Bool) async {
        guard changingSession == nil else { return }
        changingSession = session.id
        mySessionsNotice = nil
        mySessionsError = nil
        defer { changingSession = nil }
        do {
            if joining {
                let address = try await service.joinPersonalSession(session.id)
                if case .paused = session.connection, !session.supportsImmediateJoin {
                    mySessionsNotice = "已允许 \(address) 重新接入"
                } else {
                    mySessionsNotice = "已加入 \(address)"
                }
            } else {
                let address = try await service.leavePersonalSession(session.id)
                mySessionsNotice = "\(address) 已退出 Reason Network"
            }
            await refreshMySessions()
            await refresh()
        } catch {
            mySessionsError = error.localizedDescription
        }
    }
    func leaveNetwork(_ id: String) async throws {
        guard directory?.networkID == id, !leavingNetwork, !sending, changingSession == nil else {
            throw NetworkError("Network 状态已变化或有操作正在进行，请稍后重试。")
        }
        leavingNetwork = true
        defer { leavingNetwork = false }
        try await service.leaveNetwork(expected: id)
        directory = nil
        locals = []
        unjoinedCodexSessions = []
        conversations = []
        messages = []
        messageCache.removeAll()
        hasEarlier = false
        mySessions = []
        error = nil
        notice = ""
        mirrorWarning = nil
        doctor = ""
        departureCount += 1
    }

    func supportsSessionExit() async throws -> Bool { try await service.supportsSessionExit() }

    func exitLocal(_ local: LocalSession) async throws -> String {
        guard own?.key == local.key, changingSession == nil else { throw NetworkError("本机会话已变化，请重新选择。") }
        changingSession = local.key
        defer { changingSession = nil }
        let address = try await service.leavePersonalSession(local.key)
        await refresh()
        if selectedLocal == local.name { selectedLocal = locals.first(where: { $0.key != local.key })?.name ?? "" }
        return address
    }

    func invitation() async throws -> String { try await service.inviteLink() }
    func diagnose() async {
        guard !diagnosing else { return }; diagnosing = true
        defer { diagnosing = false }
        do { doctor = try await service.diagnose().nonEmpty ?? "本次检查未返回诊断信息。" }
        catch { doctor = error.localizedDescription }
    }
}
