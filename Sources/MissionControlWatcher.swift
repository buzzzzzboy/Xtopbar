import AppKit
import ApplicationServices

/// 调度中心（Mission Control）开没开。
///
/// 系统没有公开的 API，但 Dock 进程的无障碍对象会发几条私有通知：
/// `AXExposeShowAllWindows`（调度中心）、`AXExposeShowFrontWindows`（App Exposé）、
/// `AXExposeShowDesktop`（显示桌面）、`AXExposeExit`（退出）。yabai 等窗口管理器都靠它。
/// 需要辅助功能权限；没权限时什么都收不到，条的行为和以前一样。
///
/// Dock 会重启（「隐藏系统 Dock」开关就会重启它一次），重启后 pid 变了，
/// 旧的观察者全部作废 —— 所以盯着 Dock 的启动通知重新挂，再用低频轮询兜底。
@MainActor
final class MissionControlWatcher {

    /// 进入 / 退出调度中心（含 App Exposé）
    var onChange: ((Bool) -> Void)?
    private(set) var isActive = false

    private static let dockBundleID = "com.apple.dock"
    /// 这几条算「进入」；显示桌面不算 —— 那时窗口被推开了，条正好用得上
    private static let showNotifications = ["AXExposeShowAllWindows", "AXExposeShowFrontWindows"]
    private static let otherNotifications = ["AXExposeShowDesktop", "AXExposeExit"]

    private var observer: AXObserver?
    private var dockElement: AXUIElement?
    private var dockPID: pid_t = 0
    private var retryTimer: Timer?
    private var workspaceTokens: [NSObjectProtocol] = []
    /// 退出通知万一丢了，条会一直藏着：调度中心里点窗口 / 切 App 必然会退出它，
    /// 所以看到前台 App 变化后稍等一下还没收到退出，就当已经退出
    private var staleCheck: DispatchWorkItem?

    func start() {
        attach()
        let nc = NSWorkspace.shared.notificationCenter
        workspaceTokens.append(nc.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            let bundleID = app?.bundleIdentifier
            MainActor.assumeIsolated {
                guard bundleID == MissionControlWatcher.dockBundleID else { return }
                // Dock 刚起来时无障碍树还没建好，晚一点再挂
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { self?.attach() }
            }
        })
        workspaceTokens.append(nc.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleStaleCheck() }
        })

        // 兜底：权限是后来才给的、Dock 换了 pid 没收到启动通知……5 秒看一眼
        let timer = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.attach() }
        }
        RunLoop.main.add(timer, forMode: .common)
        retryTimer = timer
    }

    /// 挂到当前的 Dock 进程上（已经挂在同一个 pid 上就什么都不做）
    private func attach() {
        guard WindowBridge.isTrusted,
              let dock = NSRunningApplication.runningApplications(
                withBundleIdentifier: Self.dockBundleID).first(where: { !$0.isTerminated })
        else { return }
        let pid = dock.processIdentifier
        guard observer == nil || pid != dockPID else { return }
        detach()

        var created: AXObserver?
        guard AXObserverCreate(pid, missionControlCallback, &created) == .success,
              let obs = created else {
            TTLog("MissionControl: AXObserverCreate 失败 pid=\(pid)")
            return
        }
        let element = AXUIElementCreateApplication(pid)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        var added: [String] = []
        for name in Self.showNotifications + Self.otherNotifications {
            if AXObserverAddNotification(obs, element, name as CFString, refcon) == .success {
                added.append(name)
            }
        }
        guard !added.isEmpty else {
            TTLog("MissionControl: Dock 不接受通知（多半还没起来），稍后重试")
            return
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .commonModes)
        observer = obs
        dockElement = element
        dockPID = pid
        TTLog("MissionControl: 已挂到 Dock pid=\(pid) 通知=\(added)")
    }

    private func detach() {
        if let obs = observer {
            if let element = dockElement {
                for name in Self.showNotifications + Self.otherNotifications {
                    AXObserverRemoveNotification(obs, element, name as CFString)
                }
            }
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .commonModes)
        }
        observer = nil
        dockElement = nil
        dockPID = 0
    }

    fileprivate func handle(_ notification: String) {
        TTLog("MissionControl: \(notification)")
        setActive(Self.showNotifications.contains(notification))
    }

    private func scheduleStaleCheck() {
        guard isActive else { return }
        staleCheck?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.isActive else { return }
            TTLog("MissionControl: 前台已切换但没等到退出通知，按已退出处理")
            self.setActive(false)
        }
        staleCheck = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: work)
    }

    private func setActive(_ active: Bool) {
        staleCheck?.cancel()
        guard active != isActive else { return }
        isActive = active
        onChange?(active)
    }
}

/// AXObserver 的 C 回调：不能捕获上下文，靠 refcon 找回 watcher。
/// 观察者挂在主线程 runloop 上，所以回调就在主线程。
private func missionControlCallback(_ observer: AXObserver, _ element: AXUIElement,
                                    _ notification: CFString, _ refcon: UnsafeMutableRawPointer?) {
    guard let refcon else { return }
    let watcher = Unmanaged<MissionControlWatcher>.fromOpaque(refcon).takeUnretainedValue()
    let name = notification as String
    MainActor.assumeIsolated { watcher.handle(name) }
}
