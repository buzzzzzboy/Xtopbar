import AppKit

/// 右键菜单里列的一扇窗口
struct TaskbarMenuWindow: Equatable {
    let title: String
    /// CG 坐标
    let frame: CGRect
    let minimized: Bool
    let axIndex: Int?
    let cgID: UInt32?
}

/// 任务栏标签右键菜单的内容，排法照 macOS Dock：
/// 窗口列表 → 设定档 → 开新窗口 → 选项 ▸ → Xtopbar 自己的一组 → 显示所有窗口 / 隐藏 / 结束
@MainActor
enum TaskbarAppMenu {

    /// 窗口快照里这个 App 的窗口（前台 → 后台）。多屏各一条时只列这块屏的，
    /// 一扇都对不上（窗口刚挪过屏、快照还没跟上）就全列 —— 和悬停预览同一套规则
    static func windows(for entry: AppEntry, region: ScreenRegion?) -> [TaskbarMenuWindow] {
        guard entry.isRunning else { return [] }
        let everywhere = ScreenCaptureEngine.shared.windows(of: entry.pid)
        let here = region.map { r in everywhere.filter { r.contains($0.frame) } } ?? everywhere
        return (here.isEmpty ? everywhere : here).map {
            TaskbarMenuWindow(title: $0.title, frame: $0.frame, minimized: $0.isMinimized,
                              axIndex: $0.axIndex, cgID: $0.id)
        }
    }

    /// 没有螢幕錄製权限时快照是空的：退回直接问 AX（会阻塞，在后台跑）
    nonisolated static func axFallbackWindows(pid: pid_t, region: ScreenRegion?) -> [TaskbarMenuWindow] {
        let all = WindowPresence.axWindows(pid) ?? []
        let here = region.map { r in all.filter { r.contains($0.frame) } } ?? all
        return (here.isEmpty ? all : here).map {
            TaskbarMenuWindow(title: $0.title, frame: $0.frame, minimized: $0.minimized,
                              axIndex: nil, cgID: nil)
        }
    }

    static func items(for entry: AppEntry, windows: [TaskbarMenuWindow], catalog: AppCatalog) -> [TaskbarMenuItem] {
        var items: [TaskbarMenuItem] = []
        let pid = entry.pid

        // 窗口列表：前台 App 最前面那扇打勾、最小化的画菱形（同 Dock）
        if entry.isRunning, !windows.isEmpty {
            let front = catalog.activePID == pid
            let firstOpen = windows.firstIndex { !$0.minimized }
            for (i, window) in windows.enumerated() {
                items.append(TaskbarMenuItem(
                    title: window.title.isEmpty ? entry.name : window.title,
                    symbol: window.minimized ? "diamond" : "macwindow",
                    checked: front && i == firstOpen,
                    dimmed: window.minimized,
                    action: {
                        // AX 配对可能阻塞，挪到后台
                        Task.detached(priority: .userInitiated) {
                            WindowBridge.focusWindow(pid: pid, axIndex: window.axIndex, frame: window.frame,
                                                     title: window.title, cgID: window.cgID)
                        }
                    }))
            }
            items.append(.separator)
        }

        // Chromium 系浏览器的设定档：点一个就用它开新窗口
        let profiles = BrowserProfiles.profiles(for: entry.id)
        if !profiles.isEmpty {
            items.append(.header("設定檔"))
            for profile in profiles {
                items.append(TaskbarMenuItem(title: profile.name, symbol: "person.crop.circle") {
                    BrowserProfiles.open(profile, bundleID: entry.id, appURL: entry.bundleURL)
                })
            }
            items.append(.separator)
        }

        if entry.isRunning {
            // 菜单栏里找不到「新視窗」那一项的 App（Spotify 的 ⌘N 是新增播放清單）就不给这一项。
            // 还没查过时先放着，查完不支持再换掉（见 TabBarController.openTaskbarMenu）
            if BrowserProfiles.isBrowser(entry.id) || TaskbarAppActions.newWindowAvailable[pid] != false {
                items.append(TaskbarMenuItem(title: "開新視窗", symbol: "plus.rectangle.on.rectangle") {
                    TaskbarAppActions.newWindow(entry)
                })
            }
            if let privateWindow = BrowserProfiles.privateWindow(for: entry.id) {
                items.append(TaskbarMenuItem(title: privateWindow.title, symbol: "eyeglasses") {
                    BrowserProfiles.openWindow(bundleID: entry.id, appURL: entry.bundleURL,
                                               arguments: [privateWindow.flag])
                })
            }
        } else {
            items.append(TaskbarMenuItem(title: "開啟", symbol: "arrow.up.forward.app") {
                catalog.activate(entry)
            })
        }
        items.append(.separator)

        var options: [TaskbarMenuItem] = []
        if let url = entry.bundleURL {
            options.append(TaskbarMenuItem(title: "顯示於 Finder", symbol: "folder") {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            })
        }
        if !options.isEmpty {
            items.append(TaskbarMenuItem(title: "選項", symbol: "gearshape", children: options))
            items.append(.separator)
        }

        // Xtopbar 自己的功能：放第一层，点一下就能用
        items.append(TaskbarMenuItem(title: "保留在工作列", symbol: "pin", checked: entry.isPinned) {
            if entry.isPinned { catalog.unpinFromDock(entry.id) } else { catalog.pinToDock(entry) }
        })
        if Preferences.shared.showStartButton {
            if catalog.isStartPinned(entry.id) {
                items.append(TaskbarMenuItem(title: "從開始選單取消固定", symbol: "star.slash") {
                    catalog.unpinFromStart(entry.id)
                })
            } else {
                items.append(TaskbarMenuItem(title: "固定到開始選單", symbol: "star") {
                    catalog.pinToStart(entry)
                })
            }
        }
        if entry.isRunning, !entry.isPinned {
            items.append(TaskbarMenuItem(title: "從工作列隱藏此 App", symbol: "eye.slash") {
                catalog.hide(entry)
            })
        }
        items.append(.separator)

        if entry.isRunning {
            items.append(TaskbarMenuItem(title: "顯示所有視窗", symbol: "square.grid.2x2") {
                TaskbarAppActions.showAllWindows(pid)
            })
            let hidden = NSRunningApplication(processIdentifier: pid)?.isHidden ?? false
            items.append(TaskbarMenuItem(title: hidden ? "取消隱藏" : "隱藏",
                                         symbol: hidden ? "eye" : "minus.circle") {
                guard let app = NSRunningApplication(processIdentifier: pid) else { return }
                if app.isHidden { app.unhide() } else { app.hide() }
            })
            items.append(TaskbarMenuItem(
                title: "結束", symbol: "xmark",
                action: { catalog.terminate(entry) },
                optionTitle: "強制結束", optionSymbol: "xmark.octagon",
                optionAction: { NSRunningApplication(processIdentifier: pid)?.forceTerminate() }))
        }
        return items
    }
}

extension TaskbarMenuItem {
    /// 普通的一项：标题 + 图标 + 动作
    init(title: String, symbol: String? = nil, checked: Bool = false, action: @escaping () -> Void) {
        self.init(kind: .item, title: title, symbol: symbol, checked: checked, action: action)
    }
}

/// 菜单里那些需要绕一下的动作
enum TaskbarAppActions {

    /// pid → 菜单栏里有没有「新視窗」那一项。右键菜单据此决定给不给「開新視窗」
    @MainActor static var newWindowAvailable: [pid_t: Bool] = [:]

    /// 查一次（AX 会阻塞，在后台跑），结果记进 `newWindowAvailable`。已经查过就直接回缓存
    @MainActor
    @discardableResult
    static func probeNewWindow(pid: pid_t) async -> Bool {
        if let known = newWindowAvailable[pid] { return known }
        let found = await Task.detached(priority: .userInitiated) {
            WindowBridge.newWindowMenuItem(pid: pid, press: false)
        }.value
        newWindowAvailable[pid] = found
        return found
    }

    /// 开新窗口：Chromium 系直接带 `--new-window` 参数；其它 App 按菜单栏里「新視窗」那一项。
    /// 不盲送 ⌘N：不少 App 的 ⌘N 不是开窗口（Spotify 是新增播放清單）
    @MainActor
    static func newWindow(_ entry: AppEntry) {
        if BrowserProfiles.isBrowser(entry.id) {
            BrowserProfiles.openWindow(bundleID: entry.id, appURL: entry.bundleURL, arguments: ["--new-window"])
            return
        }
        let pid = entry.pid
        WindowBridge.activateApp(pid)
        Task.detached(priority: .userInitiated) {
            WindowBridge.newWindowMenuItem(pid: pid, press: true)
        }
    }

    /// 显示所有窗口 = 这个 App 的 App Exposé（同 Dock）：先把它叫到前台，再让 Dock 对前台 App 开 Exposé。
    /// 直接跑「指揮中心」可执行文件（参数 2）在新系统上会被系统杀掉，
    /// 所以走 Dock 自己的通知 `com.apple.expose.front.awake`（私有的 CoreDockSendNotification）
    @MainActor
    static func showAllWindows(_ pid: pid_t) {
        WindowBridge.activateApp(pid)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            guard let send = coreDockSendNotification else {
                TTLog("app exposé: CoreDockSendNotification 不可用")
                return
            }
            send("com.apple.expose.front.awake" as CFString, 0)
        }
    }

    private typealias CoreDockSend = @convention(c) (CFString, Int32) -> Void

    private static let coreDockSendNotification: CoreDockSend? = {
        let path = "/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices"
        guard let handle = dlopen(path, RTLD_LAZY),
              let sym = dlsym(handle, "CoreDockSendNotification") else { return nil }
        return unsafeBitCast(sym, to: CoreDockSend.self)
    }()
}
