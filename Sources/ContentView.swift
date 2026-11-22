import SwiftUI
import AppKit

struct ContentView: View {
    @EnvironmentObject private var model: NetworkModel
    @State private var showStatus = false
    @State private var nearBottom = true
    @FocusState private var composing: Bool
    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Color.black.opacity(0.03))
            history
            composer
        }
        .background(Color.white)
        .foregroundStyle(Color.black.opacity(0.88))
        .preferredColorScheme(.light)
        .frame(minWidth: 520, minHeight: 520)
        .task { await model.start() }
    }
    private var header: some View {
        HStack(spacing: 24) {
            VStack(alignment: .leading, spacing: 5) {
            Menu {
                if model.peers.isEmpty { Text("暂无队友会话") }
                ForEach(model.peers) { session in
                    Button {
                        model.selectedPeer = session.address
                    } label: {
                        Label {
                            Text(session.title + "\n" + session.address + (session.offline ? " · 离线" : ""))
                        } icon: { Image(systemName: model.selectedPeer == session.address ? "checkmark" : "person") }
                    }
                }
                Divider()
                Button("刷新会话", systemImage: "arrow.clockwise") { Task { await model.refresh() } }
            } label: {
                Text(model.peer?.title ?? "选择会话")
                    .font(.system(size: 20, weight: .semibold))
                    .lineLimit(1)
            }
            .menuStyle(.borderlessButton)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityLabel("选择队友会话")
            Text(model.peer?.address ?? "Reason Network")
                .font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Spacer(minLength: 0)
            Button { showStatus.toggle() } label: {
                HStack(spacing: 7) {
                    Circle().fill(model.online ? Color.black.opacity(0.85) : Color.gray).frame(width: 6, height: 6)
                    Text(model.online ? "在线" : model.directory == nil && model.error == nil ? "连接中" : "离线")
                        .font(.system(size: 12, weight: .medium))
                }
                .padding(.horizontal, 13).padding(.vertical, 7)
                .background(Capsule().stroke(Color.black.opacity(0.1), lineWidth: 1))
                .contentShape(Capsule())
            }
            .buttonStyle(.plain).help("设备状态与本机会话")
            .popover(isPresented: $showStatus, arrowEdge: .bottom) { StatusView().environmentObject(model) }
        }
        .padding(.horizontal, 30).padding(.top, 14).padding(.bottom, 23)
    }
    private var history: some View {
        GeometryReader { viewport in
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 22) {
                        if model.messages.isEmpty {
                            Text(model.selectedPeer.isEmpty ? "选择一个会话" : "还没有消息")
                                .font(.system(size: 14)).foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity).padding(.top, 70)
                        }
                        ForEach(model.messages) { message in
                            MessageRow(message: message, sender: model.peer?.person ?? "", maximumWidth: min(720, (viewport.size.width - 60) * 0.82))
                                .id(message.id)
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .padding(.horizontal, 30).padding(.vertical, 24)
                }
                .modifier(ScrollPinObserver(nearBottom: $nearBottom))
                .onAppear { proxy.scrollTo("bottom", anchor: .bottom) }
                .onChange(of: model.conversationKey) { _, _ in nearBottom = true; proxy.scrollTo("bottom", anchor: .bottom) }
                .onChange(of: model.messages.last?.id) { _, _ in
                    if nearBottom || model.messages.last?.outgoing == true { proxy.scrollTo("bottom", anchor: .bottom) }
                }
            }
        }
        .overlay(alignment: .top) {
            if let error = model.error {
                HStack(spacing: 10) {
                    Image(systemName: "exclamationmark.circle")
                    Text(error).textSelection(.enabled).lineLimit(3)
                    Spacer()
                    Button("重试") { Task { await model.refresh() } }
                }
                .font(.system(size: 12)).padding(12)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                .padding(.horizontal, 24).padding(.top, 10)
            }
        }
    }
    private var composer: some View {
        VStack(spacing: 0) {
            VStack(spacing: 6) {
                ZStack(alignment: .topLeading) {
                    if model.draft.isEmpty {
                        Text("输入消息…").foregroundStyle(Color.black.opacity(0.3)).padding(.top, 8).padding(.leading, 5).allowsHitTesting(false)
                    }
                    TextEditor(text: Binding(get: { model.draft }, set: { model.draft = $0 }))
                        .scrollContentBackground(.hidden)
                        .font(.system(size: 14)).lineSpacing(4)
                        .focused($composing)
                        .accessibilityLabel("消息内容")
                        .frame(height: 65)
                }
                HStack(spacing: 12) {
                    Text(model.notice)
                        .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
                        .accessibilityAddTraits(.updatesFrequently)
                    Spacer(minLength: 0)
                    Button { Task { await model.send() } } label: {
                        ZStack {
                            Circle().fill(Color.black.opacity(model.canSend ? 0.88 : 0.07))
                            if model.sending {
                                ProgressView().controlSize(.small)
                            } else {
                                Image(systemName: "arrow.up").font(.system(size: 17, weight: .medium)).foregroundStyle(model.canSend ? Color.white : Color.black.opacity(0.22))
                            }
                        }
                        .frame(width: 32, height: 32)
                    }
                    .buttonStyle(.plain).disabled(!model.canSend)
                    .keyboardShortcut(.return, modifiers: .command)
                    .help("发送消息（⌘ Return）").accessibilityLabel(model.sending ? "发送中" : "发送消息")
                }
            }
            .padding(14)
            .background(Color(white: 0.966), in: RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(composing ? Color.black.opacity(0.16) : .clear, lineWidth: 1))
        }
        .padding(.horizontal, 24).padding(.top, 8).padding(.bottom, 22)
    }
}
private struct ScrollPinObserver: ViewModifier {
    @Binding var nearBottom: Bool
    @ViewBuilder func body(content: Content) -> some View {
        if #available(macOS 15, *) {
            content.onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.contentSize.height - geometry.contentOffset.y - geometry.containerSize.height < 100
            } action: { _, value in nearBottom = value }
        } else { content }
    }
}

// AppKit's native selectable text avoids SwiftUI SelectionOverlay relayout loops with long chats.
private struct MessageText: NSViewRepresentable {
    let body: String
    let maximumWidth: CGFloat
    private var attributed: NSAttributedString {
        let paragraph = NSMutableParagraphStyle(); paragraph.lineSpacing = 6
        return NSAttributedString(string: body, attributes: [.font: NSFont.systemFont(ofSize: 14), .foregroundColor: NSColor(calibratedWhite: 0.12, alpha: 1), .paragraphStyle: paragraph])
    }
    func makeNSView(context: Context) -> NSTextView {
        let view = NSTextView()
        view.isEditable = false; view.isSelectable = true; view.drawsBackground = false
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.isHorizontallyResizable = false; view.isVerticallyResizable = true
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return view
    }
    func updateNSView(_ view: NSTextView, context: Context) {
        if view.string != body { view.textStorage?.setAttributedString(attributed) }
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSTextView, context: Context) -> CGSize? {
        let text = attributed
        let width = max(20, min(maximumWidth, proposal.width ?? maximumWidth, ceil(text.size().width)))
        let rect = text.boundingRect(with: NSSize(width: width, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin, .usesFontLeading])
        nsView.textContainer?.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        return CGSize(width: width, height: ceil(rect.height) + 2)
    }
}
private struct MessageRow: View {
    let message: Message
    let sender: String
    let maximumWidth: CGFloat
    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            if message.outgoing { Spacer(minLength: 24) }
            VStack(alignment: message.outgoing ? .trailing : .leading, spacing: 6) {
                Text((message.outgoing ? "我" : sender) + " · " + Date(timeIntervalSince1970: message.at).formatted(date: .omitted, time: .shortened))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                MessageText(body: message.body, maximumWidth: maximumWidth - 32)
                    .padding(.horizontal, 16).padding(.vertical, 12)
                    .background(Color(white: message.outgoing ? 0.96 : 0.98), in: RoundedRectangle(cornerRadius: 13))
                    .frame(maxWidth: maximumWidth, alignment: message.outgoing ? .trailing : .leading)
                if !message.delivery.isEmpty {
                    Text(message.delivery).font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }
            if !message.outgoing { Spacer(minLength: 24) }
        }
    }
}

struct StatusView: View {
    @EnvironmentObject private var model: NetworkModel
    @State private var diagnostics = false
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(spacing: 14) {
                    Text("本机会话").font(.system(size: 12))
                    VStack(alignment: .leading, spacing: 4) {
                        Menu {
                            ForEach(model.locals) { session in
                                Button { model.selectedLocal = session.name } label: {
                                    Label(session.title + "\n" + session.name, systemImage: model.selectedLocal == session.name ? "checkmark" : "terminal")
                                }
                            }
                            if model.locals.isEmpty { Text("暂无已连接的本机会话") }
                        } label: {
                            Text(model.own?.title ?? model.selectedLocal).font(.system(size: 13, weight: .semibold))
                        }
                        .menuStyle(.borderlessButton).accessibilityLabel("选择本机会话")
                        Text((model.directory?.person ?? "") + "/" + model.selectedLocal).font(.system(size: 11, design: .monospaced)).lineLimit(2)
                    }
                }
                .foregroundStyle(.black).padding(13)
                .background(Color(white: 0.95), in: RoundedRectangle(cornerRadius: 10))
                if let tier = model.tier {
                    Label(tier == "push" ? "即时推送" : tier == "turn" ? "回合接收" : "手动接收", systemImage: tier == "push" ? "bolt.horizontal" : "arrow.down.circle")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                ForEach(model.directory?.machines ?? []) { device in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Text(device.person + (device.isMe ? " · 本机" : "")).font(.system(size: 12, weight: .medium))
                            Spacer()
                            Circle().strokeBorder(.black, lineWidth: 1).background(Circle().fill(device.online || device.isMe ? Color.black : .clear)).frame(width: 5, height: 5)
                            Text(device.state).font(.system(size: 11)).monospacedDigit()
                        }
                        Text(device.machine).font(.system(size: 11, design: .monospaced)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    }
                    .foregroundStyle(.black)
                    if device.id != model.directory?.machines.last?.id { Divider().overlay(.black.opacity(0.03)) }
                }
                DisclosureGroup("诊断", isExpanded: $diagnostics) {
                    VStack(alignment: .leading, spacing: 12) {
                        if model.diagnosing { ProgressView().controlSize(.small) }
                        Text(model.doctor.nonEmpty ?? "尚未获取诊断").font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                        if let warning = model.mirrorWarning { Text(warning).font(.system(size: 11)).foregroundStyle(.secondary) }
                        Button("重新检查", systemImage: "arrow.clockwise") { Task { await model.diagnose() } }.disabled(model.diagnosing)
                    }.padding(.top, 10)
                }
                .font(.system(size: 12)).foregroundStyle(.secondary)
                .onChange(of: diagnostics) { _, expanded in if expanded { Task { await model.diagnose() } } }
            }
            .padding(22)
        }
        .frame(width: 390, height: diagnostics ? 540 : min(480, 210 + CGFloat(model.directory?.machines.count ?? 0) * 65))
        .background(Color.white).preferredColorScheme(.light)
    }
}
