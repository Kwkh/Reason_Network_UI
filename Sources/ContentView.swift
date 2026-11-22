import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject private var model: NetworkModel
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage("darkAppearance") private var darkAppearance = false
    @State private var showStatus = false
    @State private var showConversations = false
    @State private var choosingFiles = false
    @State private var restoreScrollTo: String?
    @State private var nearBottom = true
    @FocusState private var composing: Bool
    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            history
            composer
        }
        .background(colorScheme == .dark ? Color.black : Color.white)
        .foregroundStyle(.primary)
        .tint(.primary)
        .preferredColorScheme(darkAppearance ? .dark : .light)
        .frame(minWidth: 520, minHeight: 520)
        .task { await model.start() }
        .sheet(isPresented: $model.showsUtilities, onDismiss: { Task { await model.refresh() } }) {
            NetworkUtilitiesView()
        }
        .fileImporter(isPresented: $choosingFiles, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls): model.addAttachments(urls)
            case .failure(let error): model.notice = error.localizedDescription
            }
        }
    }
    private var header: some View {
        HStack(spacing: 24) {
            Button {
                showConversations.toggle()
            } label: {
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 6) {
                        Text(model.peer?.title ?? "选择会话")
                            .font(.system(size: 20, weight: .semibold)).lineLimit(1)
                        Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
                    }
                    Text(model.peer?.id ?? "Reason Network")
                        .font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut("k")
            .accessibilityLabel("搜索或切换会话")
            .popover(isPresented: $showConversations, arrowEdge: .bottom) {
                ConversationPicker(isPresented: $showConversations)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Spacer(minLength: 0)
            Button { showStatus.toggle() } label: {
                HStack(spacing: 7) {
                    Circle().fill(model.online ? Color.primary : Color.gray).frame(width: 6, height: 6)
                    Text(model.online ? "在线" : model.directory == nil && model.error == nil ? "连接中" : "离线")
                        .font(.system(size: 12, weight: .medium))
                    if model.consoleUnread > 0 {
                        Text("\(model.consoleUnread)").font(.system(size: 11, weight: .semibold)).monospacedDigit()
                            .accessibilityLabel("控制台未读消息 \(model.consoleUnread) 条")
                    }
                }
                .padding(.horizontal, 13).padding(.vertical, 7)
                .background(Capsule().stroke(Color.primary.opacity(0.16), lineWidth: 1))
                .contentShape(Capsule())
            }
            .buttonStyle(.plain).help("设备状态与本机会话")
            .popover(isPresented: $showStatus, arrowEdge: .bottom) { StatusView(isPresented: $showStatus) }
        }
        .padding(.horizontal, 30).padding(.top, 14).padding(.bottom, 23)
    }
    private var history: some View {
        GeometryReader { viewport in
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 22) {
                        if model.hasEarlierMessages {
                            Button("加载更早的消息", systemImage: "arrow.up") {
                                restoreScrollTo = model.messages.first?.id
                                Task { await model.loadEarlierMessages() }
                            }
                            .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(.secondary)
                            .padding(.vertical, 4)
                        }
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
                .onChange(of: model.conversationKey) { _, _ in
                    restoreScrollTo = nil
                    nearBottom = true
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
                .onChange(of: model.messages.first?.id) { _, _ in
                    if let restoreScrollTo {
                        proxy.scrollTo(restoreScrollTo, anchor: .top)
                        self.restoreScrollTo = nil
                    }
                }
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
                    if model.draft.text.isEmpty {
                        Text("输入消息…").foregroundStyle(.secondary).padding(.top, 8).padding(.leading, 5).allowsHitTesting(false)
                    }
                    TextEditor(text: $model.draft.text)
                        .scrollContentBackground(.hidden)
                        .font(.system(size: 14)).lineSpacing(4)
                        .focused($composing)
                        .accessibilityLabel("消息内容")
                        .frame(height: 65)
                }
                if !model.draft.files.isEmpty {
                    ScrollView(.horizontal) {
                        HStack(spacing: 6) {
                            ForEach(model.draft.files, id: \.self) { file in
                                HStack(spacing: 5) {
                                    Text(file.lastPathComponent).lineLimit(1).frame(maxWidth: 160)
                                    Button {
                                        model.draft.files.removeAll { $0 == file }
                                    } label: {
                                        Image(systemName: "xmark")
                                    }
                                    .accessibilityLabel("移除附件 \(file.lastPathComponent)")
                                }
                                .font(.system(size: 11))
                                .padding(.horizontal, 8).padding(.vertical, 5)
                                .background(Color.primary.opacity(0.07), in: Capsule())
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                HStack(spacing: 12) {
                    Button { choosingFiles = true } label: {
                        Image(systemName: "paperclip").frame(width: 24, height: 26)
                    }
                    .buttonStyle(.plain)
                    .disabled(model.peer == nil || model.sending)
                    .accessibilityLabel("添加文本附件")
                    .help("添加文本附件，单个最多 256 KB")
                    Menu {
                        Toggle("唤醒队友会话", isOn: $model.draft.wake)
                        Toggle("在队友电脑上弹窗提醒", isOn: $model.draft.notify)
                    } label: {
                        Image(systemName: model.draft.notify ? "bell" : "ellipsis.circle")
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .accessibilityLabel("发送选项")
                    .disabled(model.peer == nil || model.sending)
                    Text(model.notice)
                        .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
                        .accessibilityAddTraits(.updatesFrequently)
                    Spacer(minLength: 0)
                    if let own = model.own {
                        Text(own.title)
                            .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                            .help("发送身份：\(own.name)")
                            .accessibilityLabel("发送身份：\(own.title)")
                    }
                    Button { Task { await model.send() } } label: {
                        ZStack {
                            Circle().fill(Color.primary.opacity(model.canSend ? 0.9 : 0.08))
                            if model.sending {
                                ProgressView().controlSize(.small)
                            } else {
                                Image(systemName: "arrow.up")
                                    .font(.system(size: 17, weight: .medium))
                                    .foregroundStyle(model.canSend ? (colorScheme == .dark ? Color.black : Color.white) : Color.primary.opacity(0.3))
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
            .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(composing ? Color.primary.opacity(0.16) : .clear, lineWidth: 1))
        }
        .padding(.horizontal, 24).padding(.top, 8).padding(.bottom, 22)
    }
}

private struct ConversationPicker: View {
    @EnvironmentObject private var model: NetworkModel
    @Environment(\.colorScheme) private var colorScheme
    @Binding var isPresented: Bool
    @State private var query = ""
    @FocusState private var searchFocused: Bool

    private var results: [NetworkSession] {
        model.peers.filter { $0.matches(query) }
    }

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 9) {
                Image(systemName: "magnifyingglass")
                TextField("搜索会话、工具或项目", text: $query)
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
                    .onSubmit { if let first = results.first { select(first) } }
                Button { Task { await model.refresh() } } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.plain).accessibilityLabel("刷新会话列表")
            }
            .padding(10).background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
            if results.isEmpty {
                Text(query.isEmpty ? "暂无可选会话" : "没有找到匹配的会话")
                    .font(.system(size: 12)).foregroundStyle(.secondary).padding(16)
            } else {
                ScrollView {
                    VStack(spacing: 1) {
                        ForEach(SessionGroup.group(results)) { group in
                            Text(group.name).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 8).padding(.vertical, 5)
                            ForEach(group.sessions) { session in
                                pickerRow(session)
                            }
                        }
                    }
                }
                .frame(height: min(340, CGFloat(results.count) * 63 + CGFloat(SessionGroup.group(results).count) * 22))
            }
            Divider()
            Button("打开会话目录", systemImage: "sidebar.left") {
                isPresented = false
                model.open(.sessions)
            }
            .buttonStyle(.plain).frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 5)
        }
        .padding(12).frame(width: 350)
        .background(colorScheme == .dark ? Color.black : Color.white)
        .onAppear { searchFocused = true }
    }

    private func pickerRow(_ session: NetworkSession) -> some View {
        let summary = model.summary(for: session)
        return Button { select(session) } label: {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(session.title).lineLimit(1)
                    Text(session.id).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1)
                    if let summary {
                        Text(summary.preview).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                if let summary, summary.unread > 0 {
                    Text("\(summary.unread)").font(.system(size: 11, weight: .semibold)).monospacedDigit()
                        .accessibilityLabel("未读 \(summary.unread) 条")
                }
                if session.offline || session.tier == "none" {
                    Text(session.statusText).foregroundStyle(.secondary).font(.system(size: 11))
                }
                if session.id == model.selectedPeer { Image(systemName: "checkmark") }
            }
            .padding(8)
            .background(session.id == model.selectedPeer ? Color.primary.opacity(0.07) : .clear, in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }.buttonStyle(.plain)
    }

    private func select(_ session: NetworkSession) {
        model.selectedPeer = session.id
        isPresented = false
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
        return NSAttributedString(string: body, attributes: [.font: NSFont.systemFont(ofSize: 14), .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph])
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
    @EnvironmentObject private var model: NetworkModel
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
                    .background(Color.primary.opacity(message.outgoing ? 0.09 : 0.045), in: RoundedRectangle(cornerRadius: 13))
                    .frame(maxWidth: maximumWidth, alignment: message.outgoing ? .trailing : .leading)
                ForEach(Array(message.attachments.enumerated()), id: \.offset) { _, attachment in
                    if let url = model.attachmentURL(for: attachment) {
                        Button {
                            NSWorkspace.shared.activateFileViewerSelecting([url])
                        } label: {
                            Label(attachment.name, systemImage: "paperclip")
                        }
                        .buttonStyle(.plain).help("在 Finder 中显示")
                    } else {
                        Label(attachment.name, systemImage: "paperclip").foregroundStyle(.secondary)
                    }
                }
                .font(.system(size: 11))
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
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage("darkAppearance") private var darkAppearance = false
    @Binding var isPresented: Bool
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
                        if let person = model.directory?.person, !model.selectedLocal.isEmpty {
                            Text(person + "/" + model.selectedLocal).font(.system(size: 11, design: .monospaced)).lineLimit(2)
                        }
                    }
                }
                .foregroundStyle(.primary).padding(13)
                .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 10))
                if let tier = model.tier {
                    let labels = ["push": "即时推送", "turn": "下次操作时接收", "pull": "手动接收", "console": "使用独立收件箱"]
                    Label(labels[tier] ?? "接收状态未知", systemImage: tier == "push" ? "bolt.horizontal" : "arrow.down.circle")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                if let team = model.directory?.team {
                    Text(team).font(.system(size: 12, weight: .semibold))
                }
                ForEach(model.directory?.machines ?? []) { device in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Text(device.person + (device.isMe ? " · 本机" : "")).font(.system(size: 12, weight: .medium))
                            Spacer()
                            Circle().strokeBorder(Color.primary, lineWidth: 1).background(Circle().fill(device.online || device.isMe ? Color.primary : .clear)).frame(width: 5, height: 5)
                            Text(device.state).font(.system(size: 11)).monospacedDigit()
                        }
                        Text(device.machine).font(.system(size: 11, design: .monospaced)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    }
                    .foregroundStyle(.primary)
                    if device.id != model.directory?.machines.last?.id { Divider() }
                }
                Divider()
                HStack {
                    Button("概览") { open(.overview) }
                    Button("会话目录") { open(.sessions) }
                    Button("设置") { open(.settings) }
                }.font(.system(size: 12))
                NetworkServiceActions()
                Toggle("深色外观", isOn: $darkAppearance)
                    .toggleStyle(.switch).controlSize(.small).font(.system(size: 12))
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
        .frame(width: 390, height: diagnostics ? 570 : min(495, 280 + CGFloat(model.directory?.machines.count ?? 0) * 65))
        .background(colorScheme == .dark ? Color.black : Color.white)
    }

    private func open(_ page: NetworkModel.UtilityPage) {
        isPresented = false
        model.open(page)
    }
}

struct NetworkServiceActions: View {
    @EnvironmentObject private var model: NetworkModel
    @State private var confirmRestart = false
    @State private var confirmRepair = false
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 13) {
                Button("复制邀请链接", systemImage: "person.badge.plus") {
                    Task { await model.manage(.invite) }
                }
                .disabled(model.managing)
                Menu("服务管理", systemImage: "gearshape") {
                    Button("重启后台服务") { confirmRestart = true }
                    Button("修复本机接入") { confirmRepair = true }
                    Divider()
                    Button("在 Finder 中查看数据目录") { NSWorkspace.shared.open(model.stateFolder) }
                    .disabled(!FileManager.default.fileExists(atPath: model.stateFolder.path))
                }
                .disabled(model.managing)
                if model.managing { ProgressView().controlSize(.small) }
            }
            if !model.managementNotice.isEmpty {
                Text(model.managementNotice).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }
        .font(.system(size: 12))
        .alert("重启后台服务？", isPresented: $confirmRestart) {
            Button("取消", role: .cancel) { }
            Button("重启") { Task { await model.manage(.restart) } }
        } message: {
            Text("连接会短暂中断，服务恢复后会自动刷新。")
        }
        .alert("重新配置本机接入？", isPresented: $confirmRepair) {
            Button("取消", role: .cancel) { }
            Button("修复") { Task { await model.manage(.repair) } }
        } message: {
            Text("会重新写入本机支持的工具接入配置，并重新配置后台服务。")
        }
    }
}
