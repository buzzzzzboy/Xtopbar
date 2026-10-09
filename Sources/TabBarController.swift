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
    /// 开始按钮 / 右键菜单 / 状态栏菜单：开关开始菜单
    func toggleStartMenu()
    /// 收起窗口预览（开始拖标签时）
    func dismissPreview()
}

/// 停靠边相关的几何：纯矩形运算，不碰 NSScreen / 面板，
/// 底部 / 顶部两套摆法能离线核对（`--test-pins` 会把两边都打一遍）。
enum DockGeometry {
    /// 面板落位：顶部 = 菜单栏正下方 inset；底部 = 可用区底边往上 inset
    /// （系统 Dock 常驻时 visibleFrame 已经把它让出去了，不会叠在一起）。
    /// 面板最小宽度只兜一个底（防止实测前宽度为 0）。
    /// 以前是 220：只剩一两个 App 时内容比 220 窄，内容靠左，右边就空出一截。
    static let minBarWidth: CGFloat = 48

    static func barFrame(edge: DockEdge, visible: CGRect,
                         width: CGFloat, height: CGFloat, inset: CGFloat) -> CGRect {
        let maxWidth = visible.width - 24
        let w = max(minBarWidth, min(width, maxWidth)).rounded(.up)
        // 原点取整：窗口落在半像素上整条内容都会发糊
        let x = (visible.midX - w / 2).rounded()
        let y = (edge == .top
            ? visible.maxY - inset - height   // visibleFrame 已排除菜单栏，maxY 即菜单栏正下方
            : visible.minY + inset).rounded()
        return CGRect(x: x, y: y, width: w, height: height)
    }

    /// 唤出区。
    /// - 顶部：菜单栏中央一块（宽度可调，默认 120pt，免得误触右上角状态图标）。
    ///   上边界越过屏幕顶 2pt：鼠标贴顶时 y == maxY，半开区间不越过就会漏判。
    /// - 底部：屏幕底边一条 6pt 高的窄带（向下越出 2pt，同理），宽度取条宽与设置值的较大者 ——
    ///   底边没有状态图标可误触，跟 Dock 一样沿着条的整段都能顶出来。
    static func hotZone(edge: DockEdge, screen: CGRect, visible: CGRect,
                        zoneWidth: CGFloat, barWidth: CGFloat) -> CGRect {
        switch edge {
        case .top:
            let menuBarHeight = screen.maxY - visible.maxY
            let height = menuBarHeight + 5
            return CGRect(x: screen.midX - zoneWidth / 2,
                          y: screen.maxY - height + 2,
                          width: zoneWidth, height: height)
        case .bottom:
            let width = max(zoneWidth, barWidth)
            return CGRect(x: screen.midX - width / 2, y: screen.minY - 2,
                          width: width, height: 6)
        }
    }

    /// 进出场位移方向：顶部从上方落下（+），底部从下方升起（−）
    static func slideSign(edge: DockEdge) -> CGFloat {
        edge == .top ? 1 : -1
    }

    /// 预览 / 开始菜单往哪边弹：条在屏幕下半部 → 向上，否则向下。
    /// 按条的实际位置而不是设置判定。
    static func opensUpward(barFrame: CGRect, visible: CGRect) -> Bool {
        barFrame.midY < visible.midY
    }

    /// 贴着条摆一个弹出面板（预览 / 开始菜单）：水平以 anchorX 为准（alignLeft 时左对齐），
    /// 垂直在条的上方或下方留 gap，最后夹进可用区。
    static func popupFrame(size: CGSize, anchorX: CGFloat, alignLeft: Bool,
                           barFrame: CGRect, visible: CGRect, gap: CGFloat) -> CGRect {
        var x = alignLeft ? anchorX : anchorX - size.width / 2
        x = max(visible.minX + 8, min(x, visible.maxX - size.width - 8))
        var y = opensUpward(barFrame: barFrame, visible: visible)
            ? barFrame.maxY + gap
            : barFrame.minY - gap - size.height
        y = max(visible.minY + 4, min(y, visible.maxY - size.height - 4))
        return CGRect(x: x, y: y, width: size.width, height: size.height)
    }
}

/// 面板生命周期 + 定位 + 尺寸自适应 + 自动隐藏 + 预览调度。
///
/// 一个实例 = 一条。多屏「各屏一条」时 `TabBarFleet` 给每块屏建一个，各管各的屏（`fixedDisplay`）。
@MainActor
final class TabBarController: TabBarHost {

    private let catalog: AppCatalog
    private let prefs: Preferences
    private let panel: FloatingPanel
    private var hostingView: FirstMouseHostingView<TabBarView>?
    private var cancellables = Set<AnyCancellable>()
    private var currentWidth: CGFloat = 0

    /// 面板高度 / 距菜单栏间隙随界面缩放联动（计算属性，uiScale 变了下次 relayout 生效）
    private var barHeight: CGFloat { TTLayout.barHeight }
    private var topInset: CGFloat { TTLayout.s(6) }

    private var isRevealed = false
    private var lastInteraction = Date.distantPast
    private var mouseTimer: Timer?
    private var isHoveringBar = false
    /// 按住标签期间连续几拍看到左键已放开（mouseUp 丢失的兜底，见 tick）
    private var releasedWhilePressing = 0

    /// 有 NSMenu 正在跟踪（右键菜单 / 状态栏菜单）。菜单是面板的子窗口，
    /// 菜单一开就必须暂停自动隐藏：用户从标签移到"退出 App"那一项时
    /// 指针早就离开条了，不暂停的话 0.2s 后连条带菜单一起收掉，根本来不及点。
    private var menuTracking = false
    private var menuObservers: [NSObjectProtocol] = []

    // MARK: - 常驻 / 不挡窗口 / 全屏让位

    /// 前台 App 在条所在的屏上全屏中。常驻的条（不自动隐藏 / 不挡窗口）此时也要让开，
    /// 和系统 Dock、Windows 任务栏一样；顶到屏幕边缘仍能临时唤出。
    private var fullscreenActive = false
    /// 巡检（全屏判断 + 挪窗口）的节拍器；一轮 AX 没跑完不叠下一轮
    private var environmentTimer: Timer?
    private var environmentPassRunning = false

    /// 调度中心开着：条淡出让位，期间不响应唤出；退出后按原模式恢复。
    /// 所有条共用一个（`TabBarFleet` 持有，进出时调各条的 `missionControlChanged`）
    private let missionControl: MissionControlWatcher

    // MARK: - 多屏

    /// 多屏「各屏一条」时这条固定停在哪块屏（显示器编号）。
    /// nil = 单条模式：按设置里的「唤出所在屏幕」挑屏（`ScreenPick`）
    private var fixedDisplay: CGDirectDisplayID?

    /// 主条（单条模式下就是那一条）：启动时由它提示缺辅助功能权限，免得每条各弹一次
    private let isPrimary: Bool

    /// 条该不该一直显示：常驻模式或「不挡窗口」，且没有 App 在全屏
    private var wantsResident: Bool {
        (prefs.hideDelay <= 0 || prefs.avoidWindows) && !fullscreenActive && !missionControl.isActive
    }

    /// 实际生效的自动隐藏延迟。该常驻时为 0；全屏让位时，本来常驻的条退回 0.2s，
    /// 这样顶边缘临时唤出后鼠标一走它还能自己收回去。
    private var effectiveHideDelay: Double {
        if wantsResident { return 0 }
        return prefs.hideDelay > 0 ? prefs.hideDelay : 0.2
    }

    // MARK: - 预览

    private let preview = PreviewController()
    private lazy var startMenu = StartMenuController(catalog: catalog)
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

    init(catalog: AppCatalog, missionControl: MissionControlWatcher,
         display: CGDirectDisplayID?, isPrimary: Bool) {
        self.catalog = catalog
        self.prefs = Preferences.shared
        self.missionControl = missionControl
        self.fixedDisplay = display
        self.isPrimary = isPrimary

        let initialScreen = display.flatMap { id in NSScreen.screens.first { $0.displayID == id } }
            ?? TabBarController.defaultScreen
        let frame = initialScreen.map {
            DockGeometry.barFrame(edge: Preferences.shared.dockEdge, visible: $0.visibleFrame,
                                  width: 600, height: TTLayout.barHeight, inset: 6)
        } ?? NSRect(x: 0, y: 0, width: 600, height: TTLayout.barHeight)
        self.panel = FloatingPanel(contentRect: frame)
        // 比系统 Dock 低一层（其它窗口照样压得住）：Dock 自动隐藏时滑鼠顶到底边把它叫出来，
        // 它盖在条上面正常用，而不是被条挡住
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.dockWindow)) - 1)

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

        // 点击命中：AppKit 窗口坐标（原点左下）→ SwiftUI 坐标（原点上左）。
        // 两段式：按下记住标签，抬起才切 App；中间拖过阈值就变成拖动排序。
        panel.onPress = { [weak self] locationInWindow in
            guard let self else { return false }
            return self.catalog.handlePress(at: self.viewPoint(fromWindow: locationInWindow))
        }
        panel.onDrag = { [weak self] locationInWindow in
            guard let self else { return }
            self.catalog.handleDrag(to: self.viewPoint(fromWindow: locationInWindow))
        }
        panel.onRelease = { [weak self] locationInWindow in
            guard let self else { return }
            self.catalog.handleRelease(at: self.viewPoint(fromWindow: locationInWindow))
            // 拖着拖着指针可能已经离开条了，从松手这一刻重新计时
            self.lastInteraction = Date()
            self.refreshPreviewAfterClick()
        }

        catalog.onLayoutNeeded = { [weak self] in self?.relayout() }
        catalog.host = self

        // 标签悬停 → 延迟弹出窗口预览
        catalog.onTabHover = { [weak self] entry in
            // 拖动排序中指针扫过的标签不弹预览、不抢高亮
            guard self?.catalog.drag == nil else { return }
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
                // 点的就是眼下正在用的那扇窗口 → 收进 Dock（同 Windows 任务栏缩图）
                if !win.isMinimized,
                   WindowBridge.minimizeIfCurrent(pid: pid, axIndex: win.axIndex,
                                                  frame: win.frame, title: win.title, cgID: win.id) {
                    return
                }
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

        // 隐藏列表 / 任务栏固定变化 → 立刻重采（否则要等 1.2s 兜底轮询）
        prefs.$hiddenApps
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.catalog.refresh() }
            .store(in: &cancellables)
        prefs.$dockPins
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.catalog.refresh() }
            .store(in: &cancellables)
        // 「只显示有窗口的 App」开关：立刻重采；打开时顺手查一轮窗口
        prefs.$onlyWindowedApps
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.catalog.refresh()
                self?.catalog.scanWindows()
            }
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
            MainActor.assumeIsolated {
                self?.menuTracking = true
                self?.catalog.menuTracking = true
            }
        })
        menuObservers.append(nc.addObserver(
            forName: NSMenu.didEndTrackingNotification, object: nil, queue: nil
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.menuTracking = false
                self.catalog.menuTracking = false
                // 菜单开着期间暂停了重采，这里补一次（菜单项的动作也可能刚改了固定）
                self.catalog.refresh()
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
            .sink { [weak self] _ in
                // 切到"常驻"立刻显示；切到更短的延迟由 tick 按 effectiveHideDelay 立刻收
                self?.applyResidency()
                self?.environmentTick()
            }
            .store(in: &cancellables)

        // 不挡窗口：打开立刻常驻并巡检一轮；关掉后 tick 按原来的自动隐藏延迟收
        prefs.$avoidWindows
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.applyResidency()
                self?.environmentTick()
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

        // 拖分隔线调大小：条跟着重排（不收预览 —— 按下分隔线时已经收了）
        LiveScale.shared.$value
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.relayout() }
            .store(in: &cancellables)

        // 圆角变了：面板阴影是按内容轮廓算的，等这一拍画完再重算，不然阴影还是旧圆角
        prefs.$barCornerRadius
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                DispatchQueue.main.async { self?.panel.invalidateShadow() }
            }
            .store(in: &cancellables)

        prefs.$hideMinimizedWindows
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.hidePreview() }
            .store(in: &cancellables)

        // 停靠边 / 图标风格改了：面板高度和位置都变了，预览、开始菜单位置作废，收起后重排
        Publishers.Merge3(prefs.$dockEdge.dropFirst().map { _ in () },
                          prefs.$iconOnly.dropFirst().map { _ in () },
                          prefs.$showStartButton.dropFirst().map { _ in () })
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.hidePreview()
                self.startMenu.close(animated: false)
                self.currentWidth = 0
                self.relayout()
            }
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
              + "錨定螢幕=\(anchorScreen?.localizedName ?? "-") 熱區=\(hotZone)")
        relayout()
        startMouseTracking()
        if isPrimary { promptAccessibilityIfNeeded() }
        applyBarEnabled()
    }

    /// 改这条停在哪块屏（多屏模式开关 / 主显示器换了）。nil = 回到单条模式
    func assign(display: CGDirectDisplayID?) {
        guard fixedDisplay != display else { return }
        fixedDisplay = display
        hidePreview()
        startMenu.close(animated: false)
        currentWidth = 0
        relayout()
    }

    /// 拆掉这条（它那块屏拔掉了 / 多屏模式关了）：停计时器和钩子、收起所有浮层
    func shutdown() {
        mouseTimer?.invalidate()
        mouseTimer = nil
        environmentTimer?.invalidate()
        environmentTimer = nil
        cancellables.removeAll()
        menuObservers.forEach { NotificationCenter.default.removeObserver($0) }
        menuObservers.removeAll()
        NotificationCenter.default.removeObserver(self)
        previewWork?.cancel()
        preview.close()
        startMenu.close(animated: false)
        isRevealed = false
        panel.orderOut(nil)
        catalog.stop()
    }

    /// 拖动排序的落点 / 让位算法（纯几何，不碰真实标签）：三个宽窄不一的标签
    /// A[0,100] B[110,150] C[160,260]，期望值写在日志里对照
    private func diagnoseTabDrag() {
        let icon = NSImage()
        let entries = ["A", "B", "C"].map {
            AppEntry(id: $0, pid: 0, name: $0, icon: icon, category: .other)
        }
        let groups = [AppGroup(id: "g", category: .other, entries: entries)]
        let frames: [String: CGRect] = [
            "A": CGRect(x: 0, y: 0, width: 100, height: 30),
            "B": CGRect(x: 110, y: 0, width: 40, height: 30),
            "C": CGRect(x: 160, y: 0, width: 100, height: 30)
        ]
        func run(_ id: String, by dx: CGFloat, expect: String) {
            guard let entry = entries.first(where: { $0.id == id }),
                  var drag = TabDrag(entry: entry, startX: 0, groups: groups, frames: frames) else { return }
            drag.move(to: dx)
            let offsets = drag.ids.map { "\($0)=\(drag.offset(for: $0))" }.joined(separator: " ")
            TTLog("  拖動 \(id) \(dx)：順序 \(drag.reorderedIDs.joined()) 位移 \(offsets)（期望 \(expect)）")
        }
        run("A", by: 20, expect: "ABC，A=20")
        run("A", by: 40, expect: "BAC，B=-110")
        run("A", by: 999, expect: "BCA，A 夾到 160，B=C=-110")
        run("C", by: -60, expect: "ACB，B=110")
        run("C", by: -999, expect: "CAB，C 夾到 -160，A=B=110")
    }

    /// 调试自检：`--test-pins`
    /// 把固定 / 运行分组、两种停靠边下的面板位置与唤出区、以及一次应用搜索写进日志，
    /// 用来核对"固定项排最前、没运行的 pid=0"和底部停靠的几何是不是对的。
    func diagnosePins() {
        catalog.refresh()
        TTLog("自檢：工作列固定 \(prefs.dockPins.map(\.name))，開始選單固定 \(prefs.startPins.map(\.name))")
        for group in catalog.groups {
            TTLog("  組 \(group.category.title)：" + group.entries.map {
                "\($0.name)[pid=\($0.pid) running=\($0.isRunning) pinned=\($0.isPinned)]"
            }.joined(separator: ", "))
        }
        diagnoseTabDrag()
        guard let screen = anchorScreen else { return }
        for edge in DockEdge.allCases {
            let bar = DockGeometry.barFrame(edge: edge, visible: screen.visibleFrame,
                                            width: catalog.preferredWidth, height: barHeight,
                                            inset: topInset)
            let zone = DockGeometry.hotZone(edge: edge, screen: screen.frame,
                                            visible: screen.visibleFrame,
                                            zoneWidth: CGFloat(prefs.hotZoneWidth),
                                            barWidth: bar.width)
            let menu = DockGeometry.popupFrame(size: StartMenuController.size, anchorX: bar.minX + 12,
                                               alignLeft: true, barFrame: bar,
                                               visible: screen.visibleFrame, gap: 8)
            TTLog("  [\(edge.rawValue)] 條=\(bar) 喚出區=\(zone) 開始選單=\(menu) "
                  + "向上彈=\(DockGeometry.opensUpward(barFrame: bar, visible: screen.visibleFrame))")
        }
        // 不挡窗口：一扇铺满可用区的窗口，两种停靠边下各会被挪成什么样
        let visibleCG = AvoidGeometry.cgRect(screen.visibleFrame)
        for edge in DockEdge.allCases {
            let bar = AvoidGeometry.cgRect(DockGeometry.barFrame(
                edge: edge, visible: screen.visibleFrame, width: catalog.preferredWidth,
                height: barHeight, inset: topInset))
            let moved = AvoidGeometry.adjusted(window: visibleCG, bar: bar, gap: topInset, edge: edge,
                                               screen: AvoidGeometry.cgRect(screen.frame),
                                               visible: visibleCG)
            TTLog("  [\(edge.rawValue)] 不擋視窗：鋪滿視窗 \(visibleCG) → \(moved.map { "\($0)" } ?? "不動")")
        }
        TTLog("  只顯示有視窗的 App=\(prefs.onlyWindowedApps)，判定無視窗：\(WindowPresence.shared.windowless.compactMap { NSRunningApplication(processIdentifier: $0)?.localizedName })")
        // 多屏各屏一条：窗口算哪块屏、这条收不收某个 App（纯逻辑样例，期望值写在日志里）
        let pair = [CGRect(x: 0, y: 0, width: 100, height: 100), CGRect(x: 100, y: 0, width: 100, height: 100)]
        let straddle = ScreenAssign.index(of: CGRect(x: 80, y: 10, width: 60, height: 50), in: pair)
        let outside = ScreenAssign.index(of: CGRect(x: 500, y: 0, width: 10, height: 10), in: pair)
        TTLog("  視窗歸屬：跨兩屏偏右 → \(straddle.map { "#\($0)" } ?? "nil")（期望 #1），"
              + "屏外 → \(outside.map { "#\($0)" } ?? "nil")（期望 nil）")
        let scope = ScreenScope(displayID: 2, isPrimary: false)
        TTLog("  副屏那條：視窗在副屏 → \(scope.admits([2], live: [1, 2]))（期望 true），"
              + "只在主屏 → \(scope.admits([1], live: [1, 2]))（期望 false），"
              + "還沒查到 → \(scope.admits(nil, live: [1, 2]))（期望 false，歸主屏那條）")
        TTLog("  同 App 多條：兩屏都有視窗 → \(scope.windowTitle([1, 2], live: [1, 2], titles: [2: "YouTube"]) ?? "nil")（期望 YouTube），"
              + "只在副屏 → \(scope.windowTitle([2], live: [1, 2], titles: [2: "YouTube"]) ?? "nil")（期望 nil），"
              + "名稱 → \(AppEntry.label(name: "Chrome", windowTitle: "一個非常非常非常非常非常長的分頁標題"))（期望截到 20 字）")
        TTLog("  視窗數圓圈：副屏那條 → \(ScreenScope.windowCount([1: 2, 2: 3], scope: scope))（期望 3），"
              + "單條模式 → \(ScreenScope.windowCount([1: 2, 2: 3], scope: nil))（期望 5）")
        TTLog("  本條螢幕=\(fixedDisplay.map { "\($0)" } ?? "單條模式")，"
              + "已知視窗分佈的 App \(WindowPresence.shared.screensByPID.count) 個")
        let lib = AppLibrary.shared
        TTLog("  應用索引 \(lib.apps.count) 個；搜尋「saf」→ \(lib.search("saf").prefix(3).map(\.name))")
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
        if wantsResident {
            reveal()               // 常驻模式 / 不挡窗口
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
        guard !isRevealed, prefs.barEnabled, !missionControl.isActive else { return }
        beginReveal()
    }

    /// - fade: 纯淡入、不滑动、稍慢一点（从调度中心回来时用，跟系统的过渡节奏一致）
    private func beginReveal(animated: Bool = true, fade: Bool = false) {
        isRevealed = true
        lastInteraction = Date()
        relayout()

        let idle = CGFloat(prefs.idleOpacity)
        guard animated, prefs.animationsEnabled else {
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
        // 顶部从上方落下，底部从下方升起
        start.origin.y += (fade ? 0 : 14) * DockGeometry.slideSign(edge: prefs.dockEdge)
        panel.alphaValue = 0
        panel.setFrame(start, display: false)
        panel.orderFrontRegardless()
        animateWindow(to: target, alpha: idle, duration: fade ? 0.2 : 0.05, timing: .easeOut)
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
        let pids = catalog.groups.flatMap { $0.entries }.map(\.pid).filter { $0 > 0 }
        Task { [weak self] in
            guard let self else { return }
            await self.engine.refresh(minInterval: 0, pids: pids)
            let ids = self.engine.warmupTargets()
            TTLog("warmup pids=\(pids.count) targets=\(ids.count)")
            self.engine.prewarm(ids, maxSize: PreviewLayout.thumbSize)
        }
    }

    /// - fade: 纯淡出、不滑动、稍慢一点（进调度中心时用）
    private func hide(animated: Bool = true, fade: Bool = false) {
        guard isRevealed else { return }
        isRevealed = false
        hidePreview()
        startMenu.close()
        // 整条要离场了，高亮状态跟着复位，下次唤出时不会残留
        catalog.pointerOverBar = false

        guard animated, prefs.animationsEnabled else {
            panel.orderOut(nil)
            panel.alphaValue = 1
            parkOnAnchorScreen()
            return
        }

        // 反向滑回屏幕边缘 + 淡出（和呼出同级别的快，0.07s）
        var end = panel.frame
        end.origin.y += (fade ? 0 : 8) * DockGeometry.slideSign(edge: prefs.dockEdge)
        animateWindow(to: end, alpha: 0, duration: fade ? 0.2 : 0.07) { [weak self] in
            guard let self, !self.isRevealed else { return }
            // 先离场再复位透明度，避免 orderOut 之前那一帧闪出全不透明的面板
            self.panel.orderOut(nil)
            self.panel.alphaValue = 1
            self.parkOnAnchorScreen()
        }
    }

    /// 收起后把面板 frame 挪回锚定屏（隐藏状态下做，无视觉影响）：
    /// 「滑鼠所在螢幕」模式下下次唤出可能换了屏，先归位免得在旧屏闪一下
    private func parkOnAnchorScreen() {
        guard !isRevealed else { return }
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
        /// 目标屏顶部照样响应，反之外接屏顶部不响应。
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

    /// 启动时的落位屏：按设置的「顶部唤出位置」算，跟运行时同一套逻辑。
    ///
    /// 千万不要用 `panel.screen`：它是"面板当前停在哪个屏"，用它算热区 = 热区跟着面板搬家。
    /// 也不要用 `NSScreen.main`：它跟着"当前接收键盘事件的窗口"漂移，同样不稳。
    static var notchedFlags: [Bool] {
        if #available(macOS 12.0, *) {
            return NSScreen.screens.map { $0.auxiliaryTopLeftArea != nil }
        }
        return NSScreen.screens.map { _ in false }
    }

    static var defaultScreen: NSScreen? {
        let screens = NSScreen.screens
        guard let i = ScreenPick.anchorIndex(for: Preferences.shared.hotZoneScreen,
                                             notched: notchedFlags,
                                             frames: screens.map(\.frame),
                                             mouse: NSEvent.mouseLocation),
              i < screens.count else { return nil }
        return screens[i]
    }

    /// 顶部热区与"默认停靠位"落在哪块屏，由设置里的「顶部唤出位置」决定。
    private var anchorScreen: NSScreen? {
        let screens = NSScreen.screens
        // 各屏一条：只认自己那块屏，屏拔掉了就是 nil（TabBarFleet 马上会拆掉这条）
        if let id = fixedDisplay { return screens.first { $0.displayID == id } }
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
    ///
    /// 停靠在底部时是屏幕底边一条窄带（见 `DockGeometry.hotZone`）。
    private var hotZone: NSRect {
        // 自己那块屏已经拔掉：别退到别的屏上去唤出（.null 不包含任何点，并集时也不占地方）
        if fixedDisplay != nil, anchorScreen == nil { return .null }
        let screen = anchorScreen ?? panel.screen ?? NSScreen.main ?? NSScreen.screens[0]
        return DockGeometry.hotZone(edge: prefs.dockEdge,
                                    screen: screen.frame,
                                    visible: screen.visibleFrame,
                                    zoneWidth: CGFloat(prefs.hotZoneWidth),
                                    barWidth: catalog.barWidth)
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

        // 全屏判断 + 挪窗口走 AX，比鼠标轮询贵得多：0.5s 一轮足够跟上窗口变化
        let env = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.environmentTick() }
        }
        RunLoop.main.add(env, forMode: .common)
        environmentTimer = env
    }

    /// 该常驻就把条亮出来（切换设置 / 退出全屏时调）。反方向不用管：
    /// 不该常驻时 tick 会按 effectiveHideDelay 把闲着的条收掉。
    private func applyResidency() {
        guard prefs.barEnabled, wantsResident else { return }
        reveal()
    }

    /// 常驻类模式的巡检（0.5s 一轮）：
    /// 1. 前台 App 在条所在屏上有没有全屏窗口 —— 有就让条让位；
    /// 2. 「不挡窗口」开着时，把前台 App 压到条上的窗口挪开 / 缩短（Windows 任务栏同款）。
    ///
    /// 只看前台 App：后台窗口就算被条盖住一角，切到前台的那一刻（0.5s 内）也会被挪开；
    /// 每轮去问所有 App 的窗口，对 Electron 系既慢又容易问出空列表。
    private func environmentTick() {
        guard prefs.barEnabled, prefs.hideDelay <= 0 || prefs.avoidWindows else {
            setFullscreen(false)
            return
        }
        // 调度中心里窗口都被缩成缩略图了，这时候量窗口 / 挪窗口都没有意义
        guard !environmentPassRunning, !missionControl.isActive,
              let screen = anchorScreen else { return }
        guard let front = NSWorkspace.shared.frontmostApplication,
              front.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
            // 前台是自己（设置窗口）：不存在"别人全屏"
            setFullscreen(false)
            return
        }

        let rest = TabBarController.targetFrame(for: screen, edge: prefs.dockEdge,
                                                width: catalog.preferredWidth,
                                                height: barHeight, inset: topInset)
        // 用户正按着鼠标（拖窗口 / 拉窗口边）时别抢，松手后下一轮再挪
        let adjust = prefs.avoidWindows && isRevealed
            && NSEvent.pressedMouseButtons == 0
        let bar = AvoidGeometry.cgRect(rest)
        let screenCG = AvoidGeometry.cgRect(screen.frame)
        let visibleCG = AvoidGeometry.cgRect(screen.visibleFrame)
        let edge = prefs.dockEdge
        let gap = topInset
        let pid = front.processIdentifier

        environmentPassRunning = true
        Task.detached(priority: .utility) { [weak self] in
            let fullscreen = WindowBridge.avoidPass(pid: pid, bar: bar, gap: gap, edge: edge,
                                                    screen: screenCG, visible: visibleCG,
                                                    adjust: adjust)
            await self?.finishEnvironmentPass(fullscreen: fullscreen)
        }
    }

    private func finishEnvironmentPass(fullscreen: Bool) {
        environmentPassRunning = false
        setFullscreen(fullscreen)
    }

    private func setFullscreen(_ on: Bool) {
        guard fullscreenActive != on else { return }
        fullscreenActive = on
        TTLog("fullscreen \(on ? "進入 → 條讓位" : "退出 → 條恢復常駐")")
        // 进入全屏：lastInteraction 早就过期了，下一帧 tick 按 0.2s 延迟收起（鼠标正停在条上则等它离开）
        if !on { applyResidency() }
    }

    /// 进调度中心：条（连同预览、开始菜单）淡出；退出：常驻类模式淡入恢复，
    /// 自动隐藏模式本来就藏着，保持藏着等鼠标顶边唤出。
    func missionControlChanged(_ active: Bool) {
        TTLog("MissionControl \(active ? "進入 → 條淡出" : "退出 → 恢復")")
        if active {
            hidePreview()
            startMenu.close(animated: false)
            hide(fade: true)
        } else {
            // 从这一刻重新计时，别一回来就被判定为"闲置太久"立刻又收掉
            lastInteraction = Date()
            guard prefs.barEnabled, wantsResident, !isRevealed else { return }
            beginReveal(fade: true)
        }
    }

    private func tick() {
        guard prefs.barEnabled else {
            if isRevealed { hide() }
            return
        }
        // 调度中心开着：条已经淡出，期间唤出区、自动隐藏计时一概不管
        guard !missionControl.isActive else { return }

        let mouse = NSEvent.mouseLocation
        let now = Date()
        let delay = effectiveHideDelay

        // 按住标签期间 mouseUp 丢了（左键其实已经放开）：清掉按住 / 拖动状态。
        // 连续两拍都是放开才算 —— 快速单击时键刚放开、mouseUp 还排在队列里，
        // 只看一拍会把这次点击吞掉。
        if catalog.isPressing, NSEvent.pressedMouseButtons & 1 == 0 {
            releasedWhilePressing += 1
            if releasedWhilePressing >= 2 { catalog.cancelPress() }
        } else {
            releasedWhilePressing = 0
        }

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
        //
        // 右键菜单开着时不动它：子菜单常伸出条外，指针移过去时 pointerNear 会翻成
        // false，@Published 一变 SwiftUI 就重建整个菜单，子菜单当场收起、永远够不着。
        let pointerNear = hot.union(panelZone).contains(mouse)
        if !menuTracking, catalog.pointerOverBar != pointerNear {
            catalog.pointerOverBar = pointerNear
        }

        if menuTracking || startMenu.isVisible || catalog.isPressing {
            // 菜单开着：指针在菜单上（面板的子窗口），条不能收。
            // 开始菜单开着：它是贴着条弹出的，条收了菜单就悬空了。
            // 按住标签 / 拖动排序中：拖出条外也不能收，松手后再按正常延迟。
            // 持续续期，关菜单/会话结束后按正常延迟收起。
            lastInteraction = now
        } else if inPanel || inPreview || inHot {
            lastInteraction = now
            if !isRevealed {
                TTLog("hotZone 喚出 mouse=\(mouse) zone=\(hot) screen=\(anchorScreen?.localizedName ?? "-")")
                reveal()
            }
        } else if isRevealed, delay > 0, now.timeIntervalSince(lastInteraction) > delay {
            hide()
            return
        }

        guard isRevealed else { return }

        // 悬停时更实一点，便于阅读
        let target: CGFloat = (inPanel || startMenu.isVisible) ? 1.0 : CGFloat(prefs.idleOpacity)
        if abs(panel.alphaValue - target) > 0.02 {
            animateAlpha(to: target, duration: 0.12)
        }

        // 预览卡片的悬停高亮：复用这次轮询，和主面板高亮同一套坐标
        if preview.isVisible {
            preview.updatePointer(screenPoint: mouse)
        }

        // 预览的保持/收起：光标在主面板与预览面板之间穿行时（中间有 8pt 空隙）
        // 不能立刻收起，留 0.4s 宽限。
        //
        // 纯按指针位置判断，不依赖 onTabHoverEnd：以前进过预览会把 hoverEndTime 清掉，
        // 之后从预览直接移走再也没人重新计时，预览就一直挂着，只能点一个窗口才关得掉。
        // SwiftUI 的 onHover(false) 也可能漏发，所以"还停在标签上"额外要求指针真在面板里。
        if preview.isVisible {
            let inPreviewPanel = preview.frame.insetBy(dx: -8, dy: -16).contains(mouse)
            let onTab = hoveredEntry != nil && inPanel
            if inPreviewPanel || onTab || menuTracking {
                hoverEndTime = nil
            } else if let left = hoverEndTime {
                if now.timeIntervalSince(left) > 0.4 { hidePreview() }
            } else {
                hoverEndTime = now
            }
        }

        // 面板常驻时窗口集合会变（新开/关闭窗口），定期刷新快照 + 补热缓存
        if prefs.previewEnabled, now.timeIntervalSince(lastWarmup) > 3.0 {
            warmup()
        }
    }

    /// AppKit 窗口坐标（原点左下）→ SwiftUI 坐标（原点上左）
    private func viewPoint(fromWindow location: NSPoint) -> NSPoint {
        let height = panel.contentView?.bounds.height ?? barHeight
        return NSPoint(x: location.x, y: height - location.y)
    }

    @objc private func screenChanged() {
        currentWidth = 0
        relayout()
    }

    // MARK: - 预览调度

    private func schedulePreview(for entry: AppEntry) {
        hoveredEntry = entry
        previewWork?.cancel()
        // 没在运行的固定项没有窗口可看；开始菜单开着时也别在它旁边再弹一层
        guard prefs.previewEnabled, isRevealed, entry.isRunning, !startMenu.isVisible else { return }

        let work = DispatchWorkItem { [weak self] in
            guard let self, self.hoveredEntry?.id == entry.id else { return }
            self.showPreview(for: entry)
        }
        previewWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + previewDelay, execute: work)
    }

    /// 先用快照立刻弹（零延迟），再现查一遍：快照最多落后 3 秒，
    /// 刚最小化 / 放回的窗口状态常常还是旧的，会弹错卡片甚至该弹不弹。
    /// 查完窗口集合或最小化状态变了、光标还停在这个标签上，就按新的重弹。
    private func showPreview(for entry: AppEntry) {
        guard let labelRect = self.catalog.tabFrames[entry.id] else { return }
        // SwiftUI 坐标（原点上左）→ 屏幕坐标
        let screenRect = NSRect(
            x: self.panel.frame.minX + labelRect.minX,
            y: self.panel.frame.maxY - labelRect.maxY,
            width: labelRect.width,
            height: labelRect.height
        )
        let show = {
            self.preview.show(for: entry,
                              anchorInScreen: screenRect,
                              mainPanelFrame: self.panel.frame,
                              hideMinimized: self.prefs.hideMinimizedWindows,
                              region: self.catalog.screenRegion)
        }
        show()
        let signature = { self.engine.windows(of: entry.pid).map { "\($0.id):\($0.isMinimized)" } }
        let before = signature()
        let pids = self.catalog.groups.flatMap { $0.entries }.map(\.pid).filter { $0 > 0 }
        Task { [weak self] in
            guard let self else { return }
            await self.engine.refresh(minInterval: 0.3, pids: pids)
            guard self.hoveredEntry?.id == entry.id, signature() != before else { return }
            show()
        }
    }

    /// 预览开着时点了标签（收起 / 放回窗口）：卡片还是点之前的状态，会把「已最小化」
    /// 挂在已经放回来的窗口上。等动作落地后按新状态重弹（只剩一扇开着的窗口就自己收掉）
    private func refreshPreviewAfterClick() {
        guard preview.isVisible, let entry = hoveredEntry else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self, self.hoveredEntry?.id == entry.id else { return }
            self.showPreview(for: entry)
        }
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

    // MARK: - 开始菜单

    /// 别的条要开开始菜单了：这条上开着的收掉（同一时间只开一个）
    func closeStartMenu() {
        guard startMenu.isVisible else { return }
        startMenu.close()
    }

    func toggleStartMenu() {
        if startMenu.isVisible {
            startMenu.close()
            return
        }
        guard prefs.barEnabled, !missionControl.isActive else { return }
        // 从状态栏菜单 / 快捷入口打开时条可能还藏着：先把条唤出来，菜单要贴着开始按钮弹
        if !isRevealed { beginReveal(animated: false) }
        hidePreview()
        lastInteraction = Date()

        let buttonRect = catalog.tabFrames[AppCatalog.startButtonID]
            .map { r in
                NSRect(x: panel.frame.minX + r.minX, y: panel.frame.maxY - r.maxY,
                       width: r.width, height: r.height)
            } ?? NSRect(x: panel.frame.minX + 12, y: panel.frame.minY, width: 1, height: 1)
        startMenu.onClose = { [weak self] in
            self?.catalog.startMenuOpen = false
            // 从关菜单这一刻重新计时，别一关条就瞬间消失
            self?.lastInteraction = Date()
        }
        startMenu.show(anchorInScreen: buttonRect, barFrame: panel.frame, barWindow: panel)
        catalog.startMenuOpen = true
        // 「背景執行」区要知道谁没窗口：开关关着时平时不查，这里立刻补查一轮
        catalog.scanWindows()
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
        return "螢幕錄製 \(screen) · 輔助使用 \(ax)"
    }

    // MARK: - Layout

    private static func targetFrame(for screen: NSScreen, edge: DockEdge,
                                    width: CGFloat, height: CGFloat, inset: CGFloat) -> NSRect {
        DockGeometry.barFrame(edge: edge, visible: screen.visibleFrame,
                              width: width, height: height, inset: inset)
    }

    private func relayout() {
        // 用 anchorScreen（设置里指定的屏 / 这条固定的屏），不用 panel.screen ——
        // 后者反映的是面板旧位置，以它兜底会一直指错屏。
        // 各屏一条、自己那块屏刚拔掉：原地不动，等 TabBarFleet 拆掉这条，别跳到别人的屏上叠着
        if fixedDisplay != nil, anchorScreen == nil { return }
        guard let screen = anchorScreen ?? panel.screen ?? NSScreen.main ?? NSScreen.screens.first
        else { return }
        // preferredWidth 已经优先返回 SwiftUI 实测的内容宽度，
        // 这样左右两边的 12pt 内边距才真的对称，最右边的标签不会被圆角切掉。
        let target = TabBarController.targetFrame(
            for: screen,
            edge: prefs.dockEdge,
            width: catalog.preferredWidth,
            height: barHeight,
            inset: topInset
        )

        if abs(target.width - currentWidth) > 0.5 || abs(target.height - panel.frame.height) > 0.5 {
            currentWidth = target.width
            panel.setFrame(target, display: true, animate: false)
            hostingView?.frame = NSRect(origin: .zero, size: target.size)
            catalog.barWidth = target.width
        } else if panel.frame != target {
            panel.setFrame(target, display: true, animate: false)
        }
    }
}
