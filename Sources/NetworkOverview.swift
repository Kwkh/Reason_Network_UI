import AppKit
import SwiftUI

struct CopyInvitationButton: View {
    @EnvironmentObject private var workspaces: WorkspaceController
    @EnvironmentObject private var model: NetworkModel
    @State private var copyingInvite = false
    @State private var inviteFeedback: String?

    var body: some View {
        HStack {
            Button("复制邀请链接", systemImage: "link") {
                copyingInvite = true
                inviteFeedback = nil
                Task {
                    defer { copyingInvite = false }
                    do {
                        let link = try await model.invitation()
                        guard model === workspaces.current else { return }
                        NSPasteboard.general.clearContents()
                        inviteFeedback = NSPasteboard.general.setString(link, forType: .string) ? "已复制" : "复制失败"
                    } catch { inviteFeedback = "获取失败，请检查连接" }
                }
            }.buttonStyle(.plain).disabled(copyingInvite)
            Spacer()
            Text(copyingInvite ? "获取中…" : inviteFeedback ?? "").foregroundStyle(.secondary)
                .accessibilityAddTraits(.updatesFrequently)
        }.font(.system(size: 12))
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
    @State private var includeOffline = false
    private let panelInset: CGFloat = 34

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("概览").font(.title2.weight(.semibold))
                Spacer()
                Button("完成") { dismiss() }.keyboardShortcut(.cancelAction)
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
                Button("新建 Network", systemImage: "plus") { adding = .create }
                Button("加入 Network", systemImage: "link") { adding = .join }
            } label: {
                Text(workspaces.selection?.name ?? model.directory?.team ?? "选择 Network")
                    .font(.title.weight(.semibold)).lineLimit(1).truncationMode(.tail)
            }
            .menuStyle(.borderlessButton).fixedSize(horizontal: true, vertical: false)
            .accessibilityLabel("选择 Network")
            .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, panelInset).padding(.bottom, 6)

            if let error = model.error {
                ContentUnavailableView {
                    Label("无法载入网络概览", systemImage: "network.slash")
                } description: {
                    Text(error)
                } actions: {
                    Button("重试") { Task { await model.refresh() } }
                }
            } else if let directory = model.directory {
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        VStack(alignment: .leading, spacing: 6) {
                            let verified = directory.machines.first(where: \.isMe)?.verified
                            Label(directory.person + (verified.map { $0 ? " · 账号已验证" : " · 账号未验证" } ?? ""),
                                  systemImage: verified == true ? "checkmark.seal" : "person.crop.circle")
                                .foregroundStyle(.secondary)
                        }
                        CopyInvitationButton().id(ObjectIdentifier(model)).disabled(directory.team?.nonEmpty == nil)
                        HStack(spacing: 40) {
                            metric("在线会话", directory.sessions.filter(\.available).count)
                            metric("在线设备", directory.machines.filter(\.online).count)
                        }
                        Divider()
                        sessionList(directory)
                        Divider()
                        VStack(alignment: .leading, spacing: 12) {
                            Text("设备").font(.headline)
                            if directory.machines.isEmpty { Text("暂无设备").foregroundStyle(.secondary) }
                            ForEach(directory.machines) { device in
                                HStack {
                                    Image(systemName: device.isMe ? "laptopcomputer" : "desktopcomputer")
                                        .foregroundStyle(.secondary).frame(width: 24)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(device.machine).lineLimit(1).help(device.machine)
                                        Text(device.person + (device.isMe ? " · 本机" : ""))
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Text(device.state).font(.caption).monospacedDigit().foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, panelInset).padding(.bottom, 20)
                }
            } else {
                ProgressView("正在读取网络状态…").frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
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
                Text(includeOffline ? "全部会话" : "在线会话").font(.headline)
                Spacer()
                Button(includeOffline ? "只看在线" : "查看全部") { includeOffline.toggle() }
                    .buttonStyle(.link)
            }
            if sessions.isEmpty {
                Text(includeOffline ? "暂无已知会话" : "暂无在线会话").foregroundStyle(.secondary)
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
                            Button(session.available ? "发消息" : "查看对话") {
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
    var title: String { self == .create ? "新建 Network" : "加入 Network" }
}

struct WorkspaceForm: View {
    @EnvironmentObject private var workspaces: WorkspaceController
    @Environment(\.dismiss) private var dismiss
    let action: WorkspaceAction
    @State var person: String
    @State private var value = ""
    @State private var busy = false
    @State private var error: String?
    var onComplete: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(action.title).font(.title2.weight(.semibold))
            Group {
                if action == .create { TextField("Network 名称", text: $value) }
                else { SecureField("完整邀请链接", text: $value) }
            }.networkFormField()
            NetworkPersonField(person: $person)
            if let error { Text(error).foregroundStyle(.red).font(.callout).textSelection(.enabled) }
            HStack {
                if busy { ProgressView().controlSize(.small) }
                Spacer()
                Button("取消") { dismiss() }.buttonStyle(.plain).foregroundStyle(.secondary)
                    .keyboardShortcut(.cancelAction)
                Button(action.title) {
                    busy = true
                    Task {
                        defer { busy = false }
                        do {
                            try await workspaces.add(name: value, invitation: action == .join ? value : nil, person: person)
                            dismiss()
                            onComplete()
                        } catch { self.error = error.localizedDescription }
                    }
                }.buttonStyle(SetupActionStyle()).keyboardShortcut(.defaultAction)
                    .disabled(value.isEmpty || person.isEmpty)
            }
        }.padding(24).frame(width: 380).disabled(busy).interactiveDismissDisabled(busy)
            .networkSheetBackground()
    }
}
