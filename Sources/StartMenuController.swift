import AppKit
import SwiftUI
import Combine

/// 开始菜单的界面状态（搜索词 / 键盘选中项 / 是否在看「所有应用」）
@MainActor
final class StartMenuModel: ObservableObject {
    @Published var query = "" {
        didSet { if query != oldValue { selection = 0 } }
    }
    /// 搜索结果里键盘选中的下标（↑↓ 移动，回车打开）
    @Published var selection = 0
    @Published var showAll = false
    /// 每次打开 +1，视图据此把焦点重新放回搜索框
    @Published var focusToken = 0

    var results: [LibraryApp] { AppLibrary.shared.search(query) }

    func reset() {
        query = ""
        selection = 0
        showAll = false
        focusToken &+= 1
    }
}

/// 开始菜单浮层：贴着条上的开始按钮弹出（条在底部就向上弹，在顶部就向下弹）。
///
/// 和主面板 / 预览面板不同，它要接收键盘输入（搜索框），所以打开时 `makeKey`。
/// 面板是 nonactivating 的：变成 key 窗口但**不激活 TopTab**，
/// 前台 App 不会失焦（Spotlight / Alfred 同款做法）。
@MainActor
final class StartMenuController {

    private let catalog: AppCatalog
    private let model = StartMenuModel()
    private let panel: FloatingPanel
    private var hosting: FirstMouseHostingView<StartMenuView>?
    private var monitors: [Any] = []
    private var resignObserver: NSObjectProtocol?
    private weak var barWindow: NSWindow?

    /// 菜单收起时回调（条据此复位开始按钮的按下态、重新计自动隐藏）
    var onClose: (@MainActor () -> Void)?

    var isVisible: Bool { panel.isVisible }
    var frame: NSRect { panel.frame }

    static var size: CGSize { CGSize(width: TTLayout.s(560), height: TTLayout.s(600)) }

    init(catalog: AppCatalog) {
        self.catalog = catalog
        let size = StartMenuController.size
        panel = FloatingPanel(contentRect: NSRect(origin: .zero, size: size))
        // 比主面板高一层：两者贴在一起时菜单的阴影压在条上，而不是反过来
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)

        let view = StartMenuView(
            model: model,
            library: AppLibrary.shared,
            prefs: Preferences.shared,
            catalog: catalog,
            onLaunch: { [weak self] app in self?.launch(app) },
            onSettings: { [weak self] in
                self?.close()
                SettingsWindowController.shared.show()
            }
        )
        let host = FirstMouseHostingView(rootView: view)
        host.frame = NSRect(origin: .zero, size: size)
        host.autoresizingMask = [.width, .height]
        panel.contentView = host
        hosting = host
    }

    // MARK: - 显示 / 收起

    /// - Parameters:
    ///   - anchorInScreen: 开始按钮在屏幕坐标里的位置（菜单左边缘对齐它）
    ///   - barFrame: 主面板 frame（决定向上还是向下弹）
    ///   - barWindow: 主面板窗口 —— 在它上面的点击不算"点外面"，
    ///     否则点开始按钮关菜单会先被外部点击关掉、再被按钮重新打开
    func show(anchorInScreen: NSRect, barFrame: NSRect, barWindow: NSWindow) {
        self.barWindow = barWindow
        AppLibrary.shared.refreshIfStale()
        model.reset()

        let size = StartMenuController.size
        let screen = NSScreen.screens.first { $0.frame.intersects(barFrame) }
            ?? NSScreen.main ?? NSScreen.screens[0]
        let target = DockGeometry.popupFrame(size: size, anchorX: anchorInScreen.minX,
                                             alignLeft: true, barFrame: barFrame,
                                             visible: screen.visibleFrame, gap: 8)
        hosting?.frame = NSRect(origin: .zero, size: size)

        let upward = DockGeometry.opensUpward(barFrame: barFrame, visible: screen.visibleFrame)
        if Preferences.shared.animationsEnabled {
            var start = target
            start.origin.y += upward ? -12 : 12
            panel.alphaValue = 0
            panel.setFrame(start, display: false)
            panel.makeKeyAndOrderFront(nil)
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.14
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().setFrame(target, display: true)
                panel.animator().alphaValue = 1
            }
        } else {
            panel.setFrame(target, display: true)
            panel.alphaValue = 1
            panel.makeKeyAndOrderFront(nil)
        }
        installMonitors()
        TTLog("startMenu show frame=\(target) upward=\(upward) apps=\(AppLibrary.shared.apps.count)")
    }

    func close() {
        guard panel.isVisible else { return }
        removeMonitors()
        panel.orderOut(nil)
        panel.alphaValue = 1
        onClose?()
    }

    private func launch(_ app: LibraryApp) {
        close()
        catalog.launch(url: app.url, bundleID: app.bundleID)
    }

    // MARK: - 键盘 / 点外面收起

    private func installMonitors() {
        removeMonitors()

        // 键盘：Esc 收起；有搜索词时 ↑↓ 选、回车打开。
        // 不用 SwiftUI onKeyPress：焦点在搜索框里时 ↑↓ 会先被文本框吃掉（挪光标）。
        if let m = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            // assumeIsolated 只能带出 Sendable 的值，所以回传"吃不吃"而不是事件本身
            let swallow = MainActor.assumeIsolated { () -> Bool in
                guard let self else { return false }
                return self.handleKey(event.keyCode, inPanel: event.window === self.panel)
            }
            return swallow ? nil : event
        }) { monitors.append(m) }

        // 点到自己 App 的其它窗口（条本身除外，见 show 的注释）
        if let m = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] event in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    let w = event.window
                    // 右键菜单是独立的弹出窗口，点菜单项不算点外面
                    let isMenu = (w?.level.rawValue ?? 0) >= NSWindow.Level.popUpMenu.rawValue
                    if w !== self.panel, w !== self.barWindow, !isMenu { self.close() }
                }
                return event
            }) { monitors.append(m) }

        // 点到别的 App（桌面、其它窗口）
        if let m = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] _ in
                DispatchQueue.main.async { self?.close() }
            }) { monitors.append(m) }

        // 焦点被别的窗口拿走（比如 ⌘Tab 到别处）
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
    private func handleKey(_ keyCode: UInt16, inPanel: Bool) -> Bool {
        guard panel.isVisible, inPanel else { return false }
        switch keyCode {
        case 53: // Esc：有搜索词先清空，再按一次收起
            if !model.query.isEmpty {
                model.query = ""
            } else if model.showAll {
                model.showAll = false
            } else {
                close()
            }
            return true
        case 125, 126: // ↓ ↑
            guard !model.query.isEmpty else { return false }
            let count = model.results.count
            guard count > 0 else { return true }
            let step = keyCode == 125 ? 1 : -1
            model.selection = min(max(model.selection + step, 0), count - 1)
            return true
        case 36, 76: // 回车
            let results = model.results
            guard !model.query.isEmpty, results.indices.contains(model.selection) else { return true }
            launch(results[model.selection])
            return true
        default:
            return false
        }
    }
}
