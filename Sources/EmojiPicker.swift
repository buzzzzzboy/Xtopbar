import AppKit
import SwiftUI

/// 选择器左边栏的分类：同 macOS「字元檢視器」——常用項目、喜好項目、表情符號（再分 8 类）、各种特殊符號
enum PickerCategory: Hashable {
    case frequent
    case favorites
    case emoji(EmojiCategory)
    case symbol(SymbolCategory)

    /// Tab / ⇧Tab 依次走过的顺序（和画面上从上到下一致）
    static let order: [PickerCategory] =
        [.frequent, .favorites] + EmojiCategory.allCases.map { .emoji($0) } + SymbolCategory.allCases.map { .symbol($0) }

    var title: String {
        switch self {
        case .frequent:          return "常用項目"
        case .favorites:         return "喜好項目"
        case .emoji(let c):      return c.title
        case .symbol(let c):     return c.title
        }
    }

    var isEmoji: Bool {
        if case .emoji = self { return true }
        return false
    }

    /// 存 UserDefaults 用：下次打开回到上次看的分类
    var key: String {
        switch self {
        case .frequent:          return "frequent"
        case .favorites:         return "favorites"
        case .emoji(let c):      return "emoji.\(c.rawValue)"
        case .symbol(let c):     return "symbol.\(c.rawValue)"
        }
    }

    init?(key: String) {
        guard let match = Self.order.first(where: { $0.key == key }) else { return nil }
        self = match
    }
}

/// 选择器的尺寸：网格列数按宽度算死，键盘上下移动要用
enum EmojiPickerLayout {
    static let size = CGSize(width: 860, height: 520)
    static let sidebarWidth: CGFloat = 178
    static let subcolumnWidth: CGFloat = 168
    static let cell: CGFloat = 52
    static let spacing: CGFloat = 4
    static let gridPadding: CGFloat = 10

    static func columns(subcolumn: Bool) -> Int {
        let width = size.width - sidebarWidth - (subcolumn ? subcolumnWidth : 0) - gridPadding * 2
        return max(Int((width + spacing) / (cell + spacing)), 1)
    }
}

/// 表情符號選擇器的界面状态：搜索词、当前分类、键盘选中项，以及按这些算出来的网格
@MainActor
final class EmojiPickerModel: ObservableObject {

    struct Section: Identifiable {
        let id: String
        let title: String
        let items: [Emoji]
        /// 这一区第一个格子在整个网格里的下标
        let start: Int
    }

    enum Move { case left, right, up, down }

    @Published var query = "" {
        didSet { if query != oldValue { rebuild(resetSelection: true) } }
    }
    @Published var category: PickerCategory = .emoji(.smileysPeople) {
        didSet {
            guard category != oldValue else { return }
            if case .emoji(let c) = category { lastEmoji = c }
            UserDefaults.standard.set(category.key, forKey: Self.categoryKey)
            rebuild(resetSelection: true)
        }
    }
    /// 左边栏点「表情符號」时回到的那一类
    private(set) var lastEmoji: EmojiCategory = .smileysPeople
    @Published var selection = 0
    @Published private(set) var sections: [Section] = []
    /// 网格内容的身份：换分类 / 换搜索词时整块换掉（不逐格比对上千个格子，也顺便滚回顶部）
    @Published private(set) var contentID = 0
    /// 键盘移动后要滚到的格子 / 区头（视图据此 scrollTo）。带序号：滚到同一个目标也要再滚一次
    struct ScrollRequest: Equatable {
        var id: String
        var serial: Int
    }
    @Published private(set) var scrollRequest: ScrollRequest?
    /// 每次打开 +1，视图据此把焦点放回搜索框
    @Published private(set) var focusToken = 0
    /// 打开时在前台的 App（↵ 贴到它里面）
    @Published private(set) var targetApp: String?
    /// 有「辅助使用」权限才能模拟 ⌘V 贴上；没有就只拷贝
    @Published private(set) var canPaste = false

    private(set) var flat: [Emoji] = []
    /// 刚用键盘移动过：这段时间里鼠标"悬停"多半是内容滚到了指针底下，不算数
    private var lastKeyMove = Date.distantPast
    /// 打开时的鼠标位置：面板正好弹在指针底下时，指针没动过就不算悬停（不然一打开选中项就跳走）
    private var mouseAtOpen: NSPoint?

    private static let categoryKey = "emojiPickerCategory"

    init() {
        if let saved = UserDefaults.standard.string(forKey: Self.categoryKey),
           let c = PickerCategory(key: saved) {
            category = c
            if case .emoji(let e) = c { lastEmoji = e }
        }
    }

    var selected: Emoji? { flat.indices.contains(selection) ? flat[selection] : nil }
    var isSearching: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }
    /// 第二栏（表情的 8 个分类）显示与否；搜索时收起，网格变宽
    var showsSubcolumn: Bool { category.isEmoji && !isSearching }
    var columns: Int { EmojiPickerLayout.columns(subcolumn: showsSubcolumn) }

    func reset(targetApp: String?, canPaste: Bool) {
        self.targetApp = targetApp
        self.canPaste = canPaste
        mouseAtOpen = NSEvent.mouseLocation
        query = ""
        // 上次停在「常用項目」但还没有记录：直接看表情
        if category == .frequent, EmojiStore.shared.history.isEmpty { category = .emoji(lastEmoji) }
        rebuild(resetSelection: true)
        focusToken &+= 1
    }

    func rebuild(resetSelection: Bool = false) {
        let store = EmojiStore.shared
        var list: [(id: String, title: String, items: [Emoji])] = []
        if isSearching {
            list.append(("results", "搜尋結果", store.search(query)))
        } else {
            switch category {
            case .frequent:
                list.append(("frequent", "常用項目", store.frequent(limit: columns * 6)))
            case .favorites:
                list.append(("favorites", "喜好項目", store.pinned))
            case .emoji(let c):
                list.append((c.rawValue, c.title, store.byCategory[c] ?? []))
            case .symbol(let c):
                for (i, section) in (SymbolLibrary.shared.sections[c] ?? []).enumerated() {
                    list.append(("\(c.rawValue)-\(i)", section.title ?? c.title, section.items))
                }
            }
        }

        var start = 0
        sections = list.filter { !$0.items.isEmpty }.map { s in
            defer { start += s.items.count }
            return Section(id: s.id, title: s.title, items: s.items, start: start)
        }
        flat = sections.flatMap(\.items)
        if resetSelection {
            selection = 0
            contentID &+= 1
        } else {
            selection = min(selection, max(flat.count - 1, 0))
        }
    }

    // MARK: - 键盘 / 鼠标选中

    func move(_ direction: Move) {
        guard !flat.isEmpty, let loc = locate(selection) else { return }
        let (s, i) = (loc.section, loc.offset)
        let cols = columns
        let section = sections[s]
        var target = selection
        switch direction {
        case .left:
            target = max(selection - 1, 0)
        case .right:
            target = min(selection + 1, flat.count - 1)
        case .down:
            if i + cols < section.items.count {
                target = selection + cols
            } else if i / cols < (section.items.count - 1) / cols {
                // 下面还有一行但不满：落到那行最后一个
                target = section.start + section.items.count - 1
            } else if s + 1 < sections.count {
                let next = sections[s + 1]
                target = next.start + min(i % cols, next.items.count - 1)
            }
        case .up:
            if i >= cols {
                target = selection - cols
            } else if s > 0 {
                let prev = sections[s - 1]
                let lastRow = (prev.items.count - 1) / cols * cols
                target = prev.start + min(lastRow + i % cols, prev.items.count - 1)
            }
        }
        selection = target
        lastKeyMove = Date()
        // 选到一区的第一行时连区头一起露出来
        if let loc = locate(target) {
            requestScroll(loc.offset < cols ? Self.headerID(sections[loc.section])
                                            : Self.cellID(sections[loc.section], flat[target]))
        }
    }

    func hover(_ index: Int) {
        guard Date().timeIntervalSince(lastKeyMove) > 0.4 else { return }
        if let start = mouseAtOpen {
            guard hypot(NSEvent.mouseLocation.x - start.x, NSEvent.mouseLocation.y - start.y) > 2 else { return }
            mouseAtOpen = nil
        }
        if selection != index { selection = index }
    }

    /// Tab / ⇧Tab：按左边栏从上到下换分类（搜索中按 Tab 就清掉搜索词回到分类）
    func cycleCategory(forward: Bool) {
        if isSearching { query = ""; return }
        let order = PickerCategory.order
        let i = order.firstIndex(of: category) ?? 0
        category = order[(i + (forward ? 1 : order.count - 1)) % order.count]
    }

    private func requestScroll(_ id: String) {
        scrollRequest = ScrollRequest(id: id, serial: (scrollRequest?.serial ?? 0) &+ 1)
    }

    /// 第 index 个格子在哪一区、区里第几个
    private func locate(_ index: Int) -> (section: Int, offset: Int)? {
        guard let s = sections.lastIndex(where: { $0.start <= index }) else { return nil }
        return (s, index - sections[s].start)
    }

    static func cellID(_ section: Section, _ emoji: Emoji) -> String { "\(section.id)|\(emoji.base)" }
    static func headerID(_ section: Section) -> String { "header|\(section.id)" }
}

/// 表情符號選擇器浮层：在鼠标所在屏幕的中间偏上弹出（同 Raycast），
/// 不跟悬浮条走。面板是 nonactivating 的：能打字，但前台 App 不失焦，
/// 所以 ↵ 关掉面板后模拟 ⌘V 就贴进原来那个 App 里
@MainActor
final class EmojiPickerController {
    static let shared = EmojiPickerController()

    static var size: CGSize { EmojiPickerLayout.size }

    private let model = EmojiPickerModel()
    private let panel: FloatingPanel
    private var monitors: [Any] = []
    private var resignObserver: NSObjectProtocol?
    /// 每次开 / 关 +1：淡出播完时若已被重新打开，就别再 orderOut
    private var animationToken = 0

    var isVisible: Bool { panel.isVisible && !closing }
    private var closing = false

    /// 启动后在空闲时先把资料读好、界面建好，第一次按快捷键就能马上弹出来
    static func warmUp() {
        _ = EmojiStore.shared.byCategory
        _ = SymbolLibrary.shared.all
        _ = EmojiStore.shared.pinned
        let controller = shared
        controller.model.rebuild(resetSelection: true)
        controller.panel.contentView?.layoutSubtreeIfNeeded()
    }

    private init() {
        panel = FloatingPanel(contentRect: NSRect(origin: .zero, size: Self.size))
        // 比开始菜单再高一层
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 2)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        let view = EmojiPickerView(
            model: model,
            store: .shared,
            prefs: .shared,
            onPick: { [weak self] emoji, paste in self?.commit(emoji, paste: paste) }
        )
        let host = FirstMouseHostingView(rootView: view)
        host.frame = NSRect(origin: .zero, size: Self.size)
        host.autoresizingMask = [.width, .height]
        panel.contentView = host
    }

    func toggle() {
        isVisible ? close() : show()
    }

    func show() {
        // 刚收起又马上打开（连按两下 ⌥ 开关两次）：交还键盘的那段时间还没过，先结束它，不然面板拿不到 key
        FloatingPanel.handingKeyBack = false
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
            ?? NSScreen.main ?? NSScreen.screens[0]
        let visible = screen.visibleFrame
        // 中间偏上：上下留白 2 : 3，和 Raycast / Spotlight 的位置差不多
        let origin = NSPoint(x: visible.midX - Self.size.width / 2,
                             y: visible.minY + (visible.height - Self.size.height) * 0.6)
        panel.setFrame(NSRect(origin: origin, size: Self.size), display: false)

        // Xtopbar 是 accessory App、面板不激活它，所以这时的前台 App 就是用户正在用的那个
        let front = NSWorkspace.shared.frontmostApplication
        let target = front?.processIdentifier == ProcessInfo.processInfo.processIdentifier ? nil : front?.localizedName
        model.reset(targetApp: target, canPaste: AXIsProcessTrusted())

        animationToken &+= 1
        closing = false
        panel.ignoresMouseEvents = false
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if !panel.isVisible { panel.alphaValue = 0 }
        panel.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = reduceMotion ? 0 : 0.1
            panel.animator().alphaValue = 1
        }
        installMonitors()
        TTLog("emojiPicker show screen=\(screen.frame) target=\(target ?? "-") ax=\(model.canPaste)")
    }

    /// - Parameter animated: 贴上时传 false —— 要立刻把键盘交回原来的 App 再按 ⌘V
    func close(animated: Bool = true) {
        guard panel.isVisible, !closing || !animated else { return }
        removeMonitors()
        closing = true
        animationToken &+= 1
        let token = animationToken
        panel.ignoresMouseEvents = true
        guard animated, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            finishClose()
            return
        }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.1
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.animationToken == token else { return }
                self.finishClose()
            }
        })
    }

    private func finishClose() {
        closing = false
        // 收起时键盘交还前台 App（见 FloatingPanel.handingKeyBack）
        FloatingPanel.handingKeyBack = true
        panel.orderOut(nil)
        panel.alphaValue = 0
        panel.ignoresMouseEvents = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { FloatingPanel.handingKeyBack = false }
    }

    // MARK: - 贴上 / 拷贝

    /// - Parameter paste: true = 贴进原来的 App（模拟 ⌘V，之后把剪贴板换回原来的内容）；
    ///   false = 只拷贝到剪贴板
    private func commit(_ emoji: Emoji, paste: Bool) {
        let store = EmojiStore.shared
        let text = emoji.glyph(tone: emoji.supportsTone ? store.tone : 0)
        store.recordUse(emoji)
        let pb = NSPasteboard.general
        let pasting = paste && model.canPaste
        let saved = pasting ? Self.snapshot(pb) : []
        pb.clearContents()
        pb.setString(text, forType: .string)
        if pasting {
            // 告诉剪贴板管理器（Raycast、Maccy…）这是临时内容，别记进历史
            pb.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
        }
        let ours = pb.changeCount
        close(animated: !pasting)
        TTLog("emojiPicker \(pasting ? "paste" : "copy") \(text)")
        guard pasting else { return }

        // 等键盘回到原来的 App 再按 ⌘V
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            Self.postCommandV()
            // 目标 App 读完剪贴板后换回原来的内容；期间用户又拷贝了别的就不动
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                guard pb.changeCount == ours else { return }
                pb.clearContents()
                if !saved.isEmpty { pb.writeObjects(saved) }
            }
        }
    }

    private static func snapshot(_ pb: NSPasteboard) -> [NSPasteboardItem] {
        (pb.pasteboardItems ?? []).map { item in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) { copy.setData(data, forType: type) }
            }
            return copy
        }
    }

    private static func postCommandV() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let vKey: CGKeyCode = 9
        for down in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: down)
            event?.flags = .maskCommand
            event?.post(tap: .cghidEventTap)
        }
    }

    // MARK: - 键盘 / 点外面收起（同开始菜单）

    private func installMonitors() {
        removeMonitors()

        if let m = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            let swallow = MainActor.assumeIsolated { () -> Bool in
                guard let self, event.window === self.panel else { return false }
                return self.handleKey(event)
            }
            return swallow ? nil : event
        }) { monitors.append(m) }

        // 点到自己 App 的其它窗口（右键菜单除外）
        if let m = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] event in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    let isMenu = (event.window?.level.rawValue ?? 0) >= NSWindow.Level.popUpMenu.rawValue
                    if event.window !== self.panel, !isMenu { self.close() }
                }
                return event
            }) { monitors.append(m) }

        // 点到别的 App
        if let m = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] _ in
                DispatchQueue.main.async { self?.close() }
            }) { monitors.append(m) }

        // 焦点被别的窗口拿走（⌘Tab 到别处、开始菜单打开…）
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: panel, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        }
    }

    private func removeMonitors() {
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors.removeAll()
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        resignObserver = nil
    }

    /// 返回 true = 吃掉这个按键
    private func handleKey(_ event: NSEvent) -> Bool {
        guard panel.isVisible else { return false }
        // 输入法正在组字（注音 / 拼音候选还没确认）：按键全归输入法
        if let editor = panel.firstResponder as? NSTextView, editor.hasMarkedText() { return false }
        let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
        switch event.keyCode {
        case 53: // Esc：先清搜索词，再收起
            if !model.query.isEmpty { model.query = "" } else { close() }
            return true
        case 123 where flags.isEmpty: model.move(.left); return true
        case 124 where flags.isEmpty: model.move(.right); return true
        case 125 where flags.isEmpty: model.move(.down); return true
        case 126 where flags.isEmpty: model.move(.up); return true
        case 36, 76: // ↵ 贴上；⌘↵ 只拷贝
            guard let emoji = model.selected else { return true }
            commit(emoji, paste: !flags.contains(.command))
            return true
        case 48: // Tab / ⇧Tab：换分类
            model.cycleCategory(forward: !flags.contains(.shift))
            return true
        case 35 where flags == [.command, .shift]: // ⌘⇧P：加入 / 移除喜好項目
            if let emoji = model.selected {
                EmojiStore.shared.togglePin(emoji)
                model.rebuild()
            }
            return true
        default:
            return false
        }
    }
}

// MARK: - 视图

struct EmojiPickerView: View {
    @ObservedObject var model: EmojiPickerModel
    @ObservedObject var store: EmojiStore
    @ObservedObject var prefs: Preferences
    let onPick: (Emoji, Bool) -> Void

    @FocusState private var searchFocused: Bool

    private let corner: CGFloat = 14
    private typealias L = EmojiPickerLayout

    var body: some View {
        VStack(spacing: 0) {
            searchBar
            Divider().opacity(0.6)
            HStack(spacing: 0) {
                sidebar
                Divider().opacity(0.6)
                if model.showsSubcolumn {
                    subcolumn
                    Divider().opacity(0.6)
                }
                grid
            }
            Divider().opacity(0.6)
            actionBar
        }
        .frame(width: L.size.width, height: L.size.height)
        .background(GlassBackdrop(style: prefs.glassStyle, cornerRadius: corner))
        .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: corner, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.5)
        )
        .onAppear { searchFocused = true }
        .onChange(of: model.focusToken) { _, _ in
            // 下一拍再聚焦：面板刚 makeKey，同一拍里设焦点有时不生效
            DispatchQueue.main.async { searchFocused = true }
        }
    }

    // MARK: 搜索栏

    private var searchBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
            TextField("搜尋表情符號與符號…", text: $model.query)
                .textFieldStyle(.plain)
                .font(.system(size: 17))
                .focused($searchFocused)
            if !model.query.isEmpty {
                Button { model.query = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("清除")
            }
            toneMenu
        }
        .padding(.horizontal, 18)
        .frame(height: 52)
    }

    private var toneMenu: some View {
        Menu {
            toneButtons
        } label: {
            HStack(spacing: 3) {
                Text(EmojiTone.swatches[store.tone]).font(.system(size: 14))
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold))
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(Capsule().fill(Color.primary.opacity(0.08)))
            .contentShape(Capsule())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("膚色")
    }

    // MARK: 左边栏 / 表情分类栏

    private var sidebar: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 1) {
                sidebarRow(PickerCategory.frequent, title: "常用項目", icon: .system("clock"))
                sidebarRow(PickerCategory.favorites, title: "喜好項目", icon: .system("star.fill"))
                sidebarRow(PickerCategory.emoji(model.lastEmoji), title: "表情符號", icon: .system("face.smiling"),
                           selected: model.category.isEmoji)
                ForEach(SymbolCategory.allCases) { c in
                    sidebarRow(PickerCategory.symbol(c), title: c.title, icon: .glyph(c.icon))
                }
            }
            .padding(8)
        }
        .frame(width: L.sidebarWidth)
    }

    private var subcolumn: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 1) {
                ForEach(EmojiCategory.allCases) { c in
                    sidebarRow(PickerCategory.emoji(c), title: c.title, icon: .system(c.symbol))
                }
            }
            .padding(8)
        }
        .frame(width: L.subcolumnWidth)
    }

    private enum RowIcon {
        case system(String)
        case glyph(String)
    }

    private func sidebarRow(_ category: PickerCategory, title: String, icon: RowIcon,
                            selected: Bool? = nil) -> some View {
        let isSelected = !model.isSearching && (selected ?? (model.category == category))
        return Button {
            model.query = ""
            model.category = category
            searchFocused = true
        } label: {
            HStack(spacing: 8) {
                Group {
                    switch icon {
                    case .system(let name): Image(systemName: name).font(.system(size: 13))
                    case .glyph(let g):     Text(g).font(.system(size: 14))
                    }
                }
                .frame(width: 20)
                .foregroundStyle(.secondary)
                Text(title)
                    .font(.system(size: 12.5))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .frame(height: 28)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(isSelected ? Color.accentColor.opacity(0.22) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: 网格

    private var grid: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: true) {
                if model.sections.isEmpty {
                    emptyState
                } else {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: L.spacing),
                                             count: model.columns),
                              alignment: .leading, spacing: L.spacing) {
                        ForEach(model.sections) { section in
                            Section {
                                ForEach(section.items.indices, id: \.self) { offset in
                                    cell(section.items[offset], index: section.start + offset, section: section)
                                }
                            } header: {
                                Text(section.title)
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.leading, 4)
                                    .padding(.top, section.start == 0 ? 0 : 8)
                                    .id(EmojiPickerModel.headerID(section))
                            }
                        }
                    }
                    .padding(L.gridPadding)
                }
            }
            // 换分类 / 搜索词时整块换新：不去逐格比对旧网格，滚动位置也回到顶部
            .id(model.contentID)
            .onChange(of: model.scrollRequest) { _, request in
                if let request { proxy.scrollTo(request.id) }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func cell(_ emoji: Emoji, index: Int, section: EmojiPickerModel.Section) -> some View {
        // 用 Button 不用 onTapGesture：非激活浮层里 tap 手势命中不稳定（见 FloatingPanel）
        Button { onPick(emoji, true) } label: {
            EmojiCell(glyph: emoji.glyph(tone: emoji.supportsTone ? store.tone : 0),
                      isEmoji: emoji.group != nil,
                      selected: model.selection == index)
                .equatable()
        }
        .buttonStyle(.plain)
        .onHover { if $0 { model.hover(index) } }
            .contextMenu { menu(for: emoji) }
            .id(EmojiPickerModel.cellID(section, emoji))
    }

    @ViewBuilder
    private func menu(for emoji: Emoji) -> some View {
        Button(model.canPaste ? "貼上" : "拷貝") { onPick(emoji, model.canPaste) }
        if model.canPaste {
            Button("拷貝到剪貼簿") { onPick(emoji, false) }
        }
        Divider()
        Button(store.isPinned(emoji) ? "從喜好項目移除" : "加入喜好項目") {
            store.togglePin(emoji)
            model.rebuild()
        }
        if store.history[emoji.base] != nil {
            Button("從常用項目移除") {
                store.forget(emoji)
                model.rebuild()
            }
        }
        if emoji.supportsTone {
            Divider()
            toneButtons
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        VStack(spacing: 8) {
            if model.isSearching {
                Text("🔍").font(.system(size: 34))
                Text("找不到「\(model.query)」相關的表情符號或符號")
            } else if model.category == .favorites {
                Image(systemName: "star").font(.system(size: 28)).foregroundStyle(.secondary)
                Text("還沒有喜好項目。右鍵任一字元 →「加入喜好項目」，或按 ⌘⇧P。")
            } else {
                Image(systemName: "clock").font(.system(size: 28)).foregroundStyle(.secondary)
                Text("用過的表情符號和符號會出現在這裡。")
            }
        }
        .font(.system(size: 13))
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        .padding(.top, 120)
        .padding(.horizontal, 24)
    }

    // MARK: 底栏

    private var actionBar: some View {
        HStack(spacing: 10) {
            if let emoji = model.selected {
                Text(emoji.glyph(tone: emoji.supportsTone ? store.tone : 0))
                    .font(.system(size: 18))
                Text(emoji.name)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if store.isPinned(emoji) {
                    Image(systemName: "star.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            if let emoji = model.selected {
                if model.canPaste {
                    actionButton("拷貝", keys: ["⌘", "↵"]) { onPick(emoji, false) }
                    actionButton(model.targetApp.map { "貼上到「\($0)」" } ?? "貼上", keys: ["↵"]) {
                        onPick(emoji, true)
                    }
                } else {
                    actionButton("拷貝", keys: ["↵"]) { onPick(emoji, false) }
                        .help("要直接貼上，請在「系統設定 › 隱私權與安全性 › 輔助使用」允許 Xtopbar")
                }
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 44)
        .background(Color.primary.opacity(0.05))
    }

    @ViewBuilder
    private var toneButtons: some View {
        ForEach(0..<EmojiTone.count, id: \.self) { i in
            Button {
                store.tone = i
            } label: {
                Text("\(EmojiTone.swatches[i])  \(EmojiTone.titles[i])\(store.tone == i ? "  ✓" : "")")
            }
        }
    }

    private func actionButton(_ title: String, keys: [String], action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(title)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                HStack(spacing: 2) {
                    ForEach(keys, id: \.self) { key in
                        Text(key)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.secondary)
                            .frame(minWidth: 18, minHeight: 16)
                            .background(
                                RoundedRectangle(cornerRadius: 4, style: .continuous)
                                    .fill(Color.primary.opacity(0.10))
                            )
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Capsule().fill(Color.primary.opacity(0.08)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// 网格里的一格。Equatable：选中项变了只重画新旧两格，不用整个网格重算
private struct EmojiCell: View, Equatable {
    let glyph: String
    let isEmoji: Bool
    let selected: Bool

    var body: some View {
        Text(glyph)
            .font(.system(size: isEmoji ? 30 : 24))
            .lineLimit(1)
            .minimumScaleFactor(0.5)
            .frame(maxWidth: .infinity)
            .frame(height: EmojiPickerLayout.cell)
            .background {
                if selected {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(Color.accentColor.opacity(0.28))
                }
            }
            .contentShape(Rectangle())
    }
}
