import AppKit
import SwiftUI

/// 「背景執行」资料夹：在跑、但一扇窗口都没有的 App 不上条，收进一个跟在条尾巴后面的独立小方块。
///
/// 只在「只顯示有視窗的 App」关着时出现（开着时这些 App 直接不显示）。
/// 小方块画 2×2 迷你图标 + 数字，点一下往条外侧弹出图标网格；网格里点一个 = 激活它
/// （多数 App 会顺势重开一扇窗口，有了窗口下一轮采集就自己回到条上），右键可结束。
///
/// 它是独立窗口，不在条的 SwiftUI 里：条的宽度、命中区域、拖动排序都不受影响。
/// 显示 / 收起 / 透明度由 `TabBarController` 跟着条一起驱动。
@MainActor
final class BackgroundFolderController {

    /// 网格开没开（小方块据此画按下态）
    final class State: ObservableObject {
        @Published var open = false
    }

    private let catalog: AppCatalog
    private let state = State()
    private let chip: FloatingPanel
    private let popup: FloatingPanel
    private var popupHost: FirstMouseHostingView<BackgroundFolderGrid>?
    private var monitors: [Any] = []
    /// 每次出场 / 离场 +1：离场动画播完时若已重新出场，就别再 orderOut
    private var visibilityToken = 0
    private var resignObserver: NSObjectProtocol?

    /// 网格收起时回调（条据此重新计自动隐藏）
    var onClose: (@MainActor () -> Void)?
    /// 网格要打开了（条据此收掉预览、开始菜单）
    var onOpen: (@MainActor () -> Void)?

    /// 条和小方块之间的间隙
    static var gap: CGFloat { TTLayout.s(6) }
    /// 小方块边长 = 条高（同高的方块，看起来是条的一截尾巴）
    static var side: CGFloat { TTLayout.barHeight }
    /// 条要给小方块让出的宽度
    static var tailWidth: CGFloat { side + gap }

    init(catalog: AppCatalog) {
        self.catalog = catalog
        chip = FloatingPanel(contentRect: NSRect(x: 0, y: 0, width: 42, height: 42))
        // 和条同一层
        chip.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.dockWindow)) - 1)
        popup = FloatingPanel(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100))
        // 同开始菜单：比条高一层，阴影压在条上
        popup.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)

        let chipHost = FirstMouseHostingView(rootView: BackgroundFolderChip(
            catalog: catalog, prefs: Preferences.shared, state: state))
        chipHost.autoresizingMask = [.width, .height]
        chip.contentView = chipHost
        // 左键在窗口层截走（同条的标签），右键落到 SwiftUI 的 contextMenu
        chip.onTap = { [weak self] _ in
            self?.toggle()
            return true
        }

        let grid = BackgroundFolderGrid(
            catalog: catalog,
            onOpen: { [weak self] entry in
                self?.close()
                self?.catalog.activate(entry)
            })
        let host = FirstMouseHostingView(rootView: grid)
        host.autoresizingMask = [.width, .height]
        popup.contentView = host
        popupHost = host
    }

    /// 有没有要收的 App（没有就整个不显示）
    var hasApps: Bool { !catalog.backgroundApps.isEmpty }
    var isChipVisible: Bool { chip.isVisible }
    var isOpen: Bool { popup.isVisible }

    /// 指针在小方块或网格上（条据此不自动收起）
    func contains(_ point: NSPoint) -> Bool {
        (chip.isVisible && chip.frame.insetBy(dx: -1, dy: -1).contains(point))
            || (popup.isVisible && popup.frame.insetBy(dx: -1, dy: -1).contains(point))
    }

    /// 小方块贴在条的右边
    static func chipFrame(barFrame: NSRect) -> NSRect {
        NSRect(x: barFrame.maxX + gap, y: barFrame.minY, width: side, height: barFrame.height)
    }

    // MARK: - 小方块：跟着条进出场

    /// 条挪了 / 变大小：跟上（不改显示状态）
    func place(barFrame: NSRect) {
        let target = Self.chipFrame(barFrame: barFrame)
        if chip.frame != target { chip.setFrame(target, display: true) }
    }

    /// 跟条一起出场。dy = 条进场的起始位移（0 = 不滑）；duration nil = 不做动画
    func reveal(barFrame: NSRect, dy: CGFloat, alpha: CGFloat, duration: TimeInterval?) {
        guard hasApps else { conceal(dy: 0, duration: nil); return }
        visibilityToken &+= 1
        let target = Self.chipFrame(barFrame: barFrame)
        guard let duration else {
            chip.setFrame(target, display: true)
            chip.alphaValue = alpha
            chip.orderFrontRegardless()
            return
        }
        var start = target
        start.origin.y += dy
        chip.alphaValue = 0
        chip.setFrame(start, display: false)
        chip.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = duration
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            chip.animator().setFrame(target, display: true)
            chip.animator().alphaValue = alpha
        }
    }

    /// 跟条一起离场
    func conceal(dy: CGFloat, duration: TimeInterval?) {
        close(animated: false)
        guard chip.isVisible else { return }
        visibilityToken &+= 1
        let token = visibilityToken
        guard let duration else {
            chip.orderOut(nil)
            chip.alphaValue = 1
            return
        }
        var end = chip.frame
        end.origin.y += dy
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = duration
            chip.animator().setFrame(end, display: true)
            chip.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.visibilityToken == token else { return }
                self.chip.orderOut(nil)
                self.chip.alphaValue = 1
            }
        }
    }

    /// 待机半透明 / 悬停变实：和条同一个透明度
    func setAlpha(_ value: CGFloat) {
        guard chip.isVisible, abs(chip.alphaValue - value) > 0.02 else { return }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.12
            chip.animator().alphaValue = value
        }
    }

    // MARK: - 网格

    func toggle() {
        isOpen ? close() : open()
    }

    func open() {
        guard hasApps, chip.isVisible else { return }
        onOpen?()
        let size = BackgroundFolderGrid.size(count: catalog.backgroundApps.count)
        let screen = NSScreen.screens.first { $0.frame.intersects(chip.frame) }
            ?? NSScreen.main ?? NSScreen.screens[0]
        let target = DockGeometry.popupFrame(size: size, anchorX: chip.frame.midX, alignLeft: false,
                                             barFrame: chip.frame, visible: screen.visibleFrame, gap: 8)
        popup.setFrame(target, display: true)
        popupHost?.frame = NSRect(origin: .zero, size: size)
        popup.alphaValue = 0
        FloatingPanel.handingKeyBack = false  // 见 FloatingPanel.orderOutHandingKeyBack
        popup.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = Preferences.shared.animationsEnabled ? 0.12 : 0
            popup.animator().alphaValue = 1
        }
        state.open = true
        installMonitors()
        TTLog("backgroundFolder open frame=\(target) apps=\(catalog.backgroundApps.map(\.name))")
    }

    func close(animated: Bool = true) {
        guard popup.isVisible else { return }
        TTLog("backgroundFolder close")
        removeMonitors()
        state.open = false
        if animated, Preferences.shared.animationsEnabled {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.1
                popup.animator().alphaValue = 0
            } completionHandler: { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, !self.state.open else { return }
                    // 键盘交还前台 App（刚切过去的 App），别让 key 落到悬浮条上
                    self.popup.orderOutHandingKeyBack()
                }
            }
        } else {
            popup.orderOutHandingKeyBack()
        }
        onClose?()
    }

    /// 资料夹里的 App 变了：网格开着就按新的数量重排，空了就收
    func appsChanged() {
        guard isOpen else { return }
        guard hasApps else { close(); return }
        let size = BackgroundFolderGrid.size(count: catalog.backgroundApps.count)
        guard popup.frame.size != size else { return }
        let screen = NSScreen.screens.first { $0.frame.intersects(chip.frame) }
            ?? NSScreen.main ?? NSScreen.screens[0]
        let target = DockGeometry.popupFrame(size: size, anchorX: chip.frame.midX, alignLeft: false,
                                             barFrame: chip.frame, visible: screen.visibleFrame, gap: 8)
        popup.setFrame(target, display: true)
    }

    func shutdown() {
        close(animated: false)
        chip.orderOut(nil)
    }

    // MARK: - Esc / 点外面收起（同开始菜单）

    private func installMonitors() {
        removeMonitors()
        if let m = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            let swallow = MainActor.assumeIsolated { () -> Bool in
                guard let self, event.keyCode == 53, event.window === self.popup else { return false }
                self.close()
                return true
            }
            return swallow ? nil : event
        }) { monitors.append(m) }

        // 点到自己的其它窗口。小方块本身除外：它的点击自己会 toggle
        if let m = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] event in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    let w = event.window
                    let isMenu = (w?.level.rawValue ?? 0) >= NSWindow.Level.popUpMenu.rawValue
                    if w !== self.popup, w !== self.chip, !isMenu { self.close() }
                }
                return event
            }) { monitors.append(m) }

        if let m = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] _ in
                DispatchQueue.main.async { self?.close() }
            }) { monitors.append(m) }

        resignObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: popup, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                // 右键菜单开着时 key 会被菜单拿走一下，别因此收掉
                guard let self, !self.menuOpen else { return }
                self.close()
            }
        }
    }

    /// 有右键菜单开着（条那边的菜单跟踪通知会设）
    var menuOpen = false

    private func removeMonitors() {
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors.removeAll()
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        resignObserver = nil
    }
}

/// 条尾巴后面的小方块：2×2 迷你图标 + 右下角数字
struct BackgroundFolderChip: View {
    @ObservedObject var catalog: AppCatalog
    @ObservedObject var prefs: Preferences
    @ObservedObject var state: BackgroundFolderController.State
    @ObservedObject var liveScale = LiveScale.shared

    @State private var hovering = false

    private var apps: [AppEntry] { catalog.backgroundApps }

    var body: some View {
        let side = TTLayout.barHeight
        // 四个迷你图标围成的方块：小一点，留出四周的玻璃边
        let tile = side * (prefs.iconOnly ? 0.62 : 0.6)
        let mini = (tile - TTLayout.s(2)) / 2
        ZStack {
            RoundedRectangle(cornerRadius: TTLayout.s(9), style: .continuous)
                .fill(Color.primary.opacity(state.open ? 0.18 : (hovering ? 0.10 : 0)))
                .padding(TTLayout.s(4))
            LazyVGrid(columns: [GridItem(.fixed(mini), spacing: TTLayout.s(2)),
                                GridItem(.fixed(mini), spacing: TTLayout.s(2))],
                      spacing: TTLayout.s(2)) {
                // 超过 4 个：前 3 格放图标，第 4 格写「+没放进来的个数」
                ForEach(apps.prefix(apps.count > 4 ? 3 : 4)) { entry in
                    Image(nsImage: entry.icon)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: mini, height: mini)
                }
                if apps.count > 4 {
                    Text("+\(apps.count - 3)")
                        .font(.system(size: mini * 0.62, weight: .semibold).monospacedDigit())
                        .foregroundStyle(Color.primary.opacity(0.7))
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                        .frame(width: mini, height: mini)
                }
            }
            .frame(width: tile, height: tile)
            .scaleEffect(hovering && !state.open ? 1.08 : 1)
        }
        .frame(width: side, height: side)
        .background(GlassBackdrop(style: prefs.glassStyle, cornerRadius: TTLayout.barCornerRadius))
        .clipShape(RoundedRectangle(cornerRadius: TTLayout.barCornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: TTLayout.barCornerRadius, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.5)
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .animation(prefs.animationsEnabled ? .easeOut(duration: 0.11) : nil, value: hovering)
        .animation(prefs.animationsEnabled ? .easeOut(duration: 0.11) : nil, value: state.open)
        .help("背景執行（\(apps.count) 個 App）")
        .contextMenu {
            Button("全部結束", role: .destructive) {
                for entry in apps { catalog.terminate(entry) }
            }
            Divider()
            Toggle("只顯示有視窗的 App", isOn: $prefs.onlyWindowedApps)
        }
    }
}

/// 点开小方块弹出的图标网格。尺寸固定，不跟「介面縮放」走（同开始菜单）
struct BackgroundFolderGrid: View {
    @ObservedObject var catalog: AppCatalog
    @ObservedObject var prefs = Preferences.shared
    let onOpen: (AppEntry) -> Void

    static let cell = CGSize(width: 76, height: 74)
    static let maxColumns = 4
    static let maxRows = 5
    static let padding: CGFloat = 12
    static let header: CGFloat = 28

    static func size(count: Int) -> CGSize {
        let cols = max(1, min(maxColumns, count))
        let rows = max(1, min(maxRows, Int(ceil(Double(count) / Double(cols)))))
        return CGSize(width: CGFloat(cols) * cell.width + padding * 2,
                      height: header + CGFloat(rows) * cell.height + padding * 2)
    }

    private var apps: [AppEntry] { catalog.backgroundApps }

    var body: some View {
        let cols = max(1, min(Self.maxColumns, apps.count))
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("背景執行")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Text("\(apps.count)")
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 4)
            .frame(height: Self.header, alignment: .top)
            ScrollView(.vertical, showsIndicators: false) {
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(Self.cell.width), spacing: 0), count: cols),
                          spacing: 0) {
                    ForEach(apps) { entry in
                        BackgroundFolderCell(entry: entry,
                                             onOpen: { onOpen(entry) },
                                             onQuit: { catalog.terminate(entry) })
                    }
                }
            }
        }
        .padding(Self.padding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(GlassBackdrop(style: prefs.glassStyle, cornerRadius: 14))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.5)
        )
    }
}

private struct BackgroundFolderCell: View {
    let entry: AppEntry
    let onOpen: () -> Void
    let onQuit: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: onOpen) {
            VStack(spacing: 4) {
                Image(nsImage: entry.icon)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 40, height: 40)
                Text(entry.name)
                    .font(.system(size: 11))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: BackgroundFolderGrid.cell.width - 10)
            }
            .frame(width: BackgroundFolderGrid.cell.width - 4, height: BackgroundFolderGrid.cell.height - 4)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(hovering ? 0.10 : 0))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(width: BackgroundFolderGrid.cell.width, height: BackgroundFolderGrid.cell.height)
        .onHover { hovering = $0 }
        .help(entry.name)
        .contextMenu {
            Button("開啟") { onOpen() }
            Button("結束 App", role: .destructive) { onQuit() }
        }
    }
}
