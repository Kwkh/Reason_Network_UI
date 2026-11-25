import SwiftUI
import AppKit

struct AppRootView: View {
    @EnvironmentObject private var network: NetworkModel
    @EnvironmentObject private var workspaces: WorkspaceController
    @StateObject private var setup = SetupModel()
    @State private var entered = false
    var body: some View {
        Group {
            if !setup.checked {
                ProgressView(L10n.text("正在检查环境…")).controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if entered {
                ContentView()
            } else {
                SetupView(model: setup, isSheet: false) { workspaces.reload(); entered = true }
            }
        }
        .environmentObject(setup)
        .safeAreaInset(edge: .top, spacing: 0) {
            if let event = workspaces.departureNotices.first {
                DepartureNoticeBanner(event: event) { workspaces.acknowledgeDeparture(event.id) }
            }
        }
        .frame(minWidth: 540, minHeight: 520)
        .task {
            while !Task.isCancelled {
                await workspaces.refreshDepartureNotices()
                do { try await Task.sleep(for: .seconds(4)) } catch { return }
            }
        }
        .task {
            await setup.check()
            workspaces.reload()
            entered = !workspaces.items.isEmpty || setup.snapshot.ready || (setup.snapshot.installed && setup.snapshot.background && setup.snapshot.wired && setup.snapshot.issue != nil)
        }
        .onChange(of: network.departureCount) {
            guard network.departureCount > 0, network.directory == nil else { return }
            Task {
                await workspaces.didLeave()
                if workspaces.items.isEmpty { entered = false; setup.didLeave() }
                await setup.check()
            }
        }
        .sheet(isPresented: $setup.presented) {
            SetupView(model: setup, isSheet: true) { setup.presented = false }
                .frame(width: 540, height: 590)
                .networkSheetBackground()
        }
    }
}

struct DepartureNoticeBanner: View {
    let event: NetworkDeparture
    let acknowledge: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: event.reason == .dissolved ? "archivebox" : "rectangle.portrait.and.arrow.right")
                .font(.body).foregroundStyle(.secondary).frame(width: 20, height: 20)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(event.title).font(.headline)
                Text(event.detail).font(.callout).foregroundStyle(.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityElement(children: .combine)
            Spacer(minLength: 8)
            Button(L10n.text("好"), action: acknowledge)
                .buttonStyle(.bordered).controlSize(.small)
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .frame(maxWidth: 620)
        .padding(.horizontal, 16).padding(.vertical, 8)
        .frame(maxWidth: .infinity)
    }
}

struct SetupView: View {
    @ObservedObject var model: SetupModel
    let isSheet: Bool
    let completion: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var details = false
    @State private var help = false
    @State private var creating = false
    @State private var joining = false
    @State private var archive: NetworkWorkspace?
    @State private var joinError: InterfaceMessage?
    @EnvironmentObject private var workspaces: WorkspaceController

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Image(systemName: "bubble.left.and.text.bubble.right")
                            .font(.system(size: 32, weight: .light)).accessibilityHidden(true)
                        Spacer()
                        Menu {
                            Picker(L10n.text("语言"), selection: Binding(
                                get: { L10n.shared.preference }, set: { L10n.shared.preference = $0 }
                            )) {
                                ForEach(AppLanguage.allCases, id: \.self) { language in
                                    Text(language.title).tag(language)
                                }
                            }
                            .pickerStyle(.inline).labelsHidden()
                        } label: {
                            Label(L10n.shared.preference.title, systemImage: "globe")
                        }
                        .menuStyle(.borderlessButton).fixedSize()
                        .accessibilityLabel(L10n.text("语言"))
                        .accessibilityValue(L10n.shared.preference.title)
                    }
                    Text("Reason Network").font(.system(size: 27, weight: .semibold))
                    Text(model.snapshot.ready ? L10n.text("已经准备就绪") : L10n.text("连接你的协作会话"))
                        .font(.system(size: 14)).foregroundStyle(.secondary)
                        .contentTransition(.numericText())
                }
                HStack(spacing: 18) {
                    stage(L10n.text("环境"), number: 0)
                    Image(systemName: "chevron.right").font(.system(size: 9)).foregroundStyle(.tertiary)
                    stage("Network", number: 1)
                    Image(systemName: "chevron.right").font(.system(size: 9)).foregroundStyle(.tertiary)
                    stage(L10n.text("会话"), number: 2)
                }
                .font(.system(size: 12))
                VStack(alignment: .leading, spacing: 18) {
                    if model.step == 0 { dependencies }
                    else if model.step == 1 { join }
                    else { connected }
                }
                .frame(maxWidth: .infinity, minHeight: 150, alignment: .topLeading)
                ArchiveChoices(items: workspaces.archives, selection: $archive)
                if model.busy {
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text(L10n.text(model.activity)).font(.system(size: 12)).foregroundStyle(.secondary)
                            .contentTransition(.numericText())
                    }.accessibilityElement(children: .combine)
                }
                if let error = model.error {
                    Label(error.text, systemImage: "exclamationmark.circle")
                        .font(.system(size: 12)).foregroundStyle(.red).textSelection(.enabled)
                }
                if let issue = model.snapshot.issue {
                    DisclosureGroup(L10n.text("连接详情"), isExpanded: $details) {
                        Text(issue.text).font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary).textSelection(.enabled).padding(.top, 8)
                    }.font(.system(size: 12))
                }
                HStack(spacing: 18) {
                    Button(L10n.text("重新检查"), systemImage: "arrow.clockwise") { Task { await model.check() } }
                        .disabled(model.busy)
                    Button(L10n.text("帮助"), systemImage: "questionmark.circle") { help.toggle() }
                        .popover(isPresented: $help) {
                            VStack(alignment: .leading, spacing: 14) {
                                Text(L10n.text("如何连接")).font(.headline)
                                Text(L10n.text("向队友获取 Network 邀请链接；邀请方需保持在线。同一身份的新机器可使用原机器生成的一次性代码。"))
                                Text(L10n.text("配置会为已安装的代理添加官方 MCP / hooks，并设置后台服务。已有 Network 不会被替换。"))
                                Link(L10n.text("官方说明"), destination: URL(string: "https://reasonmachines.com/network")!)
                            }.font(.system(size: 12)).padding(20).frame(width: 300)
                        }
                    Spacer()
                    if isSheet {
                        Button(L10n.text("关闭")) { completion() }.disabled(model.busy)
                    }
                }
                .font(.system(size: 12)).buttonStyle(.plain).foregroundStyle(.secondary)
            }
            .padding(38)
            .frame(maxWidth: isSheet ? .infinity : 510, alignment: .leading)
            .frame(maxWidth: .infinity, minHeight: 510, alignment: .top)
        }
        .background(Color(nsColor: .textBackgroundColor))
        .sheet(item: $archive) { NetworkArchiveView(workspace: $0) }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: model.step)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: model.busy)
    }

    private func stage(_ title: String, number: Int) -> some View {
        HStack(spacing: 6) {
            Image(systemName: model.step > number || model.snapshot.ready ? "checkmark.circle" : "\(number + 1).circle")
            Text(title)
        }.foregroundStyle(model.step == number ? Color.primary : Color.secondary)
    }
    private var dependencies: some View {
        VStack(alignment: .leading, spacing: 18) {
            checkRow(L10n.text("Reason 命令行工具"), complete: model.snapshot.installed)
            checkRow(L10n.text("逐会话管理后台"), complete: model.snapshot.background && model.snapshot.participation)
            checkRow(L10n.text("Codex 接入"), complete: model.snapshot.wired)
            if !model.snapshot.codex {
                Text(L10n.text("请先安装并打开 Codex，再回来继续配置。"))
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                Link(L10n.text("获取 Codex"), destination: URL(string: "https://chatgpt.com/download/")!)
            }
            if model.snapshot.installed {
                action(L10n.text("配置后台与会话")) { await model.configure() }
            } else {
                action(L10n.text("安装并配置")) { await model.install() }
            }
            Text(L10n.text("安装 App 内置的兼容后台，并为已安装的代理配置接入。"))
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }
    private var join: some View {
        VStack(alignment: .leading, spacing: 16) {
            TextField(L10n.text("邀请链接或四词代码"), text: $model.invitation, axis: .vertical)
                .lineLimit(1...3).networkFormField()
                .accessibilityLabel(L10n.text("Network 邀请链接或一次性代码"))
            NetworkPersonField(person: $model.name)
            if model.snapshot.needsBackendUpdate { action(L10n.text("更新兼容后台")) { await model.configure() } }
            Button(L10n.text("新建 Network")) { creating = true }
                .sheet(isPresented: $creating) { WorkspaceForm(action: .create, person: model.name, onComplete: completion) }
            if let joinError { Text(joinError.text).font(.callout).foregroundStyle(.red) }
            action(joining ? L10n.text("正在加入…") : L10n.text("加入 Network")) {
                joining = true
                defer { joining = false }
                do {
                    try await workspaces.add(name: "", invitation: model.invitation, person: model.name)
                    model.invitation = ""
                    await model.check()
                    completion()
                } catch { joinError = InterfaceMessage { error.localizedDescription } }
            }
                .disabled(model.invitation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.snapshot.issue != nil)
        }.disabled(model.busy || joining)
    }
    private var connected: some View {
        let active = workspaces.current.directory
        let team = active?.team ?? model.snapshot.team
        let sessions = active.map { d in d.sessions.filter { $0.person == d.person && $0.machine == d.machine && $0.available }.count } ?? model.snapshot.sessions
        return VStack(alignment: .leading, spacing: 18) {
            Label(team ?? L10n.text("Network 已连接"), systemImage: "checkmark.circle")
                .font(.system(size: 15, weight: .medium))
            Text(sessions > 0 ? L10n.text("本机会话已在线。") : L10n.text("在「我的会话」里选择要接入这个 Network 的本机对话。"))
                .font(.system(size: 13)).foregroundStyle(.secondary)
            if sessions == 0 {
                Button(L10n.text("打开 Codex"), systemImage: "arrow.up.forward.app") {
                    if let url = ["com.openai.codex", "com.openai.chat"].compactMap({
                        NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0)
                    }).first {
                        NSWorkspace.shared.openApplication(at: url, configuration: .init())
                    }
                }.buttonStyle(.plain)
            }
            if model.snapshot.needsBackendUpdate {
                action(L10n.text("更新兼容后台")) { await model.configure() }
            }
            Button(L10n.text("进入聊天"), action: completion)
                .buttonStyle(SetupActionStyle())
                .disabled(!model.snapshot.ready || model.busy)
        }
    }
    private func checkRow(_ title: String, complete: Bool) -> some View {
        HStack {
            Text(title).font(.system(size: 13))
            Spacer()
            Image(systemName: complete ? "checkmark" : "minus")
                .font(.system(size: 12, weight: .medium)).foregroundStyle(complete ? .primary : .tertiary)
                .accessibilityLabel(complete ? L10n.text("已配置") : L10n.text("待配置"))
        }
    }
    private func action(_ title: String, operation: @escaping () async -> Void) -> some View {
        Button(title) { Task { await operation() } }
            .buttonStyle(SetupActionStyle())
            .disabled(model.busy)
    }
}

extension View {
    func networkSheetBackground() -> some View {
        presentationBackground(Color(nsColor: .textBackgroundColor))
    }

    func networkFormField() -> some View {
        textFieldStyle(.plain).font(.system(size: 13))
            .padding(12).background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
    }
}

struct NetworkPersonField: View {
    @Binding var person: String

    var body: some View {
        HStack {
            Text(L10n.text("你的名称")).foregroundStyle(.secondary)
            TextField(L10n.text("名称"), text: $person).textFieldStyle(.plain).accessibilityLabel(L10n.text("你的名称"))
        }.font(.system(size: 13)).padding(.horizontal, 2)
    }
}

struct SetupActionStyle: ButtonStyle {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        let dark = scheme == .dark
        let ink: Color = dark ? .black : .white
        let fill: Color = dark ? .white : .black
        configuration.label
            .font(.body.weight(.medium))
            .padding(.horizontal, 15)
            .frame(minHeight: 28)
            .foregroundStyle(enabled ? ink : Color.secondary)
            .background {
                Capsule().fill(enabled ? fill.opacity(configuration.isPressed ? 0.78 : 0.94) : Color.primary.opacity(0.09))
            }
            .contentShape(Capsule())
    }
}
