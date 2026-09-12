import AppKit
import ApplicationServices
import Combine

/// 一个可点击的标签 = 一个正在运行的 App
struct AppEntry: Identifiable, Equatable {
    let id: String
    let pid: pid_t
    let name: String
    let icon: NSImage
    let category: AppCategory

    static func == (lhs: AppEntry, rhs: AppEntry) -> Bool {
        lhs.id == rhs.id && lhs.pid == rhs.pid && lhs.category == rhs.category
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
                MainActor.assumeIsolated { self?.refresh() }
            }
            subscribers.append(token)
        }

        // 兜底轮询：兜住任何漏掉的通知
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 1.2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        RunLoop.main.add(refreshTimer!, forMode: .common)

        refresh()
    }

    func stop() {
        refreshTimer?.invalidate()
        refreshTimer = nil
        let nc = NSWorkspace.shared.notificationCenter
        subscribers.forEach { nc.removeObserver($0) }
        subscribers.removeAll()
    }

    // MARK: - Collection

    private func collect() -> [AppEntry] {
        let hidden = Preferences.shared.hiddenApps
        let apps = NSWorkspace.shared.runningApplications.filter { app in
            guard app.activationPolicy == .regular else { return false }
            guard app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return false }
            guard !app.isTerminated else { return false }
            // 用户手动隐藏的 App 不出现在标签里（不退出、不动窗口，只是不显示）
            if let bid = app.bundleIdentifier, hidden[bid] != nil { return false }
            return true
        }

        var entries: [AppEntry] = []
        for app in apps {
            let bid = app.bundleIdentifier ?? app.executableURL?.path ?? "pid-\(app.processIdentifier)"
            let name = app.localizedName ?? bid
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
                category: AppCategory.classify(name: name, bundleID: bid)
            ))
        }
        return entries
    }

    /// 稳定排序：组内按名称，避免"点完就移位"导致误点
    private func sorted(_ entries: [AppEntry]) -> [AppEntry] {
        entries.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private func group(_ entries: [AppEntry]) -> [AppGroup] {
        var buckets: [AppCategory: [AppEntry]] = [:]
        for e in entries { buckets[e.category, default: []].append(e) }

        return buckets
            .map { AppGroup(id: $0.key.rawValue, category: $0.key, entries: sorted($0.value)) }
            .sorted { $0.category.rank < $1.category.rank }
    }

    // MARK: - Refresh

    func refresh() {
        let frontmost = NSWorkspace.shared.frontmostApplication
        let frontPID = frontmost?.processIdentifier ?? -1

        let entries = collect()
        let newGroups = group(entries)

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
            activate(hit)
            return true
        }
        return false
    }

    func activate(_ entry: AppEntry) {
        activatePID(entry.pid)
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
        var next = mru
        next.removeAll { $0 == pid }
        next.insert(pid, at: 0)
        if next.count > 12 { next.removeLast(next.count - 12) }
        mru = next
    }

    // MARK: - ⌘Tab 键盘会话（AppRing 同款机制）
    //
    // 第一次 ⌘Tab：立即弹条 + 预选上一个 App；
    // 再按 Tab：沿 MRU 前进高亮；
    // 松开 ⌘：提交高亮项（快按快放因此天然等于"切上一个"）；
    // Esc / 鼠标点标签 / 再按一次 ⌘Tab 前松手：取消。

    /// 会话进行中（tick 据此暂停自动隐藏；松 ⌘ 据此决定要不要提交）
    @Published private(set) var keyboardSession = false
    /// 当前键盘高亮的 pid（视图层画蓝底）
    @Published private(set) var keyboardHighlightPID: pid_t = 0
    /// 会话的循环序列（MRU 优先，未进过 MRU 的可见 App 补在后面）
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
        let visible = groups.flatMap(\.entries)
        guard visible.count >= 2 else {
            TTLog("kbdSession: 可见 App 不足(\(visible.count))")
            return false
        }
        let visiblePIDs = Set(visible.map(\.pid))
        var cycle = mru.filter { visiblePIDs.contains($0) }
        // 当前前台排第一（它可能还没进过 MRU，比如刚被鼠标点起来）
        if let i = cycle.firstIndex(of: activePID) {
            cycle.remove(at: i)
        }
        cycle.insert(activePID, at: 0)
        // 从没进过 MRU 的 App 按显示顺序补在后面，保证 Tab 连按能循环到全部
        cycle.append(contentsOf: visible.map(\.pid).filter { !cycle.contains($0) })

        sessionCycle = cycle
        sessionIndex = 1
        keyboardHighlightPID = cycle[1]
        keyboardSession = true
        TTLog("kbdSession start → \(Self.name(of: cycle[1])) cycle=\(cycle.count)")
        return true
    }

    /// 会话中再按 Tab：前进一格。
    func cycleKeyboardSession() {
        guard keyboardSession, !sessionCycle.isEmpty else { return }
        sessionIndex = (sessionIndex + 1) % sessionCycle.count
        keyboardHighlightPID = sessionCycle[sessionIndex]
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
        guard let app = NSRunningApplication(processIdentifier: entry.pid) else { return }
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

    // MARK: - Sizing

    /// 面板理想宽度（首帧兜底）：内容实测 + 内边距，上限交给控制器按屏幕裁。
    /// 内容宽度上报到位后就以实测为准。
    var preferredWidth: CGFloat {
        guard contentWidth <= 1 else { return contentWidth }
        let font = NSFont.systemFont(ofSize: 12, weight: .medium)
        var total: CGFloat = 16
        for (index, group) in groups.enumerated() {
            if index > 0 { total += 12 }
            for entry in group.entries {
                let textWidth = min((entry.name as NSString).size(withAttributes: [.font: font]).width, 108)
                total += 18 + 6 + ceil(textWidth) + 18 + 2
            }
        }
        return total
    }
}
