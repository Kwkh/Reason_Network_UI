import SwiftUI

enum SenderPresence: String {
    case archived = "已归档", missing = "本机未找到", unverified = "待核实"
    case online = "在线", offline = "离线", reconnecting = "正在重新接入", history = "仅历史记录", unknown = "状态未知"
}

@MainActor
final class NetworkModel: ObservableObject {
    @Published var directory: Directory?
    @Published var locals: [LocalSession] = []
    @Published var messages: [Message] = []
    @Published private(set) var waitingForHistory = true
    @Published var conversations: [NetworkSession] = []
    @Published var selectedLocal: String {
        didSet {
            guard oldValue != selectedLocal else { return }
            UserDefaults.standard.set(selectedLocal, forKey: "selectedLocal" + preferenceScope)
            UserDefaults.standard.set(own?.key, forKey: "selectedLocalKey" + preferenceScope)
            conversations = []
            changedConversation()
        }
    }
    @Published var selectedPeer: String { didSet { guard oldValue != selectedPeer else { return }; UserDefaults.standard.set(selectedPeer, forKey: "selectedPeer" + preferenceScope); changedConversation() } }
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
    private var readingFrom: Message.RowKey?
    private var selectionGeneration = 0

    func loadEarlier(before message: Message) async throws -> MessagePage {
        guard let network = directory?.networkID else { throw NetworkError("本机尚未加入 Network。") }
        guard message.local == selectedLocal, message.peer == selectedPeer else { throw CancellationError() }
        let generation = selectionGeneration
        let page = try await service.history(network: network, local: message.local, peer: message.peer, before: message.rowKey)
        guard generation == selectionGeneration, directory?.networkID == network, !leavingNetwork else { throw CancellationError() }
        if let first = page.messages.first { readingFrom = first.rowKey }
        return page
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
    private var noticeExpiry: Task<Void, Never>?
    @Published var notice: InterfaceMessage = "" {
        didSet {
            noticeExpiry?.cancel()
            noticeExpiry = nil
        }
    }
    @Published var error: InterfaceMessage?
    @Published var mirrorWarning: InterfaceMessage?
    @Published var doctor: InterfaceMessage = ""
    @Published var diagnosing = false
    private let service: ReasonService
    @Published private(set) var mySessions: [PersonalSession] = []
    @Published private(set) var loadingMySessions = false
    @Published private(set) var changingSession: String?
    @Published private(set) var mySessionsNotice: InterfaceMessage?
    @Published private(set) var mySessionsError: InterfaceMessage?
    @Published private(set) var changingAllConnections = false
    @Published var connectionReport: InterfaceMessage?
    private var requestAgain = false
    private var messageCache: [String: [Message]] = [:]
    private let preferenceScope: String
    init(service: ReasonService = ReasonService(), preferenceScope: String = "") {
        self.preferenceScope = preferenceScope
        self.service = service
        selectedLocal = UserDefaults.standard.string(forKey: "selectedLocal" + preferenceScope) ?? ""
        selectedPeer = UserDefaults.standard.string(forKey: "selectedPeer" + preferenceScope) ?? ""
    }
    var conversationKey: String { (directory?.networkID ?? "") + "/" + selectedLocal + "/" + selectedPeer }
    var draft: String {
        get { options.text }
        set {
            let value = String(newValue.prefix(10_000))
            if options.text != value { options.text = value }
        }
    }
    var peers: [NetworkSession] {
        guard let directory else { return [] }
        var result = directory.sessions.filter { directory.isRecipient($0, sendingAs: selectedLocal) }
        let ownAddress = directory.person + "/" + selectedLocal
        for session in locals where (!session.historyOnly || session.restriction != nil) && session.name != selectedLocal {
            let address = directory.person + "/" + session.name
            if !result.contains(where: { $0.address == address }) {
                result.append(NetworkSession(address: address, name: session.name, person: directory.person,
                                             machine: directory.machine, agent: session.agent, status: "offline", clientTitle: session.title, restriction: session.restriction))
            }
        }
        for previous in conversations where previous.address != ownAddress && !result.contains(where: { $0.address == previous.address }) {
            result.append(previous)
        }
        return result
    }
    var peer: NetworkSession? { peers.first { $0.address == selectedPeer } }
    var own: LocalSession? { locals.first { $0.name == selectedLocal } }
    var senderPresence: SenderPresence {
        own.map(presence(for:)) ?? .unknown
    }
    func presence(for session: LocalSession) -> SenderPresence {
        switch session.restriction {
        case .archived: return .archived
        case .missing: return .missing
        case .unverified: return .unverified
        case nil: break
        }
        if session.historyOnly { return .history }
        if reconnectingKey == session.key { return .reconnecting }
        guard error == nil, let directory else { return .unknown }
        return directory.liveLocalSession(named: session.name, agent: session.agent) == nil ? .offline : .online
    }
    var senderOffline: Bool {
        online && own?.historyOnly == false && directory?.liveLocalSession(named: selectedLocal, agent: own?.agent ?? "") == nil
    }
    var reconnectingSender: Bool { own != nil && reconnectingKey == own?.key }
    @Published private(set) var reconnectingKey: String?
    @Published private var disconnectingKey: String?
    var disconnectingSender: Bool { own != nil && disconnectingKey == own?.key }
    var canSend: Bool {
        !leavingNetwork && !sending && !changingAllConnections && online && !senderOffline && !reconnectingSender && !disconnectingSender && own?.historyOnly == false && peer?.available == true && (!draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !options.files.isEmpty)
    }
    var online: Bool { directory != nil && error == nil }
    var tier: String? { guard online else { return nil }; return directory?.liveLocalSession(named: selectedLocal, agent: own?.agent ?? "")?.tier }
    @Published var receiveModeError: InterfaceMessage?

    func changeReceiveMode(_ mode: ReceiveMode, local: LocalSession, network: String) async {
        guard own?.key == local.key, presence(for: local) == .online else { return }
        await setReceiveMode(mode, for: [local], network: network, batch: false)
    }

    var onlineReceiveTargets: [LocalSession] {
        eligibleLocalSessions(with: .online)
    }

    func changeAllReceiveModes(_ mode: ReceiveMode, network: String) async {
        guard mode == .pull || mode == .push else { return }
        await setReceiveMode(mode, for: onlineReceiveTargets, network: network, batch: true)
    }

    private func setReceiveMode(_ mode: ReceiveMode, for targets: [LocalSession], network: String, batch: Bool) async {
        guard !targets.isEmpty, directory?.networkID == network, changingSession == nil, !leavingNetwork else { return }
        defer { changingSession = nil }
        var effective: [String: ReceiveMode] = [:]
        var errors: [String: InterfaceMessage] = [:]
        for local in targets {
            guard directory?.networkID == network else { return }
            changingSession = local.key
            do {
                effective[local.key] = try await service.setReceiveMode(mode, local: local, network: network)
            } catch {
                errors[local.key] = InterfaceMessage { error.localizedDescription }
            }
        }
        await refresh()
        guard directory?.networkID == network else { return }
        let failures = targets.compactMap { local -> InterfaceMessage? in
            let current = directory?.liveLocalSession(named: local.name, agent: local.agent)?.tier.flatMap(ReceiveMode.init(rawValue:))
            let reason: InterfaceMessage
            if let error = errors[local.key] { reason = error }
            else if let current, self.error == nil {
                if current == mode && effective[local.key] == mode { return nil }
                reason = InterfaceMessage { L10n.format("后台当前生效的是「%@」。", current.title) }
            } else {
                reason = "暂时无法获得该会话的最新状态。"
            }
            return InterfaceMessage { local.title + " (" + local.name + ") · " + reason.text }
        }
        if batch {
            let summary = InterfaceMessage { L10n.format("%lld/%lld 个本机会话已设为%@", targets.count - failures.count, targets.count, mode.title) }
            showTemporaryNotice(summary)
            receiveModeError = failures.isEmpty ? nil : InterfaceMessage { ([summary] + failures).map(\.text).joined(separator: "\n") }
        } else if own?.key == targets.first?.key {
            receiveModeError = failures.first
        }
    }

    func start() async {
        while !Task.isCancelled {
            await refresh()
            do { try await Task.sleep(for: .seconds(3)) } catch { break }
        }
    }
    private func changedConversation() {
        selectionGeneration += 1
        readingFrom = nil
        let cached = messageCache[conversationKey]
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
            let generation = selectionGeneration, floor = readingFrom, network = directory?.networkID
            do {
                let snapshot = try await service.snapshot(local: local, peer: peer, readingFrom: floor, readingNetwork: network)
                guard !leavingNetwork, departure == departureCount else { return }
                guard generation == selectionGeneration, floor == readingFrom else { requestAgain = true; continue }
                if network != snapshot.directory.networkID {
                    selectionGeneration += 1
                    readingFrom = nil
                }
                if directory != snapshot.directory { directory = snapshot.directory }
                if locals != snapshot.localSessions { locals = snapshot.localSessions }
                let savedKey = UserDefaults.standard.string(forKey: "selectedLocalKey" + preferenceScope)
                if let savedKey, let sender = locals.first(where: { $0.key == savedKey }), sender.name != selectedLocal {
                    selectedLocal = sender.name
                    requestAgain = true
                    continue
                }
                if let own, savedKey == nil {
                    UserDefaults.standard.set(own.key, forKey: "selectedLocalKey" + preferenceScope)
                }
                let defaultSender = locals.first(where: { !$0.historyOnly })?.name ?? ""
                if !locals.contains(where: { $0.name == selectedLocal }), selectedLocal != defaultSender {
                    selectedLocal = defaultSender
                    requestAgain = true
                    continue
                }
                if error != nil { error = nil }
                if mirrorWarning != snapshot.mirrorWarning { mirrorWarning = snapshot.mirrorWarning }
                if waitingForHistory { waitingForHistory = false }
                if conversations != snapshot.conversations { conversations = snapshot.conversations }
                if hasEarlier != snapshot.hasEarlier { hasEarlier = snapshot.hasEarlier }
                messageCache[conversationKey] = Array(snapshot.messages.suffix(100))
                if messages != snapshot.messages { messages = snapshot.messages }
                if !peers.contains(where: { $0.address == selectedPeer }), selectedPeer != (peers.first?.address ?? "") {
                    selectedPeer = peers.first?.address ?? ""
                    requestAgain = true
                }
            } catch {
                guard !leavingNetwork, departure == departureCount else { return }
                guard generation == selectionGeneration, floor == readingFrom else { requestAgain = true; continue }
                if error is ReasonService.MembershipEnded { clearAfterDeparture(); return }
                self.error = InterfaceMessage { error.localizedDescription }
            }
        } while requestAgain && !Task.isCancelled
    }
    func send() async {
        guard canSend, let network = directory?.networkID else { return }
        let local = selectedLocal, peer = selectedPeer, item = options, key = conversationKey
        sending = true; notice = "发送中…"
        do {
            guard let sender = own, sender.name == local else { throw LocalSenderOffline() }
            let status = try await service.send(network: network, local: local, expectedKey: sender.key, to: peer, body: item.text, files: item.files, notify: item.notify)
            if drafts[key] == item { drafts.removeValue(forKey: key) }
            if key == conversationKey { notice = status }
            await refresh()
            if key == conversationKey { sentCount += 1 }
        } catch is LocalSenderOffline {
            if key == conversationKey { notice = "本次消息未发送。" }
            await refresh()
        } catch {
            if key == conversationKey { notice = InterfaceMessage { error.localizedDescription + L10n.text("；请确认投递状态后再重试。") } }
        }
        sending = false
    }
    func connectionTargets(disconnect: Bool) -> [LocalSession] {
        eligibleLocalSessions(with: disconnect ? .online : .offline)
    }

    private func eligibleLocalSessions(with status: SenderPresence) -> [LocalSession] {
        guard online, !sending, !leavingNetwork, changingSession == nil, !changingAllConnections else { return [] }
        return locals.filter { $0.hasRegistration && presence(for: $0) == status }
    }

    func changeAllConnections(network: String, disconnect: Bool) async {
        let targets = connectionTargets(disconnect: disconnect)
        guard !targets.isEmpty, directory?.networkID == network else { return }
        changingAllConnections = true
        defer { changingAllConnections = false }
        await changeConnections(targets, network: network, disconnect: disconnect, batch: true)
    }

    func changeSenderConnection(_ local: LocalSession, network: String, disconnect: Bool) async {
        guard own?.key == local.key, connectionTargets(disconnect: disconnect).contains(where: { $0.key == local.key }) else { return }
        await changeConnections([local], network: network, disconnect: disconnect, batch: false)
    }

    private func changeConnections(_ targets: [LocalSession], network: String, disconnect: Bool, batch: Bool) async {
        guard directory?.networkID == network, changingSession == nil, !sending, !leavingNetwork else { return }
        let key = conversationKey
        var errors: [String: InterfaceMessage] = [:]
        defer { changingSession = nil; reconnectingKey = nil; disconnectingKey = nil }
        for local in targets {
            changingSession = local.key
            disconnectingKey = disconnect ? local.key : nil
            reconnectingKey = disconnect ? nil : local.key
            do {
                if disconnect {
                    try await service.removeLocal(local, network: network, keepListed: true)
                } else {
                    try await service.reconnectLocal(local, network: network)
                }
            } catch {
                errors[local.key] = InterfaceMessage { error.localizedDescription }
            }
        }
        await refresh()
        guard directory?.networkID == network else { return }
        reconnectingKey = nil
        let failures = targets.compactMap { local -> InterfaceMessage? in
            let current = locals.first { $0.key == local.key }
            if let current, presence(for: current) == (disconnect ? .offline : .online), errors[local.key] == nil { return nil }
            let reason = errors[local.key] ?? "后台尚未确认会话状态，请稍后刷新。"
            return batch ? InterfaceMessage { local.title + " (" + local.name + ") · " + reason.text } : reason
        }
        if batch {
            let summary = InterfaceMessage { L10n.format(disconnect ? "已断开 %lld/%lld 个本机会话" : "已接入 %lld/%lld 个本机会话", targets.count - failures.count, targets.count) }
            showTemporaryNotice(summary)
            connectionReport = failures.isEmpty ? nil : InterfaceMessage { ([summary] + failures).map(\.text).joined(separator: "\n") }
        } else if key == conversationKey {
            notice = failures.first ?? ""
        }
    }
    private func showTemporaryNotice(_ summary: InterfaceMessage) {
        notice = summary
        noticeExpiry = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(3)) }
            catch { return }
            guard !Task.isCancelled else { return }
            self?.notice = ""
        }
    }

    func refreshMySessions() async {
        guard !loadingMySessions else { return }
        loadingMySessions = true
        defer { loadingMySessions = false }
        do {
            mySessions = try await service.personalSessions()
            mySessionsError = nil
        } catch {
            mySessionsError = InterfaceMessage { error.localizedDescription }
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
                    mySessionsNotice = InterfaceMessage { L10n.format("已允许 %@ 重新接入", address) }
                } else {
                    mySessionsNotice = InterfaceMessage { L10n.format("已加入 %@", address) }
                }
            } else {
                let address = try await service.leavePersonalSession(session.id)
                mySessionsNotice = InterfaceMessage { L10n.format("%@ 已退出 Reason Network", address) }
            }
            await refreshMySessions()
            await refresh()
        } catch {
            mySessionsError = InterfaceMessage { error.localizedDescription }
        }
    }
    func deleteLocalHistory(network: String, local: String, peer: String) async throws {
        guard directory?.networkID == network, selectedLocal == local, !leavingNetwork else {
            throw NetworkError("会话状态已变化，请刷新后重试。")
        }
        try await service.deleteLocalHistory(network: network, local: local, peer: peer)
        messageCache.removeValue(forKey: network + "/" + local + "/" + peer)
        if directory?.networkID == network && selectedLocal == local {
            selectionGeneration += 1
            conversations.removeAll { $0.address == peer }
            if selectedPeer == peer { readingFrom = nil; messages = []; hasEarlier = false }
        }
        await refresh()
    }

    func removeDevice(_ device: Device, network: String) async throws {
        guard directory?.networkID == network, directory?.managesNetwork == true, !device.isMe else {
            throw NetworkError("当前 Network 已变化，请重新确认。")
        }
        try await service.removeDevice(device.endpoint, network: network)
        await refresh()
    }
    func leaveNetwork(_ id: String, dissolving: Bool = false) async throws {
        guard directory?.networkID == id, !leavingNetwork, !sending, changingSession == nil else {
            throw NetworkError("Network 状态已变化或有操作正在进行，请稍后重试。")
        }
        leavingNetwork = true
        defer { leavingNetwork = false }
        try await service.leaveNetwork(expected: id, dissolving: dissolving)
        clearAfterDeparture()
    }
    private func clearAfterDeparture() {
        selectionGeneration += 1
        readingFrom = nil
        directory = nil
        locals = []
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
        guard own?.key == local.key, let network = directory?.networkID, !sending, !leavingNetwork, changingSession == nil else { throw NetworkError("本机会话已变化，请重新选择。") }
        changingSession = local.key
        defer { changingSession = nil }
        let address = (directory?.person ?? "") + "/" + local.name
        try await service.removeLocal(local, network: network)
        await refresh()
        if selectedLocal == local.name { selectedLocal = locals.first(where: { !$0.historyOnly && $0.key != local.key })?.name ?? "" }
        return address
    }

    func invitation() async throws -> String { try await service.inviteLink() }
    func diagnose() async {
        guard !diagnosing else { return }; diagnosing = true
        defer { diagnosing = false }
        do {
            let report = try await service.diagnose(localKey: own?.key)
            doctor = report.text.isEmpty ? "本次检查未返回诊断信息。" : report
        }
        catch { doctor = InterfaceMessage { error.localizedDescription } }
    }
}
