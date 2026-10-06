import AppKit
import Combine

extension NSScreen {
    /// 显示器编号（CGDirectDisplayID）。插拔 / 改排列后 `screens` 的下标会变，编号不变，
    /// 所以"这条停在哪块屏""这个 App 的窗口在哪块屏"都按它记。
    var displayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }
}

/// 窗口算哪块屏的：纯几何，不碰 NSScreen，`--test-pins` 会打一组样例。
enum ScreenAssign {
    /// 和哪块屏重叠面积最大就算哪块；一块都不沾（被拖到屏外 / 尺寸为 0）返回 nil。
    /// 坐标随便哪套都行，只要 frame 和 screens 是同一套。
    static func index(of frame: CGRect, in screens: [CGRect]) -> Int? {
        var best: Int?
        var bestArea: CGFloat = 0
        for (i, screen) in screens.enumerated() {
            let overlap = frame.intersection(screen)
            guard !overlap.isNull else { continue }
            let area = overlap.width * overlap.height
            if area > bestArea {
                bestArea = area
                best = i
            }
        }
        return best
    }
}

/// 一块屏在全局坐标（CG / AX，原点主屏左上）里的范围，连同其它屏一起带着 ——
/// 判定"这扇窗口在不在这块屏上"得和所有屏比，跨在两块屏中间的窗口只算重叠多的那块。
/// 值类型，能直接带进后台的 AX 调用里。
struct ScreenRegion: Sendable, Equatable {
    /// 全部屏（CG 坐标），顺序同 `NSScreen.screens`，第 0 块是带菜单栏的主显示器
    let screens: [CGRect]
    /// 本屏在 `screens` 里的下标
    let index: Int

    /// 一块都不沾的窗口算主显示器（第 0 块）的，和 `ScreenScope` 的兜底一致
    func contains(_ frame: CGRect) -> Bool {
        (ScreenAssign.index(of: frame, in: screens) ?? 0) == index
    }

    @MainActor static func of(displayID: CGDirectDisplayID) -> ScreenRegion? {
        let all = NSScreen.screens
        guard let i = all.firstIndex(where: { $0.displayID == displayID }) else { return nil }
        return ScreenRegion(screens: all.map { AvoidGeometry.cgRect($0.frame) }, index: i)
    }
}

/// 多屏「各屏一条」时，一条只管一块屏：运行中的 App 只上它窗口所在的那（几）块屏的条。
/// 固定项不受影响，每条都有（同 Windows「只在視窗所在的工作列顯示按鈕」）。
struct ScreenScope: Equatable {
    let displayID: CGDirectDisplayID
    /// 主显示器那条：不知道窗口在哪的 App 放这里
    let isPrimary: Bool

    /// - screens: 这个 App 的窗口落在哪几块屏（`WindowPresence.screensByPID`），nil = 还没查到
    /// - live: 眼下接着的屏
    ///
    /// 不知道在哪（还没查到 / 没有窗口 / 所在屏刚拔掉）就放主显示器那条，
    /// 免得 App 在哪条上都找不到。
    func admits(_ screens: Set<CGDirectDisplayID>?, live: Set<CGDirectDisplayID>) -> Bool {
        let known = (screens ?? []).intersection(live)
        return known.isEmpty ? isPrimary : known.contains(displayID)
    }

    /// 这条上该给 App 名字后面带的窗口标题：只有它在不止一块（接着的）屏上有窗口、
    /// 出现在好几条上时才带，取这块屏上最前面那扇窗口的标题；只在一条上就不带，保持原名
    func windowTitle(_ screens: Set<CGDirectDisplayID>?, live: Set<CGDirectDisplayID>,
                     titles: [CGDirectDisplayID: String]?) -> String? {
        guard (screens ?? []).intersection(live).count > 1 else { return nil }
        return titles?[displayID]
    }
}

/// 管所有条：单条模式就一条；「在所有螢幕上顯示」开着并接了多块屏时每块屏一条。
///
/// 每条是一个完整的 `TabBarController` + 自己的 `AppCatalog`（自己的面板、预览、开始菜单、
/// 自动隐藏 / 不挡窗口 / 全屏让位），只有全局只能有一份的东西收在这里：
/// - **主条**（`primary`）永远在：单条模式下就是原来那一条；多屏时停在主显示器上。
///   ⌘Tab 钩子只装在它身上（系统里只能有一个拦截者），⌘Tab 会话期间它临时放开屏幕过滤、列出全部 App
/// - **调度中心观察者**只开一个，进出时通知每一条
/// - 状态栏菜单的动作在这里分发：开始菜单开在鼠标所在屏的那条上
@MainActor
final class TabBarFleet {

    private let prefs = Preferences.shared
    private let missionControl: MissionControlWatcher

    /// 主条（单条模式下就是唯一那条）
    let primary: TabBarController
    private let primaryCatalog: AppCatalog

    /// 多屏时其余各屏的条（显示器编号 → 条）
    private var secondaries: [CGDirectDisplayID: (controller: TabBarController, catalog: AppCatalog)] = [:]
    private var cancellables = Set<AnyCancellable>()

    var controllers: [TabBarController] { [primary] + secondaries.values.map { $0.controller } }

    init(catalog: AppCatalog) {
        let watcher = MissionControlWatcher()
        missionControl = watcher
        primaryCatalog = catalog
        primary = TabBarController(catalog: catalog, missionControl: watcher,
                                   display: nil, ownsCmdTab: true)
    }

    func start() {
        missionControl.onChange = { [weak self] active in
            self?.controllers.forEach { $0.missionControlChanged(active) }
        }
        missionControl.start()
        // 先摆好主条该停哪块屏，start 里第一次落位才不会先在别的屏闪一下
        layoutBars()
        primary.start()

        prefs.$allScreens
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.layoutBars() }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.layoutBars() }
            .store(in: &cancellables)
    }

    /// 按开关和眼下接了几块屏，增删各屏的条（启动、插拔屏幕、改开关时调）
    private func layoutBars() {
        let screens = NSScreen.screens
        let multi = prefs.allScreens && screens.count > 1
        let primaryID = multi ? screens.first?.displayID : nil

        primary.assign(display: primaryID)
        primaryCatalog.screenScope = primaryID.map { ScreenScope(displayID: $0, isPrimary: true) }

        let wanted = multi ? screens.dropFirst().compactMap(\.displayID) : []
        for (id, bar) in secondaries where !wanted.contains(id) {
            bar.controller.shutdown()
            secondaries[id] = nil
        }
        for id in wanted where secondaries[id] == nil {
            let catalog = AppCatalog()
            catalog.screenScope = ScreenScope(displayID: id, isPrimary: false)
            catalog.start()
            let controller = TabBarController(catalog: catalog, missionControl: missionControl,
                                              display: id, ownsCmdTab: false)
            controller.start()
            secondaries[id] = (controller, catalog)
        }
        // 屏幕变了，各 App 的窗口落在哪块屏得重新量
        if multi { primaryCatalog.scanWindows() }
        TTLog("TabBarFleet 多螢幕=\(multi) 主條=\(primaryID.map { "\($0)" } ?? "-") "
              + "其它螢幕=\(secondaries.keys.sorted())")
    }

    // MARK: - 状态栏菜单的动作

    func applyBarEnabled() {
        controllers.forEach { $0.applyBarEnabled() }
    }

    /// 开在鼠标所在屏的那条上（找不到就主条）；别的条上开着的先收掉
    func toggleStartMenu() {
        let mouse = NSEvent.mouseLocation
        let target = secondaries.first { bar in
            NSScreen.screens.first { $0.displayID == bar.key }?.frame.contains(mouse) ?? false
        }?.value.controller ?? primary
        for controller in controllers where controller !== target { controller.closeStartMenu() }
        target.toggleStartMenu()
    }

    func dismissPreview() {
        controllers.forEach { $0.dismissPreview() }
    }

    func refreshCatalog() {
        controllers.forEach { $0.refreshCatalog() }
    }

    func requestScreenCapturePermission() {
        primary.requestScreenCapturePermission()
    }

    func requestAccessibilityPermission() {
        primary.requestAccessibilityPermission()
    }
}
