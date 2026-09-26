import AppKit
import ApplicationServices

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
/// AX 是同步阻塞 API，整轮查询丢进 `Task.detached`，按 pid 走 `WindowBridge.axGate` 串行，
/// 不同 App 之间并发。
@MainActor
final class WindowPresence {

    static let shared = WindowPresence()

    /// 判定为"没有窗口"的 pid
    private(set) var windowless: Set<pid_t> = []

    /// 集合变化回调（AppCatalog 据此重采）
    var onChange: (@MainActor () -> Void)?

    private var emptyStreak: [pid_t: Int] = [:]
    private var inFlight = false

    /// 连续几次"没窗口"才藏
    private static let hideAfter = 2

    private init() {}

    func scan(pids: [pid_t]) {
        guard AXIsProcessTrusted() else {
            // 权限被撤销：不再过滤，已经藏起来的全部放回来
            if !windowless.isEmpty {
                windowless = []
                emptyStreak = [:]
                onChange?()
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

    private func apply(_ results: [(pid: pid_t, count: Int?)], scanned: [pid_t]) {
        inFlight = false
        var next = windowless
        for r in results {
            guard let count = r.count else { continue }   // 问不出来：维持原判
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
        emptyStreak = emptyStreak.filter { alive.contains($0.key) }

        guard next != windowless else { return }
        TTLog("WindowPresence 無視窗 App：\(next.compactMap { NSRunningApplication(processIdentifier: $0)?.localizedName })")
        windowless = next
        onChange?()
    }

    // MARK: - 查询（后台）

    nonisolated static func query(_ pids: [pid_t]) async -> [(pid: pid_t, count: Int?)] {
        let onScreen = onScreenWindowOwners()
        return await withTaskGroup(of: (pid: pid_t, count: Int?).self) { group in
            for pid in pids {
                group.addTask {
                    let n = countAXWindows(pid)
                    // AX 回空但屏上明明有它的窗口：信窗口服务器
                    if n == 0, onScreen.contains(pid) { return (pid, 1) }
                    return (pid, n)
                }
            }
            var out: [(pid: pid_t, count: Int?)] = []
            for await r in group { out.append(r) }
            return out
        }
    }

    /// nil = 问不出来；0 = 确实没有（含最小化在内的）真窗口
    nonisolated static func countAXWindows(_ pid: pid_t) -> Int? {
        WindowBridge.axGate(for: pid) {
            let app = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(app, 0.3)
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
                  let list = value as? [AXUIElement] else { return nil }
            var n = 0
            for win in list {
                let role = ScreenCaptureEngine.stringAttr(win, kAXRoleAttribute as CFString) ?? ""
                let subrole = ScreenCaptureEngine.stringAttr(win, kAXSubroleAttribute as CFString) ?? ""
                let size = ScreenCaptureEngine.axFrame(of: win)?.size ?? .zero
                if ScreenCaptureEngine.isRealWindow(role: role, subrole: subrole, size: size) { n += 1 }
            }
            return n
        }
    }

    /// 屏上有一块够大、看得见的 layer-0 表面的 pid
    nonisolated static func onScreenWindowOwners() -> Set<pid_t> {
        let opts: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]] else {
            return []
        }
        var owners = Set<pid_t>()
        for w in list {
            guard (w[kCGWindowLayer as String] as? Int) == 0,
                  let pid = (w[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                  let bounds = w[kCGWindowBounds as String] as? [String: Any],
                  let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary),
                  rect.width >= 120, rect.height >= 90 else { continue }
            if let alpha = (w[kCGWindowAlpha as String] as? NSNumber)?.doubleValue, alpha <= 0.01 { continue }
            owners.insert(pid)
        }
        return owners
    }
}
