import AppKit
import ApplicationServices
import CoreGraphics
import ScreenCaptureKit

/// 可跨并发域传递的图片包装（CGImage 本身未标 Sendable）
struct SendableImage: @unchecked Sendable {
    let value: CGImage
}

/// 窗口快照条目（值类型，可安全跨并发域）
struct WindowInfo: Identifiable, Sendable {
    /// 窗口服务器 ID。AX 有、SC 没有对应窗口时为合成 ID（抓不到像素，用图标兜底）
    let id: UInt32
    let title: String
    let frame: CGRect
    let isOnScreen: Bool
    let isMinimized: Bool
    /// 该窗口在 App 的 AX 窗口数组里的下标；点击时用它精确定位
    let axIndex: Int?
}

/// 窗口枚举（辅助功能 API 定集合）+ 缩略图抓取（ScreenCaptureKit 出像素）。
///
/// 为什么这么分工：
/// - **集合必须用 AX**。窗口服务器的 `optionOnScreenOnly` 列不出最小化 / 其它桌面的窗口；
///   换成 `optionAll` 又会混进一大堆不可见的辅助表面（实测 Chrome 2 个真窗口对应 7 条记录，
///   微信 1 个真窗口对应 4 条）。AX 的 `kAXWindowsAttribute` 给的正是用户认知里的"窗口"，
///   还自带 `AXMinimized`。
/// - **像素必须用 ScreenCaptureKit**。AX 没有像素；而 `CGWindowListCreateImage` 对最小化 /
///   其它桌面的窗口一律返回 nil。SC 用 `onScreenWindowsOnly: false` 能抓到，且能直接按
///   目标尺寸渲染，省掉「全分辨率抓取 + 自己缩放」。
final class ScreenCaptureEngine: @unchecked Sendable {
    static let shared = ScreenCaptureEngine()

    private let lock = NSLock()
    /// windowID → SCWindow（抓图需要 SCWindow 句柄，只有 windowID 不够）
    private var windowsByID: [UInt32: SCWindow] = [:]
    /// pid → 该 App 的窗口，前台→后台
    private var byPID: [pid_t: [WindowInfo]] = [:]
    private var lastEnumerated = Date.distantPast
    /// 合成 ID 的基准（AX 有窗口但 SC 抓不到时用）
    private static let syntheticBase: UInt32 = 0xF000_0000

    private final class CacheEntry {
        let image: CGImage
        let at: Date
        init(_ image: CGImage) { self.image = image; self.at = Date() }
    }

    /// 抓图缓存。命中即零延迟，过期则先用旧图顶上、后台再刷新（stale-while-revalidate）
    private let cache = NSCache<NSNumber, CacheEntry>()

    private init() {
        cache.countLimit = 128
        cache.totalCostLimit = 96 * 1024 * 1024
    }

    // MARK: - 权限

    static var hasPermission: Bool { CGPreflightScreenCaptureAccess() }

    /// 每次启动最多弹一次系统授权请求。
    /// 不用 UserDefaults 记「已请求过」—— 重签名后授权会失效，
    /// 记死了就再也不会提示，用户只会看到预览里全是图标占位而不知为何。
    private static var requestedThisLaunch = false
    static func requestPermissionIfNeeded() {
        guard !hasPermission, !requestedThisLaunch else { return }
        requestedThisLaunch = true
        CGRequestScreenCaptureAccess()
    }

    // MARK: - 窗口枚举

    /// 刷新窗口快照。`minInterval` 秒内的重复调用直接复用上次结果。
    /// `pids` 是需要在意的 App（用于 AX 精确化）—— 不在列表里的进程只做粗略过滤。
    @discardableResult
    func refresh(minInterval: TimeInterval, pids: [pid_t]) async -> Bool {
        guard isStale(minInterval) else { return false }

        guard let content = try? await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: false
        ) else { return false }

        var scByPID: [pid_t: [SCWindow]] = [:]
        for win in content.windows where Self.looksLikeWindow(win) {
            guard let pid = win.owningApplication?.processID else { continue }
            scByPID[pid, default: []].append(win)
        }

        // 同一帧几何被 3 个以上进程同时列出 → 系统共享缓冲，不是谁的窗口。
        // 实测 `500×500 @0,456` 出现在微信 / Chrome / 抖店工作台 / 快递打印助手 / NDM /
        // Shadowrocket / loginwindow / Siri / UserNotificationCenter … 几乎每个进程名下，
        // 按尺寸筛根本筛不掉（500×500 一点也不小）。
        var frameOwners: [String: Set<pid_t>] = [:]
        for (pid, list) in scByPID {
            for win in list { frameOwners[Self.frameKey(win.frame), default: []].insert(pid) }
        }
        let sharedFrames = Set(frameOwners.filter { $0.value.count >= 3 }.keys)

        // AX 调用是同步阻塞的，丢到后台线程
        let axByPID = await Task.detached(priority: .utility) {
            await Self.axWindowsByPID(pids)
        }.value

        let zOrder = Self.zOrderMap()
        var freshHandles: [UInt32: SCWindow] = [:]
        var grouped: [pid_t: [WindowInfo]] = [:]

        TTLog("AX " + pids.map { "\($0):\(axByPID[$0].map { "\($0.filter(\.real).count)/\($0.count)" } ?? "miss")" }
                .joined(separator: " ")
              + " shared=\(sharedFrames.count)")

        for (pid, scList) in scByPID {
            let infos = Self.resolve(pid: pid, scList: scList, axList: axByPID[pid],
                                     zOrder: zOrder, sharedFrames: sharedFrames,
                                     handles: &freshHandles)
            if !infos.isEmpty { grouped[pid] = infos }
        }
        // AX 里有、SC 完全没列出的窗口也要露出来（抓不到像素就用图标兜底）。
        // 同样要过「座位」检查 —— App 无障碍树里的幻影不因为 SC 缺席就变成真的。
        for (pid, axList) in axByPID where grouped[pid] == nil {
            var seats = SeatPool(pid: pid)
            let real = axList.filter(\.real).filter { seats.take(near: $0.frame) }
            guard !real.isEmpty else { continue }
            grouped[pid] = real.map { ax in
                WindowInfo(id: Self.syntheticBase + UInt32(ax.index),
                           title: ax.title,
                           frame: ax.frame,
                           isOnScreen: false,
                           isMinimized: ax.minimized,
                           axIndex: ax.index)
            }
        }

        store(handles: freshHandles, grouped: grouped)
        return true
    }

    /// SC 会把大量不可见的小辅助表面（输入法候选框、tooltip、状态条，常见 100×30 / 1470×33）
    /// 也列成 layer 0，先按尺寸粗筛。
    private static func looksLikeWindow(_ win: SCWindow) -> Bool {
        win.windowLayer == 0 && win.frame.width >= 150 && win.frame.height >= 110
    }

    private static func frameKey(_ f: CGRect) -> String {
        "\(Int(f.minX.rounded())):\(Int(f.minY.rounded())):\(Int(f.width.rounded())):\(Int(f.height.rounded()))"
    }

    /// AX 拿不到时的兜底门槛。窗口服务器里躺着一堆「幽灵」——图层 0、不在屏、
    /// 名字还像模像样（实测抖店工作台 `task 200×200`、`Rust SDK 500×500`，
    /// 微信 `700×640` / `576×665` / `280×380`）。只放行两种：
    ///   1. 此刻真在屏幕上 —— 唯一不需要猜的硬信号；
    ///   2. 不在屏、非共享缓冲、有标题、且尺寸像正经窗口 —— 覆盖最小化 / 其它桌面的
    ///      真窗口（实测快递打印助手 `手工订单 1360×841`、NDM `1015×585`、
    ///      微信 `880×721`、Shadowrocket `1024×768`）。
    /// 宁可少列几个，也不能把幽灵塞进预览里 —— 用户对"我开着几个窗口"是有数的。
    private static func plausible(_ win: SCWindow, sharedFrames: Set<String>) -> Bool {
        if win.isOnScreen { return true }
        guard !sharedFrames.contains(frameKey(win.frame)) else { return false }
        guard let title = win.title, !title.isEmpty else { return false }
        return win.frame.width >= 800 && win.frame.height >= 500
    }

    /// 用 AX 窗口集合给 SC 的原始列表定集合、定顺序、补标题。
    /// AX 拿不到（没辅助功能权限 / App 不响应）就退回严格启发式。
    ///
    /// **AX 回了空数组就要信**：它说明这个 App 真的没有窗口。
    /// 早先「空」和「拿不到」一样走启发式，结果微信这种把主界面挂在
    /// 屏幕外的 App 会一直多出一张点不动也关不掉的幽灵卡片。
    private static func resolve(pid: pid_t,
                                scList: [SCWindow],
                                axList: [AXWindow]?,
                                zOrder: [UInt32: Int],
                                sharedFrames: Set<String>,
                                handles: inout [UInt32: SCWindow]) -> [WindowInfo] {
        let sorted = scList.sorted { (zOrder[$0.windowID] ?? Int.max) < (zOrder[$1.windowID] ?? Int.max) }

        guard let axList else {
            return sorted.compactMap { win in
                guard Self.plausible(win, sharedFrames: sharedFrames) else { return nil }
                handles[win.windowID] = win
                return WindowInfo(id: win.windowID, title: win.title ?? "", frame: win.frame,
                                  isOnScreen: win.isOnScreen, isMinimized: false, axIndex: nil)
            }
        }
        guard !axList.isEmpty else { return [] }

        var unused = sorted
        var out: [WindowInfo] = []
        // 「座位池」：窗口服务器里该 pid 的 layer-0 大表面。AX 报的每个真窗口
        // 都必须领到一个座位 —— 实测 QQ 偶发把同一个窗口在无障碍树里报成两条
        // （同标题同几何），第二条领不到座位，就是用户看到的「多余的空白窗口」
        // （合成卡片、图标兜底、缩略图空白、点它也点不动）。
        // 有座位才放行，同一个表面只发一张票。
        var seats = SeatPool(pid: pid)
        // 只认「用户眼里的窗口」。非窗口元素（访达会多报一条 AXScrollArea）直接跳过，
        // 也不从 unused 里取配对，免得把它的 SC 表面吃掉。
        for ax in axList where ax.real {
            let match = takeMatch(from: &unused, ax: ax)
            if let match {
                handles[match.windowID] = match
                let title = ax.title.isEmpty ? (match.title ?? "") : ax.title
                // SC 匹配本身就是真实性的硬证据，座位没领到也保留；
                // 领座位是为了把「同一表面只认一次」的账记上，让后面的重复上报领不到票
                _ = seats.take(near: ax.frame)
                out.append(WindowInfo(id: match.windowID, title: title, frame: ax.frame,
                                      isOnScreen: match.isOnScreen, isMinimized: ax.minimized,
                                      axIndex: ax.index))
            } else {
                // AX 说有窗口但 SC 没有对应表面 —— 找窗口服务器要证据
                guard seats.take(near: ax.frame) else {
                    TTLog("drop phantom pid=\(pid) ax=\(ax.index) title=\"\(ax.title)\" frame=\(ax.frame)")
                    continue
                }
                out.append(WindowInfo(id: syntheticBase + UInt32(ax.index), title: ax.title,
                                      frame: ax.frame, isOnScreen: false,
                                      isMinimized: ax.minimized, axIndex: ax.index))
            }
        }
        return out
    }

    /// 窗口服务器「座位池」：该 pid 在 `CGWindowListCopyWindowInfo(.optionAll)` 里
    /// 的全部 layer-0 大表面（含最小化 / 其它桌面的窗口）。每个真实存在的窗口
    /// 在这里都有一个对应条目 —— AX 树里多报出来的幻影没有。
    private struct SeatPool {
        private var seats: [CGRect]

        init(pid: pid_t) {
            guard let list = CGWindowListCopyWindowInfo(
                [.optionAll, .excludeDesktopElements], kCGNullWindowID
            ) as? [[String: Any]] else {
                seats = []
                return
            }
            seats = list.compactMap { info in
                guard (info[kCGWindowOwnerPID as String] as? pid_t) == pid,
                      (info[kCGWindowLayer as String] as? Int) == 0,
                      let b = info[kCGWindowBounds as String] as? [String: NSNumber] else { return nil }
                let rect = CGRect(x: b["X"]?.doubleValue ?? 0, y: b["Y"]?.doubleValue ?? 0,
                                  width: b["Width"]?.doubleValue ?? 0,
                                  height: b["Height"]?.doubleValue ?? 0)
                // 与 isRealWindow 的尺寸门槛保持同量级，避免把小辅助表面当座位
                guard rect.width >= 120, rect.height >= 90 else { return nil }
                return rect
            }
        }

        /// 领一个几何接近 `frame` 的座位。领到返回 true 并把座位从池里移走。
        mutating func take(near frame: CGRect, tolerance: CGFloat = 8) -> Bool {
            guard let index = seats.firstIndex(where: {
                abs($0.minX - frame.minX) <= tolerance
                    && abs($0.minY - frame.minY) <= tolerance
                    && abs($0.width - frame.width) <= tolerance
                    && abs($0.height - frame.height) <= tolerance
            }) else { return false }
            seats.remove(at: index)
            return true
        }
    }

    /// 从待选池里取出与 AX 窗口对应的那个 SC 窗口。
    ///
    /// **标题证据优先于几何**：Chrome 多窗口的常态是所有窗口几何完全相同
    ///（`0,33 1470×841` × N），此时几何毫无区分力，只能靠池内顺序（z 序）盲配。
    /// 而 AX 列表顺序与 CG z 序在 Chrome 激活窗口的异步重排期经常不一致
    ///（枚举时三份快照各取一时点），盲配就会把 B 窗口的 CG 编号安到 A 卡片上 ——
    /// 表现即"点 A 跳 B、来回跳"：缩略图像素和定位锚点都指错了窗口。
    ///
    /// 打分（从高到低）：标题精确+几何一致 > 标题宽松+几何一致 > 标题精确 >
    /// 标题宽松 > 无标题证据+几何一致 > 无标题证据 > 标题明确不同+几何一致 > 其余。
    /// 标题明确不同的候选排最后 —— 宁可让它落空走幻影检查，也不要把错窗口的
    /// 编号安上去。取走即从池里移除，避免同名同尺寸的多个窗口全指向同一条。
    private static func takeMatch(from pool: inout [SCWindow], ax: AXWindow) -> SCWindow? {
        func sameFrame(_ win: SCWindow) -> Bool {
            abs(win.frame.minX - ax.frame.minX) <= 2
                && abs(win.frame.minY - ax.frame.minY) <= 2
                && abs(win.frame.width - ax.frame.width) <= 2
                && abs(win.frame.height - ax.frame.height) <= 2
        }
        /// 3=精确一致，2=宽松一致（CG 侧标题常被截断，如"新标签页" vs
        /// "新标签页 - Google Chrome"），1=有一边没标题、帮不上忙，0=标题明确不同
        func titleScore(_ win: SCWindow) -> Int {
            let st = win.title ?? ""
            guard !st.isEmpty, !ax.title.isEmpty else { return 1 }
            if st == ax.title { return 3 }
            if st.hasPrefix(ax.title) || ax.title.hasPrefix(st)
                || st.contains(ax.title) || ax.title.contains(st) { return 2 }
            return 0
        }
        func rank(_ win: SCWindow) -> Int {
            switch (titleScore(win), sameFrame(win)) {
            case (3, true):  return 7
            case (2, true):  return 6
            case (3, false): return 5
            case (2, false): return 4
            case (1, true):  return 3
            case (1, false): return 2
            case (_, true):  return 1   // 标题对不上但几何一致：弱证据
            default:         return 0
            }
        }
        guard let index = pool.indices.max(by: { rank(pool[$0]) < rank(pool[$1]) }) else { return nil }
        // 只剩"标题明确不同"的候选时视为配不上，交给上层的座位/幻影检查处理
        guard rank(pool[index]) > 1 else { return nil }
        return pool.remove(at: index)
    }

    private static func zOrderMap() -> [UInt32: Int] {
        guard let list = CGWindowListCopyWindowInfo(
            [.optionAll, .excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]] else { return [:] }
        var map: [UInt32: Int] = [:]
        for (index, info) in list.enumerated() {
            if let id = info[kCGWindowNumber as String] as? UInt32 { map[id] = index }
        }
        return map
    }

    private func store(handles: [UInt32: SCWindow], grouped: [pid_t: [WindowInfo]]) {
        lock.lock(); defer { lock.unlock() }
        windowsByID = handles
        byPID = grouped
        lastEnumerated = Date()
    }

    private func isStale(_ minInterval: TimeInterval) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return Date().timeIntervalSince(lastEnumerated) >= minInterval
    }

    /// 某个进程的全部窗口（含最小化 / 其它桌面），前台→后台排序
    func windows(of pid: pid_t) -> [WindowInfo] {
        lock.lock(); defer { lock.unlock() }
        return byPID[pid] ?? []
    }

    func window(id: UInt32) -> WindowInfo? {
        lock.lock(); defer { lock.unlock() }
        for (_, list) in byPID {
            if let hit = list.first(where: { $0.id == id }) { return hit }
        }
        return nil
    }

    /// 预热候选：把缓冲池先填上，悬停时就不用等抓图
    func warmupTargets(perApp: Int = 6, total: Int = 48) -> [UInt32] {
        lock.lock(); defer { lock.unlock() }
        var ids: [UInt32] = []
        // 在屏窗口优先（它们最可能被悬停到）
        let ordered = byPID.sorted { a, b in
            (a.value.contains(where: \.isOnScreen) ? 0 : 1) < (b.value.contains(where: \.isOnScreen) ? 0 : 1)
        }
        for (_, wins) in ordered {
            for win in wins.prefix(perApp) where ids.count < total {
                guard win.id < Self.syntheticBase else { continue }
                ids.append(win.id)
            }
            if ids.count >= total { break }
        }
        return ids
    }

    // MARK: - 抓图

    /// 取缓存。`maxAge` 秒内的算新鲜；传 0 表示不检查时效
    func cached(_ windowID: UInt32, maxAge: TimeInterval) -> CGImage? {
        guard let entry = cache.object(forKey: NSNumber(value: windowID)) else { return nil }
        if maxAge > 0, Date().timeIntervalSince(entry.at) > maxAge { return nil }
        return entry.image
    }

    /// 按窗口自身宽高比缩放到 `maxSize` 内抓图。抓不到（无权限 / 特殊窗口）返回 nil。
    func capture(_ windowID: UInt32, maxSize: CGSize) async -> SendableImage? {
        guard let win = handle(windowID) else { return nil }
        guard Self.hasPermission else { return nil }

        let f = win.frame
        guard f.width > 1, f.height > 1 else { return nil }
        let scale = min(maxSize.width / f.width, maxSize.height / f.height, 1.0)
        let config = SCStreamConfiguration()
        config.width = max(1, Int((f.width * scale).rounded()))
        config.height = max(1, Int((f.height * scale).rounded()))
        config.showsCursor = false
        config.ignoreShadowsSingleWindow = true
        config.scalesToFit = true

        let filter = SCContentFilter(desktopIndependentWindow: win)
        guard let image = try? await SCScreenshotManager.captureImage(
            contentFilter: filter, configuration: config
        ) else { return nil }

        cache.setObject(CacheEntry(image),
                        forKey: NSNumber(value: windowID),
                        cost: image.bytesPerRow * image.height)
        return SendableImage(value: image)
    }

    /// 后台预热：并发抓取，单个失败不影响其它。
    func prewarm(_ windowIDs: [UInt32], maxSize: CGSize, maxConcurrency: Int = 6) {
        let todo = windowIDs.filter { cached($0, maxAge: 3.0) == nil }
        guard !todo.isEmpty, Self.hasPermission else { return }
        Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            await withTaskGroup(of: Void.self) { group in
                var running = 0
                for id in todo {
                    if running >= maxConcurrency {
                        await group.next()
                        running -= 1
                    }
                    group.addTask { _ = await self.capture(id, maxSize: maxSize) }
                    running += 1
                }
                await group.waitForAll()
            }
        }
    }

    /// 同步取窗口句柄。锁只在同步函数里取 —— NSLock 在 async 上下文里不可用
    private func handle(_ windowID: UInt32) -> SCWindow? {
        lock.lock(); defer { lock.unlock() }
        return windowsByID[windowID]
    }

    // MARK: - 辅助功能

    struct AXWindow: Sendable {
        /// 在**原始** AX 窗口数组里的下标。过滤后下标会错位，但 focusWindow 是按下标
        /// 直接定位元素的，所以必须留原始值。
        let index: Int
        let title: String
        let frame: CGRect
        let minimized: Bool
        /// 用户认知里的"窗口"（排除 AX 窗口数组里混进来的非窗口元素）
        let real: Bool
    }

    /// 查询一批 App 的 AX 窗口。**并发**发问，避免 N 个 App 的超时串行叠加。
    ///
    /// 失败要重试一次：Chromium / Electron 系的 App（微信、抖店工作台、Chrome …）
    /// 第一次被 AX 查询时要现场构建整棵无障碍树，很容易超过超时时间返回
    /// `kAXErrorCannotComplete`。旧代码把这种失败和"这个 App 没有窗口"一视同仁，
    /// 于是掉进启发式分支，把窗口服务器里的幽灵表面当成窗口——这正是
    /// 「抖店工作台 2 个真窗口显示成 4 个、微信 1 个显示成 2 个」的来源。
    ///
    /// **回空也要重试**：Electron 系被问到回「success + 空数组」时错误码是 0，
    /// 和"真的没有窗口"在返回值上分不开，只能再问一次。
    private static func axWindowsByPID(_ pids: [pid_t]) async -> [pid_t: [AXWindow]] {
        guard AXIsProcessTrusted() else { return [:] }

        var out: [pid_t: [AXWindow]] = [:]
        var retry: [pid_t] = []

        await withTaskGroup(of: (pid_t, [AXWindow]?).self) { group in
            for pid in pids { group.addTask { (pid, await queryAX(pid)) } }
            for await (pid, list) in group {
                if let list, !list.isEmpty { out[pid] = list } else { retry.append(pid) }
            }
        }

        guard !retry.isEmpty else { return out }
        try? await Task.sleep(nanoseconds: 200_000_000)   // 给对端把树建完的时间
        await withTaskGroup(of: (pid_t, [AXWindow]?).self) { group in
            for pid in retry { group.addTask { (pid, await queryAX(pid)) } }
            for await (pid, list) in group {
                // 重试后仍然是「success + 空」就照实记录 —— 说明这个 App 真的没有窗口
                if let list { out[pid] = list } else { TTLog("AX miss pid=\(pid)") }
            }
        }
        return out
    }

    /// nil = 查询失败（超时 / 无响应）；`[]` = 这个 App 确实没有窗口。两者不能混为一谈。
    ///
    /// 必须走 `WindowBridge.axGate`：Electron / Chromium 系被并发询问
    /// `kAXWindowsAttribute` 会返回「success + 空数组」，而这里恰恰是并发查的。
    /// 一旦查空，`resolve` 就掉进启发式分支，幽灵窗口和「点哪个都回到第一个」全来了。
    private static func queryAX(_ pid: pid_t) async -> [AXWindow]? {
        WindowBridge.axGate(for: pid) {
            let app = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(app, 0.6)
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
                  let list = value as? [AXUIElement] else { return nil }

            return list.enumerated().map { index, win in
                let rect = axFrame(of: win) ?? .zero
                let role = stringAttr(win, kAXRoleAttribute as CFString) ?? ""
                let subrole = stringAttr(win, kAXSubroleAttribute as CFString) ?? ""
                return AXWindow(index: index,
                                title: stringAttr(win, kAXTitleAttribute as CFString) ?? "",
                                frame: rect,
                                minimized: boolAttr(win, kAXMinimizedAttribute as CFString) ?? false,
                                real: isRealWindow(role: role, subrole: subrole, size: rect.size))
            }
        }
    }

    /// `kAXWindowsAttribute` 并不保证只给窗口：实测访达会多报一条
    /// role=AXScrollArea 的桌面滚动区（1470×956）；部分 App 还会把附属表面报成
    /// role=AXWindow。按 role / subrole / 尺寸三重判定。
    private static func isRealWindow(role: String, subrole: String, size: CGSize) -> Bool {
        guard role == "AXWindow", size.width >= 120, size.height >= 90 else { return false }
        switch subrole {
        case "AXStandardWindow":
            return true
        case "", "AXDialog", "AXFloatingWindow", "AXSystemDialog":
            // 少数 App 不上报 subrole；对话框 / 浮动面板也算窗口，但要够大，
            // 免得把下载气泡、输入法候选框之类的小附属表面收进来。
            return size.width >= 260 && size.height >= 180
        default:
            return false
        }
    }

    private static func stringAttr(_ element: AXUIElement, _ attribute: CFString) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else { return nil }
        return value as? String
    }

    private static func boolAttr(_ element: AXUIElement, _ attribute: CFString) -> Bool? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else { return nil }
        return (value as? Bool) ?? (value as? NSNumber)?.boolValue
    }

    private static func axFrame(of win: AXUIElement) -> CGRect? {
        guard let origin = pointAttr(win, kAXPositionAttribute as CFString),
              let size = sizeAttr(win, kAXSizeAttribute as CFString) else { return nil }
        return CGRect(origin: origin, size: size)
    }

    private static func pointAttr(_ win: AXUIElement, _ attribute: CFString) -> CGPoint? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(win, attribute, &value) == .success,
              let v = value, CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        guard AXValueGetValue(v as! AXValue, .cgPoint, &point) else { return nil }
        return point
    }

    private static func sizeAttr(_ win: AXUIElement, _ attribute: CFString) -> CGSize? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(win, attribute, &value) == .success,
              let v = value, CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        var size = CGSize.zero
        guard AXValueGetValue(v as! AXValue, .cgSize, &size) else { return nil }
        return size
    }
}
