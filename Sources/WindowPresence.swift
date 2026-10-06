import AppKit
import ApplicationServices
import Combine

/// 哪些运行中的 App 眼下**一个窗口都没有**（「只显示有窗口的 App」用）。
///
/// 判定：
/// - **AX 定集合**（`kAXWindowsAttribute`，同预览那套 `isRealWindow` 过滤）：最小化的窗口也算，
///   只剩最小化窗口的 App 仍然留在条上，点一下能把窗口还原
/// - **窗口服务器兜底**：AX 回空、但 CG 里这个 pid 在屏上有一块够大的 layer-0 表面 → 算有窗口。
///   Electron 系偶尔会对 AX 回「success + 空数组」（见 ScreenCaptureEngine.queryAX 的注释），
///   不兜这一下会把正开着窗口的微信 / QQ 从条上藏掉
/// - **问不出来（超时 / 失败）= 未知 = 维持原判**，绝不因为 AX 卡了一下就把 App 藏掉
/// - **连续两次都是"没窗口"才藏**：新启动的 App 窗口还没建好、或 AX 树刚在构建，
///   一次空不说明问题；也避免关窗 / 开窗瞬间标签闪一下
///
/// 没有辅助功能权限时不做过滤（拿不到最小化窗口，宁可多显示）。
///
/// 顺带记下每个 App 的窗口落在哪几块屏（`screensByPID`），多屏「各屏一条」按它分 App。
/// 同一轮 AX 查询里就有窗口 frame，不多问一次。
///
/// AX 是同步阻塞 API，整轮查询丢进 `Task.detached`，按 pid 走 `WindowBridge.axGate` 串行，
/// 不同 App 之间并发。
@MainActor
final class WindowPresence: ObservableObject {

    static let shared = WindowPresence()

    /// 判定为"没有窗口"的 pid
    /// 开始菜单的「背景執行」区直接观察它
    @Published private(set) var windowless: Set<pid_t> = []

    /// 各 App 的窗口（含最小化的）落在哪几块屏（显示器编号）。没有窗口的不在表里；
    /// 跨两块屏的窗口只算重叠多的那块，一块都不沾的算主显示器
    @Published private(set) var screensByPID: [pid_t: Set<CGDirectDisplayID>] = [:]

    /// 各 App 在每块屏上最前面那扇窗口的标题（Chrome 就是当前分页）。
    /// 同一个 App 出现在好几条上时，条上的名字后面带上它，分得清哪条是哪扇窗口
    @Published private(set) var frontTitles: [pid_t: [CGDirectDisplayID: String]] = [:]

    /// 各 App 在每块屏上开着几扇窗口（含最小化的）。条上图标角落的数字圆圈按它画
    @Published private(set) var windowCounts: [pid_t: [CGDirectDisplayID: Int]] = [:]

    /// 上面几张表有变化（主线程同步发出）。每块屏的条各有一个 AppCatalog，都要据此重采
    let changed = PassthroughSubject<Void, Never>()

    private var emptyStreak: [pid_t: Int] = [:]
    private var inFlight = false

    /// 连续几次"没窗口"才藏
    private static let hideAfter = 2

    private init() {}

    func scan(pids: [pid_t]) {
        guard AXIsProcessTrusted() else {
            // 权限被撤销：不再过滤，已经藏起来的全部放回来
            if !windowless.isEmpty || !screensByPID.isEmpty || !frontTitles.isEmpty || !windowCounts.isEmpty {
                windowless = []
                screensByPID = [:]
                frontTitles = [:]
                windowCounts = [:]
                emptyStreak = [:]
                changed.send()
            }
            return
        }
        guard !inFlight, !pids.isEmpty else { return }
        inFlight = true
        Task.detached(priority: .utility) {
            let results = await WindowPresence.query(pids)
            await MainActor.run { WindowPresence.shared.apply(results, scanned: pids) }
        }
    }

    private func apply(_ results: [(pid: pid_t, windows: [WindowSample]?)], scanned: [pid_t]) {
        inFlight = false
        let screens = NSScreen.screens
        let screenRects = screens.map { AvoidGeometry.cgRect($0.frame) }
        let screenIDs = screens.map(\.displayID)
        var next = windowless
        var nextScreens = screensByPID
        var nextTitles = frontTitles
        var nextCounts = windowCounts
        for r in results {
            guard let windows = r.windows else { continue }   // 问不出来：维持原判
            let count = windows.count
            if count == 0 || screens.isEmpty {
                nextScreens[r.pid] = nil
                nextTitles[r.pid] = nil
                nextCounts[r.pid] = nil
            } else {
                let placed = windows.compactMap { w in
                    screenIDs[ScreenAssign.index(of: w.frame, in: screenRects) ?? 0].map { (id: $0, window: w) }
                }
                nextScreens[r.pid] = Set(placed.map { $0.id })
                let titles = WindowSample.frontTitles(placed)
                nextTitles[r.pid] = titles.isEmpty ? nil : titles
                nextCounts[r.pid] = placed.reduce(into: [CGDirectDisplayID: Int]()) { counts, p in counts[p.id, default: 0] += 1 }
            }
            if count > 0 {
                emptyStreak[r.pid] = 0
                next.remove(r.pid)
            } else {
                let streak = (emptyStreak[r.pid] ?? 0) + 1
                emptyStreak[r.pid] = streak
                if streak >= Self.hideAfter { next.insert(r.pid) }
            }
        }
        // 已退出的 pid 不留账
        let alive = Set(scanned)
        next = next.filter { alive.contains($0) }
        nextScreens = nextScreens.filter { alive.contains($0.key) }
        nextTitles = nextTitles.filter { alive.contains($0.key) }
        nextCounts = nextCounts.filter { alive.contains($0.key) }
        emptyStreak = emptyStreak.filter { alive.contains($0.key) }

        guard next != windowless || nextScreens != screensByPID || nextTitles != frontTitles
                || nextCounts != windowCounts else { return }
        if next != windowless {
            TTLog("WindowPresence 無視窗 App：\(next.compactMap { NSRunningApplication(processIdentifier: $0)?.localizedName })")
        }
        windowless = next
        screensByPID = nextScreens
        frontTitles = nextTitles
        windowCounts = nextCounts
        changed.send()
    }

    // MARK: - 查询（后台）

    /// 每个 pid 的真窗口（AX 顺序 = 前后次序）。nil = 问不出来；空 = 确实没有窗口
    nonisolated static func query(_ pids: [pid_t]) async -> [(pid: pid_t, windows: [WindowSample]?)] {
        let onScreen = onScreenWindowFrames()
        return await withTaskGroup(of: (pid: pid_t, windows: [WindowSample]?).self) { group in
            for pid in pids {
                group.addTask {
                    let windows = axWindows(pid)
                    // AX 回空但屏上明明有它的窗口：信窗口服务器（拿不到标题）
                    if windows?.isEmpty == true, let cg = onScreen[pid], !cg.isEmpty {
                        return (pid, cg.map { WindowSample(frame: $0, title: "", minimized: false) })
                    }
                    return (pid, windows)
                }
            }
            var out: [(pid: pid_t, windows: [WindowSample]?)] = []
            for await r in group { out.append(r) }
            return out
        }
    }

    /// nil = 问不出来；空 = 确实没有（含最小化在内的）真窗口
    nonisolated static func axWindows(_ pid: pid_t) -> [WindowSample]? {
        WindowBridge.axGate(for: pid) {
            let app = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(app, 0.3)
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
                  let list = value as? [AXUIElement] else { return nil }
            var windows: [WindowSample] = []
            for win in list {
                let role = ScreenCaptureEngine.stringAttr(win, kAXRoleAttribute as CFString) ?? ""
                let subrole = ScreenCaptureEngine.stringAttr(win, kAXSubroleAttribute as CFString) ?? ""
                guard let frame = ScreenCaptureEngine.axFrame(of: win),
                      ScreenCaptureEngine.isRealWindow(role: role, subrole: subrole, size: frame.size)
                else { continue }
                var minimized: CFTypeRef?
                AXUIElementCopyAttributeValue(win, kAXMinimizedAttribute as CFString, &minimized)
                windows.append(WindowSample(
                    frame: frame,
                    title: ScreenCaptureEngine.stringAttr(win, kAXTitleAttribute as CFString) ?? "",
                    minimized: (minimized as? NSNumber)?.boolValue ?? false))
            }
            return windows
        }
    }

    /// 屏上够大、看得见的 layer-0 表面，按 pid 归（CG 坐标）
    nonisolated static func onScreenWindowFrames() -> [pid_t: [CGRect]] {
        let opts: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]] else {
            return [:]
        }
        var owners: [pid_t: [CGRect]] = [:]
        for w in list {
            guard (w[kCGWindowLayer as String] as? Int) == 0,
                  let pid = (w[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                  let bounds = w[kCGWindowBounds as String] as? [String: Any],
                  let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary),
                  rect.width >= 120, rect.height >= 90 else { continue }
            if let alpha = (w[kCGWindowAlpha as String] as? NSNumber)?.doubleValue, alpha <= 0.01 { continue }
            owners[pid, default: []].append(rect)
        }
        return owners
    }
}

/// 一扇真窗口的快照（后台 AX 查询 → 主线程）
struct WindowSample: Sendable, Equatable {
    /// CG 坐标
    let frame: CGRect
    let title: String
    let minimized: Bool

    /// 每块屏上最前面那扇窗口的标题：按 AX 顺序（前后次序）取第一扇开着的；
    /// 这块屏上只剩最小化的就取最小化里最前的。没标题的跳过。纯逻辑，`--test-pins` 打样例
    static func frontTitles<ID: Hashable>(_ placed: [(id: ID, window: WindowSample)]) -> [ID: String] {
        var titles: [ID: String] = [:]
        for preferOpen in [true, false] {
            for p in placed where titles[p.id] == nil && (!preferOpen || !p.window.minimized) {
                let title = p.window.title.trimmingCharacters(in: .whitespacesAndNewlines)
                if !title.isEmpty { titles[p.id] = title }
            }
        }
        return titles
    }
}
