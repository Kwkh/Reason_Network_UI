import AppKit
import SwiftUI

struct NetworkUtilitiesView: View {
    @EnvironmentObject private var model: NetworkModel
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage("darkAppearance") private var darkAppearance = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 16) {
                Picker("控制台页面", selection: $model.utilityPage) {
                    ForEach(NetworkModel.UtilityPage.allCases) { page in Text(page.rawValue).tag(page) }
                }
                .labelsHidden().pickerStyle(.segmented).frame(width: 224)
                Spacer(minLength: 0)
                if let lastUpdate = model.lastUpdate {
                    Text("更新于 " + lastUpdate.formatted(date: .omitted, time: .standard))
                        .font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
                }
                Button { Task { await model.refresh() } } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.plain).accessibilityLabel("刷新")
                Button { darkAppearance.toggle() } label: { Image(systemName: darkAppearance ? "sun.max" : "moon") }
                    .buttonStyle(.plain).accessibilityLabel("切换外观")
                Button("返回聊天") { model.showsUtilities = false }.keyboardShortcut(.cancelAction)
            }
            .padding(20)
            Divider()
            switch model.utilityPage {
            case .overview: NetworkOverview()
            case .sessions: SessionDirectory()
            case .settings: NetworkSettings()
            }
        }
        .frame(minWidth: 620, idealWidth: 720, minHeight: 490, idealHeight: 620)
        .background(colorScheme == .dark ? Color.black : Color.white)
        .tint(.primary)
    }
}

private struct NetworkOverview: View {
    @EnvironmentObject private var model: NetworkModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 21) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(model.directory?.team ?? "尚未连接网络").font(.system(size: 26, weight: .semibold))
                        if let directory = model.directory {
                            let verified = directory.machines.first(where: \.isMe)?.verified == true
                            Label(directory.person + (verified ? " · 账号已验证" : " · 账号未验证"),
                                  systemImage: verified ? "checkmark.seal" : "person.crop.circle")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Button("复制邀请链接", systemImage: "person.badge.plus") { Task { await model.manage(.invite) } }
                        .disabled(model.managing || model.directory?.team == nil)
                }
                if !model.managementNotice.isEmpty {
                    Text(model.managementNotice).font(.system(size: 12)).foregroundStyle(.secondary).textSelection(.enabled)
                }
                HStack(spacing: 12) {
                    metric("在线会话", model.listedSessions.filter { !$0.offline && $0.acceptsMessages }.count)
                    metric("在线设备", model.directory?.machines.filter { $0.isMe || $0.online }.count ?? 0)
                    metric("控制台未读", model.consoleUnread)
                }
                HStack {
                    Text("在线会话").font(.system(size: 15, weight: .semibold))
                    Spacer()
                    Button("查看全部", systemImage: "arrow.right") { model.utilityPage = .sessions }.buttonStyle(.plain)
                }
                let groups = SessionGroup.group(model.listedSessions.filter { !$0.offline })
                if groups.isEmpty {
                    Text("暂无在线会话").foregroundStyle(.secondary)
                }
                ForEach(groups) { group in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(group.name).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                        ForEach(group.sessions) { session in
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(session.title).lineLimit(1).font(.system(size: 13, weight: .medium))
                                    if let path = session.cwd?.nonEmpty ?? session.repo?.nonEmpty {
                                        Text(path).lineLimit(1).font(.system(size: 11)).foregroundStyle(.secondary).help(path)
                                    }
                                }
                                Spacer()
                                Text(session.statusText).font(.system(size: 11)).foregroundStyle(.secondary)
                                Button("发消息") { model.openConversation(session) }.disabled(!session.acceptsMessages)
                            }
                            .padding(9)
                            .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 8))
                        }
                    }
                }
                if let directory = model.directory, !directory.machines.isEmpty {
                    Text("设备").font(.system(size: 15, weight: .semibold))
                    ForEach(directory.machines) { device in
                        HStack(spacing: 11) {
                            Image(systemName: device.isMe ? "laptopcomputer" : "desktopcomputer").frame(width: 24)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(device.machine).font(.system(size: 12, weight: .medium))
                                Text(device.person + (device.isMe ? " · 本机" : "")).font(.system(size: 11)).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(device.state).font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
                        }
                    }
                }
            }
            .padding(24)
        }
    }

    private func metric(_ title: String, _ value: Int) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(.system(size: 11)).foregroundStyle(.secondary)
            Text("\(value)").font(.system(size: 25, weight: .semibold)).monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(13)
        .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 10))
    }
}

private struct SessionDirectory: View {
    @EnvironmentObject private var model: NetworkModel
    @AppStorage("showOfflineSessions") private var showOffline = false
    @State private var query = ""
    @State private var detail: NetworkSession?

    private var people: [PersonSessions] {
        PersonSessions.group(model.listedSessions.filter { (showOffline || !$0.offline) && $0.matches(query) })
    }

    var body: some View {
        VStack(spacing: 16) {
            HStack(spacing: 16) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("搜索人、Agent 或对话", text: $query).textFieldStyle(.plain)
                }
                .padding(9).background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                Toggle("显示离线", isOn: $showOffline).toggleStyle(.checkbox)
            }
            .padding(.horizontal, 24).padding(.top, 20)
            if people.isEmpty {
                Text("没有匹配的会话").foregroundStyle(.secondary).frame(maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(people) { person in
                            Text(person.name).font(.system(size: 15, weight: .semibold)).padding(.top, 9)
                                .accessibilityAddTraits(.isHeader)
                            ForEach(person.agents) { agent in
                                Text(agent.name).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                                    .padding(.top, 3)
                                ForEach(agent.sessions) { session in
                                    sessionRow(session)
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 24).padding(.bottom, 20)
                }
            }
        }
        .sheet(item: $detail) { session in SessionDetails(session: session) }
    }

    private func sessionRow(_ session: NetworkSession) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(session.title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                Text(session.id).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Text(session.statusText).font(.system(size: 11)).foregroundStyle(.secondary)
            Button { detail = session } label: { Image(systemName: "info.circle") }
                .buttonStyle(.plain).accessibilityLabel("会话详情").help("会话详情")
            Button("发消息") { model.openConversation(session) }.disabled(!session.acceptsMessages)
        }
        .padding(10)
        .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct SessionDetails: View {
    @EnvironmentObject private var model: NetworkModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @State private var copied = false
    let session: NetworkSession
    private var fields: [(String, String)] {
        [("会话", session.name), ("地址", session.id), ("工具", session.agentName), ("设备", session.machine ?? "未提供"),
         ("项目目录", session.cwd?.nonEmpty ?? "未提供"), ("仓库", session.repo ?? "未提供"), ("分支", session.branch ?? "未提供"),
         ("状态", session.statusText), ("消息接收", session.deliveryText)]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("会话详情").font(.system(size: 20, weight: .semibold))
                Spacer()
                Button("完成") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            ForEach(fields, id: \.0) { field in
                LabeledContent(field.0) { Text(field.1).textSelection(.enabled) }
                    .font(.system(size: 12))
            }
            Button(copied ? "已复制会话地址" : "复制会话地址") {
                model.copy(session.id)
                copied = true
            }
        }
        .padding(24).frame(width: 510).background(colorScheme == .dark ? Color.black : Color.white)
    }
}

private struct NetworkSettings: View {
    @EnvironmentObject private var model: NetworkModel
    @AppStorage("darkAppearance") private var darkAppearance = false
    @State private var diagnostics = false
    @State private var copiedDiagnostic = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                settingsSection("网络连接") {
                    setting("本机服务", model.online ? "已连接" : "未连接")
                    setting("当前账号", model.directory?.person ?? "未登录")
                    setting("中继", model.team?.relay_connected.map { $0 ? "已连接" : "未连接" } ?? "状态未知")
                    if let udp = model.team?.udp {
                        setting("UDP 端口", "\(udp.port) · " + (udp.fixed == nil ? "自动分配" : "固定端口"))
                    }
                    Link("打开 Reason Network 网页", destination: URL(string: "https://reasonmachines.com/network")!)
                }
                settingsSection("服务管理") {
                    setting("引擎版本", model.engineVersion.nonEmpty ?? "尚未获取")
                    setting("数据目录", model.stateFolder.path)
                    NetworkServiceActions()
                    let log = model.stateFolder.appendingPathComponent("daemon.log")
                    Button("在 Finder 中查看后台日志", systemImage: "doc.text") {
                        NSWorkspace.shared.activateFileViewerSelecting([log])
                    }.disabled(!FileManager.default.fileExists(atPath: log.path))
                    Button("运行诊断", systemImage: "stethoscope") {
                        copiedDiagnostic = false
                        diagnostics = true
                        Task { await model.diagnose() }
                    }.disabled(model.diagnosing)
                    if diagnostics {
                        if model.diagnosing {
                            ProgressView().controlSize(.small)
                        } else if !model.doctor.isEmpty {
                            ScrollView {
                                Text(model.doctor).font(.system(size: 11, design: .monospaced))
                                    .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .frame(maxHeight: 165)
                            Button(copiedDiagnostic ? "已复制诊断结果" : "复制诊断结果") {
                                model.copy(model.doctor)
                                copiedDiagnostic = true
                            }
                        }
                        if let warning = model.mirrorWarning { Text(warning).foregroundStyle(.secondary) }
                    }
                }
                settingsSection("控制台") {
                    Toggle("深色外观", isOn: $darkAppearance).toggleStyle(.switch).controlSize(.small)
                    setting("控制台地址", model.consoleAddress ?? "尚未连接")
                    setting("消息记录", "保存在这台电脑")
                }
            }
            .padding(24).font(.system(size: 12))
        }
        .task { await model.loadEngineVersion() }
    }

    private func setting(_ title: String, _ value: String) -> some View {
        LabeledContent(title) { Text(value).textSelection(.enabled) }
    }

    private func settingsSection<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.system(size: 14, weight: .semibold))
            content()
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 10))
    }
}
