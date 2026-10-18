import SwiftUI
import AppKit

// 任务栏标签的右键菜单：内容照 macOS Dock（窗口列表 / 设定档 / 开新窗口 / 选项 / 隐藏 / 结束），
// 外观照 Windows 11 的右键菜单（圆角半透明底、每项前面有图标、行距宽、悬停整行圆角高亮）。
// NSMenu 改不了外观，所以自己画：一个主菜单浮窗 + 一个子菜单浮窗。

/// 菜单里的一项
struct TaskbarMenuItem {
    enum Kind { case item, separator, header }

    var kind: Kind = .item
    var title = ""
    /// SF Symbol；勾选项不画图标，图标栏里画勾（同 Windows 11）
    var symbol: String?
    var checked = false
    /// 淡一点的文字（最小化的窗口）
    var dimmed = false
    var children: [TaskbarMenuItem] = []
    var action: (() -> Void)?
    /// 按住 ⌥ 时换成的标题 / 动作（结束 → 强制结束，同 Dock）
    var optionTitle: String?
    var optionSymbol: String?
    var optionAction: (() -> Void)?

    var selectable: Bool { kind == .item && (action != nil || !children.isEmpty) }

    static let separator = TaskbarMenuItem(kind: .separator)
    static func header(_ title: String) -> TaskbarMenuItem { TaskbarMenuItem(kind: .header, title: title) }

    /// 去掉头尾和连续的分隔线：各段按条件可有可无，拼起来常会多出线
    static func tidy(_ items: [TaskbarMenuItem]) -> [TaskbarMenuItem] {
        var out: [TaskbarMenuItem] = []
        for item in items {
            if item.kind == .separator, out.isEmpty || out.last?.kind == .separator { continue }
            out.append(item)
        }
        while out.last?.kind == .separator { out.removeLast() }
        return out
    }
}

/// 行的命中区域上报（菜单自己的坐标系，原点上左）
private struct MenuRowFramesKey: PreferenceKey {
    static var defaultValue: [Int: CGRect] = [:]
    static func reduce(value: inout [Int: CGRect], nextValue: () -> [Int: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}

/// 一层菜单的交互状态（悬停 / 按下 / ⌥）。项目本身直接塞进 View，换项目时重设 rootView，
/// 这样 fittingSize 立刻是新尺寸，不用等 SwiftUI 下一轮刷新
@MainActor
final class TaskbarMenuModel: ObservableObject {
    @Published var highlighted: Int?
    @Published var pressed: Int?
    @Published var optionDown = false

    var items: [TaskbarMenuItem] = []
    var rowFrames: [Int: CGRect] = [:]
    /// 指针眼下所在的行（窗口层追踪）
    var pointerRow: Int?

    func index(at point: CGPoint) -> Int? {
        rowFrames.first { $0.value.contains(point) }?.key
    }

    /// 键盘上下移动：跳过分隔线和小标题，到头绕回来
    func step(_ delta: Int) {
        let candidates = items.indices.filter { items[$0].selectable }
        guard !candidates.isEmpty else { return }
        guard let current = highlighted, let pos = candidates.firstIndex(of: current) else {
            highlighted = delta > 0 ? candidates.first : candidates.last
            return
        }
        highlighted = candidates[(pos + delta + candidates.count) % candidates.count]
    }
}

struct TaskbarMenuView: View {
    static let space = "xtopbar.taskbarMenu"

    let items: [TaskbarMenuItem]
    @ObservedObject var model: TaskbarMenuModel
    @ObservedObject var prefs: Preferences

    /// 圆角跟着条的设定走（设置里的「圓角」），和条、资料夹看起来是一套
    private var radius: CGFloat { TTLayout.barCornerRadius }
    /// 行高亮和外框同心：外圆角减去行左右内缩的 4pt
    private var rowRadius: CGFloat { max(radius - TTLayout.s(4), TTLayout.s(3)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                row(index, item)
            }
        }
        .padding(.vertical, TTLayout.s(4))
        // 宽度跟内容走，但有上下限：窗口标题太长时在中间截断
        .frame(minWidth: TTLayout.s(220), maxWidth: TTLayout.s(360), alignment: .leading)
        .fixedSize()
        .background(GlassBackdrop(style: prefs.glassStyle, cornerRadius: radius))
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
        )
        .coordinateSpace(name: Self.space)
        .onPreferenceChange(MenuRowFramesKey.self) { frames in
            model.rowFrames = frames
        }
    }

    @ViewBuilder
    private func row(_ index: Int, _ item: TaskbarMenuItem) -> some View {
        switch item.kind {
        case .separator:
            Rectangle()
                .fill(Color.primary.opacity(0.10))
                .frame(height: 1)
                .padding(.vertical, TTLayout.s(4))
        case .header:
            Text(item.title)
                .font(.system(size: TTLayout.font(11.5), weight: .semibold))
                .foregroundStyle(Color.secondary)
                .lineLimit(1)
                .padding(.horizontal, TTLayout.s(16))
                .padding(.top, TTLayout.s(6))
                .padding(.bottom, TTLayout.s(3))
        case .item:
            itemRow(index, item)
        }
    }

    private func itemRow(_ index: Int, _ item: TaskbarMenuItem) -> some View {
        let alt = model.optionDown && item.optionTitle != nil
        let title = alt ? item.optionTitle ?? item.title : item.title
        let symbol = alt ? item.optionSymbol ?? item.symbol : item.symbol
        let hot = model.highlighted == index
        let fill: Double = model.pressed == index ? 0.06 : (hot ? 0.10 : 0)
        return HStack(spacing: TTLayout.s(12)) {
            Group {
                if item.checked {
                    Image(systemName: "checkmark")
                        .font(.system(size: TTLayout.font(12), weight: .semibold))
                } else if let symbol {
                    Image(systemName: symbol)
                        .font(.system(size: TTLayout.font(13)))
                }
            }
            .foregroundStyle(Color.primary.opacity(item.dimmed ? 0.5 : 0.85))
            .frame(width: TTLayout.s(16), height: TTLayout.s(16))

            Text(title)
                .font(.system(size: TTLayout.font(13)))
                .foregroundStyle(Color.primary.opacity(item.dimmed ? 0.55 : 1))
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: TTLayout.s(16))

            if !item.children.isEmpty {
                Image(systemName: "chevron.right")
                    .font(.system(size: TTLayout.font(10), weight: .semibold))
                    .foregroundStyle(Color.secondary)
            }
        }
        .padding(.horizontal, TTLayout.s(12))
        .frame(height: TTLayout.s(32))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: rowRadius, style: .continuous)
                .fill(Color.primary.opacity(fill))
        )
        .padding(.horizontal, TTLayout.s(4))
        .background(
            GeometryReader { geo in
                Color.clear.preference(key: MenuRowFramesKey.self,
                                       value: [index: geo.frame(in: .named(Self.space))])
            }
        )
    }
}

/// 悬停也在窗口层判：SwiftUI 的 onHover 在不激活的浮窗里会漏掉移动，高亮停在旧的那一行。
/// 盖在内容上面只收追踪事件，点击照常穿过去
private final class MenuHoverView: NSView {
    /// 指针位置（SwiftUI 坐标，原点上左）；移出菜单为 nil
    var onMove: ((CGPoint?) -> Void)?

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self))
    }

    private func report(_ event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        onMove?(CGPoint(x: p.x, y: bounds.height - p.y))
    }

    override func mouseMoved(with event: NSEvent) { report(event) }
    override func mouseEntered(with event: NSEvent) { report(event) }
    override func mouseExited(with event: NSEvent) { onMove?(nil) }
}

/// 主菜单 + 一层子菜单。点击、悬停都和标签条一样在窗口层做命中测试（SwiftUI 在非激活浮窗里不稳）。
/// 开着时接 key，好处理 Esc / 方向键 / 回车
@MainActor
final class TaskbarMenuController {

    private let mainModel = TaskbarMenuModel()
    private let subModel = TaskbarMenuModel()
    private let mainPanel: FloatingPanel
    private let subPanel: FloatingPanel
    private let mainHost: FirstMouseHostingView<TaskbarMenuView>
    private let subHost: FirstMouseHostingView<TaskbarMenuView>

    private var monitors: [Any] = []
    private var observers: [NSObjectProtocol] = []
    private var pendingPress: (sub: Bool, index: Int)?
    private var hoverWork: DispatchWorkItem?
    /// 子菜单是从主菜单第几项展开的
    private var subParent: Int?
    /// 键盘焦点在子菜单
    private var keyInSub = false
    private var anchor: NSRect = .zero
    private var barFrame: NSRect = .zero

    var onOpen: (() -> Void)?
    var onClose: (() -> Void)?

    var isVisible: Bool { mainPanel.isVisible }

    init() {
        mainPanel = FloatingPanel(contentRect: NSRect(x: 0, y: 0, width: 220, height: 100))
        subPanel = FloatingPanel(contentRect: NSRect(x: 0, y: 0, width: 220, height: 100))
        mainHost = FirstMouseHostingView(rootView: TaskbarMenuView(items: [], model: mainModel, prefs: .shared))
        subHost = FirstMouseHostingView(rootView: TaskbarMenuView(items: [], model: subModel, prefs: .shared))

        for (panel, host) in [(mainPanel, mainHost), (subPanel, subHost)] {
            panel.level = .popUpMenu
            panel.hasShadow = true
            panel.animationBehavior = .none
            host.frame = NSRect(origin: .zero, size: panel.frame.size)
            host.autoresizingMask = [.width, .height]
            panel.contentView = host
            panel.acceptsMouseMovedEvents = true
        }
        wire(sub: false)
        wire(sub: true)
    }

    private func panel(sub: Bool) -> FloatingPanel { sub ? subPanel : mainPanel }
    private func model(sub: Bool) -> TaskbarMenuModel { sub ? subModel : mainModel }

    private func wire(sub: Bool) {
        let panel = self.panel(sub: sub)
        let model = self.model(sub: sub)
        // 两段式点击：按下给反馈，抬起落在同一项才执行
        panel.onPress = { [weak self] location in
            guard let self else { return true }
            let index = model.index(at: self.viewPoint(location, in: panel))
            if let index, model.items[index].selectable {
                model.pressed = index
                self.pendingPress = (sub, index)
            } else {
                self.pendingPress = nil
            }
            // 菜单里的点击一律吃掉（点在分隔线 / 小标题上什么都不做，菜单也不收）
            return true
        }
        panel.onRelease = { [weak self] location in
            guard let self else { return }
            model.pressed = nil
            let index = model.index(at: self.viewPoint(location, in: panel))
            guard let pending = self.pendingPress, pending.sub == sub, pending.index == index else { return }
            self.pendingPress = nil
            self.choose(pending.index, sub: sub)
        }
        let tracker = MenuHoverView(frame: panel.contentView?.bounds ?? .zero)
        tracker.autoresizingMask = [.width, .height]
        tracker.onMove = { [weak self] point in
            guard let self else { return }
            let row = point.flatMap { model.index(at: $0) }
            guard row != model.pointerRow else { return }
            if let old = model.pointerRow { self.hoverEnd(old, sub: sub) }
            model.pointerRow = row
            if let row { self.hover(row, sub: sub) }
        }
        panel.contentView?.addSubview(tracker)
    }

    /// AppKit 窗口坐标（原点左下）→ SwiftUI 坐标（原点上左）
    private func viewPoint(_ location: NSPoint, in panel: NSPanel) -> CGPoint {
        CGPoint(x: location.x, y: panel.frame.height - location.y)
    }

    // MARK: - 开 / 关

    /// anchor：标签在屏幕上的位置；barFrame：整条的位置（决定往上还是往下弹）
    func show(items: [TaskbarMenuItem], anchor: NSRect, barFrame: NSRect) {
        if isVisible { close() }
        self.anchor = anchor
        self.barFrame = barFrame
        let optionDown = NSEvent.modifierFlags.contains(.option)
        for model in [mainModel, subModel] {
            model.highlighted = nil
            model.pressed = nil
            model.pointerRow = nil
            model.optionDown = optionDown
        }
        keyInSub = false
        subParent = nil
        let frame = setContent(TaskbarMenuItem.tidy(items), sub: false)
        let upward = DockGeometry.opensUpward(barFrame: barFrame, visible: visibleFrame(for: anchor))
        // 同 Windows 11：从条那一侧滑出来一点点
        present(mainPanel, at: frame, slide: CGSize(width: 0, height: upward ? -10 : 10))
        // 刚收起又马上打开（右键另一个标签）：交还键盘的那段时间还没过，先结束它，不然拿不到 key
        FloatingPanel.handingKeyBack = false
        mainPanel.makeKey()
        installMonitors()
        onOpen?()
    }

    /// 菜单开着时换内容（窗口列表现查回来了）。子菜单开着就不动，免得行在指针下面跳
    func update(items: [TaskbarMenuItem]) {
        guard isVisible, !subPanel.isVisible else { return }
        mainModel.highlighted = nil
        mainModel.pressed = nil
        mainModel.pointerRow = nil
        pendingPress = nil
        let frame = setContent(TaskbarMenuItem.tidy(items), sub: false)
        mainPanel.setFrame(frame, display: true)
    }

    func close() {
        guard mainPanel.isVisible else { return }
        removeMonitors()
        hoverWork?.cancel()
        pendingPress = nil
        closeSub()
        mainPanel.orderOutHandingKeyBack()
        onClose?()
    }

    /// 换上项目、量尺寸，返回主菜单（或调用方再挪的子菜单）该摆的位置
    @discardableResult
    private func setContent(_ items: [TaskbarMenuItem], sub: Bool) -> NSRect {
        let model = self.model(sub: sub)
        let host = sub ? subHost : mainHost
        model.items = items
        // 不清 rowFrames：换内容后行的位置要是没变，SwiftUI 不会再报一次，清掉就再也点不中了。
        // 位置变了它自然会报新的
        host.rootView = TaskbarMenuView(items: items, model: model, prefs: .shared)
        host.layoutSubtreeIfNeeded()
        let size = host.fittingSize
        return DockGeometry.popupFrame(size: size, anchorX: anchor.midX, alignLeft: false,
                                       barFrame: barFrame, visible: visibleFrame(for: anchor),
                                       gap: TTLayout.s(6))
    }

    private func visibleFrame(for rect: NSRect) -> NSRect {
        let screen = NSScreen.screens.first { $0.frame.intersects(rect) } ?? NSScreen.main
        return screen?.visibleFrame ?? rect
    }

    private func present(_ panel: FloatingPanel, at frame: NSRect, slide: CGSize) {
        let animated = Preferences.shared.animationsEnabled
            && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        guard animated else {
            panel.alphaValue = 1
            panel.setFrame(frame, display: true)
            panel.orderFrontRegardless()
            return
        }
        panel.alphaValue = 0
        panel.setFrame(frame.offsetBy(dx: slide.width, dy: slide.height), display: true)
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.16
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.1, 0.9, 0.2, 1)
            panel.animator().alphaValue = 1
            panel.animator().setFrame(frame, display: true)
        }
    }

    // MARK: - 子菜单

    private func openSub(for index: Int) {
        guard mainModel.items.indices.contains(index) else { return }
        let item = mainModel.items[index]
        guard !item.children.isEmpty else { return }
        if subParent == index, subPanel.isVisible { return }
        guard let row = mainModel.rowFrames[index] else { return }
        subParent = index
        subModel.highlighted = nil
        subModel.pressed = nil
        subModel.pointerRow = nil
        setContent(item.children, sub: true)
        let size = subHost.fittingSize
        let main = mainPanel.frame
        let visible = visibleFrame(for: main)
        let rowTop = main.maxY - row.minY
        // 子菜单第一行和父项对齐（扣掉菜单上下的内边距）
        var y = rowTop + TTLayout.s(4) - size.height
        y = max(visible.minY + 4, min(y, visible.maxY - size.height - 4))
        // 默认往右，右边放不下就往左
        var x = main.maxX + TTLayout.s(2)
        var slide = -6.0
        if x + size.width > visible.maxX - 4 {
            x = main.minX - TTLayout.s(2) - size.width
            slide = 6
        }
        present(subPanel, at: NSRect(x: x, y: y, width: size.width, height: size.height),
                slide: CGSize(width: slide, height: 0))
    }

    private func closeSub() {
        subParent = nil
        keyInSub = false
        subModel.highlighted = nil
        subModel.pressed = nil
        subModel.pointerRow = nil
        if subPanel.isVisible { subPanel.orderOut(nil) }
    }

    // MARK: - 悬停

    private func hover(_ index: Int, sub: Bool) {
        let model = self.model(sub: sub)
        guard model.items.indices.contains(index), model.items[index].selectable else { return }
        hoverWork?.cancel()
        model.highlighted = index
        if sub {
            keyInSub = true
            mainModel.highlighted = subParent
            return
        }
        keyInSub = false
        let item = mainModel.items[index]
        // 悬停一小会儿再开 / 关子菜单：指针斜着划过别的行去子菜单时不会被半路收掉
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.isVisible else { return }
            if !item.children.isEmpty {
                self.openSub(for: index)
            } else if self.subPanel.isVisible {
                self.closeSub()
            }
        }
        hoverWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (item.children.isEmpty ? 0.25 : 0.12), execute: work)
    }

    private func hoverEnd(_ index: Int, sub: Bool) {
        let model = self.model(sub: sub)
        guard model.highlighted == index else { return }
        // 父项在子菜单开着时保持高亮（同 Windows 11）
        if !sub, subParent == index, subPanel.isVisible { return }
        model.highlighted = nil
    }

    // MARK: - 执行

    private func choose(_ index: Int, sub: Bool) {
        let model = self.model(sub: sub)
        guard model.items.indices.contains(index) else { return }
        let item = model.items[index]
        if !item.children.isEmpty {
            hoverWork?.cancel()
            openSub(for: index)
            return
        }
        let action = model.optionDown ? item.optionAction ?? item.action : item.action
        close()
        // 菜单先收掉再做事：动作可能会激活别的 App / 改固定列表
        DispatchQueue.main.async { action?() }
    }

    // MARK: - 键盘 / 点外面收起

    private func installMonitors() {
        removeMonitors()

        if let m = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            let swallow = MainActor.assumeIsolated { () -> Bool in
                guard let self else { return false }
                return self.handleKey(event.keyCode)
            }
            return swallow ? nil : event
        }) { monitors.append(m) }

        // ⌥ 按下 / 放开：结束 ⇄ 强制结束
        let flags: (NSEvent) -> Void = { [weak self] event in
            let down = event.modifierFlags.contains(.option)
            DispatchQueue.main.async {
                guard let self else { return }
                if self.mainModel.optionDown != down {
                    self.mainModel.optionDown = down
                    self.subModel.optionDown = down
                }
            }
        }
        if let m = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged, handler: { event in
            flags(event)
            return event
        }) { monitors.append(m) }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged, handler: flags) {
            monitors.append(m)
        }

        // 点到自己 App 的其它窗口（条、预览…）：收起，事件照常往下传（右键别的标签就接着开它的菜单）
        if let m = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown], handler: { [weak self] event in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if event.window !== self.mainPanel, event.window !== self.subPanel { self.close() }
                }
                return event
            }) { monitors.append(m) }

        // 点到别的 App（桌面、其它窗口）
        if let m = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown], handler: { [weak self] _ in
                DispatchQueue.main.async { self?.close() }
            }) { monitors.append(m) }

        let ws = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didActivateApplicationNotification, NSWorkspace.activeSpaceDidChangeNotification] {
            observers.append(ws.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.close() }
            })
        }
        // key 被别的窗口拿走（⌘Tab 之类）。转给子菜单不算
        observers.append(NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: mainPanel, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let key = NSApp.keyWindow
                if key !== self.mainPanel, key !== self.subPanel { self.close() }
            }
        })
    }

    private func removeMonitors() {
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors.removeAll()
        observers.forEach {
            NotificationCenter.default.removeObserver($0)
            NSWorkspace.shared.notificationCenter.removeObserver($0)
        }
        observers.removeAll()
    }

    /// 返回 true = 吃掉这个按键
    private func handleKey(_ keyCode: UInt16) -> Bool {
        guard isVisible else { return false }
        let model = self.model(sub: keyInSub)
        switch keyCode {
        case 53: // Esc：先收子菜单，再收整个
            if subPanel.isVisible {
                let parent = subParent
                closeSub()
                mainModel.highlighted = parent
            } else {
                close()
            }
        case 125: model.step(1)   // ↓
        case 126: model.step(-1)  // ↑
        case 124: // →：展开子菜单并进去
            if !keyInSub, let index = mainModel.highlighted, !mainModel.items[index].children.isEmpty {
                enterSub(index)
            }
        case 123: // ←：退回主菜单
            if keyInSub {
                let parent = subParent
                closeSub()
                mainModel.highlighted = parent
            }
        case 36, 76, 49: // 回车 / 空格
            guard let index = model.highlighted else { return true }
            if !keyInSub, !mainModel.items[index].children.isEmpty {
                enterSub(index)
            } else {
                choose(index, sub: keyInSub)
            }
        default:
            return false
        }
        return true
    }

    private func enterSub(_ index: Int) {
        hoverWork?.cancel()
        openSub(for: index)
        keyInSub = true
        subModel.highlighted = nil
        subModel.step(1)
    }
}
