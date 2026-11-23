import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject private var model: NetworkModel
    @State private var showStatus = false
    @State private var composerHeight: CGFloat = 70
    @State private var editorHeight: CGFloat = 46
    @State private var senderHintHeight: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @State private var composing = false
    @State private var pickingFiles = false
    @State private var pickerConversation = ""
    @State private var preview: AttachmentPreview?
    private struct AttachmentPreview: Identifiable {
        let id = UUID()
        let name: String
        let text: String
    }


    private var conversationFade: Animation? {
        reduceMotion ? nil : .easeInOut(duration: 0.20)
    }

    private let maximumSidebarWidth: CGFloat = 320
    private let minimumDetailWidth: CGFloat = 335

    var body: some View {
        GeometryReader { window in
            let narrowestDetail = max(minimumDetailWidth, window.size.width - maximumSidebarWidth - 1)
            let sidebarLimit = min(maximumSidebarWidth, window.size.width - minimumDetailWidth - 1)
            splitView(narrowestDetail: narrowestDetail, sidebarLimit: max(185, sidebarLimit))
        }
        .frame(minWidth: 540, minHeight: 520)
        .disabled(model.leavingNetwork)
        .overlay {
            if model.leavingNetwork {
                ProgressView("正在退出 Network…").padding(18)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            }
        }
        .task { await model.start() }
        .alert("接收模式未切换或未确认", isPresented: Binding(get: { model.receiveModeError != nil },
                                                  set: { if !$0 { model.receiveModeError = nil } })) {
            Button("好", role: .cancel) {}
        } message: { Text(model.receiveModeError ?? "") }
        .fileImporter(isPresented: $pickingFiles, allowedContentTypes: [.data], allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls): model.attach(urls, to: pickerConversation)
            case .failure(let error):
                if (error as NSError).code != NSUserCancelledError { model.notice = error.localizedDescription }
            }
        }
        .sheet(item: $preview) { item in
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(item.name).font(.headline).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button("完成") { preview = nil }.keyboardShortcut(.cancelAction)
                }
                ScrollView {
                    Text(verbatim: item.text).font(.system(.body, design: .monospaced))
                        .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                }
            }.padding(20).frame(minWidth: 440, minHeight: 300)
        }
    }

    private func splitView(narrowestDetail: CGFloat, sidebarLimit: CGFloat) -> some View {
        NavigationSplitView {
            ConversationSidebar()
                .background(SidebarSizing())
                .navigationSplitViewColumnWidth(min: 185, ideal: min(220, sidebarLimit), max: sidebarLimit)
                .navigationTitle("会话")
        } detail: {
            ZStack(alignment: .bottom) {
                history.clipped()
                composer
                    .onGeometryChange(for: CGFloat.self) { ceil($0.size.height) } action: { composerHeight = $0 }
            }
            .background(Color(nsColor: .textBackgroundColor).ignoresSafeArea(.container, edges: .top))
            .foregroundStyle(.primary)
            .frame(minWidth: minimumDetailWidth)
            .toolbar {
                let titleItem = ToolbarItem(placement: .principal) {
                    conversationTitle(maxWidth: min(360, narrowestDetail - 180))
                }
                if #available(macOS 26, *) {
                    titleItem.sharedBackgroundVisibility(.hidden)
                } else {
                    titleItem
                }
                let statusItem = ToolbarItem(placement: .primaryAction) { statusButton }
                if #available(macOS 26, *) {
                    statusItem.sharedBackgroundVisibility(.hidden)
                } else { statusItem }
            }
            // A window-wide toolbar fill covers the top of the native floating sidebar.
            .toolbarBackground(.hidden, for: .windowToolbar)
        }
        .navigationSplitViewStyle(.balanced)
    }

    private func conversationTitle(maxWidth: CGFloat) -> some View {
        let peer = model.peer
        let title = peer?.title ?? "选择会话"
        let address = peer?.address ?? "Reason Network"
        let singleLineTitle = title.components(separatedBy: .newlines)
            .filter { !$0.isEmpty }.joined(separator: " ")

        return VStack(spacing: 1) {
            Text(singleLineTitle)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color(nsColor: .labelColor))
                .truncationMode(.tail)
            HStack(spacing: 5) {
                Text(address)
                    .font(.system(size: 10, design: .monospaced))
                    .truncationMode(.middle)
                if let peer {
                    let status = model.online ? peer.statusText : "状态未知"
                    Text(status)
                        .font(.system(size: 10))
                        .layoutPriority(1)
                        .contentTransition(reduceMotion ? .identity : .numericText())
                        .animation(conversationFade, value: status)
                }
            }
            .foregroundStyle(Color(nsColor: .secondaryLabelColor))
        }
        .lineLimit(1)
        .frame(maxWidth: maxWidth)
        .fixedSize(horizontal: true, vertical: true)
        .accessibilityElement(children: .combine)
        .help(peer?.titleHelp ?? address)
        .contentTransition(.opacity)
        .animation(conversationFade, value: model.selectedPeer)
    }

    private var statusButton: some View {
        let indicator = model.senderPresence
        return Button { showStatus.toggle() } label: {
            HStack(spacing: 7) {
                Image(systemName: indicator.symbol)
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(indicator.color)
                    .frame(width: 8)
                    .contentTransition(.opacity)
                Text(indicator.shortLabel)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .contentTransition(reduceMotion ? .identity : .numericText())
            }
            .padding(.horizontal, 6).padding(.vertical, 7)
            .frame(minWidth: 64)
            .background(Capsule().stroke(Color.primary.opacity(0.16), lineWidth: 1))
            .contentShape(Capsule())
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.16), value: indicator)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("本机会话状态")
        .accessibilityValue(indicator.rawValue)
        .help("当前本机会话 · " + indicator.rawValue + "。点击查看设备状态。")
        .popover(isPresented: $showStatus, arrowEdge: .bottom) { StatusView().environmentObject(model) }
    }
    private var history: some View {
        ZStack {
            ConversationHistory(messages: model.messages, sender: model.peer?.person ?? "",
                                waiting: model.waitingForHistory && model.error == nil,
                                hasPeer: !model.selectedPeer.isEmpty, failed: model.error != nil,
                                sentCount: model.sentCount, overlayInset: composerHeight, hasEarlier: model.hasEarlier,
                                earlier: model.loadEarlier, openAttachment: { file in
                                    Task {
                                        let text: String
                                        do { text = try await model.readAttachment(file) }
                                        catch { text = error.localizedDescription }
                                        preview = AttachmentPreview(name: file.name, text: text)
                                    }
                                })
                .id(model.conversationKey)
                .transition(.opacity)
        }
        .animation(conversationFade, value: model.conversationKey)
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
        let showsSenderHint = model.senderOffline || model.reconnectingSender
        return VStack(alignment: .leading, spacing: 4) {
            if !model.notice.isEmpty {
                Text(model.notice)
                    .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
                    .accessibilityAddTraits(.updatesFrequently)
            }
            if !model.options.files.isEmpty {
                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        ForEach(model.options.files, id: \.self) { file in
                            Button { model.options.files.removeAll { $0 == file } } label: {
                                HStack(spacing: 5) {
                                    Image(systemName: "paperclip")
                                    Text(verbatim: file.lastPathComponent).lineLimit(1)
                                    Image(systemName: "xmark").imageScale(.small)
                                }
                            }.buttonStyle(.bordered).controlSize(.small).help("移除 " + file.lastPathComponent)
                        }
                    }
                }.scrollIndicators(.hidden)
            }
            VStack(alignment: .leading, spacing: 0) {
                Button { showStatus = true } label: {
                    Label(model.reconnectingSender ? "正在重新接入本机会话…" : "本机会话离线 · 查看接入选项",
                          systemImage: "network.slash")
                        .contentTransition(reduceMotion ? .identity : .numericText())
                        .animation(reduceMotion ? nil : .easeInOut(duration: 0.16), value: model.reconnectingSender)
                }
                .buttonStyle(.plain).font(.caption).foregroundStyle(.secondary)
                .padding(.horizontal, 18).padding(.top, 10)
                .fixedSize(horizontal: false, vertical: true)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { senderHintHeight = $0 }
                .modifier(SenderHintViewport(height: showsSenderHint ? senderHintHeight : 0))
                .opacity(showsSenderHint ? 1 : 0)
                .animation(reduceMotion ? nil : .smooth(duration: 0.24), value: showsSenderHint)
                .disabled(!showsSenderHint)
                .allowsHitTesting(showsSenderHint)
                .accessibilityHidden(!showsSenderHint)
                ZStack(alignment: .bottomTrailing) {
                    DraftField(text: Binding(get: { model.draft }, set: { model.draft = $0 }),
                               focused: $composing,
                               heightChanged: { editorHeight = $0 }, onSend: { Task { await model.send() } })
                        .id(model.conversationKey)
                        .padding(.leading, 32)
                        .frame(height: editorHeight)
                        .frame(maxWidth: .infinity)
                    HStack {
                        Menu {
                            Button("添加文本附件…", systemImage: "paperclip") {
                                pickerConversation = model.conversationKey
                                pickingFiles = true
                            }
                            Toggle("在对方电脑上弹窗提醒", isOn: $model.options.notify)
                        } label: {
                            Image(systemName: model.options.notify ? "bell.fill" : "plus")
                                .font(.system(size: 14, weight: .medium))
                                .foregroundStyle(colorScheme == .dark ? Color(white: 0.92) : Color(white: 0.22))
                                .frame(width: 28, height: 28)
                                .contentShape(Rectangle())
                        }
                        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
                        .disabled(model.selectedLocal.isEmpty || model.selectedPeer.isEmpty)
                        .accessibilityLabel("附件与发送选项").help("附件与发送选项")
                        Spacer()
                        Button { Task { await model.send() } } label: {
                            ZStack {
                                Circle().fill(Color.primary.opacity(model.canSend ? 0.92 : 0.08))
                                if model.sending {
                                    ProgressView().controlSize(.small)
                                } else {
                                    Image(systemName: "arrow.up")
                                        .font(.system(size: 15, weight: .medium))
                                        .foregroundStyle(model.canSend ? Color(nsColor: .textBackgroundColor) : .secondary)
                                }
                            }
                            .frame(width: 28, height: 28)
                        }
                        .buttonStyle(.plain).disabled(!model.canSend)
                        .keyboardShortcut(.return, modifiers: .command)
                        .help("发送消息（Enter），换行（Shift＋Enter）").accessibilityLabel(model.sending ? "发送中" : "发送消息")
                    }
                    .padding(.horizontal, 12).padding(.bottom, 9)
                }
            }
            .modifier(ComposerGlass(focused: composing))
            .animation(reduceMotion ? nil : .smooth(duration: 0.24), value: editorHeight)
        }
        .padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 16)
    }
}

// Interpolate the height reported to the glass shell, keeping the native editor anchored below.
private struct SenderHintViewport: AnimatableModifier {
    var height: CGFloat
    var animatableData: CGFloat {
        get { height }
        set { height = newValue }
    }

    func body(content: Content) -> some View {
        content.frame(height: height, alignment: .bottomLeading).clipped()
    }
}

private struct ComposerGlass: ViewModifier {
    let focused: Bool
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @ViewBuilder func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: 22)
        if reduceTransparency {
            content.background(Color(nsColor: .controlBackgroundColor), in: shape)
        } else if #available(macOS 26, *) {
            content.glassEffect(.regular, in: shape)
                .compositingGroup()
                .shadow(color: .black.opacity(0.08), radius: 10, x: 0, y: 3)
        } else {
            content.background(.regularMaterial, in: shape)
                .overlay(shape.strokeBorder(Color.primary.opacity(focused ? 0.18 : 0.10), lineWidth: 0.5))
                .compositingGroup()
                .shadow(color: .black.opacity(0.08), radius: 10, x: 0, y: 3)
        }
    }
}

private func configureOverlayScroller(_ scroll: NSScrollView) {
    scroll.scrollerStyle = .overlay
    scroll.autohidesScrollers = true
    scroll.verticalScroller = NSScroller()
    scroll.verticalScroller?.controlSize = .small
    scroll.verticalScroller?.knobStyle = .default
    scroll.verticalScroller?.alphaValue = 0.55
    scroll.scrollsDynamically = true
    scroll.verticalScrollElasticity = .automatic
}

private final class DraftScrollView: NSScrollView {
    var requiredContentHeight: CGFloat = 46 {
        didSet {
            if oldValue != requiredContentHeight { needsLayout = true }
        }
    }

    override func tile() {
        super.tile()
        // Ignore temporary overflow while the input is still growing to fit its contents.
        let viewportHeight = (superview as? DraftInputHost)?.bounds.height ?? contentSize.height
        let shouldShowScroller = requiredContentHeight > 156.5 && viewportHeight >= 155.5
        if hasVerticalScroller != shouldShowScroller { hasVerticalScroller = shouldShowScroller }
        guard let editor = documentView as? DraftEditor, let container = editor.textContainer else { return }
        let width = max(1, contentSize.width - 36 - 46)
        if abs(container.containerSize.width - width) > 0.5 {
            container.containerSize = NSSize(width: width, height: CGFloat.greatestFiniteMagnitude)
        }
        let inset = NSSize(width: 18, height: 14)
        if editor.textContainerInset != inset { editor.textContainerInset = inset }
    }
}

// The scroll view uses its final layout height; only the outer viewport animates.
private final class DraftInputHost: NSView {
    let scroll = DraftScrollView()
    var heightChanged: ((CGFloat) -> Void)?
    private var preferredHeight: CGFloat?
    private let storage = NSTextStorage()
    private let measurementLayout = NSLayoutManager()
    private let measurementContainer = NSTextContainer(containerSize: .zero)
    private var measuredValue: NSAttributedString?
    private var measuredWidth: CGFloat = 0
    private var measuredHeight: CGFloat = 46
    private var updating = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
        layer?.cornerRadius = 22
        measurementContainer.lineFragmentPadding = 0
        measurementLayout.addTextContainer(measurementContainer)
        storage.addLayoutManager(measurementLayout)
        addSubview(scroll)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        guard let editor = scroll.documentView as? DraftEditor else { return }
        synchronize(editor.string)
    }

    func synchronize(_ text: String) {
        guard !updating, bounds.width > 82,
              let editor = scroll.documentView as? DraftEditor else { return }
        updating = true
        defer { updating = false }
        let value = NSAttributedString(string: text.isEmpty ? " " : text,
                                       attributes: editor.typingAttributes)
        let width = floor(bounds.width - 82)
        if measuredWidth != width || measuredValue?.isEqual(to: value) != true {
            storage.setAttributedString(value)
            measurementContainer.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
            measurementLayout.ensureLayout(for: measurementContainer)
            let textHeight = max(measurementLayout.usedRect(for: measurementContainer).maxY,
                                 measurementLayout.extraLineFragmentRect.maxY)
            measuredHeight = max(46, ceil(textHeight) + 29)
            measuredWidth = width
            measuredValue = value
        }
        scroll.requiredContentHeight = measuredHeight
        let target = min(156, scroll.requiredContentHeight)
        let frame = NSRect(x: 0, y: 0, width: bounds.width, height: target)
        if scroll.frame != frame { scroll.frame = frame }
        scroll.tile()
        if scroll.requiredContentHeight <= 156.5 {
            scroll.contentView.scroll(to: .zero)
            scroll.reflectScrolledClipView(scroll.contentView)
        }
        if preferredHeight != target {
            preferredHeight = target
            heightChanged?(target)
        }
    }
}

private final class DraftEditor: NSTextView {
    var confirmingComposition = false
    var keyModifiers: NSEvent.ModifierFlags = []
    override func keyDown(with event: NSEvent) {
        keyModifiers = event.modifierFlags
        confirmingComposition = hasMarkedText()
        defer { confirmingComposition = false }
        super.keyDown(with: event)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty else { return }
        NSAttributedString(string: "输入消息…", attributes: [
            .font: font ?? NSFont.systemFont(ofSize: 14),
            .foregroundColor: NSColor(name: nil) { appearance in
                appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                    ? .white.withAlphaComponent(0.45) : .black.withAlphaComponent(0.22)
            }
        ]).draw(at: textContainerOrigin)
    }
}

private struct DraftField: NSViewRepresentable {
    @Binding var text: String
    @Binding var focused: Bool
    let heightChanged: (CGFloat) -> Void
    let onSend: () -> Void

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: DraftField
        var requestedHeight: CGFloat?
        init(_ parent: DraftField) { self.parent = parent }

        func textDidBeginEditing(_ notification: Notification) { parent.focused = true }
        func textDidEndEditing(_ notification: Notification) { parent.focused = false }
        func textDidChange(_ notification: Notification) {
            guard let editor = notification.object as? DraftEditor else { return }
            editor.needsDisplay = true
            (editor.enclosingScrollView?.superview as? DraftInputHost)?.synchronize(editor.string)
            guard !editor.hasMarkedText() else { return }
            parent.text = editor.string
        }

        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard selector == #selector(NSResponder.insertNewline(_:)),
                  let editor = textView as? DraftEditor else { return false }
            guard !editor.hasMarkedText(), !editor.confirmingComposition else { return true }
            if editor.keyModifiers.contains(.shift) {
                editor.insertNewlineIgnoringFieldEditor(nil)
            } else {
                parent.text = editor.string
                parent.onSend()
            }
            return true
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> DraftInputHost {
        let host = DraftInputHost(frame: .zero)
        let scroll = host.scroll
        let coordinator = context.coordinator
        host.heightChanged = { [weak coordinator] target in
            guard let coordinator else { return }
            coordinator.requestedHeight = target
            DispatchQueue.main.async {
                guard coordinator.requestedHeight == target else { return }
                coordinator.parent.heightChanged(target)
            }
        }
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = false
        configureOverlayScroller(scroll)
        scroll.scrollerInsets = NSEdgeInsets(top: 22, left: 0, bottom: 22, right: 0)

        let editor = DraftEditor(frame: .zero)
        editor.isRichText = false
        editor.allowsUndo = true
        editor.drawsBackground = false
        editor.textContainerInset = NSSize(width: 18, height: 14)
        editor.textContainer?.lineFragmentPadding = 0
        editor.textContainer?.widthTracksTextView = false
        editor.isHorizontallyResizable = false
        editor.isVerticallyResizable = true
        editor.autoresizingMask = [.width]
        editor.minSize = .zero
        editor.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        editor.font = .systemFont(ofSize: 14, weight: .regular)
        editor.textColor = .labelColor
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 4
        editor.defaultParagraphStyle = paragraph
        editor.typingAttributes = [.font: editor.font!, .foregroundColor: NSColor.labelColor,
                                   .paragraphStyle: paragraph]
        editor.setAccessibilityLabel("消息内容")
        editor.delegate = context.coordinator
        scroll.documentView = editor
        scroll.contentView.postsBoundsChangedNotifications = true
        return host
    }

    func updateNSView(_ host: DraftInputHost, context: Context) {
        let scroll = host.scroll
        context.coordinator.parent = self
        guard let editor = scroll.documentView as? DraftEditor else { return }
        if editor.string != text, !editor.hasMarkedText() {
            let selection = editor.selectedRange()
            editor.string = text
            editor.setSelectedRange(NSRange(location: min(selection.location, (text as NSString).length), length: 0))
            editor.needsDisplay = true
            if text.isEmpty { scroll.contentView.scroll(to: .zero) }
        }
        host.synchronize(editor.hasMarkedText() ? editor.string : text)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView host: DraftInputHost, context: Context) -> CGSize? {
        guard let width = proposal.width else { return nil }
        return CGSize(width: width, height: proposal.height ?? 46)
    }
}

// Keep the chat window in place while AppKit animates the native sidebar.
private struct SidebarSizing: NSViewRepresentable {
    final class Marker: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            var ancestor = superview
            while let view = ancestor {
                if let split = view as? NSSplitView,
                   let controller = split.delegate as? NSSplitViewController,
                   let sidebar = controller.splitViewItems.first(where: { $0.behavior == .sidebar }) {
                    sidebar.collapseBehavior = .useConstraints
                    return
                }
                ancestor = view.superview
            }
        }
    }
    func makeNSView(context: Context) -> Marker { Marker() }
    func updateNSView(_ view: Marker, context: Context) {}
}

private struct GroupHeading: View {
    let title: String
    let icon: String
    let expanded: Bool
    let toggle: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 7) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .rotationEffect(.degrees(expanded ? 90 : 0))
                    .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: expanded)
                    .frame(width: 11)
                Image(systemName: icon).foregroundStyle(.secondary)
                Text(title).fontWeight(.medium).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 0)
            }
            .padding(.vertical, 5).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityValue(expanded ? "已展开" : "已收起")
    }
}

private extension SenderPresence {
    var color: Color {
        switch self {
        case .online: Color(nsColor: .systemGreen)
        case .offline: Color(nsColor: .systemRed)
        default: .secondary
        }
    }

    var symbol: String {
        switch self {
        case .online: "circle.fill"
        case .offline: "circle"
        case .reconnecting: "circle.lefthalf.filled"
        case .history: "clock"
        case .unknown: "minus.circle"
        }
    }

    var menuImage: Image {
        let size = NSImage.SymbolConfiguration(pointSize: 9, weight: .semibold)
        let palette = NSImage.SymbolConfiguration(paletteColors: [NSColor(color)])
        guard let symbolImage = NSImage(systemSymbolName: symbol, accessibilityDescription: rawValue)?
            .withSymbolConfiguration(size.applying(palette)) else { return Image(systemName: symbol) }
        // The native menu scales its image slot. Center the smaller glyph on a full-size canvas.
        let menuIcon = NSImage(size: NSSize(width: 16, height: 16), flipped: false) { bounds in
            let scale = 8 / max(symbolImage.size.width, symbolImage.size.height)
            let size = NSSize(width: symbolImage.size.width * scale, height: symbolImage.size.height * scale)
            let rect = NSRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2,
                              width: size.width, height: size.height)
            symbolImage.draw(in: rect)
            return true
        }
        return Image(nsImage: menuIcon).renderingMode(.original)
    }

    var shortLabel: String {
        switch self {
        case .reconnecting: "接入中"
        case .unknown: "未知"
        case .history: "历史"
        default: rawValue
        }
    }
}

private struct ConversationSidebar: View {
    @EnvironmentObject private var model: NetworkModel

    @State private var query = ""
    @EnvironmentObject private var setup: SetupModel
    private enum Page: Int, Identifiable {
        case personal, overview
        var id: Self { self }
    }
    @State private var page: Page?
    @State private var settingsOpen = false
    @State private var confirmingLeave = false
    @State private var leaveTarget: Directory?
    @State private var leaveFailure: String?

    @State private var collapsed: Set<[String]> = []
    @FocusState private var searchFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var terms: [Substring] { query.split(whereSeparator: \.isWhitespace) }

    private var senderMenu: some View {
        let indicator = model.senderPresence
        let title = model.own?.title ?? model.selectedLocal
        return HStack(spacing: 6) {
            Image(systemName: indicator.symbol)
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(indicator.color)
                .frame(width: 10, height: 12)
                .contentTransition(.opacity)
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.16), value: indicator)
                .help("本机会话 · " + indicator.rawValue)
                .accessibilityHidden(true)
            Menu {
                Picker("本机会话", selection: $model.selectedLocal) {
                    ForEach(model.locals) { session in
                        let presence = model.presence(for: session)
                        Label {
                            Text(session.title + (session.historyOnly ? " · 历史记录" : ""))
                        } icon: {
                            presence.menuImage
                        }
                        .accessibilityLabel(session.title + "，" + presence.rawValue)
                        .tag(session.name)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } label: {
                Text(title)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.visible)
            .accessibilityLabel("选择本机会话")
            .accessibilityValue(title + "，" + indicator.rawValue)
            .help(title + "\n" + model.selectedLocal + " · " + indicator.rawValue)
        }
    }

    private func expansion(_ key: [String]) -> Binding<Bool> {
        Binding(get: { !terms.isEmpty || !collapsed.contains(key) }, set: { expanded in
            guard terms.isEmpty else { return }
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) {
                if expanded { collapsed.remove(key) } else { collapsed.insert(key) }
            }
        })
    }

    private enum SidebarRow: Identifiable {
        case person(String)
        case agent(person: String, name: String)
        case session(NetworkSession)

        var id: [String] {
            switch self {
            case .person(let person): ["person", person]
            case .agent(let person, let name): ["agent", person, name]
            case .session(let session): ["session", session.person] + session.overviewID
            }
        }
    }

    private var visibleRows: [SidebarRow] {
        let tokens = terms
        let sessions = model.peers.filter { session in
            let haystack = [session.person, NetworkSession.agentDisplayName(session.agent), session.title,
                            session.address, session.repo ?? "", session.machine ?? ""].joined(separator: " ")
            return tokens.allSatisfy { haystack.localizedCaseInsensitiveContains(String($0)) }
        }
        let groups = Dictionary(grouping: sessions, by: \.person)
        var rows: [SidebarRow] = []
        for person in groups.keys.sorted() {
            rows.append(.person(person))
            guard expansion([person]).wrappedValue else { continue }
            let agents = Dictionary(grouping: groups[person] ?? []) {
                $0.offline ? "离线" : NetworkSession.agentDisplayName($0.agent)
            }
            for name in agents.keys.sorted() {
                rows.append(.agent(person: person, name: name))
                if expansion([person, name]).wrappedValue {
                    rows.append(contentsOf: (agents[name] ?? []).map(SidebarRow.session))
                }
            }
        }
        return rows
    }

    var body: some View {
        let rows = visibleRows
        VStack(alignment: .leading, spacing: 0) {
            if !model.locals.isEmpty {
                senderMenu
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            VStack(spacing: 6) {
                HStack(spacing: 7) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("搜索会话", text: $query).textFieldStyle(.plain)
                        .focused($searchFocused)
                    if !query.isEmpty {
                        Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.plain).foregroundStyle(.secondary).accessibilityLabel("清除搜索")
                    }
                }
                .padding(.horizontal, 9).frame(height: 28)
                .background(.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 7))
                Button { page = .personal } label: {
                    Label("我的会话", systemImage: "person.crop.rectangle.stack")
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 6).contentShape(Rectangle())
                }.buttonStyle(.plain).keyboardShortcut("5")
            }
            .padding(.horizontal, 14).padding(.bottom, 6)
            .background {
                Button("搜索会话") { searchFocused = true }.keyboardShortcut("k").hidden()
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(rows) { row in
                        switch row {
                        case .person(let person):
                            let people = expansion([person])
                            GroupHeading(title: person == model.directory?.person ? person + " · 我" : person,
                                         icon: "person", expanded: people.wrappedValue) {
                                people.wrappedValue.toggle()
                            }
                        case .agent(let person, let name):
                            let branch = expansion([person, name])
                            GroupHeading(title: name, icon: "terminal", expanded: branch.wrappedValue) {
                                branch.wrappedValue.toggle()
                            }
                            .padding(.leading, 13)
                        case .session(let session):
                            peerButton(session)
                        }
                    }
                }
                .padding(.leading, 16)
                .padding(.trailing, 10)
            }
            .accessibilityLabel("会话联系人")
            .overlay(alignment: .top) {
                if rows.isEmpty && model.directory != nil {
                    Text(terms.isEmpty ? "暂无可查看的会话" : "没有匹配的会话")
                        .font(.callout).foregroundStyle(.secondary).padding(.top)
                }
            }
            HStack {
                Button { settingsOpen.toggle() } label: {
                    Image(systemName: "gearshape")
                        .font(.system(size: 15))
                        .frame(width: 30, height: 30)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .popover(isPresented: $settingsOpen, arrowEdge: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Button {
                            settingsOpen = false
                            page = .overview
                        } label: {
                            Label("概览", systemImage: "square.grid.2x2")
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(6).contentShape(Rectangle())
                        }
                        Button {
                            settingsOpen = false
                            setup.presented = true
                        } label: {
                            Label("环境配置", systemImage: "slider.horizontal.3")
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(6).contentShape(Rectangle())
                        }
                        Divider()
                        Button(role: .destructive) {
                            settingsOpen = false
                            leaveTarget = model.directory
                            confirmingLeave = true
                        } label: {
                            Label("退出当前 Network", systemImage: "rectangle.portrait.and.arrow.right")
                                .foregroundStyle(.red)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(6).contentShape(Rectangle())
                        }
                        .disabled(model.directory?.networkID == nil || model.sending || model.changingSession != nil)
                    }
                    .buttonStyle(.plain).padding(8).frame(width: 180)
                }
                .accessibilityLabel("设置")
                .help("设置")
                Spacer()
            }
            .padding(.leading, 10)
            .padding(.vertical, 5)
        }
        .alert("退出当前 Network？", isPresented: $confirmingLeave, presenting: leaveTarget) { target in
            Button("取消", role: .cancel) {}
            Button("退出 Network", role: .destructive) {
                guard let id = target.networkID else { return }
                Task {
                    do { try await model.leaveNetwork(id) }
                    catch { leaveFailure = SetupInput.redacted(error.localizedDescription) }
                }
            }
        } message: { target in
            Text("这台 Mac 上的所有会话都会与「" + (target.team ?? "当前 Network") + "」断开。本机聊天记录会保留，重新加入同一个 Network 后可以继续查看。")
        }
        .alert("无法退出 Network", isPresented: Binding(get: { leaveFailure != nil }, set: { if !$0 { leaveFailure = nil } })) {
            Button("好", role: .cancel) {}
        } message: { Text(leaveFailure ?? "") }
        .sheet(item: $page) { destination in
            switch destination {
            case .overview: NetworkOverview()
            case .personal: PersonalSessionsView().frame(minWidth: 540, idealWidth: 620, minHeight: 420, idealHeight: 520)
            }
        }
    }
    private func peerButton(_ session: NetworkSession) -> some View {
        let selected = model.selectedPeer == session.address
        return Button { model.selectedPeer = session.address } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.title).lineLimit(1)
                    if session.title != session.name {
                        Text(session.name).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 3)
                if session.offline { Text("离线").font(.caption2).foregroundStyle(.secondary) }
            }
            .padding(.leading, 36).padding(.trailing, 5).padding(.vertical, 5)
            .background(.primary.opacity(selected ? 0.10 : 0), in: RoundedRectangle(cornerRadius: 7))
            .contentShape(Rectangle())
        }.buttonStyle(.plain).help(session.titleHelp)
            .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private struct ConversationHistory: View {
    let messages: [Message]
    let sender: String
    let waiting: Bool
    let hasPeer: Bool
    let failed: Bool
    let sentCount: Int
    let overlayInset: CGFloat
    let hasEarlier: Bool
    let earlier: (Message) async throws -> MessagePage
    let openAttachment: (MessageAttachment) -> Void
    @State private var pending = false
    @State private var latestRequest = 0

    var body: some View {
        ZStack(alignment: .top) {
            NativeTranscript(messages: messages, sender: sender, sentCount: sentCount,
                             latestRequest: latestRequest, pendingChanged: { pending = $0 },
                             hasEarlier: hasEarlier, earlier: earlier, openAttachment: openAttachment)
                .overlay(alignment: .bottom) {
                    if pending {
                        Button("查看最新消息", systemImage: "arrow.down") { latestRequest += 1 }
                            .buttonStyle(.bordered).padding(.bottom, overlayInset + 8)
                    }
                }
            if messages.isEmpty && !failed {
                Group {
                    if waiting { ProgressView().controlSize(.small).accessibilityLabel("载入会话") }
                    else { Text(hasPeer ? "还没有消息" : "选择一个会话").font(.system(size: 14)).foregroundStyle(.secondary) }
                }.padding(.top, 94)
            }
        }
    }
}

private final class TranscriptTextView: NSTextView {}

private final class TranscriptRecord {
    let message: Message
    let text: NSAttributedString
    let naturalWidth: CGFloat
    var sizes: [CGFloat: CGSize] = [:]
    var bodySize = CGSize.zero
    let storage = NSTextStorage()
    let layout = NSLayoutManager()
    let container = NSTextContainer(containerSize: .zero)

    init(_ message: Message) {
        self.message = message
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 6
        let body = NSMutableAttributedString(string: message.body.isEmpty ? " " : message.body, attributes: [
            .font: NSFont.systemFont(ofSize: 14, weight: .light),
            .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph
        ])
        for (index, file) in message.attachments.enumerated() {
            var style: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.secondaryLabelColor]
            if file.directory != nil { style[.link] = URL(string: "reason-attachment:\(index)") }
            body.append(NSAttributedString(string: "\n📎 " + file.name, attributes: style))
        }
        text = body
        naturalWidth = ceil(text.size().width)
        container.lineFragmentPadding = 0
        layout.addTextContainer(container)
        storage.addLayoutManager(layout)
        storage.setAttributedString(text)
    }
    var rowHeight: CGFloat { 19 + bodySize.height + 24 + (message.delivery.isEmpty ? 0 : 18) + 22 }
}

private final class TranscriptCell: NSTableCellView, NSTextViewDelegate {
    var openAttachment: ((MessageAttachment) -> Void)?
    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        if let record, let url = link as? URL, url.scheme == "reason-attachment",
           let index = Int(url.absoluteString.dropFirst("reason-attachment:".count)),
           record.message.attachments.indices.contains(index) {
            openAttachment?(record.message.attachments[index])
        }
        return true
    }
    // Match the height measurer and character-based scroll anchors. The default
    // TextKit 2 view otherwise switches engines when an anchor reads layoutManager.
    let text = TranscriptTextView(usingTextLayoutManager: false)
    private let header = NSTextField(labelWithString: "")
    private let delivery = NSTextField(labelWithString: "")
    private let bubble = NSView()
    private var record: TranscriptRecord?
    private var inset: CGFloat = 12
    private var sender = ""

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        bubble.wantsLayer = true
        bubble.layer?.cornerRadius = 13
        text.delegate = self
        text.isEditable = false
        text.isSelectable = true
        text.drawsBackground = false
        text.textContainerInset = .zero
        text.textContainer?.lineFragmentPadding = 0
        text.textContainer?.widthTracksTextView = true
        text.isHorizontallyResizable = false
        text.isVerticallyResizable = false
        header.font = .systemFont(ofSize: 11)
        delivery.font = .systemFont(ofSize: 10)
        for label in [header, delivery] {
            label.textColor = .secondaryLabelColor
            label.lineBreakMode = .byTruncatingTail
            addSubview(label)
        }
        addSubview(bubble)
        addSubview(text)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(_ record: TranscriptRecord?, sender: String, inset: CGFloat) {
        let changed = self.record?.message != record?.message
        let headerChanged = changed || self.sender != sender
        self.sender = sender
        self.record = record
        self.inset = inset
        for view in [header, delivery, bubble, text] { view.isHidden = record == nil }
        guard let record else { return }
        if changed { text.textStorage?.setAttributedString(record.text) }
        if headerChanged {
            let message = record.message
            header.stringValue = (message.outgoing ? "我" : sender) + " · " +
                Date(timeIntervalSince1970: message.at).formatted(date: .omitted, time: .shortened)
            delivery.stringValue = message.delivery
            header.alignment = message.outgoing ? .right : .left
            delivery.alignment = header.alignment
            updateBubble()
        }
        needsLayout = true
    }

    private func updateBubble() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            bubble.layer?.backgroundColor = NSColor.labelColor
                .withAlphaComponent(record?.message.outgoing == true ? 0.09 : 0.045).cgColor
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateBubble()
    }

    override func layout() {
        super.layout()
        guard let record else { return }
        let size = record.bodySize
        let bubbleWidth = size.width + 32
        let x = record.message.outgoing ? bounds.width - inset - bubbleWidth : inset
        header.frame = NSRect(x: inset, y: 0, width: max(1, bounds.width - 2 * inset), height: 13)
        bubble.frame = NSRect(x: x, y: 19, width: bubbleWidth, height: size.height + 24)
        text.frame = NSRect(x: x + 16, y: 31, width: size.width, height: size.height)
        delivery.frame = NSRect(x: inset, y: 19 + size.height + 30,
                                width: max(1, bounds.width - 2 * inset), height: 12)
    }
}

private final class TranscriptScrollView: NSScrollView {
    var widthChanged: ((CGFloat) -> Void)?
    override func tile() {
        super.tile()
        widthChanged?(contentSize.width)
    }
}

private struct NativeTranscript: NSViewRepresentable {
    let messages: [Message]
    let sender: String
    let sentCount: Int
    let latestRequest: Int
    let pendingChanged: (Bool) -> Void
    let hasEarlier: Bool
    let earlier: (Message) async throws -> MessagePage
    let openAttachment: (MessageAttachment) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSScrollView { context.coordinator.scroll }
    func updateNSView(_ view: NSScrollView, context: Context) { context.coordinator.update(self) }

    @MainActor final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        let scroll = TranscriptScrollView()
        let table = NSTableView()
        private let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("message"))
        private var reading = ConversationReadingWindow()
        private var latest: [Message] = []
        private var records: [TranscriptRecord] = []
        private var sender = ""
        private var width: CGFloat = 0
        private var inset: CGFloat = 12
        private var updating = false
        private var sentCount: Int?
        private var latestRequest: Int?
        private var boundsObserver: NSObjectProtocol?
        private var scrollObserver: NSObjectProtocol?
        private var inputMonitor: Any?
        private var resizeAnchor: Anchor?
        private var resizeEnd: Task<Void, Never>?
        private var pendingChanged: ((Bool) -> Void)?
        private var publishedPending = false
        private var latestHasEarlier = false
        private var pageHasEarlier = false
        private var loadingEarlier = false
        private var earlier: ((Message) async throws -> MessagePage)?
        private var openAttachment: ((MessageAttachment) -> Void)?
        private let earlierButton = NSButton(title: "加载更早的消息", target: nil, action: nil)
        private func updateEarlierButton() {
            earlierButton.isHidden = !(reading.expanded ? pageHasEarlier : latestHasEarlier)
            earlierButton.isEnabled = !loadingEarlier
        }
        @objc private func loadEarlier() {
            guard let first = reading.messages.first, !loadingEarlier, let earlier else { return }
            loadingEarlier = true
            updateEarlierButton()
            Task { [weak self] in
                do {
                    let page = try await earlier(first)
                    guard let self else { return }
                    if self.reading.messages.first?.rowKey == first.rowKey {
                        let anchor = self.capture()
                        self.reading.prepend(page, before: first.rowKey)
                        self.pageHasEarlier = page.hasEarlier
                        if page.messages.isEmpty { self.latestHasEarlier = false }
                        self.applyMessages(anchor: anchor)
                    }
                } catch is CancellationError {
                    // The conversation changed while this page was loading.
                } catch {
                    if let window = self?.scroll.window { _ = await NSAlert(error: error).beginSheetModal(for: window) }
                }
                self?.loadingEarlier = false
                self?.updateEarlierButton()
            }
        }

        private struct Anchor {
            var bottom: Bool
            var id: Message.RowKey?
            var character: Int?
            var screenY: CGFloat = 0
        }

        override init() {
            super.init()
            earlierButton.isBordered = false
            earlierButton.font = .systemFont(ofSize: 12)
            earlierButton.target = self
            earlierButton.action = #selector(loadEarlier)
            table.addTableColumn(column)
            table.headerView = nil
            table.style = .plain
            table.columnAutoresizingStyle = .noColumnAutoresizing
            table.usesAutomaticRowHeights = false
            table.intercellSpacing = .zero
            table.selectionHighlightStyle = .none
            table.allowsEmptySelection = true
            table.allowsTypeSelect = false
            table.focusRingType = .none
            table.backgroundColor = .clear
            table.dataSource = self
            table.delegate = self
            table.setAccessibilityLabel("聊天消息")
            scroll.borderType = .noBorder
            scroll.drawsBackground = false
            scroll.hasVerticalScroller = true
            configureOverlayScroller(scroll)
            scroll.documentView = table
            scroll.widthChanged = { [weak self] width in self?.resize(to: width) }
            scroll.contentView.postsBoundsChangedNotifications = true
            scrollObserver = NotificationCenter.default.addObserver(
                forName: NSScrollView.willStartLiveScrollNotification, object: scroll, queue: .main
            ) { [weak self] _ in MainActor.assumeIsolated { self?.endResize() } }
            inputMonitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .leftMouseDown]) { [weak self] event in
                if let self, event.window === self.scroll.window,
                   self.scroll.bounds.contains(self.scroll.convert(event.locationInWindow, from: nil)) {
                    self.endResize()
                }
                return event
            }
            boundsObserver = NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification, object: scroll.contentView, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, !self.updating else { return }
                    if self.reading.hasPendingUpdate && self.atBottom { self.showLatest() }
                }
            }
        }

        private func endResize() {
            resizeEnd?.cancel()
            resizeEnd = nil
            resizeAnchor = nil
        }

        deinit {
            resizeEnd?.cancel()
            if let scrollObserver { NotificationCenter.default.removeObserver(scrollObserver) }
            if let inputMonitor { NSEvent.removeMonitor(inputMonitor) }
            if let boundsObserver { NotificationCenter.default.removeObserver(boundsObserver) }
        }

        private var atBottom: Bool {
            table.bounds.maxY - scroll.documentVisibleRect.maxY <= 8
        }

        func update(_ value: NativeTranscript) {
            earlier = value.earlier
            openAttachment = value.openAttachment
            latestHasEarlier = value.hasEarlier
            if reading.expanded, let first = reading.messages.first, first.rowKey == value.messages.first?.rowKey {
                pageHasEarlier = value.hasEarlier
            }
            defer { updateEarlierButton() }
            pendingChanged = value.pendingChanged
            let forceLatest = sentCount.map { $0 != value.sentCount } == true ||
                latestRequest.map { $0 != value.latestRequest } == true
            sentCount = value.sentCount
            latestRequest = value.latestRequest
            let senderChanged = sender != value.sender
            sender = value.sender
            latest = value.messages
            if forceLatest { showLatest(); return }
            let anchor = capture()
            let pin = reading.receive(latest, atBottom: atBottom)
            if records.map(\.message) != reading.messages {
                applyMessages(anchor: pin ? Anchor(bottom: true) : anchor)
            } else if senderChanged {
                configureVisibleCells()
            }
            publishPending()
        }

        private func publishPending() {
            let pending = reading.hasPendingUpdate
            guard publishedPending != pending else { return }
            publishedPending = pending
            DispatchQueue.main.async { [weak self] in
                guard let self, self.publishedPending == pending else { return }
                self.pendingChanged?(pending)
            }
        }

        private func showLatest() {
            reading.show(latest)
            updateEarlierButton()
            applyMessages(anchor: Anchor(bottom: true))
            publishPending()
        }

        private func applyMessages(anchor: Anchor) {
            endResize()
            guard !updating else { return }
            updating = true
            defer { updating = false }
            let old = Dictionary(uniqueKeysWithValues: records.map { ($0.message.rowKey, $0) })
            records = reading.messages.map { message in
                if let record = old[message.rowKey], record.message == message { return record }
                return TranscriptRecord(message)
            }
            prepareSizes()
            table.reloadData()
            table.layoutSubtreeIfNeeded()
            configureVisibleCells()
            restore(anchor)
        }

        private func resize(to newWidth: CGFloat) {
            let newWidth = floor(newWidth)
            guard !updating, newWidth > 0, abs(width - newWidth) >= 1 else { return }
            var selection: (id: Message.RowKey, range: NSRange)?
            if let text = table.window?.firstResponder as? TranscriptTextView,
               let record = record(at: table.row(for: text)) {
                selection = (record.message.rowKey, text.selectedRange())
            }
            let anchor = resizeAnchor ?? capture()
            resizeAnchor = anchor
            resizeEnd?.cancel()
            resizeEnd = Task { @MainActor [weak self] in
                do { try await Task.sleep(for: .milliseconds(180)) } catch { return }
                self?.resizeAnchor = nil
            }
            updating = true
            defer { updating = false }
            width = newWidth
            inset = min(64, max(12, (width - 560) * 0.08 + 12))
            prepareSizes()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0
                context.allowsImplicitAnimation = false
                column.width = width
                table.reloadData()
                table.layoutSubtreeIfNeeded()
                configureVisibleCells()
                restore(anchor)
                if let selection, let index = records.firstIndex(where: { $0.message.rowKey == selection.id }),
                   let cell = table.view(atColumn: 0, row: index + 1, makeIfNecessary: true) as? TranscriptCell {
                    cell.text.setSelectedRange(selection.range)
                    table.window?.makeFirstResponder(cell.text)
                }
            }
        }

        private func prepareSizes() {
            let limit = max(20, floor(min(720, (max(335, width) - 2 * inset) * 0.82)) - 32)
            for record in records {
                let textWidth = max(20, min(limit, record.naturalWidth))
                if let cached = record.sizes[textWidth] { record.bodySize = cached; continue }
                record.container.containerSize = NSSize(width: textWidth, height: CGFloat.greatestFiniteMagnitude)
                record.layout.ensureLayout(for: record.container)
                let trailingHeight = record.layout.extraLineFragmentTextContainer === record.container
                    ? record.layout.extraLineFragmentRect.maxY : 0
                let height = max(record.layout.usedRect(for: record.container).maxY, trailingHeight)
                let size = CGSize(width: textWidth, height: ceil(height) + 2)
                if record.sizes.count >= 256 { record.sizes.removeAll(keepingCapacity: true) }
                record.sizes[textWidth] = size
                record.bodySize = size
            }
        }

        private func configureVisibleCells() {
            let visible = table.rows(in: scroll.documentVisibleRect)
            guard visible.location != NSNotFound else { return }
            for row in visible.location..<NSMaxRange(visible) {
                guard let cell = table.view(atColumn: 0, row: row, makeIfNecessary: false) as? TranscriptCell else { continue }
                cell.configure(record(at: row), sender: sender, inset: inset)
                cell.layoutSubtreeIfNeeded()
            }
        }

        private func record(at row: Int) -> TranscriptRecord? {
            records.indices.contains(row - 1) ? records[row - 1] : nil
        }

        private func capture() -> Anchor {
            if records.isEmpty || atBottom { return Anchor(bottom: true) }
            let visible = scroll.documentVisibleRect
            var row = min(records.count, max(1, table.row(at: CGPoint(x: 1, y: visible.minY + 40))))
            if let cell = table.view(atColumn: 0, row: row, makeIfNecessary: false) as? TranscriptCell,
               cell.text.convert(cell.text.bounds, to: table).maxY < visible.minY + 40 {
                row = min(records.count, row + 1)
            }
            guard let record = record(at: row) else { return Anchor(bottom: false) }
            var anchor = Anchor(bottom: false, id: record.message.rowKey)
            anchor.screenY = table.rect(ofRow: row).minY - visible.minY
            if let cell = table.view(atColumn: 0, row: row, makeIfNecessary: false) as? TranscriptCell,
               let layout = cell.text.layoutManager, let container = cell.text.textContainer {
                layout.ensureLayout(for: container)
                let point = cell.text.convert(CGPoint(x: inset + 16, y: visible.minY + 40), from: table)
                let glyph = layout.glyphIndex(for: CGPoint(x: 0, y: max(0, point.y)), in: container)
                if glyph < layout.numberOfGlyphs {
                    anchor.character = layout.characterIndexForGlyph(at: glyph)
                    let lineY = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil).minY
                    anchor.screenY = cell.text.convert(CGPoint(x: 0, y: lineY), to: table).y - visible.minY
                }
            }
            return anchor
        }

        private func restore(_ anchor: Anchor) {
            var origin = scroll.contentView.bounds.origin
            if anchor.bottom {
                origin.y = max(0, table.bounds.height - scroll.contentSize.height)
            } else if let index = records.firstIndex(where: { $0.message.rowKey == anchor.id }) {
                let row = index + 1
                origin.y = table.rect(ofRow: row).minY - anchor.screenY
                if let character = anchor.character,
                   let cell = table.view(atColumn: 0, row: row, makeIfNecessary: true) as? TranscriptCell,
                   let layout = cell.text.layoutManager, let container = cell.text.textContainer {
                    cell.configure(records[index], sender: sender, inset: inset)
                    cell.layoutSubtreeIfNeeded()
                    layout.ensureLayout(for: container)
                    let character = min(character, max(0, cell.text.string.utf16.count - 1))
                    let glyph = layout.glyphIndexForCharacter(at: character)
                    if glyph < layout.numberOfGlyphs {
                        let lineY = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil).minY
                        origin.y = cell.text.convert(CGPoint(x: 0, y: lineY), to: table).y - anchor.screenY
                    }
                }
            } else { return }
            var bounds = scroll.contentView.bounds
            bounds.origin = origin
            scroll.contentView.scroll(to: scroll.contentView.constrainBoundsRect(bounds).origin)
            scroll.reflectScrolledClipView(scroll.contentView)
        }

        func numberOfRows(in tableView: NSTableView) -> Int { records.count + 2 }
        func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
            if row == 0 { return 28 }
            return record(at: row)?.rowHeight ?? 70
        }
        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            if row == 0 {
                let header = NSView()
                header.addSubview(earlierButton)
                earlierButton.translatesAutoresizingMaskIntoConstraints = false
                NSLayoutConstraint.activate([earlierButton.centerXAnchor.constraint(equalTo: header.centerXAnchor),
                                             earlierButton.centerYAnchor.constraint(equalTo: header.centerYAnchor)])
                return header
            }
            let identifier = NSUserInterfaceItemIdentifier("message-cell")
            let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? TranscriptCell ?? TranscriptCell()
            cell.identifier = identifier
            cell.openAttachment = openAttachment
            cell.configure(record(at: row), sender: sender, inset: inset)
            return cell
        }
    }
}

struct StatusView: View {
    @EnvironmentObject private var setup: SetupModel
    @EnvironmentObject private var model: NetworkModel
    @State private var exitSupported = false
    @State private var exitStatus: String?
    @State private var diagnostics = false
    @State private var viewportHeight: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var refreshing = false
    @State private var refreshResult: String?
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 11) {
                HStack(spacing: 8) {
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
                    .foregroundStyle(.primary).padding(10)
                    .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
                    .layoutPriority(1)
                    Color.clear
                        .frame(minWidth: 48, maxWidth: .infinity)
                        .overlay {
                            if model.senderOffline || model.reconnectingSender || model.tier != nil {
                                Button {
                                    Task { await model.reconnectSender() }
                                } label: {
                                    Text(model.reconnectingSender ? "接入中…" : model.senderOffline ? "重新接入" : "已接入")
                                        .font(.system(size: 11, weight: .medium)).lineLimit(1)
                                        .contentTransition(reduceMotion ? .identity : .numericText())
                                        .foregroundStyle(.secondary)
                                        .frame(width: 48)
                                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .disabled(!model.senderOffline || model.changingSession != nil || model.sending || model.leavingNetwork)
                                .help(model.senderOffline ? "重新接入当前本机会话" : "本机会话接入状态")
                                .transition(.opacity)
                            }
                        }
                        .animation(reduceMotion ? nil : .easeInOut(duration: 0.16), value: model.senderOffline || model.reconnectingSender)
                        .animation(reduceMotion ? nil : .easeInOut(duration: 0.16), value: model.reconnectingSender)
                }
                .fixedSize(horizontal: false, vertical: true)
                if let local = model.own, !local.historyOnly, let network = model.directory?.networkID {
                    let actual = model.tier.flatMap(ReceiveMode.init(rawValue:))
                    Menu {
                        if let actual {
                            Picker("偏好接收模式", selection: Binding(get: { actual }, set: { mode in
                                Task { await model.changeReceiveMode(mode, local: local, network: network) }
                            })) {
                                ForEach(ReceiveMode.allCases, id: \.self) { mode in Text(mode.title).tag(mode) }
                            }
                            .pickerStyle(.inline).labelsHidden()
                        }
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: actual == .push ? "bolt.horizontal" : "arrow.down.circle")
                                .frame(width: 14)
                            Text(actual?.title ?? "接收模式")
                                .contentTransition(reduceMotion ? .identity : .numericText())
                            Image(systemName: "chevron.down")
                                .font(.system(size: 8, weight: .medium))
                        }
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .frame(minHeight: 24)
                        .contentShape(Rectangle())
                    }
                    .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
                    .fixedSize()
                    .padding(.bottom, 3)
                    .animation(reduceMotion ? nil : .easeInOut(duration: 0.16), value: actual)
                    .disabled(actual == nil || model.changingSession != nil || model.senderPresence != .online)
                    .accessibilityLabel("偏好接收模式").accessibilityValue(actual?.title ?? "暂不可用")
                    .help(actual == nil ? "接入后可查看和切换接收模式" : "切换当前本机会话的接收模式")
                }
                ForEach(model.directory?.machines ?? []) { device in
                    VStack(alignment: .leading, spacing: 7) {
                        HStack {
                            Text(device.person + (device.isMe ? " · 本机" : "")).font(.system(size: 12, weight: .medium))
                            Spacer()
                            Circle().fill(model.online ? (device.online ? Color.primary : Color(nsColor: .systemRed)) : Color.secondary).frame(width: 5, height: 5)
                            Text(model.online ? device.state : "状态未知").font(.system(size: 11)).monospacedDigit()
                        }
                        Text(device.machine).font(.system(size: 11, design: .monospaced)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    }
                    .foregroundStyle(.primary)
                    if device.id != model.directory?.machines.last?.id { Divider() }
                }
                HStack(spacing: 10) {
                    Button {
                        refreshing = true
                        refreshResult = nil
                        Task {
                            await model.refresh()
                            refreshResult = model.error == nil ? "已刷新" : "刷新失败"
                            refreshing = false
                        }
                    } label: {
                        HStack(spacing: 8) {
                            Group {
                                if refreshing { ProgressView().controlSize(.mini) }
                                else { Image(systemName: "arrow.clockwise") }
                            }
                            .frame(width: 14, height: 14)
                            Text(refreshing ? "刷新中…" : "刷新对话")
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(refreshing)
                    .help("刷新会话列表、当前对话消息和设备状态")
                    Spacer()
                    Text(refreshResult ?? "")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .accessibilityAddTraits(.updatesFrequently)
                }
                .font(.system(size: 12))
                .foregroundStyle(.primary)
                CopyInvitationButton()
                Button("环境配置", systemImage: "slider.horizontal.3") { setup.presented = true }
                    .buttonStyle(.plain).font(.system(size: 12))
                VStack(alignment: .leading, spacing: 4) {
                    Button("退出当前会话", systemImage: "rectangle.portrait.and.arrow.right") {
                        guard let local = model.own else { return }
                        exitStatus = "正在退出 " + local.name + "…"
                        Task {
                            do { exitStatus = "已退出 " + (try await model.exitLocal(local)) }
                            catch { exitStatus = error.localizedDescription }
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(!exitSupported || model.own?.historyOnly != false || model.changingSession != nil)
                    if let exitStatus {
                        Text(exitStatus).font(.caption).foregroundStyle(.secondary)
                            .accessibilityAddTraits(.updatesFrequently)
                    }
                }.font(.system(size: 12))
                DisclosureGroup(isExpanded: $diagnostics) {
                    if !model.doctor.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            Text(model.doctor).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                            if let warning = model.mirrorWarning { Text(warning).font(.system(size: 11)).foregroundStyle(.secondary) }
                            Button("重新检查", systemImage: "arrow.clockwise") { Task { await model.diagnose() } }
                                .disabled(model.diagnosing)
                        }.padding(.top, 8)
                    }
                } label: {
                    HStack(spacing: 6) {
                        Text("诊断")
                        if diagnostics && model.diagnosing {
                            ProgressView().controlSize(.mini)
                                .accessibilityLabel("正在检查")
                        }
                    }
                    .frame(minHeight: 16)
                }
                .font(.system(size: 12)).foregroundStyle(.secondary)
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: diagnostics)
                .onChange(of: diagnostics) { _, expanded in if expanded { Task { await model.diagnose() } } }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .onGeometryChange(for: CGFloat.self) { ceil($0.size.height) } action: { height in
                let target = min(height, StatusViewport.maximumHeight)
                guard target > 0, viewportHeight != target else { return }
                withAnimation(viewportHeight > 0 && !reduceMotion ? .smooth(duration: 0.24) : nil) {
                    viewportHeight = target
                }
            }
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(width: 340)
        .modifier(StatusViewport(height: viewportHeight))
        .fixedSize(horizontal: false, vertical: true)
        .background(Color(nsColor: .windowBackgroundColor))
        .task {
            do {
                exitSupported = try await model.supportsSessionExit()
                if !exitSupported { exitStatus = "当前后台不支持单独退出会话" }
            } catch { exitStatus = "无法连接会话管理服务" }
        }
    }
}

// Feed the native popover the interpolated viewport size on each SwiftUI layout pass.
private struct StatusViewport: AnimatableModifier {
    static let maximumHeight: CGFloat = 480
    var height: CGFloat
    var animatableData: CGFloat {
        get { height }
        set { height = newValue }
    }

    func body(content: Content) -> some View {
        content
            .frame(height: height > 0 ? height : nil, alignment: .top)
            .frame(maxHeight: Self.maximumHeight, alignment: .top)
            .transaction { $0.animation = nil }
    }
}

private struct PersonalSessionsView: View {
    @EnvironmentObject private var model: NetworkModel
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var selectedAgent = ""

    @State private var collapsed: Set<[String]> = []
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private func heading(_ title: String, icon: String, key: [String]) -> some View {
        GroupHeading(title: title, icon: icon, expanded: !collapsed.contains(key)) {
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) {
                if collapsed.contains(key) { collapsed.remove(key) } else { collapsed.insert(key) }
            }
        }
    }

    private var agents: [String] {
        Set(model.mySessions.map(\.agentName)).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
    private var matches: [PersonalSession] {
        model.mySessions.filter { (selectedAgent.isEmpty || $0.agentName == selectedAgent) && $0.matches(query) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("我的会话").font(.title2.weight(.semibold))
                Spacer()
                Button("完成") { dismiss() }.keyboardShortcut(.cancelAction)
            }.padding(.horizontal, 22).padding(.top, 18)
            HStack(spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("搜索本机会话或项目", text: $query).textFieldStyle(.plain)
                }
                .padding(8).background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                Menu {
                    Picker("工具", selection: $selectedAgent) {
                        Text("全部工具").tag("")
                        ForEach(agents, id: \.self) { Text($0).tag($0) }
                    }.pickerStyle(.inline).labelsHidden()
                } label: {
                    Text(selectedAgent.nonEmpty ?? "全部工具").lineLimit(1)
                }.menuStyle(.borderlessButton).fixedSize().accessibilityLabel("选择工具")
                Button { Task { await model.refreshMySessions() } } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(model.loadingMySessions).help("刷新本机会话").accessibilityLabel("刷新本机会话")
            }
            .padding(.horizontal, 22).padding(.top, 16)

            if let status = model.mySessionsError ?? model.mySessionsNotice {
                Text(status).font(.system(size: 12)).textSelection(.enabled).padding(.horizontal, 22)
            }
            if matches.isEmpty {
                Group {
                    if model.loadingMySessions { ProgressView().controlSize(.small) }
                    else { Text(query.isEmpty ? "暂无本机会话" : "没有找到匹配的会话").font(.system(size: 12)).foregroundStyle(.secondary) }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 7) {
                        let byAgent = Dictionary(grouping: matches, by: \.agentName)
                        ForEach(byAgent.keys.sorted(), id: \.self) { agent in
                            heading(agent, icon: "terminal", key: [agent])
                            if !collapsed.contains([agent]) {
                                let projects = Dictionary(grouping: byAgent[agent] ?? [], by: \.displayProject)
                                let recent = projects.mapValues { $0.first?.updated ?? .distantPast }
                                let ordered = projects.keys.sorted {
                                    if agent == NetworkSession.agentDisplayName("codex"), recent[$0] != recent[$1] {
                                        return (recent[$0] ?? .distantPast) > (recent[$1] ?? .distantPast)
                                    }
                                    return ($0.position, $0.name, $0.id) < ($1.position, $1.name, $1.id)
                                }
                                ForEach(ordered, id: \.id) { project in
                                    heading(project.name, icon: "folder", key: [agent, project.id])
                                        .padding(.leading, 15)
                                    if !collapsed.contains([agent, project.id]) {
                                        let sessions = (projects[project] ?? []).sorted {
                                            if $0.pinned != $1.pinned { return $0.pinned }
                                            return ($0.updated, $0.id) > ($1.updated, $1.id)
                                        }
                                        ForEach(sessions) { session in
                                            sessionRow(session).padding(.leading, 42)
                                        }
                                    }
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 22).padding(.bottom, 20)
                }
            }
        }
        .task { await model.refreshMySessions() }
    }

    private func sessionRow(_ session: PersonalSession) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(session.title).font(.system(size: 13, weight: .medium)).lineLimit(1).help(session.title)
            }
            Spacer(minLength: 0)
            Text(session.connection.label).font(.system(size: 11)).foregroundStyle(.secondary)
            if model.changingSession == session.id {
                ProgressView().controlSize(.small).frame(width: 56)
            } else if session.canLeave {
                Button("退出") { Task { await model.leaveMySession(session) } }
                    .disabled(model.changingSession != nil)
                    .help("停止该会话接入 Reason Network，直到你重新加入。")
                    .accessibilityLabel("退出 \(session.title)")
            } else if session.canJoin {
                Button(joinTitle(session)) {
                    Task { await model.joinMySession(session) }
                }
                .disabled(model.changingSession != nil)
                .help("将这个会话加入当前 Reason Network")
                .accessibilityLabel("加入 \(session.title)")
            } else if session.connection == .notJoined {
                Text("在原工具打开").font(.system(size: 11)).foregroundStyle(.secondary)
            } else if case .online = session.connection {
                Text("需要新版后台").font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 6)
    }

    private func joinTitle(_ session: PersonalSession) -> String {
        switch session.connection {
        case .notJoined: "加入"
        case .paused where !session.supportsImmediateJoin: "允许接入"
        default: "重新接入"
        }
    }
}
