import AppKit
import ApplicationServices
import Combine

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

    static func == (lhs: AppEntry, rhs: AppEntry) -> Bool {
        lhs.id == rhs.id && lhs.pid == rhs.pid && lhs.category == rhs.category
            && lhs.isRunning == rhs.isRunning && lhs.isPinned == rhs.isPinned
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
    private var lastSignature: String = ""

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

        WindowPresence.shared.onChange = { [weak self] in self?.refresh() }
        refresh()
        scanWindows()
    }

    func stop() {
        refreshTimer?.invalidate()
        refreshTimer = nil
        let nc = NSWorkspace.shared.notificationCenter
        subscribers.forEach { nc.removeObserver($0) }
        subscribers.removeAll()
    }

    // MARK: - Collection

    /// 后台查一轮"哪些 App 没有窗口"（结果变了会回调 refresh）。开关关着就不查。
    func scanWindows() {
        guard Preferences.shared.onlyWindowedApps else { return }
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

        let hidden = prefs.hiddenApps
        // 「只显示有窗口的 App」：没窗口的运行中 App 不上条（固定项上面已经收走了，不受影响）
        let windowless: Set<pid_t> = prefs.onlyWindowedApps ? WindowPresence.shared.windowless : []
        let others = running.filter { e in
            !pinnedIDs.contains(e.id) && hidden[e.id] == nil && !windowless.contains(e.pid)
        }
        return (pinned, others)
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
    /// 顺序只在启动 / 退出时变，点标签切换不会挪位，不会误点。
    /// 拿不到启动时间的（极少见）排最后，再按 pid 兜底保证稳定。
    private func sorted(_ entries: [AppEntry]) -> [AppEntry] {
        entries.sorted { a, b in
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
        guard !menuTracking else { return }
        let frontmost = NSWorkspace.shared.frontmostApplication
        let frontPID = frontmost?.processIdentifier ?? -1

        let collected = collect()
        let newGroups = group(pinned: collected.pinned, running: collected.running)

        let signature = newGroups.map { g in
            "\(g.id):" + g.entries.map { "\($0.id)#\($0.pid)" }.joined(separator: ",")
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

    /// 窗口层命中测试入口：point 使用「原点在左上」的坐标系
    func handleTap(at point: NSPoint) -> Bool {
        if let rect = tabFrames[Self.startButtonID], rect.contains(point) {
            if keyboardSession { endKeyboardSession() }
            host?.toggleStartMenu()
            return true
        }
        var hit: AppEntry?
        for group in groups {
            for entry in group.entries {
                if let rect = tabFrames[entry.id], rect.contains(point) {
                    hit = entry
                    break
                }
            }
            if hit != nil { break }
        }
        if let hit {
            // ⌘Tab 会话中用鼠标点了标签：点击本身就是选择，
            // 结束会话避免松 ⌘ 时再提交一次高亮（可能不是点中的这个）
            if keyboardSession { endKeyboardSession() }
            activate(hit, fromClick: true)
            // 这次如果条是 ⌘Tab 呼出来的，选完立刻消失，不等鼠标离开的倒计时
            host?.dismissQuickSwitch()
            return true
        }
        return false
    }

    /// - fromClick: 鼠标点标签（Windows 任务栏语义：前台 App 再点一下 = 最小化）。
    ///   ⌘Tab 提交 / 右键菜单等其它入口只管激活。
    func activate(_ entry: AppEntry, fromClick: Bool = false) {
        guard entry.isRunning, entry.pid > 0 else {
            // 固定了但没在运行：点一下 = 启动（同点 Dock 上没有小圆点的图标）
            if let url = entry.bundleURL { launch(url: url, bundleID: entry.id) }
            return
        }
        let pid = entry.pid
        guard fromClick, Preferences.shared.clickToMinimize, WindowBridge.isTrusted else {
            activatePID(pid)
            return
        }
        // 点前台 App：把它开着的窗口全部最小化；一个开着的都没有（上次点图标收起来了）
        // 就恢复它们再激活。条是不抢焦点的面板，点它不会改变前台 App，这里读到的就是点之前的前台。
        let isFront = NSWorkspace.shared.frontmostApplication?.processIdentifier == pid
        guard isFront else {
            // 后台 App：照常立刻激活（切换手感不能等 AX），被点图标收进 Dock 的窗口顺手放回来
            activatePID(pid)
            Task.detached(priority: .userInitiated) { WindowBridge.restoreMinimized(pid: pid) }
            return
        }
        // AX 读写可能卡到超时，挪到后台，别卡住鼠标
        Task.detached(priority: .userInitiated) { [weak self] in
            if WindowBridge.minimizeOpenWindows(pid: pid) { return }
            WindowBridge.restoreMinimized(pid: pid)
            await self?.activatePID(pid)
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
        mru.removeAll { NSRunningApplication(processIdentifier: $0)?.isTerminated ?? true }
        // 没在运行的固定项切不过去，不进 ⌘Tab 循环
        let visible = groups.flatMap(\.entries).filter { $0.pid > 0 }
        guard visible.count >= 2 else {
            TTLog("kbdSession: 可见 App 不足(\(visible.count))")
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
        guard entry.pid > 0, let app = NSRunningApplication(processIdentifier: entry.pid) else { return }
        TTLog("terminate \(entry.name) pid=\(entry.pid)")
        app.terminate()
        let pid = entry.pid
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
            if let still = NSRunningApplication(processIdentifier: pid), !still.isTerminated {
                TTLog("terminate timeout → forceTerminate \(entry.name)")
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
                    let textWidth = min((entry.name as NSString).size(withAttributes: [.font: font]).width, 108)
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
