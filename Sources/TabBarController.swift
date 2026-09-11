import AppKit
import SwiftUI
import Combine

/// 主面板向上层暴露的能力（右键菜单 / 状态栏菜单用）
@MainActor
protocol TabBarHost: AnyObject {
    func openSettings()
    func requestScreenCapturePermission()
    func requestAccessibilityPermission()
    func permissionSummary() -> String
}

/// 面板生命周期 + 定位 + 尺寸自适应 + 自动隐藏 + 预览调度
@MainActor
final class TabBarController: TabBarHost {

    private let catalog: AppCatalog
    private let prefs: Preferences
    private let panel: FloatingPanel
    private var hostingView: FirstMouseHostingView<TabBarView>?
    private var cancellables = Set<AnyCancellable>()
    private var currentWidth: CGFloat = 0

    private let barHeight: CGFloat = 42
    private let topInset: CGFloat = 6

    private var isRevealed = false
    private var lastInteraction = Date.distantPast
    private var mouseTimer: Timer?
    private var isHoveringBar = false

    // MARK: - 预览

    private let preview = PreviewController()
    private var previewWork: DispatchWorkItem?
    private var hoveredEntry: AppEntry?
    /// 鼠标离开标签的时刻：留一点宽限期，让光标能顺利从标签滑进预览面板
    private var hoverEndTime: Date?

    /// 预览防抖：0.12s 足够滤掉扫过标签时的抖动，同时体感接近即时。
    /// （图已预热到缓存里，真正的弹出延迟只由它决定）
    private let previewDelay: TimeInterval = 0.12

    private let engine = ScreenCaptureEngine.shared
    /// 面板显示期间的窗口快照刷新节流
    private var lastWarmup = Date.distantPast

    init(catalog: AppCatalog) {
        self.catalog = catalog
        self.prefs = Preferences.shared

        let screen = NSScreen.main ?? NSScreen.screens[0]
        let frame = TabBarController.targetFrame(for: screen, width: 600, height: 42, topInset: 6)
        self.panel = FloatingPanel(contentRect: frame)

        let view = TabBarView(
            catalog: catalog,
            prefs: prefs,
            onHoverChange: { [weak self] hovering in
                self?.isHoveringBar = hovering
            }
        )
        let host = FirstMouseHostingView(rootView: view)
        host.frame = NSRect(origin: .zero, size: frame.size)
        host.autoresizingMask = [.width, .height]
        panel.contentView = host
        self.hostingView = host

        // 点击命中：AppKit 窗口坐标（原点左下）→ SwiftUI 坐标（原点上左）
        panel.onTap = { [weak self] locationInWindow in
            guard let self else { return false }
            let height = self.panel.contentView?.bounds.height ?? self.barHeight
            let point = NSPoint(x: locationInWindow.x, y: height - locationInWindow.y)
            return self.catalog.handleTap(at: point)
        }

        catalog.onLayoutNeeded = { [weak self] in self?.relayout() }
        catalog.host = self

        // 标签悬停 → 延迟弹出窗口预览
        catalog.onTabHover = { [weak self] entry in
            self?.hoverEndTime = nil
            self?.schedulePreview(for: entry)
        }
        catalog.onTabHoverEnd = { [weak self] in
            self?.previewWork?.cancel()
            self?.hoveredEntry = nil
            self?.hoverEndTime = Date()
        }

        preview.onSelectWindow = { [weak self] pid, win in
            // AX 配对可能阻塞到 0.25s 超时，挪到后台线程，别卡住鼠标
            Task.detached(priority: .userInitiated) {
                // cgID = 卡片缩略图像素的来源窗口，是唯一不会错位的锚点
                WindowBridge.focusWindow(pid: pid, axIndex: win.axIndex,
                                         frame: win.frame, title: win.title, cgID: win.id)
            }
            self?.hidePreview()
        }

        catalog.$groups
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.relayout() }
            .store(in: &cancellables)

        observePreferences()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }

    /// 偏好变化 → 立刻反映到面板上。设置窗口改完不需要重启。
    private func observePreferences() {
        prefs.$barEnabled
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.applyBarEnabled() }
            .store(in: &cancellables)

        prefs.$hideDelay
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] delay in
                guard let self else { return }
                if delay <= 0 {
                    self.reveal()                      // 切到"常驻"立刻显示
                } else if self.isRevealed,
                          Date().timeIntervalSince(self.lastInteraction) > delay {
                    self.hide()                        // 切到更短的延迟立刻生效
                }
            }
            .store(in: &cancellables)

        // 关掉预览 / 换过滤条件 / 换材质：正在显示的预览面板内容已经不对了，直接收起
        prefs.$previewEnabled
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] enabled in if !enabled { self?.hidePreview() } }
            .store(in: &cancellables)

        prefs.$hideMinimizedWindows
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.hidePreview() }
            .store(in: &cancellables)

        prefs.$glassStyle
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.hidePreview() }
            .store(in: &cancellables)

        // 不透明度变小：立刻把待机中的面板压暗
        prefs.$idleOpacity
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] value in
                guard let self, self.isRevealed, !self.isHoveringBar else { return }
                self.panel.alphaValue = CGFloat(value)
            }
            .store(in: &cancellables)
    }

    // MARK: - Show / Hide

    /// 启动时进入"藏起来"状态，鼠标顶到屏幕顶部才出现
    func start() {
        TTLog("start screen=\(ScreenCaptureEngine.hasPermission) ax=\(WindowBridge.isTrusted) "
              + "bid=\(Bundle.main.bundleIdentifier ?? "-") "
              + "glass=\(prefs.glassStyle.rawValue) delay=\(prefs.hideDelay)")
        relayout()
        startMouseTracking()
        promptAccessibilityIfNeeded()
        applyBarEnabled()
    }

    /// 悬浮条总开关 + 常驻判断。状态栏菜单和设置窗口都会调它。
    func applyBarEnabled() {
        guard prefs.barEnabled else {
            hidePreview()
            hide()
            catalog.pointerOverBar = false
            panel.orderOut(nil)
            return
        }
        if prefs.hideDelay <= 0 {
            reveal()               // 常驻模式
        } else if !isRevealed {
            panel.alphaValue = 0
            panel.orderOut(nil)
        }
    }

    /// 没拿到辅助功能权限时提示一次。
    ///
    /// 这个权限决定窗口列表准不准：没有它就只能靠窗口服务器的启发式猜，
    /// 猜的结果就是"抖店工作台 2 个真窗口显示成 4 个"这类幽灵窗口。
    /// 每次启动最多弹一次；签名固定后授权一次就会一直有效。
    private var promptedAX = false
    private func promptAccessibilityIfNeeded() {
        guard !promptedAX, !WindowBridge.isTrusted else { return }
        promptedAX = true
        // 延后一点，别和启动动画抢焦点
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            WindowBridge.requestAccessibilityPermission()
        }
    }

    private func reveal() {
        guard !isRevealed, prefs.barEnabled else { return }
        isRevealed = true
        lastInteraction = Date()
        relayout()

        let idle = CGFloat(prefs.idleOpacity)
        guard prefs.animationsEnabled else {
            panel.setFrame(panel.frame, display: true)
            panel.alphaValue = idle
            panel.orderFrontRegardless()
            warmup()
            return
        }

        // 快速淡入 + 从上方滑落（旧版式的加速版）。起始必须全透明：
        // 首帧布局/玻璃重采样会闪一下，透明度 0 时看不见，alpha=1 会闪烁。
        let target = panel.frame
        var start = target
        start.origin.y += 14
        panel.alphaValue = 0
        panel.setFrame(start, display: false)
        panel.orderFrontRegardless()
        animateWindow(to: target, alpha: idle, duration: 0.05, timing: .easeOut)
        warmup()
    }

    /// 面板一出现就在后台把窗口快照和缩略图备好 ——
    /// 等用户真的悬停到某个标签时，图已经在缓存里，弹出即完整。
    private func warmup() {
        guard prefs.previewEnabled else { return }
        guard ScreenCaptureEngine.hasPermission else {
            ScreenCaptureEngine.requestPermissionIfNeeded()
            return
        }
        lastWarmup = Date()
        let pids = catalog.groups.flatMap { $0.entries }.map(\.pid)
        Task { [weak self] in
            guard let self else { return }
            await self.engine.refresh(minInterval: 0, pids: pids)
            let ids = self.engine.warmupTargets()
            TTLog("warmup pids=\(pids.count) targets=\(ids.count)")
            self.engine.prewarm(ids, maxSize: PreviewLayout.thumbSize)
        }
    }

    private func hide() {
        guard isRevealed else { return }
        isRevealed = false
        hidePreview()
        // 整条要离场了，高亮状态跟着复位，下次唤出时不会残留
        catalog.pointerOverBar = false

        guard prefs.animationsEnabled else {
            panel.orderOut(nil)
            panel.alphaValue = 1
            return
        }

        // 反向滑回上方 + 淡出（和呼出同级别的快，0.07s）
        var end = panel.frame
        end.origin.y += 8
        animateWindow(to: end, alpha: 0, duration: 0.07) { [weak self] in
            guard let self, !self.isRevealed else { return }
            // 先离场再复位透明度，避免 orderOut 之前那一帧闪出全不透明的面板
            self.panel.orderOut(nil)
            self.panel.alphaValue = 1
        }
    }

    private func animateAlpha(to value: CGFloat, duration: TimeInterval, completion: (() -> Void)? = nil) {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = duration
            panel.animator().alphaValue = value
        } completionHandler: { completion?() }
    }

    /// 面板整体位移 + 透明度一起动（进出场用）
    private func animateWindow(to frame: NSRect,
                               alpha: CGFloat,
                               duration: TimeInterval,
                               timing: CAMediaTimingFunctionName = .easeOut,
                               completion: (() -> Void)? = nil) {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = duration
            ctx.timingFunction = CAMediaTimingFunction(name: timing)
            panel.animator().setFrame(frame, display: true)
            panel.animator().alphaValue = alpha
        } completionHandler: { completion?() }
    }

    // MARK: - 鼠标热点

    /// 顶部中央的唤醒区（菜单栏高度），鼠标顶上来就显示。
    ///
    /// 宽度可在设置里调（默认 120pt ≈ 4 个状态栏图标），**不跟面板宽度走**：
    /// 之前按 `max(面板宽, 380)` 算，App 一多或外接屏缩放比例不同时，
    /// 唤醒区会横向铺满大半个菜单栏，鼠标去点右上角状态图标就误唤醒，
    /// 干扰正常点击。唤醒只需要顶部中间一小块，面板出来后由面板区域
    /// 自己维持驻留（tick 里的并集判断），收窄不影响日常使用。
    private var hotZone: NSRect {
        let screen = panel.screen ?? NSScreen.main ?? NSScreen.screens[0]
        let menuBarHeight = screen.frame.maxY - screen.visibleFrame.maxY
        let height = menuBarHeight + 5
        let width = CGFloat(prefs.hotZoneWidth)
        // 上边界故意越过屏幕顶部 2pt：鼠标贴到最上面时 y 正好等于 maxY，
        // 而 NSRect.contains 是半开区间，不越过就会漏判。
        return NSRect(x: screen.frame.midX - width / 2,
                      y: screen.frame.maxY - height + 2,
                      width: width, height: height)
    }

    private func startMouseTracking() {
        // 轮询鼠标位置：不需要任何权限。30Hz 的读取开销依然可忽略，
        // 但把"顶到屏幕边缘 → 面板出现"的最坏响应从 100ms 压到 33ms ——
        // 唤醒手感是"立刻"还是"慢半拍"，差的就是这一档。
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        mouseTimer = timer
    }

    private func tick() {
        guard prefs.barEnabled else {
            if isRevealed { hide() }
            return
        }

        let mouse = NSEvent.mouseLocation
        let now = Date()
        let delay = prefs.hideDelay

        let panelZone = panel.frame.insetBy(dx: -1, dy: -1)
        let inPanel = isRevealed && panelZone.contains(mouse)
        let inPreview = preview.isVisible && preview.frame.insetBy(dx: -1, dy: -1).contains(mouse)
        let hot = hotZone
        let inHot = hot.contains(mouse)

        // 蓝色高亮跟随指针。够得着的范围 = 唤醒热点区 ∪ 面板区，两者必须并集：
        // 它们之间留着几 pt 的缝，光标从菜单栏往下滑进条里时会有一瞬间
        // 两边都不沾，高亮就会闪一下。
        //
        // 用双向同步而不是"只撤不点"：唤出那一刻指针还停在菜单栏热点区，
        // 这时就该亮起当前前台 App，否则面板出来了却没有任何方位指示。
        // 窗口被 orderOut 后 SwiftUI 的 onHover 不再补发事件，也只能靠它兜底复位。
        let pointerNear = hot.union(panelZone).contains(mouse)
        if catalog.pointerOverBar != pointerNear {
            catalog.pointerOverBar = pointerNear
        }

        if inPanel || inPreview || inHot {
            lastInteraction = now
            if !isRevealed { reveal() }
        } else if isRevealed, delay > 0, now.timeIntervalSince(lastInteraction) > delay {
            hide()
            return
        }

        guard isRevealed else { return }

        // 悬停时更实一点，便于阅读
        let target: CGFloat = inPanel ? 1.0 : CGFloat(prefs.idleOpacity)
        if abs(panel.alphaValue - target) > 0.02 {
            animateAlpha(to: target, duration: 0.12)
        }

        // 预览卡片的悬停高亮：复用这次轮询，和主面板高亮同一套坐标
        if preview.isVisible {
            preview.updatePointer(screenPoint: mouse)
        }

        // 预览的保持/收起：光标在主面板与预览面板之间穿行时（中间有 8pt 空隙）
        // 不能立刻收起，留 0.4s 宽限。
        if preview.isVisible {
            let inPreviewPanel = preview.frame.insetBy(dx: -8, dy: -16).contains(mouse)
            if inPreviewPanel {
                hoverEndTime = nil
            } else if hoveredEntry == nil,
                      let left = hoverEndTime,
                      now.timeIntervalSince(left) > 0.4 {
                hidePreview()
            }
        }

        // 面板常驻时窗口集合会变（新开/关闭窗口），定期刷新快照 + 补热缓存
        if prefs.previewEnabled, now.timeIntervalSince(lastWarmup) > 3.0 {
            warmup()
        }
    }

    @objc private func screenChanged() {
        currentWidth = 0
        relayout()
    }

    // MARK: - 预览调度

    private func schedulePreview(for entry: AppEntry) {
        hoveredEntry = entry
        previewWork?.cancel()
        guard prefs.previewEnabled, isRevealed else { return }

        let work = DispatchWorkItem { [weak self] in
            guard let self, self.hoveredEntry?.id == entry.id else { return }
            guard let labelRect = self.catalog.tabFrames[entry.id] else { return }
            // SwiftUI 坐标（原点上左）→ 屏幕坐标
            let screenRect = NSRect(
                x: self.panel.frame.minX + labelRect.minX,
                y: self.panel.frame.maxY - labelRect.maxY,
                width: labelRect.width,
                height: labelRect.height
            )
            self.preview.show(for: entry,
                              anchorInScreen: screenRect,
                              mainPanelFrame: self.panel.frame,
                              hideMinimized: self.prefs.hideMinimizedWindows)
        }
        previewWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + previewDelay, execute: work)
    }

    private func hidePreview() {
        previewWork?.cancel()
        hoveredEntry = nil
        hoverEndTime = nil
        preview.hide()
    }

    // MARK: - 对外动作（右键菜单 / 状态栏菜单）

    func openSettings() {
        SettingsWindowController.shared.show()
    }

    func dismissPreview() {
        hidePreview()
    }

    func refreshCatalog() {
        catalog.refresh()
    }

    // MARK: - 权限

    func requestScreenCapturePermission() {
        CGRequestScreenCaptureAccess()
    }

    func requestAccessibilityPermission() {
        // 系统弹窗自带"打开系统设置"按钮；再深链一次面板，免得用户还得自己翻。
        WindowBridge.requestAccessibilityPermission()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            WindowBridge.openAccessibilitySettings()
        }
    }

    func permissionSummary() -> String {
        let screen = ScreenCaptureEngine.hasPermission ? "✅" : "❌"
        let ax = WindowBridge.isTrusted ? "✅" : "❌"
        return "屏幕录制 \(screen) · 辅助功能 \(ax)"
    }

    // MARK: - Layout

    private static func targetFrame(for screen: NSScreen, width: CGFloat, height: CGFloat, topInset: CGFloat) -> NSRect {
        let visible = screen.visibleFrame
        let maxWidth = visible.width - 24
        let w = max(220, min(width, maxWidth))
        let x = visible.midX - w / 2
        // visibleFrame 已排除菜单栏，maxY 即菜单栏正下方
        let y = visible.maxY - topInset - height
        return NSRect(x: x, y: y, width: w, height: height)
    }

    private func relayout() {
        guard let screen = panel.screen ?? NSScreen.main ?? NSScreen.screens.first else { return }
        // preferredWidth 已经优先返回 SwiftUI 实测的内容宽度，
        // 这样左右两边的 12pt 内边距才真的对称，最右边的标签不会被圆角切掉。
        let target = TabBarController.targetFrame(
            for: screen,
            width: catalog.preferredWidth,
            height: barHeight,
            topInset: topInset
        )

        if abs(target.width - currentWidth) > 0.5 {
            currentWidth = target.width
            panel.setFrame(target, display: true, animate: false)
            hostingView?.frame = NSRect(origin: .zero, size: target.size)
            catalog.barWidth = target.width
        } else if panel.frame != target {
            panel.setFrame(target, display: true, animate: false)
        }
    }
}
