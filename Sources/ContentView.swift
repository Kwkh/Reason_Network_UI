import SwiftUI
import AppKit

struct ContentView: View {
    @EnvironmentObject private var model: NetworkModel
    @State private var showStatus = false
    @State private var composerHeight: CGFloat = 70
    @State private var editorHeight: CGFloat = 46
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var composing = false

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
        .task { await model.start() }
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
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { composerHeight = $0 }
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
                ToolbarItem(placement: .primaryAction) { statusButton }
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
            Text(address)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                .truncationMode(.middle)
        }
        .lineLimit(1)
        .frame(maxWidth: maxWidth)
        .fixedSize(horizontal: true, vertical: true)
        .accessibilityElement(children: .combine)
        .help([title, address].joined(separator: "\n"))
        .contentTransition(.opacity)
        .animation(conversationFade, value: model.selectedPeer)
    }

    private var statusButton: some View {
        Button { showStatus.toggle() } label: {
            HStack(spacing: 7) {
                Circle().fill(model.online ? Color.primary.opacity(0.85) : Color.gray).frame(width: 6, height: 6)
                Text(model.online ? "在线" : model.directory == nil && model.error == nil ? "连接中" : "离线")
                    .font(.system(size: 12, weight: .medium))
            }
            .padding(.horizontal, 13).padding(.vertical, 7)
            .background(Capsule().stroke(Color.primary.opacity(0.16), lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain).help("设备状态与本机会话")
        .popover(isPresented: $showStatus, arrowEdge: .bottom) { StatusView().environmentObject(model) }
    }
    private var history: some View {
        ZStack {
            ConversationHistory(messages: model.messages, sender: model.peer?.person ?? "",
                                waiting: model.waitingForHistory && model.error == nil,
                                hasPeer: !model.selectedPeer.isEmpty, failed: model.error != nil,
                                sentCount: model.sentCount, overlayInset: composerHeight)
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
        VStack(alignment: .leading, spacing: 4) {
            if !model.notice.isEmpty {
                Text(model.notice)
                    .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
                    .accessibilityAddTraits(.updatesFrequently)
            }
            ZStack(alignment: .bottomTrailing) {
                DraftField(text: Binding(get: { model.draft }, set: { model.draft = $0 }),
                           focused: $composing,
                           heightChanged: { editorHeight = $0 }, onSend: { Task { await model.send() } })
                    .id(model.conversationKey)
                    .frame(height: editorHeight)
                    .frame(maxWidth: .infinity)
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
                .padding(.trailing, 12).padding(.bottom, 9)
                .buttonStyle(.plain).disabled(!model.canSend)
                .keyboardShortcut(.return, modifiers: .command)
                .help("发送消息（Enter），换行（Shift＋Enter）").accessibilityLabel(model.sending ? "发送中" : "发送消息")
            }
            .modifier(ComposerGlass(focused: composing))
            .animation(reduceMotion ? nil : .smooth(duration: 0.24), value: editorHeight)
        }
        .padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 16)
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

private struct ConversationSidebar: View {
    @EnvironmentObject private var model: NetworkModel

    var body: some View {
        let groups = Dictionary(grouping: model.peers, by: \.person)
        VStack(alignment: .leading, spacing: 0) {
            if !model.locals.isEmpty {
                Menu {
                    Picker("本机会话", selection: $model.selectedLocal) {
                        ForEach(model.locals) { session in
                            Text(session.title).tag(session.name)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                } label: {
                    Text(model.own?.title ?? model.selectedLocal)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.visible)
                .accessibilityLabel("选择本机会话")
                .help((model.own?.title ?? model.selectedLocal) + "\n" + model.selectedLocal)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            List(selection: Binding<String?>(
                get: { model.selectedPeer.nonEmpty },
                set: { if let address = $0 { model.selectedPeer = address } }
            )) {
                ForEach(groups.keys.sorted(), id: \.self) { person in
                    Section {
                        ForEach(groups[person] ?? []) { session in
                            HStack {
                                Text(session.title).lineLimit(1)
                                Spacer(minLength: 4)
                                if session.offline {
                                    Text("离线").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            .font(.system(size: 13))
                            .foregroundStyle(.primary)
                            .padding(.leading, 28)
                            .tag(session.address)
                            .help(session.address)
                        }
                    } header: {
                        Label(person, systemImage: "person")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.primary)
                            .textCase(nil)
                            .padding(.top, 8)
                            .padding(.bottom, 4)
                    }
                }
            }
            .listStyle(.sidebar)
            .accessibilityLabel("队友会话")
            .overlay(alignment: .top) {
                if groups.isEmpty && model.directory != nil {
                    Text("暂无队友会话").font(.callout).foregroundStyle(.secondary).padding(.top)
                }
            }
        }
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
    @State private var pending = false
    @State private var latestRequest = 0

    var body: some View {
        ZStack(alignment: .top) {
            NativeTranscript(messages: messages, sender: sender, sentCount: sentCount,
                             latestRequest: latestRequest, pendingChanged: { pending = $0 })
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
        text = NSAttributedString(string: message.body.isEmpty ? " " : message.body, attributes: [
            .font: NSFont.systemFont(ofSize: 14, weight: .light),
            .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph
        ])
        naturalWidth = ceil(text.size().width)
        container.lineFragmentPadding = 0
        layout.addTextContainer(container)
        storage.addLayoutManager(layout)
        storage.setAttributedString(text)
    }
    var rowHeight: CGFloat { 19 + bodySize.height + 24 + (message.delivery.isEmpty ? 0 : 18) + 22 }
}

private final class TranscriptCell: NSTableCellView {
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

        private struct Anchor {
            var bottom: Bool
            var id: String?
            var character: Int?
            var screenY: CGFloat = 0
        }

        override init() {
            super.init()
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
            applyMessages(anchor: Anchor(bottom: true))
            publishPending()
        }

        private func applyMessages(anchor: Anchor) {
            endResize()
            guard !updating else { return }
            updating = true
            defer { updating = false }
            let old = Dictionary(uniqueKeysWithValues: records.map { ($0.message.id, $0) })
            records = reading.messages.map { message in
                if let record = old[message.id], record.message == message { return record }
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
            var selection: (id: String, range: NSRange)?
            if let text = table.window?.firstResponder as? TranscriptTextView,
               let record = record(at: table.row(for: text)) {
                selection = (record.message.id, text.selectedRange())
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
                if let selection, let index = records.firstIndex(where: { $0.message.id == selection.id }),
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
            var anchor = Anchor(bottom: false, id: record.message.id)
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
            } else if let index = records.firstIndex(where: { $0.message.id == anchor.id }) {
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
            if row == 0 { return 24 }
            return record(at: row)?.rowHeight ?? 70
        }
        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            let identifier = NSUserInterfaceItemIdentifier("message-cell")
            let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? TranscriptCell ?? TranscriptCell()
            cell.identifier = identifier
            cell.configure(record(at: row), sender: sender, inset: inset)
            return cell
        }
    }
}

struct StatusView: View {
    @EnvironmentObject private var setup: SetupModel
    @EnvironmentObject private var model: NetworkModel
    @State private var diagnostics = false
    @State private var refreshing = false
    @State private var refreshResult: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
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
                .foregroundStyle(.primary).padding(13)
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
                if let tier = model.tier {
                    Label(tier == "push" ? "即时推送" : tier == "turn" ? "回合接收" : "手动接收", systemImage: tier == "push" ? "bolt.horizontal" : "arrow.down.circle")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
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
                Button("环境配置", systemImage: "slider.horizontal.3") { setup.presented = true }
                    .buttonStyle(.plain).font(.system(size: 12))
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
        .frame(width: 390, height: diagnostics ? 580 : min(520, 250 + CGFloat(model.directory?.machines.count ?? 0) * 65))
        .background(Color(nsColor: .windowBackgroundColor))
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.22), value: diagnostics)
    }
}
