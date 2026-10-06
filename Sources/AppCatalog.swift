import AppKit
import ApplicationServices
import Combine
import SwiftUI

/// 一个可点击的标签 = 一个正在运行的 App，或一个固定到任务栏的 App（可能没在运行）
struct AppEntry: Identifiable, Equatable {
    let id: String
    /// 没在运行的固定项为 0
    let pid: pid_t
    let name: String
    let icon: NSImage
    let category: AppCategory
    /// .app 路径：没在运行时靠它启动 / 固定
    var bundleURL: URL? = nil
    var isRunning: Bool = true
    var isPinned: Bool = false
    /// 启动时间：运行中的 App 按它排（先开的在左，新开的接在右边）
    var launchDate: Date? = nil
    /// 多屏时同一个 App 出现在好几条上：这条（这块屏）上它最前面那扇窗口的标题，
    /// Chrome / Safari 就是当前分页。只出现在一条上时为 nil
    var windowTitle: String? = nil

    /// 这条（这块屏）上它开着几扇窗口（含最小化的）；单条模式下是全部窗口。≥ 2 时图标角落画数字圆圈
    var windowCount: Int = 0

    /// 条上显示的名字：带了窗口标题就是「名字 (标题)」，分得清每条上是哪扇窗口
    var displayName: String { AppEntry.label(name: name, windowTitle: windowTitle) }

    /// 标题太长截断（加省略号），免得一个标签把条撑得老长
    static func label(name: String, windowTitle: String?, limit: Int = 20) -> String {
        guard let raw = windowTitle?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty, raw != name else { return name }
        let title = raw.count > limit ? String(raw.prefix(limit - 1)) + "…" : raw
        return "\(name) (\(title))"
    }

    static func == (lhs: AppEntry, rhs: AppEntry) -> Bool {
        lhs.id == rhs.id && lhs.pid == rhs.pid && lhs.category == rhs.category
            && lhs.isRunning == rhs.isRunning && lhs.isPinned == rhs.isPinned
            && lhs.windowTitle == rhs.windowTitle && lhs.windowCount == rhs.windowCount
    }
}

struct AppGroup: Identifiable, Equatable {
    let id: String
    let category: AppCategory
    let entries: [AppEntry]
}

/// 运行中 App 的采集 / 分类 / 排序中心
@MainActor
final class AppCatalog: ObservableObject {

    @Published private(set) var groups: [AppGroup] = []
    @Published private(set) var activePID: pid_t = -1
    /// 面板实际可用宽度（由控制器算好后回填，视图据此布局）
    @Published var barWidth: CGFloat = 600

    /// 指针是否停在悬浮条上。
    ///
    /// 蓝色药丸高亮表达的是「这个 App 此刻可以被你点中」，不是「它是前台」。
    /// 常驻的高亮看起来像「已被选中」，切换 App 之后它还留在旧标签上，很容易
    /// 误读成点错了。所以让高亮始终跟随交互：指针离开条面就撤掉，进来再亮起。
    @Published var pointerOverBar = false

    /// 开始菜单开着（开始按钮画按下态）
    @Published var startMenuOpen = false

    /// 布局变化回调（由面板控制器消费，用于重新居中 / 调宽）
    var onLayoutNeeded: (@MainActor () -> Void)?

    /// 面板能力出口（自动隐藏配置 / 权限入口）
    weak var host: TabBarHost?

    /// 标签悬停：进入某个标签 / 离开全部标签
    var onTabHover: (@MainActor (AppEntry) -> Void)?
    var onTabHoverEnd: (@MainActor () -> Void)?

    /// 各标签在视图坐标系（原点上左）中的命中区域，由 SwiftUI 上报
    var tabFrames: [String: CGRect] = [:]

    /// 内容实测宽度（含左右 8pt 内边距），由 SwiftUI 上报。
    /// 不用 @Published：它只被控制器读取，发布出去只会引发多余的重绘。
    private(set) var contentWidth: CGFloat = 0

    /// SwiftUI 测量的内容宽度回填入口。
    /// 手算宽度（`preferredWidth`）会漏掉每标签 2pt 的外边距和 `.fixedSize()` 的文字，
    /// 结果面板比内容窄一点点，最右边的标签连高亮一起被圆角切掉。
    func reportContentWidth(_ width: CGFloat) {
        TTLog("reportContentWidth \(width) (prev \(contentWidth), barWidth \(barWidth))")
        guard width > 1, abs(width - contentWidth) > 0.5 else { return }
        contentWidth = width
        // 在视图更新过程中回调会触发 "Modifying state during view update"，推到下一轮
        DispatchQueue.main.async { [weak self] in self?.onLayoutNeeded?() }
    }

    private var iconCache: [String: NSImage] = [:]
    private var refreshTimer: Timer?
    private var subscribers: [NSObjectProtocol] = []
    private var cancellables = Set<AnyCancellable>()
    private var lastSignature: String = ""

    // MARK: - 多屏：这条只管哪块屏

    /// 多屏「各屏一条」时这条管的屏：运行中的 App 只在窗口落在这块屏上时才上条。
    /// nil = 单条模式，不按屏过滤。由 `TabBarFleet` 设。
    var screenScope: ScreenScope? {
        didSet {
            guard screenScope != oldValue else { return }
            lastSignature = ""
            refresh()
            scanWindows()
        }
    }

    /// ⌘Tab 会话期间放开屏幕过滤：快切要能切到任何一块屏上的 App
    private var scopeSuspended = false

    /// 眼下实际生效的屏幕过滤
    private var activeScope: ScreenScope? { scopeSuspended ? nil : screenScope }

    /// 这条所在屏的范围（CG 坐标）。点标签切窗口 / 最小化、预览列窗口都只管这块屏上的；
    /// 单条模式和 ⌘Tab 会话期间为 nil（不分屏）
    var screenRegion: ScreenRegion? {
        activeScope.flatMap { ScreenRegion.of(displayID: $0.displayID) }
    }

    // MARK: - Lifecycle

    func start() {
        let nc = NSWorkspace.shared.notificationCenter
        let names: [NSNotification.Name] = [
            NSWorkspace.didLaunchApplicationNotification,
            NSWorkspace.didTerminateApplicationNotification,
            NSWorkspace.didActivateApplicationNotification,
            NSWorkspace.didHideApplicationNotification,
            NSWorkspace.didUnhideApplicationNotification
        ]
        for name in names {
            let token = nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.refresh()
                    self?.scanWindows()
                }
            }
            subscribers.append(token)
        }

        // 兜底轮询：兜住任何漏掉的通知
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 1.2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refresh()
                // 关窗不会发任何 NSWorkspace 通知，"还有没有窗口"只能靠轮询
                self?.scanWindows()
            }
        }
        RunLoop.main.add(refreshTimer!, forMode: .common)

        // 每块屏的条各有一个 catalog，都订阅同一份窗口分布；同步回调，和以前的单回调时序一样
        WindowPresence.shared.changed
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.refresh() } }
            .store(in: &cancellables)
        refresh()
        scanWindows()
    }

    func stop() {
        refreshTimer?.invalidate()
        refreshTimer = nil
        cancellables.removeAll()
        let nc = NSWorkspace.shared.notificationCenter
        subscribers.forEach { nc.removeObserver($0) }
        subscribers.removeAll()
    }

    // MARK: - Collection

    /// 后台查一轮各 App 的窗口（有没有 / 在哪块屏 / 几扇 / 标题，结果变了会回调 refresh）。
    /// 图标角落的窗口数圆圈一直要用，所以不再看开关，每轮都查（没有辅助功能权限时 scan 自己会跳过）。
    func scanWindows() {
        let me = ProcessInfo.processInfo.processIdentifier
        let pids = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && !$0.isTerminated && $0.processIdentifier != me }
            .map(\.processIdentifier)
        WindowPresence.shared.scan(pids: pids)
    }

    /// 开始按钮在命中区域表里的保留 id（不会和 bundle id 撞）
    nonisolated static let startButtonID = "__start__"

    /// 采集：固定项（按固定顺序，合并运行实例）+ 其余运行中的 App。
    ///
    /// 固定项不受「隐藏此 App」影响 —— 固定本身就是"我要它在条上"的明确表态。
    private func collect() -> (pinned: [AppEntry], running: [AppEntry]) {
        let prefs = Preferences.shared
        let running = collectRunning()
        var byID: [String: AppEntry] = [:]
        for e in running where byID[e.id] == nil { byID[e.id] = e }

        var pinnedIDs = Set<String>()
        var pinned: [AppEntry] = []
        for pin in prefs.dockPins where !pinnedIDs.contains(pin.bundleID) {
            pinnedIDs.insert(pin.bundleID)
            if let live = byID[pin.bundleID] {
                pinned.append(AppEntry(id: live.id, pid: live.pid, name: live.name, icon: live.icon,
                                       category: .pinned,
                                       bundleURL: live.bundleURL ?? resolvedURL(for: pin),
                                       isRunning: true, isPinned: true))
            } else {
                let url = resolvedURL(for: pin)
                pinned.append(AppEntry(id: pin.bundleID, pid: 0,
                                       name: url.flatMap { AppNames.localized(url: $0) } ?? pin.name,
                                       icon: icon(forPin: pin, url: url),
                                       category: .pinned, bundleURL: url,
                                       isRunning: false, isPinned: true))
            }
        }

        // 退出了的 App 从拖动排序里剔掉：再开时回到最右边，而不是"记得"旧位置
        let runningIDs = Set(running.map(\.id))
        if prefs.runningOrder.contains(where: { !runningIDs.contains($0) }) {
            prefs.runningOrder.removeAll { !runningIDs.contains($0) }
        }

        let hidden = prefs.hiddenApps
        // 「只显示有窗口的 App」：没窗口的运行中 App 不上条（固定项上面已经收走了，不受影响）
        let windowless: Set<pid_t> = prefs.onlyWindowedApps ? WindowPresence.shared.windowless : []
        // 多屏各屏一条：只留窗口在这块屏上的。没有辅助功能权限就量不出窗口在哪，每条都放全部
        let scope = WindowBridge.isTrusted ? activeScope : nil
        let live = Set(NSScreen.screens.compactMap(\.displayID))
        let screensByPID = WindowPresence.shared.screensByPID
        let others = running.filter { e in
            !pinnedIDs.contains(e.id) && hidden[e.id] == nil && !windowless.contains(e.pid)
                && (scope?.admits(screensByPID[e.pid], live: live) ?? true)
        }
        // 窗口数（图标角落的数字圆圈）：各屏一条数这块屏上的，单条模式数全部。
        // 同一个 App 在好几块屏都有窗口（好几条上都有它）：名字后面再带上这块屏上那扇窗口的分页标题
        let titles = WindowPresence.shared.frontTitles
        let counts = WindowPresence.shared.windowCounts
        func labeled(_ e: AppEntry) -> AppEntry {
            guard e.pid > 0 else { return e }
            var copy = e
            copy.windowCount = ScreenScope.windowCount(counts[e.pid], scope: scope)
            copy.windowTitle = scope?.windowTitle(screensByPID[e.pid], live: live, titles: titles[e.pid])
            return copy
        }
        return (pinned.map(labeled), others.map(labeled))
    }

    /// 固定项的 .app 位置：记下的路径还在就用它，App 被挪走了就按 bundle id 问 LaunchServices
    private func resolvedURL(for pin: PinnedApp) -> URL? {
        if FileManager.default.fileExists(atPath: pin.path) { return pin.url }
        return NSWorkspace.shared.urlForApplication(withBundleIdentifier: pin.bundleID)
    }

    private func icon(forPin pin: PinnedApp, url: URL?) -> NSImage {
        if let cached = iconCache[pin.bundleID] { return cached }
        let image = url.map { NSWorkspace.shared.icon(forFile: $0.path) }
            ?? NSImage(named: NSImage.applicationIconName) ?? NSImage()
        image.size = NSSize(width: 32, height: 32)
        iconCache[pin.bundleID] = image
        return image
    }

    private func collectRunning() -> [AppEntry] {
        let apps = NSWorkspace.shared.runningApplications.filter { app in
            guard app.activationPolicy == .regular else { return false }
            guard app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return false }
            guard !app.isTerminated else { return false }
            return true
        }

        var entries: [AppEntry] = []
        for app in apps {
            let bid = app.bundleIdentifier ?? app.executableURL?.path ?? "pid-\(app.processIdentifier)"
            // 条上显示的名字跟 macOS 系统语言走（见 AppNames）；
            // 分类仍按系统接口给的名字判定，关键词表是照它写的
            let systemName = app.localizedName ?? bid
            let name = app.bundleURL.flatMap { AppNames.localized(url: $0) } ?? systemName
            let icon: NSImage
            if let cached = iconCache[bid] {
                icon = cached
            } else {
                icon = app.icon ?? NSImage(named: NSImage.applicationIconName) ?? NSImage()
                icon.size = NSSize(width: 32, height: 32)
                iconCache[bid] = icon
            }
            entries.append(AppEntry(
                id: bid,
                pid: app.processIdentifier,
                name: name,
                icon: icon,
                category: AppCategory.classify(name: systemName, bundleID: bid),
                bundleURL: app.bundleURL,
                launchDate: app.launchDate
            ))
        }
        return entries
    }

    /// 按打开时间排：先开的在左，新开的接在最右边（同 Windows 任务栏）。
    /// 顺序只在启动 / 退出 / 拖动时变，点标签切换不会挪位，不会误点。
    /// 用户拖动排过的（`runningOrder`）排在前面按排好的先后，其余接在后面按打开时间。
    /// 拿不到启动时间的（极少见）排最后，再按 pid 兜底保证稳定。
    private func sorted(_ entries: [AppEntry]) -> [AppEntry] {
        var rank: [String: Int] = [:]
        for (i, id) in Preferences.shared.runningOrder.enumerated() where rank[id] == nil { rank[id] = i }
        return entries.sorted { a, b in
            switch (rank[a.id], rank[b.id]) {
            case let (x?, y?) where x != y: return x < y
            case (.some, nil): return true
            case (nil, .some): return false
            default: break
            }
            switch (a.launchDate, b.launchDate) {
            case let (x?, y?) where x != y: return x < y
            case (.some, nil): return true
            case (nil, .some): return false
            default: return a.pid < b.pid
            }
        }
    }

    /// 固定组（保持用户排的顺序）打头，其余运行中的 App 一组、按打开时间排
    private func group(pinned: [AppEntry], running entries: [AppEntry]) -> [AppGroup] {
        var result: [AppGroup] = []
        if !pinned.isEmpty {
            result.append(AppGroup(id: AppCategory.pinned.rawValue, category: .pinned, entries: pinned))
        }
        if !entries.isEmpty {
            result.append(AppGroup(id: AppCategory.other.rawValue, category: .other, entries: sorted(entries)))
        }
        return result
    }

    // MARK: - Refresh

    /// 右键菜单开着：暂停重采。菜单内容是 SwiftUI 按视图状态生成的，
    /// groups / activePID 一变整个菜单就被重建，已展开的子菜单会当场收起。
    /// 菜单关掉时控制器会把这个标志放下并补一次 refresh。
    var menuTracking = false

    func refresh() {
        // 拖动排序中也不重采：开拖时拍的快照要和条上的标签对得上，松手会补一次
        guard !menuTracking, drag == nil else { return }
        let frontmost = NSWorkspace.shared.frontmostApplication
        let frontPID = frontmost?.processIdentifier ?? -1

        let collected = collect()
        let newGroups = group(pinned: collected.pinned, running: collected.running)

        let signature = newGroups.map { g in
            "\(g.id):" + g.entries.map {
                "\($0.id)#\($0.pid)#\($0.windowTitle ?? "")#\($0.windowCount)"
            }.joined(separator: ",")
        }.joined(separator: "|") + "|active:\(frontPID)"

        guard signature != lastSignature else { return }
        lastSignature = signature

        let countChanged = newGroups.map { $0.entries.count } != groups.map { $0.entries.count }
        groups = newGroups
        activePID = frontPID
        // 真实前台变化也要进 MRU —— 用户不经过悬浮条、直接 ⌘ 点 Dock /
        // 用系统切换器换 App 时，快切的历史不能断
        noteActive(frontPID)

        if countChanged { onLayoutNeeded?() }
    }

    // MARK: - Actions

    /// 按住的标签：抬起时没拖动 = 点击，拖动超过阈值 = 拖动排序
    private var pressedEntry: AppEntry?
    private var pressPoint: NSPoint = .zero

    /// 拖动多远才算拖（pt）。小于它的手抖仍然算点击。
    private static let dragThreshold: CGFloat = 4

    /// 鼠标按住标签中（按下还没抬起 / 正在拖）：控制器据此暂停自动隐藏
    var isPressing: Bool { pressedEntry != nil }

    /// 窗口层命中测试入口（point 使用「原点在左上」的坐标系）。
    /// 按下：开始按钮当场开关；标签先记下来，等抬起或拖动再决定是点击还是排序。
    /// 点击在抬起时才执行（同系统 Dock / Windows 任务栏）—— 按下就切 App 的话没法拖。
    func handlePress(at point: NSPoint) -> Bool {
        pressedEntry = nil
        if drag != nil { drag = nil }
        if let rect = tabFrames[Self.startButtonID], rect.contains(point) {
            if keyboardSession { endKeyboardSession() }
            host?.toggleStartMenu()
            return true
        }
        guard let hit = entry(at: point) else { return false }
        pressedEntry = hit
        pressPoint = point
        return true
    }

    /// 按住拖动：过了阈值就进入拖动排序，被拖的标签跟着指针走，同组其它标签让位
    func handleDrag(to point: NSPoint) {
        guard let pressed = pressedEntry else { return }
        if drag == nil {
            // ⌘Tab 会话里条是键盘驱动的，不在这时候排序
            guard !keyboardSession,
                  max(abs(point.x - pressPoint.x), abs(point.y - pressPoint.y)) > Self.dragThreshold,
                  let started = TabDrag(entry: pressed, startX: pressPoint.x, groups: groups, frames: tabFrames)
            else { return }
            host?.dismissPreview()
            drag = started
        }
        drag?.move(to: point.x)
    }

    /// 抬起：拖过就落位，没拖就当一次点击
    func handleRelease(at point: NSPoint) {
        let pressed = pressedEntry
        pressedEntry = nil
        if let finished = drag {
            commit(finished)
            return
        }
        guard let pressed else { return }
        // ⌘Tab 会话中用鼠标点了标签：点击本身就是选择，
        // 结束会话避免松 ⌘ 时再提交一次高亮（可能不是点中的这个）
        if keyboardSession { endKeyboardSession() }
        activate(pressed, fromClick: true)
        // 这次如果条是 ⌘Tab 呼出来的，选完立刻消失，不等鼠标离开的倒计时
        host?.dismissQuickSwitch()
    }

    /// 兜底：鼠标键其实早就放开了却没收到 mouseUp（面板中途被收起之类），
    /// 按住状态不清掉的话自动隐藏和重采会一直停着。拖到一半的不落位，原样弹回。
    func cancelPress() {
        pressedEntry = nil
        guard drag != nil else { return }
        withAnimation(Preferences.shared.animationsEnabled ? TabDrag.settle : nil) { drag = nil }
        refresh()
    }

    private func entry(at point: NSPoint) -> AppEntry? {
        for group in groups {
            for entry in group.entries {
                if let rect = tabFrames[entry.id], rect.contains(point) { return entry }
            }
        }
        return nil
    }

    // MARK: - 拖动排序

    /// 正在拖的标签（视图据此画位移）
    @Published private(set) var drag: TabDrag?

    /// 某个标签此刻该画的水平位移：被拖的跟着指针，其它的给它让出一格
    func dragOffset(for id: String) -> CGFloat {
        drag?.offset(for: id) ?? 0
    }

    /// 松手落位：固定组改 dockPins，运行中组改 runningOrder，然后带动画重排
    private func commit(_ finished: TabDrag) {
        let ids = finished.reorderedIDs
        let prefs = Preferences.shared
        if finished.target != finished.source {
            if finished.groupID == AppCategory.pinned.rawValue {
                var rest = prefs.dockPins
                var pins: [PinnedApp] = []
                for id in ids {
                    if let i = rest.firstIndex(where: { $0.bundleID == id }) { pins.append(rest.remove(at: i)) }
                }
                prefs.dockPins = pins + rest
            } else {
                // 不在条上的（没窗口 / 已隐藏）保留原来的相对顺序，接在后面
                prefs.runningOrder = ids + prefs.runningOrder.filter { !ids.contains($0) }
            }
            TTLog("drag reorder \(finished.groupID): \(ids)")
        }
        withAnimation(prefs.animationsEnabled ? TabDrag.settle : nil) {
            drag = nil
            // 先排好再撤位移：同一个事务里重排，标签从拖动时的位置滑进新格子
            lastSignature = ""
            refresh()
        }
    }

    /// - fromClick: 鼠标点标签（Windows 任务栏语义：前台 App 再点一下 = 最小化）。
    ///   ⌘Tab 提交 / 右键菜单等其它入口只管激活。
    ///
    /// 多屏各屏一条时，点的是哪块屏的条，就切到 / 收起这块屏上的窗口（同 Windows 多工作列）。
    func activate(_ entry: AppEntry, fromClick: Bool = false) {
        guard entry.isRunning, entry.pid > 0 else {
            // 固定了但没在运行：点一下 = 启动（同点 Dock 上没有小圆点的图标）
            if let url = entry.bundleURL { launch(url: url, bundleID: entry.id) }
            return
        }
        let pid = entry.pid
        let region = fromClick ? screenRegion : nil
        guard fromClick, Preferences.shared.clickToMinimize, WindowBridge.isTrusted else {
            activatePID(pid)
            if let region {
                Task.detached(priority: .userInitiated) { WindowBridge.raiseWindow(pid: pid, in: region) }
            }
            return
        }
        // 点前台 App：把它开着的窗口全部最小化；一个开着的都没有（上次点图标收起来了）
        // 就恢复它们再激活。条是不抢焦点的面板，点它不会改变前台 App，这里读到的就是点之前的前台。
        let isFront = NSWorkspace.shared.frontmostApplication?.processIdentifier == pid
        guard isFront else {
            // 后台 App：照常立刻激活（切换手感不能等 AX），被点图标收进 Dock 的窗口顺手放回来
            activatePID(pid)
            Task.detached(priority: .userInitiated) {
                WindowBridge.restoreMinimized(pid: pid)
                if let region { WindowBridge.raiseWindow(pid: pid, in: region) }
            }
            return
        }
        // AX 读写可能卡到超时，挪到后台，别卡住鼠标
        Task.detached(priority: .userInitiated) { [weak self] in
            // 前台 App 正在用的窗口在别的屏：这一下是"切到这块屏上的窗口"，不是收起
            // （这块屏上一扇它的窗口都没有就照原来的收起 / 恢复走）
            if let region, !WindowBridge.focusedWindow(pid: pid, isIn: region),
               WindowBridge.raiseWindow(pid: pid, in: region) {
                return
            }
            if WindowBridge.minimizeOpenWindows(pid: pid, in: region) { return }
            WindowBridge.restoreMinimized(pid: pid)
            await self?.activatePID(pid)
            if let region { WindowBridge.raiseWindow(pid: pid, in: region) }
        }
    }

    /// 启动 / 激活一个 .app（开始菜单和没在运行的固定项共用）
    func launch(url: URL, bundleID: String?) {
        if let bundleID { Preferences.shared.noteRecent(bundleID) }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        TTLog("launch \(url.path)")
        // 启动完成后 didLaunchApplication 通知会触发 refresh，小圆点自己会亮
        NSWorkspace.shared.openApplication(at: url, configuration: config) { _, error in
            if let error { TTLog("launch error=\(error)") }
        }
    }

    /// 按 pid 激活（点标签与 ⌘Tab 快切共用这条路径）。
    func activatePID(_ pid: pid_t) {
        guard let app = NSRunningApplication(processIdentifier: pid) else {
            return
        }
        if app.isHidden { app.unhide() }

        // 乐观更新：点谁就把高亮挪到谁身上，不用等 1.2s 的兜底轮询
        // 去读 frontmostApplication 回来（读不到时高亮会僵在旧标签上）。
        // 真激活失败也无所谓，下一轮 refresh 会用真实前台值纠正。
        activePID = pid
        noteActive(pid)

        // 走 LaunchServices 路径（等价于点击 Dock 图标）。
        // 裸的 NSRunningApplication.activate() 在 macOS 14+ 从非激活 App 调用常被忽略。
        guard let url = app.bundleURL else {
            forceActivate(app)
            return
        }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        config.promptsUserIfNeeded = false
        NSWorkspace.shared.openApplication(at: url, configuration: config) { [weak self] _, error in
            DispatchQueue.main.async {
                if error != nil {
                    TTLog("openApplication error=\(String(describing: error)) → fallback AX")
                    self?.forceActivate(app)
                }
            }
        }
    }

    /// 最近使用顺序（栈顶 = 当前前台）。⌘Tab 快按快放时取第二个 = 上一个 App。
    /// 只在真实前台变化（refresh）和主动激活（activatePID）时更新，
    /// 容量 12 足够覆盖日常来回切换，也避免退出后残留一堆失效 pid。
    @Published private(set) var mru: [pid_t] = []

    func noteActive(_ pid: pid_t) {
        guard pid > 0, mru.first != pid else { return }
        if let bid = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier,
           bid != Bundle.main.bundleIdentifier {
            Preferences.shared.noteRecent(bid)
        }
        var next = mru
        next.removeAll { $0 == pid }
        next.insert(pid, at: 0)
        if next.count > 12 { next.removeLast(next.count - 12) }
        mru = next
    }

    // MARK: - ⌘Tab 键盘会话（AppRing 同款机制）
    //
    // 第一次 ⌘Tab：立即弹条 + 预选上一个 App；
    // 再按 Tab：沿**视觉顺序**（标签从左到右）前进高亮，走到头回到第一个；
    // 松开 ⌘：提交高亮项（快按快放因此天然等于"切上一个"）；
    // Esc / 鼠标点标签 / 再按一次 ⌘Tab 前松手：取消。

    /// 会话进行中（tick 据此暂停自动隐藏；松 ⌘ 据此决定要不要提交）
    @Published private(set) var keyboardSession = false
    /// 当前键盘高亮的 pid（视图层画描边环）
    @Published private(set) var keyboardHighlightPID: pid_t = 0
    /// 会话的循环序列 = 面板上的视觉顺序（标签从左到右）
    private var sessionCycle: [pid_t] = []
    private var sessionIndex = 0

    /// 鼠标悬停接管高亮（AppRing 同款：指针扫到哪个图标，松 ⌘ 就提交哪个）
    func setKeyboardHighlight(_ pid: pid_t) {
        guard keyboardSession, let i = sessionCycle.firstIndex(of: pid) else { return }
        sessionIndex = i
        keyboardHighlightPID = pid
    }

    /// 开始会话并预选上一个 App。返回是否成功（不足两个可见 App 时返回 false）。
    @discardableResult
    func startKeyboardSession() -> Bool {
        // 多屏时主条平时只列主屏上的 App；快切得能切到任何一块屏上的，会话期间放开过滤
        if screenScope != nil, !scopeSuspended {
            scopeSuspended = true
            lastSignature = ""
            refresh()
        }
        mru.removeAll { NSRunningApplication(processIdentifier: $0)?.isTerminated ?? true }
        // 没在运行的固定项切不过去，不进 ⌘Tab 循环
        let visible = groups.flatMap(\.entries).filter { $0.pid > 0 }
        guard visible.count >= 2 else {
            TTLog("kbdSession: 可見 App 不足(\(visible.count))")
            restoreScope()
            return false
        }

        // 循环序列 = 面板上的**视觉顺序**（标签从左到右），也就是 groups.flatMap 的顺序。
        //
        // 以前用的是 MRU 顺序（"最近用过"），它跟屏幕上看到的排布毫无关系 ——
        // 于是按 Tab 时高亮会在图标之间横跳（第二个直接蹦到第四个），
        // 看着像漏了一帧。改成按视觉顺序走：每按一次就挪到右边一格，
        // 走到末尾从最左边续上，全程连贯可预期。
        let cycle = visible.map(\.pid)
        sessionCycle = cycle
        sessionIndex = SessionCycle.startIndex(visual: cycle, mru: mru, active: activePID)
        keyboardHighlightPID = cycle[sessionIndex]
        keyboardSession = true
        TTLog("kbdSession start → \(Self.name(of: cycle[sessionIndex])) "
              + "idx=\(sessionIndex)/\(cycle.count)")
        return true
    }

    /// 会话中再按 Tab：沿视觉顺序前进一格，末尾回到第一个（循环）。
    func cycleKeyboardSession() {
        guard keyboardSession, !sessionCycle.isEmpty else { return }
        sessionIndex = SessionCycle.next(sessionIndex, count: sessionCycle.count)
        keyboardHighlightPID = sessionCycle[sessionIndex]
        TTLog("kbdSession cycle → \(Self.name(of: sessionCycle[sessionIndex])) "
              + "idx=\(sessionIndex)/\(sessionCycle.count)")
    }

    /// 松开 ⌘：激活高亮项并结束会话。
    func commitKeyboardSession() {
        guard keyboardSession else { return }
        let pid = keyboardHighlightPID
        endKeyboardSession()
        guard pid > 0 else { return }
        TTLog("kbdSession commit → \(Self.name(of: pid)) pid=\(pid)")
        activatePID(pid)
    }

    /// Esc / 鼠标抢先点击：结束会话但不激活。
    func endKeyboardSession() {
        keyboardSession = false
        sessionCycle = []
        sessionIndex = 0
        keyboardHighlightPID = 0
        restoreScope()
    }

    /// ⌘Tab 会话结束：恢复屏幕过滤，条回到只列本屏的 App
    private func restoreScope() {
        guard scopeSuspended else { return }
        scopeSuspended = false
        lastSignature = ""
        refresh()
    }

    private static func name(of pid: pid_t) -> String {
        NSRunningApplication(processIdentifier: pid)?.localizedName ?? "?"
    }

    /// 兜底：AX frontmost + activate()
    private func forceActivate(_ app: NSRunningApplication) {
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(axApp, 0.2)
        AXUIElementSetAttributeValue(axApp, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        app.activate()
    }

    /// 退出 App（右键菜单）。先礼貌 terminate，5 秒后还在就强杀。
    func terminate(_ entry: AppEntry) {
        terminate(pid: entry.pid, name: entry.name)
    }

    func terminate(pid: pid_t, name: String) {
        guard pid > 0, let app = NSRunningApplication(processIdentifier: pid) else { return }
        TTLog("terminate \(name) pid=\(pid)")
        app.terminate()
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
            if let still = NSRunningApplication(processIdentifier: pid), !still.isTerminated {
                TTLog("terminate timeout → forceTerminate \(name)")
                still.forceTerminate()
            }
        }
    }

    /// 从标签里隐藏 App（右键菜单）。只记 bundle id，collect() 会过滤掉；
    /// 释放入口在设置 → 悬浮条 → 已隐藏的 App。
    func hide(_ entry: AppEntry) {
        let bid = entry.id
        // 没有 bundle id 的进程（路径/pid 兜底 key）存不下稳定标识，隐藏不了
        guard !bid.contains("/"), !bid.hasPrefix("pid-") else {
            TTLog("hide skipped: no bundle id for \(entry.name)")
            return
        }
        var hidden = Preferences.shared.hiddenApps
        hidden[bid] = entry.name
        Preferences.shared.hiddenApps = hidden
        TTLog("hide \(entry.name) (\(bid))")
    }

    // MARK: - 固定（任务栏 / 开始菜单）

    /// 能不能固定：得有稳定的 bundle id 和 .app 路径（同 hide 的判断）
    private func pinnedApp(for entry: AppEntry) -> PinnedApp? {
        let bid = entry.id
        guard !bid.contains("/"), !bid.hasPrefix("pid-"),
              let url = entry.bundleURL ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: bid)
        else {
            TTLog("pin skipped: no bundle id / url for \(entry.name)")
            return nil
        }
        return PinnedApp(bundleID: bid, path: url.path, name: entry.name)
    }

    func isDockPinned(_ id: String) -> Bool {
        Preferences.shared.dockPins.contains { $0.bundleID == id }
    }

    func isStartPinned(_ id: String) -> Bool {
        Preferences.shared.startPins.contains { $0.bundleID == id }
    }

    func pinToDock(_ entry: AppEntry) {
        guard let pin = pinnedApp(for: entry) else { return }
        pinToDock(pin)
    }

    func pinToDock(_ pin: PinnedApp) {
        let prefs = Preferences.shared
        guard !isDockPinned(pin.bundleID) else { return }
        // 固定 = 明确要它在条上，顺手从「已隐藏」里放出来
        if prefs.hiddenApps[pin.bundleID] != nil {
            var hidden = prefs.hiddenApps
            hidden.removeValue(forKey: pin.bundleID)
            prefs.hiddenApps = hidden
        }
        prefs.dockPins.append(pin)
        TTLog("pinToDock \(pin.name)")
        refresh()
    }

    func unpinFromDock(_ id: String) {
        Preferences.shared.dockPins.removeAll { $0.bundleID == id }
        refresh()
    }

    /// 固定项左右挪一格（右键「向左移 / 向右移」、设置里的上下箭头）
    func moveDockPin(_ id: String, by offset: Int) {
        var pins = Preferences.shared.dockPins
        guard let i = pins.firstIndex(where: { $0.bundleID == id }) else { return }
        let j = i + offset
        guard pins.indices.contains(j) else { return }
        pins.swapAt(i, j)
        Preferences.shared.dockPins = pins
        refresh()
    }

    func pinToStart(_ entry: AppEntry) {
        guard let pin = pinnedApp(for: entry) else { return }
        pinToStart(pin)
    }

    func pinToStart(_ pin: PinnedApp) {
        guard !isStartPinned(pin.bundleID) else { return }
        Preferences.shared.startPins.append(pin)
    }

    func unpinFromStart(_ id: String) {
        Preferences.shared.startPins.removeAll { $0.bundleID == id }
    }

    /// 已固定网格里文件夹格子的 key
    nonisolated static func startFolderKey(_ id: UUID) -> String { "folder:\(id.uuidString)" }

    /// 已固定网格的统一顺序：App 格是 bundle id，文件夹格是 `startFolderKey`。
    ///
    /// `startOrder` 只决定「第几格是文件夹、第几格是 App」，App 格按 `startPins` 的顺序依次填 ——
    /// 这样设置里给固定项排序照样生效。没记进顺序的新固定项 / 新文件夹排在最后。
    func startGridKeys() -> [String] {
        let prefs = Preferences.shared
        let pinIDs = prefs.startPins.map(\.bundleID)
        let folderKeys = prefs.startFolders.map { Self.startFolderKey($0.id) }
        let live = Set(pinIDs).union(folderKeys)
        let folderSet = Set(folderKeys)

        var seen = Set<String>()
        var slots: [String] = []
        for key in prefs.startOrder + pinIDs + folderKeys where live.contains(key) && !seen.contains(key) {
            seen.insert(key)
            slots.append(key)
        }
        var pins = pinIDs.makeIterator()
        return slots.map { folderSet.contains($0) ? $0 : (pins.next() ?? $0) }
    }

    /// 已固定网格里拖动排序（App 和文件夹混排）：把 `key` 挪到 `targetKey` 所在的位置
    func moveStartGridItem(_ key: String, to targetKey: String) {
        var keys = startGridKeys()
        guard key != targetKey,
              let i = keys.firstIndex(of: key),
              let j = keys.firstIndex(of: targetKey) else { return }
        keys.insert(keys.remove(at: i), at: j)
        let prefs = Preferences.shared
        prefs.startOrder = keys
        // startPins 跟着排成同样的相对顺序（设置页的列表也就一致了）
        let rank = Dictionary(keys.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        prefs.startPins.sort { (rank[$0.bundleID] ?? .max) < (rank[$1.bundleID] ?? .max) }
    }

    // MARK: - 开始菜单文件夹

    /// 新建文件夹（可顺手放进一个 App），返回它的 id。名字重了就加序号：新資料夾 2、3…
    @discardableResult
    func createStartFolder(with pin: PinnedApp? = nil) -> UUID {
        let names = Set(Preferences.shared.startFolders.map(\.name))
        var name = "新資料夾"
        var n = 2
        while names.contains(name) { name = "新資料夾 \(n)"; n += 1 }
        let folder = StartFolder(name: name, apps: pin.map { [$0] } ?? [])
        Preferences.shared.startFolders.append(folder)
        return folder.id
    }

    func deleteStartFolder(_ folderID: UUID) {
        Preferences.shared.startFolders.removeAll { $0.id == folderID }
    }

    func renameStartFolder(_ folderID: UUID, to name: String) {
        guard let i = Preferences.shared.startFolders.firstIndex(where: { $0.id == folderID }) else { return }
        Preferences.shared.startFolders[i].name = name
    }

    func folderContains(_ folderID: UUID, _ id: String) -> Bool {
        Preferences.shared.startFolders.first { $0.id == folderID }?.apps.contains { $0.bundleID == id } ?? false
    }

    func addToStartFolder(_ folderID: UUID, _ pin: PinnedApp) {
        guard let i = Preferences.shared.startFolders.firstIndex(where: { $0.id == folderID }),
              !Preferences.shared.startFolders[i].apps.contains(where: { $0.bundleID == pin.bundleID })
        else { return }
        Preferences.shared.startFolders[i].apps.append(pin)
    }

    func removeFromStartFolder(_ folderID: UUID, _ id: String) {
        guard let i = Preferences.shared.startFolders.firstIndex(where: { $0.id == folderID }) else { return }
        Preferences.shared.startFolders[i].apps.removeAll { $0.bundleID == id }
    }

    /// 文件夹里拖动排序：把 `id` 挪到 `targetID` 所在的位置
    func moveInStartFolder(_ folderID: UUID, _ id: String, to targetID: String) {
        guard let f = Preferences.shared.startFolders.firstIndex(where: { $0.id == folderID }) else { return }
        var apps = Preferences.shared.startFolders[f].apps
        guard id != targetID,
              let i = apps.firstIndex(where: { $0.bundleID == id }),
              let j = apps.firstIndex(where: { $0.bundleID == targetID }) else { return }
        apps.insert(apps.remove(at: i), at: j)
        Preferences.shared.startFolders[f].apps = apps
    }

    // MARK: - Sizing

    /// 面板理想宽度（首帧兜底）：内容实测 + 内边距，上限交给控制器按屏幕裁。
    /// 内容宽度上报到位后就以实测为准。
    var preferredWidth: CGFloat {
        guard contentWidth <= 1 else { return contentWidth }
        let font = NSFont.systemFont(ofSize: 12, weight: .medium)
        let iconOnly = Preferences.shared.iconOnly
        // 24 = 左右内边距；后面那段 = 开始按钮 + 分隔线（开着才算）
        var total: CGFloat = 24
        if Preferences.shared.showStartButton { total += (iconOnly ? 54 : 44) + 13 }
        for (index, group) in groups.enumerated() {
            if index > 0 { total += 13 }
            for entry in group.entries {
                if iconOnly {
                    total += 36 + 12 + 2
                } else {
                    let textWidth = min((entry.displayName as NSString).size(withAttributes: [.font: font]).width, 108)
                    total += 18 + 6 + ceil(textWidth) + 18 + 2 + 13
                }
            }
        }
        return total * TTLayout.scale
    }
}

/// ⌘Tab 会话的循环序列规则：纯下标运算，不碰 App 列表，
/// 这样"起点在哪 / 怎么循环"这条路径能离线跑回归（同 TabBarController.ScreenPick 的思路）。
///
/// 序列本身恒为**面板视觉顺序**（标签从左到右）。唯一的例外是起点：
/// 预选"上一个 App"，好让快按快放仍然等于切回上一个 App（Windows Alt+Tab 的手感）。
/// 一旦开始按 Tab，就只沿视觉顺序走 —— 每按一次挪一格，末尾回到第一个。
enum SessionCycle {

    /// 起点下标：MRU 里第一个既不是当前前台、又还在条上的 App。
    ///
    /// 找不到（MRU 里只剩当前 App、或刚启动还没记录）就退到第 1 格 ——
    /// 调用方保证可见 App ≥ 2，所以第 1 格一定存在。
    static func startIndex(visual: [pid_t], mru: [pid_t], active: pid_t) -> Int {
        guard !visual.isEmpty else { return 0 }
        let visible = Set(visual)
        if let pid = mru.first(where: { $0 != active && visible.contains($0) }),
           let i = visual.firstIndex(of: pid) {
            return i
        }
        return visual.count > 1 ? 1 : 0
    }

    /// 前进一格；末尾回到第一个（循环，不越界、不停住）。
    static func next(_ index: Int, count: Int) -> Int {
        guard count > 0 else { return 0 }
        return ((index % count) + 1) % count
    }
}

/// 一次拖动排序的状态。开拖那一刻把同组标签的位置拍个快照，之后全按快照算 ——
/// 拖动中标签带着位移，实时上报的命中区域会跟着动，拿它算落点会自己追自己。
/// 只在组内排：固定组和运行中组之间不互相拖（跨组 = 固定 / 取消固定，交给右键菜单）。
struct TabDrag: Equatable {
    let id: String
    let groupID: String
    /// 同组标签开拖时的顺序与位置（窗口坐标，原点上左）
    let ids: [String]
    let frames: [CGRect]
    let source: Int
    let startX: CGFloat
    /// 被拖标签跟着指针的位移（已夹在组的两端之内）
    private(set) var dx: CGFloat = 0
    /// 松手会落到的下标
    private(set) var target: Int

    /// 让位 / 落位共用一条弹簧：重排时布局位移和 offset 归零同步走，被让位的标签才不会抖
    static let settle = Animation.spring(response: 0.26, dampingFraction: 0.82)

    init?(entry: AppEntry, startX: CGFloat, groups: [AppGroup], frames: [String: CGRect]) {
        guard let group = groups.first(where: { $0.entries.contains { $0.id == entry.id } }) else { return nil }
        let ids = group.entries.map(\.id)
        let rects = ids.compactMap { frames[$0] }
        guard rects.count == ids.count, let source = ids.firstIndex(of: entry.id) else { return nil }
        self.id = entry.id
        self.groupID = group.id
        self.ids = ids
        self.frames = rects
        self.source = source
        self.startX = startX
        self.target = source
    }

    /// 被拖标签占的一格（自身宽度 + 到邻居的间隙 / 分隔线）：其它标签让位就挪这么多
    var step: CGFloat {
        let f = frames[source]
        if source + 1 < frames.count { return frames[source + 1].minX - f.minX }
        if source > 0 { return f.maxX - frames[source - 1].maxX }
        return f.width
    }

    mutating func move(to x: CGFloat) {
        guard let first = frames.first, let last = frames.last else { return }
        let f = frames[source]
        dx = min(max(x - startX, first.minX - f.minX), last.maxX - f.maxX)
        // 落点 = 被拖标签的前沿越过了几个邻居的中线（往右看右边沿，往左看左边沿）。
        // 不能拿中心比：位移夹在组两端之内，宽标签拖到头中心也过不了窄标签的中线，到不了末位。
        let passedRight = frames.indices.filter { $0 > source && f.maxX + dx > frames[$0].midX }.count
        let passedLeft = frames.indices.filter { $0 < source && f.minX + dx < frames[$0].midX }.count
        target = source + passedRight - passedLeft
    }

    func offset(for id: String) -> CGFloat {
        if id == self.id { return dx }
        guard let i = ids.firstIndex(of: id) else { return 0 }
        if source < i && i <= target { return -step }
        if target <= i && i < source { return step }
        return 0
    }

    var reorderedIDs: [String] {
        var result = ids
        result.remove(at: source)
        result.insert(id, at: target)
        return result
    }
}
