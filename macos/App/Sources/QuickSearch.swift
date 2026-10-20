import AppKit
import Carbon.HIToolbox
import Observation
import SwiftUI
import SistCore
import SistStore

/// The shortcuts offered for the quick search panel. Space with ⌘ is Spotlight's and with ⌃ the
/// input source switch, which Chinese users rely on.
enum QuickSearchShortcut: String, CaseIterable, Identifiable {
    case optionSpace, controlOptionSpace, shiftCommandSpace, none

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .optionSpace: return "⌥ 空格"
        case .controlOptionSpace: return "⌃⌥ 空格"
        case .shiftCommandSpace: return "⇧⌘ 空格"
        case .none: return "不使用"
        }
    }

    /// Carbon key code and modifiers
    var key: (code: UInt32, modifiers: UInt32)? {
        let space = UInt32(kVK_Space)
        switch self {
        case .optionSpace: return (space, UInt32(optionKey))
        case .controlOptionSpace: return (space, UInt32(controlKey | optionKey))
        case .shiftCommandSpace: return (space, UInt32(shiftKey | cmdKey))
        case .none: return nil
        }
    }
}

/// A system-wide shortcut through Carbon's RegisterEventHotKey: unlike a global NSEvent monitor it
/// needs no accessibility permission, and the key press does not reach the frontmost app.
final class GlobalHotKey {
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private let action: () -> Void

    init(action: @escaping () -> Void) {
        self.action = action
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, userData in
            guard let userData else { return OSStatus(eventNotHandledErr) }
            Unmanaged<GlobalHotKey>.fromOpaque(userData).takeUnretainedValue().action()
            return OSStatus(noErr)
        }, 1, &type, Unmanaged.passUnretained(self).toOpaque(), &handler)
    }

    deinit {
        unregister()
        if let handler {
            RemoveEventHandler(handler)
        }
    }

    /// false when another app holds the shortcut
    @discardableResult
    func register(_ shortcut: QuickSearchShortcut) -> Bool {
        unregister()
        guard let key = shortcut.key else { return true }
        let id = EventHotKeyID(signature: OSType(0x5349_5354), id: 1)  // 'SIST'
        return RegisterEventHotKey(key.code, key.modifiers, id, GetApplicationEventTarget(), 0, &hotKey) == OSStatus(noErr)
    }

    func unregister() {
        if let hotKey {
            UnregisterEventHotKey(hotKey)
            self.hotKey = nil
        }
    }
}

/// A floating panel that takes the keyboard without activating the app, like Spotlight: the
/// window the user was working in stays in front, and the panel goes away when they click
/// elsewhere.
final class QuickSearchPanel: NSPanel {
    convenience init() {
        self.init(contentRect: NSRect(x: 0, y: 0, width: QuickSearchView.width, height: QuickSearchView.height(rows: 0)),
                  styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isFloatingPanel = true
        level = .floating
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = false
        isMovableByWindowBackground = true
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func resignKey() {
        super.resignKey()
        orderOut(nil)
    }

    override func cancelOperation(_ sender: Any?) {
        orderOut(nil)
    }
}

/// The query typed in the panel and its first results.
@MainActor
@Observable
final class QuickSearchModel {
    var text = "" {
        didSet { if text != oldValue { schedule() } }
    }
    private(set) var hits: [SearchHit] = []
    private(set) var total = 0
    private(set) var highlightTerms: [String] = []
    var selectedIndex = 0
    /// Bumped to put the cursor in the search field
    private(set) var focusRequest = 0

    @ObservationIgnored var catalog: () -> Catalog? = { nil }
    @ObservationIgnored var hitsChanged: () -> Void = {}
    @ObservationIgnored private var task: Task<Void, Never>?

    static let limit = 30

    var selectedHit: SearchHit? {
        hits.indices.contains(selectedIndex) ? hits[selectedIndex] : nil
    }

    func requestFocus() {
        focusRequest += 1
    }

    func move(_ delta: Int) {
        guard !hits.isEmpty else { return }
        selectedIndex = min(max(selectedIndex + delta, 0), hits.count - 1)
    }

    private func schedule() {
        task?.cancel()
        let text = text
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty, let catalog = catalog() else {
            update(SearchResults.empty)
            return
        }
        task = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(100))
            guard !Task.isCancelled else { return }
            var query = SearchQuery(text: text)
            query.limit = Self.limit
            guard let results = try? await catalog.search(query), !Task.isCancelled else { return }
            self?.update(results)
        }
    }

    private func update(_ results: SearchResults) {
        hits = results.hits
        total = results.total
        highlightTerms = results.highlightTerms
        selectedIndex = 0
        hitsChanged()
    }
}

/// Shows and hides the panel, and turns keys into actions on the results.
@MainActor
final class QuickSearchController {
    private unowned let model: AppModel
    let quick = QuickSearchModel()
    private let panel = QuickSearchPanel()
    private var hotKey: GlobalHotKey?
    private var keyMonitor: Any?

    init(model: AppModel) {
        self.model = model
        quick.catalog = { [unowned model] in model.catalog }
        quick.hitsChanged = { [weak self] in self?.resize() }

        let content = NSVisualEffectView()
        content.material = .popover
        content.blendingMode = .behindWindow
        content.state = .active
        content.maskImage = Self.roundedMask(radius: 14)
        let hosting = NSHostingView(rootView: QuickSearchView(controller: self)
            .environment(model)
            .environment(quick))
        hosting.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            hosting.topAnchor.constraint(equalTo: content.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        panel.contentView = content

        hotKey = GlobalHotKey { [weak self] in
            MainActor.assumeIsolated { self?.toggle() }
        }
    }

    /// false when another app holds the shortcut
    func register(_ shortcut: QuickSearchShortcut) -> Bool {
        hotKey?.register(shortcut) ?? false
    }

    func toggle() {
        if panel.isVisible {
            hide()
        } else {
            show()
        }
    }

    func show() {
        // On the screen with the pointer, a fifth of the way down, as Spotlight
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        if let visible = screen?.visibleFrame {
            let height = QuickSearchView.height(rows: quick.hits.count)
            let top = visible.maxY - visible.height * 0.2
            panel.setFrame(NSRect(x: visible.midX - QuickSearchView.width / 2, y: top - height,
                                  width: QuickSearchView.width, height: height), display: false)
        }
        panel.makeKeyAndOrderFront(nil)
        quick.requestFocus()
        installKeyMonitor()
    }

    func hide() {
        panel.orderOut(nil)
    }

    func open(_ hit: SearchHit) {
        hide()
        model.open(hit.document)
    }

    func reveal(_ hit: SearchHit) {
        hide()
        hit.document.revealInFinder()
    }

    /// The same query in the main window, with its filters and all its results
    func showAll() {
        hide()
        model.search.text = quick.text
        model.showMainWindow()
    }

    /// The panel keeps its top edge where it is while the list grows and shrinks
    private func resize() {
        var frame = panel.frame
        let height = QuickSearchView.height(rows: quick.hits.count)
        guard frame.height != height else { return }
        frame.origin.y = frame.maxY - height
        frame.size.height = height
        panel.setFrame(frame, display: true)
        panel.invalidateShadow()
    }

    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.panel else { return event }
            return self.handle(event) ? nil : event
        }
    }

    private func handle(_ event: NSEvent) -> Bool {
        // While an input method is composing (pinyin, kana), its keys are its own: Return commits
        // the text, the arrows pick a candidate, Escape cancels
        if let editor = panel.firstResponder as? NSTextView, editor.hasMarkedText() {
            return false
        }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        switch Int(event.keyCode) {
        case kVK_DownArrow:
            quick.move(1)
        case kVK_UpArrow:
            quick.move(-1)
        case kVK_Return, kVK_ANSI_KeypadEnter:
            if flags.contains(.shift) {
                showAll()
            } else if let hit = quick.selectedHit {
                flags.contains(.command) ? reveal(hit) : open(hit)
            }
        case kVK_Escape:
            hide()
        default:
            return false
        }
        return true
    }

    private static func roundedMask(radius: CGFloat) -> NSImage {
        let edge = radius * 2 + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }
}

struct QuickSearchView: View {
    @Environment(QuickSearchModel.self) private var quick
    let controller: QuickSearchController
    @FocusState private var fieldFocused: Bool

    static let width: CGFloat = 680
    static let fieldHeight: CGFloat = 56
    static let rowHeight: CGFloat = 46
    static let footerHeight: CGFloat = 30
    static let visibleRows = 8

    static func height(rows: Int) -> CGFloat {
        rows == 0 ? fieldHeight : fieldHeight + CGFloat(min(rows, visibleRows)) * rowHeight + footerHeight + 1
    }

    var body: some View {
        @Bindable var quick = quick
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                TextField("搜索文件名、内容、路径", text: $quick.text)
                    .textFieldStyle(.plain)
                    .font(.system(size: 22))
                    .focused($fieldFocused)
            }
            .padding(.horizontal, 16)
            .frame(height: Self.fieldHeight)

            if !quick.hits.isEmpty {
                Divider()
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(Array(quick.hits.enumerated()), id: \.element.id) { index, hit in
                                QuickSearchRow(hit: hit, terms: quick.highlightTerms,
                                               isSelected: index == quick.selectedIndex)
                                    .frame(height: Self.rowHeight)
                                    .contentShape(Rectangle())
                                    .onTapGesture(count: 2) { controller.open(hit) }
                                    .onTapGesture { quick.selectedIndex = index }
                                    .id(hit.id)
                            }
                        }
                    }
                    .onChange(of: quick.selectedIndex) {
                        if let hit = quick.selectedHit {
                            proxy.scrollTo(hit.id)
                        }
                    }
                }
                footer
            }
        }
        .frame(width: Self.width)
        .frame(maxHeight: .infinity, alignment: .top)
        .onChange(of: quick.focusRequest) {
            fieldFocused = true
            // Typing replaces the previous query, as in Spotlight
            DispatchQueue.main.async {
                NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 14) {
            Text(quick.total > quick.hits.count ? "前 \(quick.hits.count) 个，共 \(Format.number(quick.total)) 个结果"
                                                : "\(quick.hits.count) 个结果")
            Spacer()
            Text("↩ 打开")
            Text("⌘↩ 在 Finder 中显示")
            Button("⇧↩ 全部结果") { controller.showAll() }
                .buttonStyle(.link)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
        .frame(height: Self.footerHeight)
        .overlay(alignment: .top) { Divider() }
    }
}

private struct QuickSearchRow: View {
    let hit: SearchHit
    let terms: [String]
    let isSelected: Bool

    var body: some View {
        let document = hit.document
        HStack(spacing: 10) {
            ThumbnailView(document: document, size: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(Highlighter.highlight(document.name, terms: terms).attributed)
                    .lineLimit(1)
                Group {
                    if let excerpt = hit.excerpt, excerpt.hasHighlights {
                        Text(excerpt.attributed)
                    } else {
                        Text(document.location)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            Text(document.modificationDate, format: .dateTime.year().month().day())
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .padding(.horizontal, 12)
        .background(isSelected ? Color.accentColor.opacity(0.25) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 6))
        .padding(.horizontal, 6)
    }
}
