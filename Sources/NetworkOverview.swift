import AppKit
import SwiftUI

struct CopyInvitationButton: View {
    @EnvironmentObject private var workspaces: WorkspaceController
    @EnvironmentObject private var model: NetworkModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var copyingInvite = false
    @State private var copiedAt: ContinuousClock.Instant?
    @State private var copyError: InterfaceMessage?

    var body: some View {
        let copied = copiedAt != nil
        HStack {
            Button {
                guard !copyingInvite else { return }
                copyingInvite = true
                copyError = nil
                Task {
                    defer { copyingInvite = false }
                    do {
                        let link = try await model.invitation()
                        guard model === workspaces.current else { return }
                        NSPasteboard.general.clearContents()
                        if NSPasteboard.general.setString(link, forType: .string) {
                            copiedAt = .now
                        } else {
                            copiedAt = nil
                            copyError = "复制失败"
                        }
                    } catch {
                        guard model === workspaces.current else { return }
                        copiedAt = nil
                        copyError = "获取失败，请检查连接"
                    }
                }
            } label: {
                Label {
                    ZStack(alignment: .leading) {
                        Text(L10n.text("复制邀请链接")).hidden().accessibilityHidden(true)
                        Text(copied ? L10n.text("已复制") : L10n.text("复制邀请链接"))
                            .contentTransition(reduceMotion ? .identity : .numericText(value: copied ? 1 : 0))
                            .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: copied)
                    }
                } icon: {
                    Image(systemName: "link")
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(copyingInvite ? L10n.text("获取中…") : "")
            Spacer()
            if let copyError {
                Text(copyError.text).foregroundStyle(.secondary).accessibilityAddTraits(.updatesFrequently)
            }
        }
        .font(.system(size: 12))
        .task(id: copiedAt) {
            guard let copiedAt else { return }
            do { try await Task.sleep(until: copiedAt.advanced(by: .seconds(2)), clock: .continuous) }
            catch { return }
            if self.copiedAt == copiedAt { self.copiedAt = nil }
        }
    }
}

struct NetworkOverview: View {
    @EnvironmentObject private var workspaces: WorkspaceController
    var body: some View {
        WorkspaceOverviewPage().environmentObject(workspaces.current)
            .onAppear { workspaces.reload() }
    }
}

private struct WorkspaceOverviewPage: View {
    @EnvironmentObject private var workspaces: WorkspaceController
    @State private var adding: WorkspaceAction?

    @EnvironmentObject private var model: NetworkModel
    @Environment(\.dismiss) private var dismiss
    @State private var archive: NetworkWorkspace?
    @State private var dissolution: NetworkWorkspace?
    @State private var failure: InterfaceMessage?
    @State private var includeOffline = false
    private let panelInset: CGFloat = 34

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(L10n.text("概览")).font(.title2.weight(.semibold))
                Spacer()
                Button(L10n.text("完成")) { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding([.top, .horizontal], panelInset)
            .padding(.bottom, 20)

            Menu {
                ForEach(workspaces.items) { item in
                    Button {
                        workspaces.select(item)
                    } label: {
                        let duplicate = workspaces.items.filter { $0.name == item.name }.count > 1
                        let name = duplicate ? item.name + " · " + item.id.prefix(6) : item.name
                        if item.id == workspaces.selection?.id { Label(name, systemImage: "checkmark") }
                        else { Text(name) }
                    }
                }
                Divider()
                ArchiveChoices(items: workspaces.archives, selection: $archive)
                Button(L10n.text("新建 Network"), systemImage: "plus") { adding = .create }
                Button(L10n.text("加入 Network"), systemImage: "link") { adding = .join }
            } label: {
                Text(workspaces.selection?.name ?? model.directory?.team ?? L10n.text("选择 Network"))
                    .font(.title.weight(.semibold)).lineLimit(1).truncationMode(.tail)
            }
            .menuStyle(.borderlessButton).fixedSize(horizontal: true, vertical: false)
            .accessibilityLabel(L10n.text("选择 Network"))
            .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, panelInset).padding(.bottom, 6)

            if let error = model.error {
                ContentUnavailableView {
                    Label(L10n.text("无法载入网络概览"), systemImage: "network.slash")
                } description: {
                    Text(error.text)
                } actions: {
                    Button(L10n.text("重试")) { Task { await model.refresh() } }
                }
            } else if let directory = model.directory {
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        VStack(alignment: .leading, spacing: 6) {
                            let verified = directory.machines.first(where: \.isMe)?.verified
                            Label(directory.person + (verified.map { $0 ? L10n.text(" · 账号已验证") : L10n.text(" · 账号未验证") } ?? ""),
                                  systemImage: verified == true ? "checkmark.seal" : "person.crop.circle")
                                .foregroundStyle(.secondary)
                        }
                        CopyInvitationButton().id(ObjectIdentifier(model)).disabled(directory.team?.nonEmpty == nil)
                        HStack(spacing: 40) {
                            metric(L10n.text("在线会话"), directory.sessions.filter(\.available).count)
                            metric(L10n.text("在线设备"), directory.machines.filter(\.online).count)
                        }
                        Divider()
                        sessionList(directory)
                        Divider()
                        VStack(alignment: .leading, spacing: 12) {
                            Text(L10n.text("设备")).font(.headline)
                            if directory.machines.isEmpty { Text(L10n.text("暂无设备")).foregroundStyle(.secondary) }
                            ForEach(directory.machines) { device in
                                HStack {
                                    Image(systemName: device.isMe ? "laptopcomputer" : "desktopcomputer")
                                        .foregroundStyle(.secondary).frame(width: 24)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(device.machine).lineLimit(1).help(device.machine)
                                        Text(device.person + (device.isMe ? L10n.text(" · 本机") : ""))
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Text(device.state).font(.caption).monospacedDigit().foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    .safeAreaInset(edge: .bottom, alignment: .leading) {
                        if directory.managesNetwork == true, let item = workspaces.selection, item.id == directory.networkID {
                            Button(L10n.text("解散 Network…"), role: .destructive) { dissolution = item }
                                .padding(.top, 16)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, panelInset).padding(.bottom, 20)
                }
            } else {
                ProgressView(L10n.text("正在读取网络状态…")).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .alert(L10n.text("解散 Network？"), isPresented: Binding(get: { dissolution != nil }, set: { if !$0 { dissolution = nil } }), presenting: dissolution) { item in
            Button(L10n.text("取消"), role: .cancel) {}
            Button(L10n.text("解散"), role: .destructive) {
                Task { do { try await model.leaveNetwork(item.id, dissolving: true); dismiss() }
                       catch { failure = InterfaceMessage { error.localizedDescription } } }
            }
        } message: { item in
            Text(L10n.format("「%@」将永久停止通信，邀请链接失效。设备同步后退出，本机已保存的聊天记录会保留。", item.name))
        }
        .alert(L10n.text("无法解散 Network"), isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
            Button(L10n.text("好"), role: .cancel) {}
        } message: { Text(failure?.text ?? "") }
        .sheet(item: $archive) { NetworkArchiveView(workspace: $0) }
        .sheet(item: $adding) { WorkspaceForm(action: $0, person: model.directory?.person ?? NSUserName()) }
        .frame(width: 540, height: 510)
        .networkSheetBackground()
    }

    private func metric(_ title: String, _ value: Int) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(value, format: .number).font(.title.weight(.medium)).monospacedDigit()
            Text(title).font(.callout).foregroundStyle(.secondary)
        }.accessibilityElement(children: .combine)
    }

    private func sessionList(_ directory: Directory) -> some View {
        let known = Set(directory.sessions.map(\.address))
        let sessions = includeOffline
            ? directory.sessions + model.peers.filter { !known.contains($0.address) }
            : directory.sessions.filter { !$0.offline }
        let groups = Dictionary(grouping: sessions) { NetworkSession.agentDisplayName($0.agent) }
        let addressCounts = Dictionary(grouping: directory.sessions, by: \.address).mapValues(\.count)
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(includeOffline ? L10n.text("全部会话") : L10n.text("在线会话")).font(.headline)
                Spacer()
                Button(includeOffline ? L10n.text("只看在线") : L10n.text("查看全部")) { includeOffline.toggle() }
                    .buttonStyle(.link)
            }
            if sessions.isEmpty {
                Text(includeOffline ? L10n.text("暂无已知会话") : L10n.text("暂无在线会话")).foregroundStyle(.secondary)
            }
            ForEach(groups.keys.sorted(), id: \.self) { agent in
                Text(agent).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                ForEach(groups[agent] ?? [], id: \.overviewID) { session in
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(session.title).lineLimit(1).help(session.titleHelp)
                            let details = [session.address, session.cwd?.nonEmpty ?? session.repo?.nonEmpty]
                                .compactMap { $0 }.joined(separator: " · ")
                            Text(details).font(.caption).foregroundStyle(.secondary)
                                .lineLimit(1).truncationMode(.middle).help(details)
                        }
                        Spacer()
                        Text(session.statusText).font(.caption).foregroundStyle(.secondary)
                        if session.person != directory.person && model.own != nil && (addressCounts[session.address] ?? 0) <= 1 {
                            Button(session.available ? L10n.text("发消息") : L10n.text("查看对话")) {
                                model.selectedPeer = session.address
                                dismiss()
                            }
                        }
                    }
                }
            }
        }
    }
}

enum WorkspaceAction: String, Identifiable {
    case create, join
    var id: Self { self }
    var title: String { self == .create ? L10n.text("新建 Network") : L10n.text("加入 Network") }
}

struct WorkspaceForm: View {
    @EnvironmentObject private var workspaces: WorkspaceController
    @Environment(\.dismiss) private var dismiss
    let action: WorkspaceAction
    @State var person: String
    @State private var value = ""
    @State private var busy = false
    @State private var error: InterfaceMessage?
    var onComplete: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(action.title).font(.title2.weight(.semibold))
            Group {
                if action == .create { TextField(L10n.text("Network 名称"), text: $value) }
                else { SecureField(L10n.text("完整邀请链接"), text: $value) }
            }.networkFormField()
            NetworkPersonField(person: $person)
            if let error { Text(error.text).foregroundStyle(.red).font(.callout).textSelection(.enabled) }
            HStack {
                if busy { ProgressView().controlSize(.small) }
                Spacer()
                Button(L10n.text("取消")) { dismiss() }.buttonStyle(.plain).foregroundStyle(.secondary)
                    .keyboardShortcut(.cancelAction)
                Button(action.title) {
                    busy = true
                    Task {
                        defer { busy = false }
                        do {
                            try await workspaces.add(name: value, invitation: action == .join ? value : nil, person: person)
                            dismiss()
                            onComplete()
                        } catch { self.error = InterfaceMessage { error.localizedDescription } }
                    }
                }.buttonStyle(SetupActionStyle()).keyboardShortcut(.defaultAction)
                    .disabled(value.isEmpty || person.isEmpty)
            }
        }.padding(24).frame(width: 380).disabled(busy).interactiveDismissDisabled(busy)
            .networkSheetBackground()
    }
}

struct ArchiveChoices: View {
    let items: [NetworkWorkspace]
    @Binding var selection: NetworkWorkspace?
    var body: some View {
        if !items.isEmpty {
            Menu(L10n.text("已解散 Network 的记录")) {
                ForEach(items) { item in
                    Button(items.filter { $0.name == item.name }.count > 1 ? item.name + " · " + item.id.prefix(6) : item.name) { selection = item }
                }
            }
        }
    }
}

struct NetworkArchiveView: View {
    let workspace: NetworkWorkspace
    @Environment(\.dismiss) private var dismiss
    @State private var messages: [Message] = []
    @State private var more = false
    @State private var failure: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(workspace.name).font(.title2.bold())
                Spacer()
                Button(L10n.text("完成")) { dismiss() }
            }
            Text(L10n.text("只读聊天记录")).foregroundStyle(.secondary)
            if let failure { Text(failure).textSelection(.enabled) }
            else if messages.isEmpty { Text(L10n.text("还没有消息")).foregroundStyle(.secondary) }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(messages, id: \.rowKey) { message in
                        VStack(alignment: .leading) {
                            HStack {
                                Text(verbatim: message.outgoing ? "\(message.local) → \(message.peer)" : "\(message.peer) → \(message.local)")
                                Spacer()
                                Text(Date(timeIntervalSince1970: message.at), format: .dateTime.month().day().hour().minute())
                            }.font(.caption).foregroundStyle(.secondary)
                            Text(verbatim: message.body).textSelection(.enabled)
                            ForEach(Array(message.attachments.enumerated()), id: \.offset) { _, file in Label(file.name, systemImage: "paperclip") }
                        }
                    }
                    if more { Button(L10n.text("更早的消息")) { load() } }
                }
            }
        }.padding(34).frame(width: 540, height: 510).networkSheetBackground().onAppear { load() }
    }
    private func load() {
        let file = workspace.root.appendingPathComponent("local-ui/messages.sqlite3")
        guard FileManager.default.fileExists(atPath: file.path) else { return }
        do {
            let db = try SQLiteStore(file, readOnly: true)
            let rows = try db.rows("SELECT * FROM network_events WHERE network=? ORDER BY at DESC,id DESC,direction DESC,local_session DESC LIMIT 101 OFFSET ?", [workspace.id,String(messages.count)])
            messages.append(contentsOf: rows.prefix(100).map(SQLiteStore.event))
            more = rows.count > 100
        } catch { failure = error.localizedDescription }
    }
}
