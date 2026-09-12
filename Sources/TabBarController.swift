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
    /// ⌘Tab 呼出开关打开但钩子装不上（缺辅助功能权限）
    func cmdTabInstallFailed()
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

    /// 面板高度 / 距菜单栏间隙随界面缩放联动（计算属性，uiScale 变了下次 relayout 生效）
    private var barHeight: CGFloat { TTLayout.s(42) }
    private var topInset: CGFloat { TTLayout.s(6) }

    private var isRevealed = false
    private var lastInteraction = Date.distantPast
    private var mouseTimer: Timer?
    private var isHoveringBar = false

    /// 有 NSMenu 正在跟踪（右键菜单 / 状态栏菜单）。菜单是面板的子窗口，
    /// 菜单一开就必须暂停自动隐藏：用户从标签移到"退出 App"那一项时
    /// 指针早就离开条了，不暂停的话 0.2s 后连条带菜单一起收掉，根本来不及点。
    private var menuTracking = false
    private var menuObservers: [NSObjectProtocol] = []

    // MARK: - ⌘Tab 呼出

    private let cmdTap = CmdTabTap()
    /// 面板钉在鼠标位置呼出（⌘Tab 模式），relayout 期间不再回中。
    /// 收起即复位，下次顶部热区唤醒回到默认位置。
    private var pinnedToMouse = false
    /// 呼出瞬间的鼠标位置。relayout 必须用这个固定锚点而不是实时鼠标：
    /// 鼠标滑进面板后若来一次 relayout（标签增减、宽度变化），
    /// 跟着实时鼠标走会让面板"追着光标跑"。
    private var pinnedAnchor: NSPoint = .zero

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

        let frame = TabBarController.defaultScreen.map {
            TabBarController.targetFrame(for: $0, width: 600, height: 42, topInset: 6)
        } ?? NSRect(x: 0, y: 0, width: 600, height: 42)
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
            // ⌘Tab 会话中指针接管高亮（AppRing 同款：扫到哪个，松 ⌘ 选哪个）
            self?.catalog.setKeyboardHighlight(entry.pid)
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

        // ⌘Tab（AppRing 同款机制）：按下立即弹条并预选上一个 App，
        // 再按 Tab 沿 MRU 前进，松开 ⌘ 提交高亮 —— 快按快放天然等于快速切换。
        cmdTap.onTabDown = { [weak self] in self?.cmdTabDown() }
        cmdTap.onTabCycle = { [weak self] in self?.cmdTabCycle() }
        cmdTap.onTabUp = { [weak self] in self?.cmdTabUp() }
        cmdTap.onCommandReleased = { [weak self] in self?.cmdCommandReleased() }
        cmdTap.onEscape = { [weak self] in
            guard let self else { return }
            self.catalog.endKeyboardSession()
            self.hide()
        }
        prefs.$cmdTabEnabled
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] on in
                guard let self, on, !self.applyCmdTab() else { return }
                // 权限不够，钩子装不上：把开关弹回去，别让设置里显示"已开启"
                self.prefs.cmdTabEnabled = false
                self.catalog.host?.cmdTabInstallFailed()
            }
            .store(in: &cancellables)

        // 隐藏列表变化 → 立刻重采（否则要等 1.2s 兜底轮询）
        prefs.$hiddenApps
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.catalog.refresh() }
            .store(in: &cancellables)

        // 右键菜单 / 状态栏菜单打开期间暂停自动隐藏。
        // 菜单窗口是面板的子窗口：不暂停的话，指针从标签移向"退出 App"
        // 那一项时离开条 0.2s，连条带菜单一起收掉，根本来不及点。
        // queue 传 nil：菜单跟踪是模态 runloop（eventTracking 模式），
        // 队列派发要等出模态才跑，同步回调才能及时把 menuTracking 置位。
        let nc = NotificationCenter.default
        menuObservers.append(nc.addObserver(
            forName: NSMenu.didBeginTrackingNotification, object: nil, queue: nil
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.menuTracking = true }
        })
        menuObservers.append(nc.addObserver(
            forName: NSMenu.didEndTrackingNotification, object: nil, queue: nil
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.menuTracking = false
                // 从关菜单这一刻重新计时，别一关就瞬间消失
                self.lastInteraction = Date()
            }
        })

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

        // 界面缩放：条要按新尺寸重排；正在显示的预览面板窗口尺寸已不对，直接收起
        prefs.$uiScale
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.hidePreview()
                self?.relayout()
            }
            .store(in: &cancellables)

        prefs.$hideMinimizedWindows
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.hidePreview() }
            .store(in: &cancellables)

        // 顶部唤出位置改了：立刻把面板摆到正确的那块屏上
        prefs.$hotZoneScreen
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.relayout() }
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
        TTLog("hotZone 模式=\(prefs.hotZoneScreen.rawValue) "
              + "锚定屏=\(anchorScreen?.localizedName ?? "-") 热区=\(hotZone)")
        relayout()
        startMouseTracking()
        promptAccessibilityIfNeeded()
        applyBarEnabled()
    }

    /// 调试用（`--test-hotzone=<屏序号>`）：重放"在 0 号屏上用过一次 ⌘Tab"的场景，
    /// 再按正常流程收起，把面板停靠位置与热区落到哪块屏写进日志。
    /// 用来验证热区不会被 ⌘Tab 带跑 —— 这正是这次修的那个 bug。
    func diagnoseHotZone(pointerOnScreen index: Int) {
        let screens = NSScreen.screens
        guard screens.indices.contains(index) else { return }
        let target = screens[index]
        TTLog("自检：模拟在 [#\(index)] \(target.localizedName) 上用 ⌘Tab 呼出")
        pinnedToMouse = true
        pinnedAnchor = NSPoint(x: target.frame.midX, y: target.frame.midY)
        beginReveal()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            TTLog("  钉住后 panel.frame=\(self.panel.frame) 所在屏=\(self.panel.screen?.localizedName ?? "-")")
            self.hide()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                let hot = self.hotZone
                let hotScreen = NSScreen.screens.first { $0.frame.intersects(hot) }
                let anchor = self.anchorScreen
                TTLog("  收起后 panel.frame=\(self.panel.frame) 所在屏=\(self.panel.screen?.localizedName ?? "-")")
                TTLog("  热区=\(hot) → 落在 \(hotScreen?.localizedName ?? "?")")
                TTLog("  锚定屏(设置=\(self.prefs.hotZoneScreen.title))=\(anchor?.localizedName ?? "-")")
                TTLog("  结论：锚定屏顶部"
                      + (hotScreen?.localizedName == anchor?.localizedName ? "可唤出 ✓" : "唤不出 ✗"))
            }
        }
    }

    /// 悬浮条总开关 + 常驻判断。状态栏菜单和设置窗口都会调它。
    func applyBarEnabled() {
        // ⌘Tab 钩子跟着总开关走：条关了就该把快捷键还给系统。
        // 开关持久化为开但钩子装不上（权限被撤销）→ 弹回并提示，不静默失败
        if !applyCmdTab() {
            prefs.cmdTabEnabled = false
            cmdTabInstallFailed()
        }
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

    /// ⌘Tab 拦截的开关收敛点：总开关关 / 功能关 → 停钩子（把快捷键还给系统）；
    /// 功能开但拿不到钩子（缺辅助功能权限）→ 保持关闭状态并提示，
    /// 免得设置里显示"已开启"实际却没生效。
    @discardableResult
    func applyCmdTab() -> Bool {
        guard prefs.cmdTabEnabled, prefs.barEnabled else {
            cmdTap.stop()
            // 钩子没了就收不到"松 ⌘"，残留会话会把条钉住不收：直接取消
            catalog.endKeyboardSession()
            cmdTap.swallowEscape = false
            return true
        }
        cmdTap.interceptEnabled = true
        guard cmdTap.start() else {
            cmdTap.stop()
            return false
        }
        return true
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
        beginReveal()
    }

    // MARK: - ⌘Tab 会话（AppRing 同款：弹条 + 预选上一个 + 松 ⌘ 提交）

    /// 第一次按下：立即在鼠标位置弹条，并预选上一个 App。
    /// 之后每一发 Tab（含按住自动重复）沿 MRU 前进高亮。
    private func cmdTabDown() {
        guard prefs.barEnabled else { return }
        // 会话中再按一次 ⌘Tab（非自动重复）：等价于"前进一格"，
        // 不能重新 start —— 那会把高亮重置回上一个 App，循环被卡死
        if catalog.keyboardSession {
            cmdTabCycle()
            return
        }
        guard catalog.startKeyboardSession() else {
            // 只有一个可见 App，没什么可切的：退回普通唤出
            revealAtMouse()
            return
        }
        cmdTap.swallowEscape = true
        revealAtMouse()
    }

    /// 会话中再按 Tab：高亮前进一格，并续住宽限期
    private func cmdTabCycle() {
        guard catalog.keyboardSession else { return }
        catalog.cycleKeyboardSession()
        bumpInteractionGrace()
    }

    /// Tab 松手：不做任何提交，等 ⌘ 松开那一刻统一决定。
    /// （用户可能按住 Tab 不放先移动鼠标，也可能 Tab 早松 ⌘ 还按着。）
    private func cmdTabUp() {}

    /// 松开 ⌘：会话结束 → 提交当前高亮。快按快放因此天然等于"切上一个"。
    private func cmdCommandReleased() {
        cmdTap.swallowEscape = false
        guard catalog.keyboardSession else { return }
        catalog.commitKeyboardSession()
        // 提交后条按正常延迟收起；高亮复位，下次唤出不残留
        lastInteraction = Date()
        // 常驻模式（不自动隐藏）下条不会自己收，得主动摆回主屏顶部 ——
        // 否则会一直钉在 ⌘Tab 弹出的那个位置（可能已经跑到副屏）
        if prefs.hideDelay <= 0 { parkOnAnchorScreen() }
    }

    /// ⌘Tab 呼出：面板钉在鼠标位置出现。已在显示（比如从顶部热区唤出）时，
    /// 直接把它挪到鼠标处并重置隐藏计时。
    func revealAtMouse() {
        guard prefs.barEnabled else { return }
        pinnedToMouse = true
        pinnedAnchor = NSEvent.mouseLocation
        TTLog("revealAtMouse anchor=\(pinnedAnchor) revealed=\(isRevealed)")
        if isRevealed {
            bumpInteractionGrace()
            relayout()
            return
        }
        beginReveal()
        bumpInteractionGrace()
    }

    /// ⌘Tab 呼出后给 0.8s 宽限：默认隐藏延迟可能只有 0.2s，
    /// 手指从键盘挪到面板需要一点时间，不给宽限条会"闪一下就没了"。
    /// 按住 Tab 自动重复时每一发都会续期。
    private func bumpInteractionGrace() {
        lastInteraction = max(lastInteraction, Date().addingTimeInterval(0.8))
    }

    private func beginReveal() {
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
        pinnedToMouse = false
        hidePreview()
        // 整条要离场了，高亮状态跟着复位，下次唤出时不会残留
        catalog.pointerOverBar = false
        // 条都离场了，⌘Tab 会话不可能还在进行（正常路径松 ⌘ 已提交）；
        // 走到这里说明是异常收尾，直接取消，别让残留会话把条钉住不收
        if catalog.keyboardSession {
            catalog.endKeyboardSession()
            cmdTap.swallowEscape = false
        }

        guard prefs.animationsEnabled else {
            panel.orderOut(nil)
            panel.alphaValue = 1
            parkOnAnchorScreen()
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
            self.parkOnAnchorScreen()
        }
    }

    /// 收起后把面板 frame 挪回锚定屏（隐藏状态下做，无视觉影响）。
    ///
    /// ⌘Tab 在副屏呼出过之后，面板 frame 会留在副屏。不挪回去的话，
    /// 面板就"停"在副屏上，下次唤出会先在副屏闪一下再跳回主屏 ——
    /// 而且任何以 panel.screen 兜底的判断都会继续指错屏。
    private func parkOnAnchorScreen() {
        guard !isRevealed else { return }
        pinnedToMouse = false
        relayout()
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

    /// 屏幕选择的纯逻辑：不碰 NSScreen，只吃"每块屏有没有刘海 + frame"，
    /// 这样多屏那条回归路径（鼠标在副屏、刘海屏该不该响应）能离线测。
    enum ScreenPick {
        /// 有刘海的那块屏；一台都没有刘海时退化成系统主屏（第 0 块）。
        static func notchedIndex(notched: [Bool]) -> Int? {
            guard !notched.isEmpty else { return nil }
            return notched.firstIndex(of: true) ?? 0
        }

        /// 带菜单栏的系统主显示器：`screens` 首元素，坐标原点恒为 (0,0)。
        /// 注意它跟"刘海屏"是两回事 —— 外接屏被设为主屏时，刘海在另一块屏上。
        static func menuBarIndex(notched: [Bool]) -> Int? {
            notched.isEmpty ? nil : 0
        }

        /// 顶部热区 / 默认停靠位用哪块屏。
        ///
        /// `.notch` / `.menuBar` 都**与鼠标位置无关** —— 鼠标在另一块屏时，
        /// 目标屏顶部照样响应，反之外接屏顶部不响应。这正是这次要修的行为：
        /// 以前热区跟着 `panel.screen` 走，⌘Tab 在副屏弹过一次，
        /// 热区就搬到副屏，刘海那块屏反而怎么顶都没反应。
        static func anchorIndex(for target: HotZoneScreen,
                                notched: [Bool],
                                frames: [CGRect],
                                mouse: CGPoint) -> Int? {
            switch target {
            case .notch:
                return notchedIndex(notched: notched)
            case .menuBar:
                return menuBarIndex(notched: notched)
            case .followMouse:
                guard let fallback = notchedIndex(notched: notched) else { return nil }
                return frames.firstIndex { $0.contains(mouse) } ?? fallback
            }
        }
    }

    /// 启动时的落位屏：按默认设置（刘海屏）。
    ///
    /// 千万不要用 `panel.screen`：它是"面板当前停在哪个屏"，⌘Tab 在副屏弹过一次
    /// 之后面板就留在副屏，用它算热区 = 热区跟着搬到副屏，刘海那块屏再也唤不出。
    /// 也不要用 `NSScreen.main`：它跟着"当前接收键盘事件的窗口"漂移，同样不稳。
    /// 合盖模式下内置屏不在列表里，`notchedIndex` 自然回落到外接那块。
    static var notchedFlags: [Bool] {
        if #available(macOS 12.0, *) {
            return NSScreen.screens.map { $0.auxiliaryTopLeftArea != nil }
        }
        return NSScreen.screens.map { _ in false }
    }

    static var defaultScreen: NSScreen? {
        let screens = NSScreen.screens
        guard let i = ScreenPick.notchedIndex(notched: notchedFlags), i < screens.count else { return nil }
        return screens[i]
    }

    /// 顶部热区与"默认停靠位"落在哪块屏，由设置里的「顶部唤出位置」决定。
    /// ⌘Tab 呼出不走这里 —— 它永远在鼠标位置弹出，那才是这个功能的意义。
    private var anchorScreen: NSScreen? {
        let screens = NSScreen.screens
        guard let i = ScreenPick.anchorIndex(for: prefs.hotZoneScreen,
                                             notched: TabBarController.notchedFlags,
                                             frames: screens.map(\.frame),
                                             mouse: NSEvent.mouseLocation),
              i < screens.count else { return nil }
        return screens[i]
    }

    /// 顶部中央的唤醒区（菜单栏高度），鼠标顶上来就显示。
    ///
    /// 宽度可在设置里调（默认 120pt ≈ 4 个状态栏图标），**不跟面板宽度走**：
    /// 之前按 `max(面板宽, 380)` 算，App 一多或外接屏缩放比例不同时，
    /// 唤醒区会横向铺满大半个菜单栏，鼠标去点右上角状态图标就误唤醒，
    /// 干扰正常点击。唤醒只需要顶部中间一小块，面板出来后由面板区域
    /// 自己维持驻留（tick 里的并集判断），收窄不影响日常使用。
    private var hotZone: NSRect {
        let screen = anchorScreen ?? panel.screen ?? NSScreen.main ?? NSScreen.screens[0]
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

        if menuTracking || catalog.keyboardSession {
            // 菜单开着：指针在菜单上（面板的子窗口），条不能收。
            // ⌘Tab 会话中：面板是键盘驱动的，条必须一直待到松 ⌘ 提交为止。
            // 持续续期，关菜单/会话结束后按正常延迟收起。
            lastInteraction = now
        } else if inPanel || inPreview || inHot {
            lastInteraction = now
            if !isRevealed {
                TTLog("hotZone 唤出 mouse=\(mouse) zone=\(hot) screen=\(anchorScreen?.localizedName ?? "-")")
                reveal()
            }
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

    func cmdTabInstallFailed() {
        // 异步弹出：这个函数可能在 start() → applicationDidFinishLaunching 栈里
        // 被调用（上次开着 ⌘Tab 但这次权限被撤销），runModal 会阻塞启动。
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = "无法接管 ⌘Tab"
            alert.informativeText = "安装键盘事件钩子需要「辅助功能」权限。\n请先在系统设置中勾选 TopTab，再回到设置里重新打开这个开关。"
            alert.addButton(withTitle: "去授权")
            alert.addButton(withTitle: "取消")
            NSApp.activate(ignoringOtherApps: true)
            if alert.runModal() == .alertFirstButtonReturn {
                WindowBridge.requestAccessibilityPermission()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    WindowBridge.openAccessibilitySettings()
                }
            }
        }
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

    /// ⌘Tab 呼出时面板钉在鼠标处：水平居中于指针，垂直方向默认放在指针上方
    /// （切 App 时手多半在下方移动，上方视野更干净）；离屏幕上缘太近就翻到下方。
    /// 贴边时按屏幕可用区内收，保证整条完整可见。
    private static func mouseFrame(for screen: NSScreen, width: CGFloat, height: CGFloat,
                                   mouse: NSPoint) -> NSRect {
        let visible = screen.visibleFrame
        let maxWidth = visible.width - 24
        let w = max(220, min(width, maxWidth))
        let x = min(max(mouse.x - w / 2, visible.minX + 12), visible.maxX - w - 12)
        let gap: CGFloat = 18
        var y = mouse.y + gap
        if y + height > visible.maxY - 8 {
            y = mouse.y - gap - height
        }
        y = min(max(y, visible.minY + 8), visible.maxY - height - 8)
        return NSRect(x: x, y: y, width: w, height: height)
    }

    private func relayout() {
        // 钉在鼠标处时以"指针所在屏"为准：panel.screen 反映的是面板旧位置，
        // 多屏下 ⌘Tab 在副屏触发、面板却还留在主屏的话会弹错地方。
        //
        // 非钉住（顶部热区唤出 / 常驻）时用 anchorScreen —— 主显示器。
        // 以前这里是 panel.screen，于是 ⌘Tab 在副屏弹过一次后，
        // 面板 frame 留在副屏，之后顶部唤出就一直在副屏，主屏彻底没反应。
        let screen: NSScreen? = pinnedToMouse
            ? (NSScreen.screens.first { $0.frame.contains(pinnedAnchor) }
                ?? panel.screen ?? NSScreen.main ?? NSScreen.screens.first)
            : (anchorScreen ?? panel.screen ?? NSScreen.main ?? NSScreen.screens.first)
        guard let screen else { return }
        // preferredWidth 已经优先返回 SwiftUI 实测的内容宽度，
        // 这样左右两边的 12pt 内边距才真的对称，最右边的标签不会被圆角切掉。
        let target = pinnedToMouse
            ? TabBarController.mouseFrame(for: screen, width: catalog.preferredWidth,
                                          height: barHeight, mouse: pinnedAnchor)
            : TabBarController.targetFrame(
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
