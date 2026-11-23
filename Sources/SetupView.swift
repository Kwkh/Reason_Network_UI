import SwiftUI
import AppKit

struct AppRootView: View {
    @EnvironmentObject private var network: NetworkModel
    @StateObject private var setup = SetupModel()
    @State private var entered = false
    var body: some View {
        Group {
            if !setup.checked {
                ProgressView("正在检查环境…").controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if entered {
                ContentView()
            } else {
                SetupView(model: setup) { entered = true }
            }
        }
        .frame(minWidth: 540, minHeight: 520)
        .environmentObject(setup)
        .task {
            await setup.check()
            entered = setup.snapshot.ready || (setup.snapshot.installed && setup.snapshot.background && setup.snapshot.wired && setup.snapshot.issue != nil)
        }
        .onChange(of: network.departureCount) {
            entered = false
            setup.didLeave()
            Task { await setup.check() }
        }
        .sheet(isPresented: $setup.presented) {
            SetupView(model: setup) { setup.presented = false }
                .frame(width: 540, height: 590)
        }
    }
}

struct SetupView: View {
    @ObservedObject var model: SetupModel
    let completion: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var details = false
    @State private var help = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                VStack(alignment: .leading, spacing: 12) {
                    Image(systemName: "bubble.left.and.text.bubble.right")
                        .font(.system(size: 32, weight: .light)).accessibilityHidden(true)
                    Text("Reason Network").font(.system(size: 27, weight: .semibold))
                    Text(model.snapshot.ready ? "已经准备就绪" : "连接你的协作会话")
                        .font(.system(size: 14)).foregroundStyle(.secondary)
                        .contentTransition(.numericText())
                }
                HStack(spacing: 18) {
                    stage("环境", number: 0)
                    Image(systemName: "chevron.right").font(.system(size: 9)).foregroundStyle(.tertiary)
                    stage("Network", number: 1)
                    Image(systemName: "chevron.right").font(.system(size: 9)).foregroundStyle(.tertiary)
                    stage("会话", number: 2)
                }
                .font(.system(size: 12))
                VStack(alignment: .leading, spacing: 18) {
                    if model.step == 0 { dependencies }
                    else if model.step == 1 { join }
                    else { connected }
                }
                .frame(maxWidth: .infinity, minHeight: 150, alignment: .topLeading)
                if model.busy {
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text(model.activity).font(.system(size: 12)).foregroundStyle(.secondary)
                            .contentTransition(.numericText())
                    }.accessibilityElement(children: .combine)
                }
                if let error = model.error {
                    Label(error, systemImage: "exclamationmark.circle")
                        .font(.system(size: 12)).foregroundStyle(.red).textSelection(.enabled)
                }
                if let issue = model.snapshot.issue {
                    DisclosureGroup("连接详情", isExpanded: $details) {
                        Text(issue).font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary).textSelection(.enabled).padding(.top, 8)
                    }.font(.system(size: 12))
                }
                HStack(spacing: 18) {
                    Button("重新检查", systemImage: "arrow.clockwise") { Task { await model.check() } }
                        .disabled(model.busy)
                    Button("帮助", systemImage: "questionmark.circle") { help.toggle() }
                        .popover(isPresented: $help) {
                            VStack(alignment: .leading, spacing: 14) {
                                Text("如何连接").font(.headline)
                                Text("向队友获取 Network 邀请链接；邀请方需保持在线。同一身份的新机器可使用原机器生成的一次性代码。")
                                Text("配置会为已安装的代理添加官方 MCP / hooks，并设置后台服务。已有 Network 不会被替换。")
                                Link("官方说明", destination: URL(string: "https://reasonmachines.com/network")!)
                            }.font(.system(size: 12)).padding(20).frame(width: 300)
                        }
                    Spacer()
                    if model.presented {
                        Button("关闭") { completion() }.disabled(model.busy)
                    }
                }
                .font(.system(size: 12)).buttonStyle(.plain).foregroundStyle(.secondary)
            }
            .padding(38).frame(maxWidth: 510, alignment: .leading)
            .frame(maxWidth: .infinity, minHeight: 510, alignment: .top)
        }
        .background(Color(nsColor: .textBackgroundColor))
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
            checkRow("Reason 命令行工具", complete: model.snapshot.installed)
            checkRow("逐会话管理后台", complete: model.snapshot.background && model.snapshot.participation)
            checkRow("Codex 接入", complete: model.snapshot.wired)
            if !model.snapshot.codex {
                Text("请先安装并打开 Codex，再回来继续配置。")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                Link("获取 Codex", destination: URL(string: "https://chatgpt.com/download/")!)
            }
            if model.snapshot.installed {
                action("配置后台与会话") { await model.configure() }
            } else {
                action("安装并配置") { await model.install() }
            }
            Text("安装 App 内置的兼容后台，并为已安装的代理配置接入。")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }
    private var join: some View {
        VStack(alignment: .leading, spacing: 16) {
            TextField("邀请链接或四词代码", text: $model.invitation, axis: .vertical)
                .lineLimit(1...3).textFieldStyle(.plain).font(.system(size: 13))
                .padding(12).background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
                .accessibilityLabel("Network 邀请链接或一次性代码")
            HStack {
                Text("你的名称").foregroundStyle(.secondary)
                TextField("名称", text: $model.name).textFieldStyle(.plain)
            }.font(.system(size: 13)).padding(.horizontal, 2)
            action("加入 Network") { await model.join() }
                .disabled(model.invitation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.snapshot.issue != nil)
        }.disabled(model.busy)
    }
    private var connected: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label(model.snapshot.team ?? "Network 已连接", systemImage: "checkmark.circle")
                .font(.system(size: 15, weight: .medium))
            Text(model.snapshot.sessions > 0 ? "本机会话已在线。" : "重启 Codex，在目标对话中发送一条消息后，会话即可出现。")
                .font(.system(size: 13)).foregroundStyle(.secondary)
            if model.snapshot.sessions == 0 {
                Button("打开 Codex", systemImage: "arrow.up.forward.app") {
                    if let url = ["com.openai.codex", "com.openai.chat"].compactMap({
                        NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0)
                    }).first {
                        NSWorkspace.shared.openApplication(at: url, configuration: .init())
                    }
                }.buttonStyle(.plain)
            }
            if model.snapshot.needsBackendUpdate {
                action("更新兼容后台") { await model.configure() }
            }
            Button("进入聊天", action: completion)
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
                .accessibilityLabel(complete ? "已配置" : "待配置")
        }
    }
    private func action(_ title: String, operation: @escaping () async -> Void) -> some View {
        Button(title) { Task { await operation() } }
            .buttonStyle(SetupActionStyle())
            .disabled(model.busy)
    }
}

private struct SetupActionStyle: ButtonStyle {
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
