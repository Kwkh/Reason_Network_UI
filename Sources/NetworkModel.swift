import SwiftUI
import AppKit

@MainActor
final class NetworkModel: ObservableObject {
    enum UtilityPage: String, CaseIterable, Identifiable {
        case overview = "概览"
        case sessions = "会话"
        case settings = "设置"
        var id: Self { self }
    }
    struct Draft: Equatable {
        var text = ""
        var files: [URL] = []
        var wake = true
        var notify = false
    }

    enum ManagementAction {
        case invite, restart, repair
    }

    @Published var directory: Directory?
    @Published var locals: [LocalSession] = []
    @Published var messages: [Message] = []
    @Published var conversations: [ConversationSummary] = []
    @Published var utilityPage: UtilityPage = .overview
    @Published var showsUtilities = false
    @Published var hasEarlierMessages = false
    @Published var consoleUnread = 0
    @Published var consoleAddress: String?
    @Published var team: ConsoleMailbox.Team?
    @Published var engineVersion = ""
    @Published var lastUpdate: Date?
    @Published var selectedLocal: String {
        didSet {
            guard oldValue != selectedLocal else { return }
            UserDefaults.standard.set(selectedLocal, forKey: "selectedLocal")
            conversations = []
            changedConversation()
        }
    }
    @Published var selectedPeer: String {
        didSet {
            guard oldValue != selectedPeer else { return }
            UserDefaults.standard.set(selectedPeer, forKey: "selectedPeer")
            changedConversation()
        }
    }
    @Published private var drafts: [String: Draft] = [:]
    @Published var sending = false
    @Published var refreshing = false
    @Published var notice = ""
    @Published var error: String?
    @Published var mirrorWarning: String?
    @Published var doctor = ""
    @Published var diagnosing = false
    @Published var managing = false
    @Published var managementNotice = ""
    private let service: ReasonService
    private var running = false
    private var requestAgain = false
    private var messageCache: [String: [Message]] = [:]
    private var messageLimit = 100

    init(service: ReasonService = ReasonService()) {
        self.service = service
        selectedLocal = UserDefaults.standard.string(forKey: "selectedLocal") ?? ""
        selectedPeer = UserDefaults.standard.string(forKey: "selectedPeer") ?? ""
    }

    var conversationKey: String { selectedLocal + "\u{0}" + selectedPeer }
    var draft: Draft {
        get { drafts[conversationKey] ?? Draft() }
        set {
            if draft != newValue { drafts[conversationKey] = newValue }
        }
    }
    var listedSessions: [NetworkSession] {
        guard let directory else { return [] }
        let ownConsole = directory.person + "/" + LocalSession.console.name
        return directory.sessions.filter { $0.address != ownConsole || $0.machine != directory.machine }
    }
    var peers: [NetworkSession] {
        guard let directory else { return [] }
        let ownAddress = directory.person + "/" + selectedLocal
        var result = directory.sessions.filter { $0.address != ownAddress || $0.machine != directory.machine }
        let knownAddresses = Set(result.map(\.id))
        for summary in conversations where !knownAddresses.contains(summary.address) && summary.address != ownAddress {
            let address = summary.address
            let parts = address.split(separator: "/", maxSplits: 1).map(String.init)
            result.append(NetworkSession(address: address, name: parts.last ?? address, person: parts.first ?? "", status: "offline"))
        }
        return result.sorted { ($0.offline ? 1 : 0, $0.title, $0.id) < ($1.offline ? 1 : 0, $1.title, $1.id) }
    }
    func summary(for session: NetworkSession) -> ConversationSummary? {
        conversations.first { $0.address == session.id }
    }
    var peer: NetworkSession? { peers.first { $0.id == selectedPeer } }
    var own: LocalSession? { locals.first { $0.name == selectedLocal } }
    var canSend: Bool {
        !sending && error == nil && own != nil && peer?.acceptsMessages == true &&
        !draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    var online: Bool { directory != nil && error == nil }
    var tier: String? {
        if selectedLocal == LocalSession.console.name { return "console" }
        return directory?.sessions.first { $0.person == directory?.person && $0.name == selectedLocal && $0.machine == directory?.machine }?.tier
    }
    var stateFolder: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".reason/network", isDirectory: true)
    }

    func start() async {
        guard !running else { return }
        running = true
        defer { running = false }
        while !Task.isCancelled {
            await refresh()
            do { try await Task.sleep(for: .seconds(3)) } catch { break }
        }
    }
    private func changedConversation() {
        messageLimit = 100
        hasEarlierMessages = false
        messages = Array((messageCache[conversationKey] ?? []).suffix(messageLimit))
        notice = ""
        if refreshing { requestAgain = true }
        else { Task { await refresh() } }
    }
    func refresh() async {
        guard !refreshing else { requestAgain = true; return }
        refreshing = true
        defer { refreshing = false }
        repeat {
            requestAgain = false
            let local = selectedLocal, peer = selectedPeer
            do {
                let viewing = !showsUtilities && NSApp.isActive && NSApp.keyWindow?.isVisible == true
                let snapshot = try await service.snapshot(local: local, peer: peer, limit: messageLimit, viewingConversation: viewing)
                if directory?.team != snapshot.directory.team || directory?.person != snapshot.directory.person {
                    messageCache.removeAll()
                }
                directory = snapshot.directory
                locals = snapshot.localSessions
                consoleAddress = snapshot.consoleAddress
                consoleUnread = snapshot.consoleUnread
                team = snapshot.team
                lastUpdate = Date()
                error = nil
                mirrorWarning = snapshot.mirrorWarning
                guard local == selectedLocal, peer == selectedPeer else { requestAgain = true; continue }
                if !locals.contains(where: { $0.name == selectedLocal }), let first = locals.first {
                    selectedLocal = first.name
                    continue
                }
                conversations = snapshot.conversations
                hasEarlierMessages = snapshot.hasEarlierMessages
                messageCache[conversationKey] = snapshot.messages
                if messages != snapshot.messages { messages = snapshot.messages }
                if self.peer == nil, !peers.isEmpty {
                    selectedPeer = conversations.first(where: { summary in peers.contains(where: { $0.id == summary.address }) })?.address ??
                        peers.first(where: \.acceptsMessages)?.id ?? peers[0].id
                }
            } catch {
                if local == selectedLocal, peer == selectedPeer { self.error = error.localizedDescription }
            }
        } while requestAgain && !Task.isCancelled
    }
    func loadEarlierMessages() async {
        guard hasEarlierMessages else { return }
        messageLimit += 100
        await refresh()
    }
    func open(_ page: UtilityPage) {
        utilityPage = page
        showsUtilities = true
    }
    func openConversation(_ session: NetworkSession) {
        if let directory, session.address == directory.person + "/" + selectedLocal, session.machine == directory.machine {
            selectedLocal = LocalSession.console.name
        }
        selectedPeer = session.id
        showsUtilities = false
    }
    func loadEngineVersion() async {
        guard engineVersion.isEmpty else { return }
        engineVersion = (try? await service.engineVersion()) ?? ""
    }
    func send() async {
        guard canSend else { return }
        let local = selectedLocal, peer = selectedPeer, outgoing = draft, key = conversationKey
        sending = true
        notice = "发送中…"
        defer { sending = false }
        do {
            let status = try await service.send(local: local, to: peer, body: outgoing.text, files: outgoing.files, wake: outgoing.wake, notify: outgoing.notify)
            if drafts[key] == outgoing { drafts[key] = Draft(wake: outgoing.wake, notify: outgoing.notify) }
            if key == conversationKey { notice = status }
            await refresh()
        } catch {
            if key == conversationKey { notice = error.localizedDescription }
        }
    }
    func diagnose() async {
        guard !diagnosing else { return }
        diagnosing = true
        defer { diagnosing = false }
        do { doctor = try await service.diagnose() }
        catch { doctor = error.localizedDescription }
    }
    func addAttachments(_ urls: [URL]) {
        var files = draft.files
        for url in urls where !files.contains(url) { files.append(url) }
        guard files.count <= 10 else { notice = "一次最多添加 10 个文本附件。"; return }
        draft.files = files
        notice = ""
    }
    func attachmentURL(for attachment: MessageAttachment) -> URL? {
        guard let path = attachment.path, path.hasPrefix("/") else { return nil }
        let file = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL
        let root = stateFolder.appendingPathComponent("inbox").resolvingSymlinksInPath().standardizedFileURL
        guard file.path.hasPrefix(root.path + "/"), FileManager.default.fileExists(atPath: file.path) else { return nil }
        return file
    }
    func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
    func manage(_ action: ManagementAction) async {
        guard !managing else { return }
        managing = true
        managementNotice = ""
        defer { managing = false }
        do {
            switch action {
            case .invite:
                let link = try await service.inviteLink()
                copy(link)
                managementNotice = "邀请链接已复制"
            case .restart:
                try await service.restart()
                managementNotice = "网络服务已重启"
                await refresh()
            case .repair:
                try await service.repair()
                managementNotice = "接入配置已更新"
                await refresh()
            }
        } catch {
            managementNotice = error.localizedDescription
        }
    }
}
