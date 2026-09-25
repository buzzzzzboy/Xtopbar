import AppKit
import Combine

/// 菜单栏（状态栏）图标 + 下拉菜单。
///
/// 菜单在每次弹出前重建（`menuNeedsUpdate`），所以勾选状态永远是最新的，
/// 不需要在每次偏好变化时手动同步一堆 NSMenuItem 的 state。
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {

    private let statusItem: NSStatusItem
    private let prefs: Preferences
    private weak var controller: TabBarController?
    private var cancellables = Set<AnyCancellable>()

    init(prefs: Preferences, controller: TabBarController) {
        self.prefs = prefs
        self.controller = controller
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        if let button = statusItem.button {
            let image = XtopbarIcon.statusBar()
            image.isTemplate = true
            button.image = image
            button.toolTip = "Xtopbar — Dock / App 切换条"
            TTLog("statusItem button ok image=\(image.size) visible=\(statusItem.isVisible)")
        } else {
            TTLog("statusItem button 为 nil")
        }

        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        applyVisibility()

        prefs.$showStatusItem
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.applyVisibility() }
            .store(in: &cancellables)
    }

    private func applyVisibility() {
        statusItem.isVisible = prefs.showStatusItem
    }

    // MARK: - 菜单

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        // 标题头（禁用项，纯展示）
        let header = NSMenuItem(title: "Xtopbar", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())

        add(to: menu,
            title: prefs.barEnabled ? "隐藏悬浮条" : "显示悬浮条",
            action: #selector(toggleBar))

        add(to: menu, title: "开始菜单", action: #selector(openStartMenu))
        add(to: menu, title: "设置…", action: #selector(openSettings), key: ",")

        // 有新版就把标题换成醒目的一行，点了直接弹更新框
        if case .available(let release) = Updater.shared.phase {
            add(to: menu, title: "有新版本 v\(release.version) →", action: #selector(checkUpdate))
        } else {
            add(to: menu, title: "检查更新…", action: #selector(checkUpdate))
        }

        menu.addItem(.separator())

        // 自动隐藏
        let delayMenu = NSMenu()
        for option in Preferences.delayOptions {
            let item = NSMenuItem(title: option.label,
                                  action: #selector(setDelay(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.representedObject = option.value
            item.state = abs(prefs.hideDelay - option.value) < 0.001 ? .on : .off
            delayMenu.addItem(item)
        }
        let delayItem = NSMenuItem(title: "自动隐藏", action: nil, keyEquivalent: "")
        delayItem.submenu = delayMenu
        menu.addItem(delayItem)

        add(to: menu, title: "只显示有窗口的 App",
            action: #selector(toggleOnlyWindowed),
            state: prefs.onlyWindowedApps)

        add(to: menu, title: "窗口预览",
            action: #selector(togglePreview),
            state: prefs.previewEnabled)

        add(to: menu, title: "只显示已打开的窗口",
            action: #selector(toggleMinimized),
            state: prefs.hideMinimizedWindows)

        menu.addItem(.separator())

        // 权限：状态行禁用展示，下面两个按钮负责请求
        let perm = NSMenuItem(title: permissionSummary(), action: nil, keyEquivalent: "")
        perm.isEnabled = false
        menu.addItem(perm)
        add(to: menu, title: "请求屏幕录制权限", action: #selector(requestScreen))
        add(to: menu, title: "请求辅助功能权限", action: #selector(requestAX))

        menu.addItem(.separator())
        add(to: menu, title: "刷新列表", action: #selector(refresh))
        menu.addItem(.separator())
        add(to: menu, title: "退出 Xtopbar", action: #selector(quit), key: "q")
    }

    private func add(to menu: NSMenu,
                     title: String,
                     action: Selector,
                     key: String = "",
                     state: Bool? = nil) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        if let state { item.state = state ? .on : .off }
        menu.addItem(item)
    }

    private func permissionSummary() -> String {
        let screen = ScreenCaptureEngine.hasPermission ? "✅" : "❌"
        let ax = WindowBridge.isTrusted ? "✅" : "❌"
        return "权限 — 屏幕录制 \(screen) 辅助功能 \(ax)"
    }

    // MARK: - 动作

    @objc private func toggleBar() {
        prefs.barEnabled.toggle()
        controller?.applyBarEnabled()
    }

    @objc private func openStartMenu() {
        // 状态栏菜单还在收尾（模态跟踪刚结束），推到下一拍再弹，免得菜单一开就被当成"点外面"关掉
        DispatchQueue.main.async { [weak self] in self?.controller?.toggleStartMenu() }
    }

    @objc private func openSettings() {
        SettingsWindowController.shared.show()
    }

    @objc private func checkUpdate() {
        Updater.shared.checkInteractively()
    }

    @objc private func setDelay(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? Double else { return }
        prefs.hideDelay = value
        controller?.applyBarEnabled()   // 从「常驻」切回自动隐藏时要立刻收起
    }

    @objc private func toggleOnlyWindowed() {
        prefs.onlyWindowedApps.toggle()
    }

    @objc private func togglePreview() {
        prefs.previewEnabled.toggle()
        if !prefs.previewEnabled { controller?.dismissPreview() }
    }

    @objc private func toggleMinimized() {
        prefs.hideMinimizedWindows.toggle()
        controller?.dismissPreview()
    }

    @objc private func requestScreen() {
        controller?.requestScreenCapturePermission()
    }

    @objc private func requestAX() {
        controller?.requestAccessibilityPermission()
    }

    @objc private func refresh() {
        controller?.refreshCatalog()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
