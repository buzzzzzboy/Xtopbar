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
    /// 正在看的文件夹（nil = 没打开文件夹）
    @Published var openFolder: UUID?
    /// 每次打开 +1，视图据此把焦点重新放回搜索框
    @Published var focusToken = 0

    var results: [LibraryApp] { AppLibrary.shared.search(query) }

    func reset() {
        query = ""
        selection = 0
        showAll = false
        openFolder = nil
        focusToken &+= 1
    }
}

/// 开始菜单浮层：贴着条上的开始按钮弹出（条在底部就向上弹，在顶部就向下弹）。
///
/// 和主面板 / 预览面板不同，它要接收键盘输入（搜索框），所以打开时 `makeKey`。
/// 面板是 nonactivating 的：变成 key 窗口但**不激活 Xtopbar**，
/// 前台 App 不会失焦（Spotlight / Alfred 同款做法）。
@MainActor
final class StartMenuController {

    private let catalog: AppCatalog
    private let model = StartMenuModel()
    private let panel: FloatingPanel
    private var hosting: FirstMouseHostingView<StartMenuView>?
    /// 内容的外框（裁掉越界部分）：开关动画时内容在里面上下滑，
    /// 看起来像从条后面升起来 / 缩回去，同 Windows 11
    private let clip = NSView()
    /// 正在播收起动画（面板还在屏上，但对外已经算关了）
    private var closing = false
    /// 每次开 / 关 +1：收起动画播完时若已被重新打开，就别再 orderOut
    private var animationToken = 0
    /// 这次是往上弹（条在下）还是往下弹；收起时按它缩回条那一侧
    private var opensUpward = true
    /// 动画期间每帧重算窗口阴影（系统阴影按窗口当前内容算，不会自己跟着 layer 动画走）
    private var shadowTimer: Timer?
    private var monitors: [Any] = []
    private var resignObserver: NSObjectProtocol?
    private weak var barWindow: NSWindow?

    /// 菜单收起时回调（条据此复位开始按钮的按下态、重新计自动隐藏）
    var onClose: (@MainActor () -> Void)?

    var isVisible: Bool { panel.isVisible && !closing }
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
        clip.frame = NSRect(origin: .zero, size: size)
        clip.wantsLayer = true
        clip.layer?.masksToBounds = true
        clip.addSubview(host)
        // 收着时内容保持透明：窗口 orderFront 比开场动画早一帧上屏，那一帧不能是完整菜单
        host.alphaValue = 0
        panel.contentView = clip
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
        opensUpward = upward
        animationToken &+= 1
        closing = false
        panel.ignoresMouseEvents = false
        panel.alphaValue = 1
        panel.setFrame(target, display: false)
        guard let host = hosting else { return }
        host.setFrameOrigin(.zero)
        host.alphaValue = 1
        // 收起动画播到一半又打开：从当前位置接着往回升，不先跳到底
        let midway = host.layer?.animation(forKey: Self.slideKey) != nil ? host.layer?.presentation() : nil
        host.layer?.removeAnimation(forKey: Self.slideKey)
        if let slide = slideDistance, let layer = host.layer {
            panel.makeKeyAndOrderFront(nil)
            trackShadow()
            let token = animationToken
            // 从条那一侧滑进来：条在下 → 内容先压在下面（y 往下），往上升；条在上反过来。
            // 直接给 layer 加显式动画：NSView.animator() 取的起点是还没提交的旧位置，开场会不动
            CATransaction.begin()
            CATransaction.setCompletionBlock { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.animationToken == token else { return }
                    self.stopTrackingShadow()
                }
            }
            // Windows 11 的减速曲线：起步快、收尾很缓
            Self.addSlide(to: layer, fromY: midway?.transform.m42 ?? (upward ? -slide : slide), toY: 0,
                          fromAlpha: midway?.opacity ?? 0, toAlpha: 1,
                          duration: 0.3, timing: CAMediaTimingFunction(controlPoints: 0.1, 0.9, 0.2, 1))
            CATransaction.commit()
        } else {
            stopTrackingShadow()
            panel.makeKeyAndOrderFront(nil)
        }
        installMonitors()
        TTLog("startMenu show frame=\(target) upward=\(upward) apps=\(AppLibrary.shared.apps.count)")
    }

    /// - Parameter animated: 调度中心 / 设置变更这类"整个场景要换"的场合传 false，直接消失
    func close(animated: Bool = true) {
        guard isVisible else {
            // 收起动画播到一半又要求立刻关：直接收尾
            if closing, !animated { finishClose() }
            return
        }
        removeMonitors()
        onClose?()
        guard animated, let slide = slideDistance, let host = hosting, host.layer != nil else {
            finishClose()
            return
        }
        closing = true
        animationToken &+= 1
        let token = animationToken
        // 缩回去的途中不接点击，免得点到正在消失的格子
        panel.ignoresMouseEvents = true
        trackShadow()
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.animationToken == token else { return }
                self.finishClose()
            }
        }
        // 加速曲线：起步慢、越走越快，干脆地收回条里。
        // 从当前实际位置起步：开场动画还没播完就关，也不会先跳回原位
        let now = host.layer?.presentation()
        Self.addSlide(to: host.layer, fromY: now?.transform.m42 ?? 0, toY: opensUpward ? -slide : slide,
                      fromAlpha: now?.opacity ?? 1, toAlpha: 0,
                      duration: 0.18, timing: CAMediaTimingFunction(controlPoints: 0.7, 0, 0.84, 0))
        CATransaction.commit()
    }

    private func finishClose() {
        closing = false
        panel.orderOut(nil)
        panel.ignoresMouseEvents = false
        stopTrackingShadow()
        hosting?.alphaValue = 0  // 见 init
        hosting?.layer?.removeAnimation(forKey: Self.slideKey)
    }

    private static let slideKey = "startMenuSlide"

    private func trackShadow() {
        shadowTimer?.invalidate()
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.panel.invalidateShadow() }
        }
        // common 模式：拖着窗口 / 菜单跟踪时也照样跑
        RunLoop.main.add(timer, forMode: .common)
        shadowTimer = timer
    }

    private func stopTrackingShadow() {
        shadowTimer?.invalidate()
        shadowTimer = nil
        panel.invalidateShadow()
    }

    /// 上下滑 + 淡入淡出。动画停在终点（fillMode forwards），模型值不动，
    /// 下次开 / 关先移除它复位
    private static func addSlide(to layer: CALayer?, fromY: CGFloat, toY: CGFloat,
                                 fromAlpha: Float, toAlpha: Float,
                                 duration: CFTimeInterval, timing: CAMediaTimingFunction) {
        guard let layer else { return }
        let slide = CABasicAnimation(keyPath: "transform.translation.y")
        slide.fromValue = fromY
        slide.toValue = toY
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = fromAlpha
        fade.toValue = toAlpha
        let group = CAAnimationGroup()
        group.animations = [slide, fade]
        group.duration = duration
        group.timingFunction = timing
        group.fillMode = .forwards
        group.isRemovedOnCompletion = false
        layer.add(group, forKey: slideKey)
    }

    /// 开关动画的滑动距离。不跟「進出場動畫」开关走（那个管的是条本身进出场），
    /// 系统开了「减少动态效果」就只淡入淡出、不滑动。
    private var slideDistance: CGFloat? {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : TTLayout.s(90)
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
            } else if model.openFolder != nil {
                model.openFolder = nil
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
