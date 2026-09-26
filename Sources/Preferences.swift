import AppKit
import Combine

/// 悬浮条 / 预览面板的背景材质。
enum GlassStyle: String, CaseIterable, Identifiable {
    case liquid
    case frosted
    case solid

    var id: String { rawValue }

    var title: String {
        switch self {
        case .liquid:  return "液態玻璃"
        case .frosted: return "毛玻璃"
        case .solid:   return "純色"
        }
    }

    var subtitle: String {
        switch self {
        case .liquid:  return "macOS 26/27 原生材質，隨系統外觀與「降低透明度」自動調節"
        case .frosted: return "經典 HUD 毛玻璃，所有系統版本都可用"
        case .solid:   return "不透明底色，最省 GPU"
        }
    }

    var symbol: String {
        switch self {
        case .liquid:  return "drop.circle"
        case .frosted: return "square.on.square.dashed"
        case .solid:   return "square.fill"
        }
    }

    /// NSGlassEffectView 需要 macOS 26+
    static var liquidAvailable: Bool {
        if #available(macOS 26.0, *) { return true }
        return false
    }

    /// 请求的样式在本机不可用时，实际会退化成什么
    var resolved: GlassStyle {
        if self == .liquid, !GlassStyle.liquidAvailable { return .frosted }
        return self
    }
}

/// 顶部热区（鼠标顶到屏幕顶部唤出的那块区域）落在哪块屏。
///
/// 做成三选一而不是写死：多屏下"主显示器"本身就有两种意思 ——
/// 系统意义上的主显示器是**带菜单栏**的那块（`NSScreen.screens[0]`），
/// 而"刘海"只在**内置屏**上，接了外接屏并把外接屏设为主屏时两者并不是一回事。
/// 默认取带菜单栏那块：顶部唤出本来就贴在菜单栏上，而那块屏就是系统主显示器。
enum HotZoneScreen: String, CaseIterable, Identifiable {
    case menuBar      // 系统主显示器（带菜单栏，screens[0]）—— 默认
    case notch        // 有刘海的那块（内置屏）
    case followMouse  // 鼠标所在屏

    var id: String { rawValue }

    var title: String {
        switch self {
        case .menuBar:     return "系統主顯示器（帶選單列）"
        case .notch:       return "內建螢幕（劉海那塊）"
        case .followMouse: return "滑鼠所在螢幕"
        }
    }

    var subtitle: String {
        switch self {
        case .menuBar:
            return "只有帶選單列的那塊螢幕頂部能喚出。把外接螢幕設為主顯示器時，就是外接螢幕 —— 系統裡的「主顯示器」指的是這塊。"
        case .notch:
            return "只有筆電內建螢幕（有劉海那塊）頂部能喚出，內建螢幕以外都不響應。"
        case .followMouse:
            return "滑鼠在哪塊螢幕，就頂哪塊螢幕的頂部喚出 —— 和 ⌘Tab 叫出同一套座標來源。"
        }
    }
}

/// 悬浮条停靠在屏幕哪条边。
///
/// 底部 = macOS Dock 的替代品（鼠标顶到屏幕底边唤出，或常驻）；
/// 顶部 = 早先的顶部切换条（鼠标顶到菜单栏中央唤出）。
enum DockEdge: String, CaseIterable, Identifiable {
    case top      // 默认：原版顶部切换条
    case bottom   // Dock 风格

    var id: String { rawValue }

    var title: String {
        switch self {
        case .bottom: return "底部（Dock）"
        case .top:    return "頂部"
        }
    }

    var subtitle: String {
        switch self {
        case .bottom:
            return "停在螢幕底部，滑鼠頂到底邊喚出 —— 可以當 Dock 用。視窗預覽和開始選單向上彈出。"
        case .top:
            return "停在選單列下方，滑鼠頂到螢幕頂部中央喚出。視窗預覽和開始選單向下彈出。"
        }
    }
}

/// 开始菜单「所有应用」的排序
enum StartMenuSort: String, CaseIterable, Identifiable {
    case name       // 按名称 A–Z（中文按拼音首字母）
    case added      // 最近加入（第一次装上的时间，新的在前）
    case updated    // 最近更新（最近一次安装 / 更新的时间，新的在前）

    var id: String { rawValue }

    var title: String {
        switch self {
        case .name:    return "名稱"
        case .added:   return "最近加入"
        case .updated: return "最近更新"
        }
    }
}

/// 一个被固定的 App（任务栏 / 开始菜单各一份列表）。
///
/// 存路径是为了 App 没在运行时也能画图标、能启动；
/// 存名字是为了 App 被删掉之后设置里还能认出它是谁。
struct PinnedApp: Codable, Equatable, Identifiable {
    let bundleID: String
    let path: String
    let name: String

    var id: String { bundleID }
    var url: URL { URL(fileURLWithPath: path) }
}

/// 开始菜单里的一个文件夹：自己起名、自己往里放 App，和「已固定」各管各的
struct StartFolder: Codable, Equatable, Identifiable {
    var id = UUID()
    var name: String
    var apps: [PinnedApp] = []
}

/// 全局偏好：集中管理 UserDefaults 读写，视图与控制器都订阅它。
///
/// 旧实现把 UserDefaults key 散落在 TabBarController 的 getter/setter 里，
/// 而且 `v > 0 ? v : 1.5` 把「不自动隐藏」（0）也读成了 1.5 —— 常驻模式
/// 实际上永远无法生效。这里统一用 `object(forKey:) != nil` 判断是否写过。
@MainActor
final class Preferences: ObservableObject {

    static let shared = Preferences()

    private enum Key {
        static let hideDelay     = "hideDelay"
        static let previewEnabled = "previewEnabled"
        static let hideMinimized = "hideMinimizedWindows"
        static let glassStyle    = "glassStyle"
        static let idleOpacity   = "idleOpacity"
        static let showStatusItem = "showStatusItem"
        static let barEnabled     = "barEnabled"
        static let animations    = "animationsEnabled"
        static let hotZoneWidth  = "hotZoneWidth"
        static let hotZoneScreen = "hotZoneScreen"
        static let cmdTabEnabled = "cmdTabEnabled"
        static let hiddenApps    = "hiddenApps"
        static let uiScale       = "uiScale"
        static let autoCheckUpdates = "autoCheckUpdates"
        static let ignoredVersion   = "ignoredVersion"
        static let dockEdge      = "dockEdge"
        static let dockPins      = "dockPins"
        static let startPins     = "startPins"
        static let startFolders  = "startFolders"
        static let recentApps    = "recentApps"
        static let iconOnly      = "iconOnly"
        static let onlyWindowedApps = "onlyWindowedApps"
        static let showStartButton = "showStartButton"
        static let hideSystemDock = "hideSystemDock"
        static let avoidWindows  = "avoidWindows"
        static let clickToMinimize = "clickToMinimize"
        static let startMenuSort = "startMenuSort"
        static let appFirstSeen  = "appFirstSeen"
        static let savedDockAutohide = "savedSystemDockAutohide"
        static let savedDockDelay    = "savedSystemDockDelay"
    }

    private let d = UserDefaults.standard

    /// 鼠标离开后多久隐藏。0 = 常驻不隐藏。
    @Published var hideDelay: Double = 0.2 {
        didSet { d.set(hideDelay, forKey: Key.hideDelay) }
    }

    /// 悬停标签时弹出窗口缩略预览
    @Published var previewEnabled: Bool = true {
        didSet { d.set(previewEnabled, forKey: Key.previewEnabled) }
    }

    /// 预览里只列「已打开」的窗口，最小化的不列
    @Published var hideMinimizedWindows: Bool = false {
        didSet { d.set(hideMinimizedWindows, forKey: Key.hideMinimized) }
    }

    /// 背景材质
    @Published var glassStyle: GlassStyle = .liquid {
        didSet { d.set(glassStyle.rawValue, forKey: Key.glassStyle) }
    }

    /// 待机（无鼠标悬停）时的不透明度；悬停时固定拉到 1.0
    @Published var idleOpacity: Double = 0.86 {
        didSet { d.set(idleOpacity, forKey: Key.idleOpacity) }
    }

    /// 是否在系统状态栏显示图标
    @Published var showStatusItem: Bool = true {
        didSet { d.set(showStatusItem, forKey: Key.showStatusItem) }
    }

    /// 悬浮条总开关。关掉后鼠标顶到屏幕顶部也不再唤出。
    @Published var barEnabled: Bool = true {
        didSet { d.set(barEnabled, forKey: Key.barEnabled) }
    }

    /// 进出场动画。老机器或远程桌面下可以关掉。
    @Published var animationsEnabled: Bool = true {
        didSet { d.set(animationsEnabled, forKey: Key.animations) }
    }

    /// 唤醒热区宽度（pt，屏幕顶部居中）。默认 120 ≈ 4 个状态栏图标；
    /// 外接屏上嫌误触可调小，嫌难唤出可调大。
    @Published var hotZoneWidth: Double = 120 {
        didSet { d.set(hotZoneWidth, forKey: Key.hotZoneWidth) }
    }

    /// 顶部热区落在哪块屏。
    ///
    /// 默认**带菜单栏的系统主显示器**（`screens[0]`）。多屏时另一块屏顶部不再唤出，
    /// 面板也固定停在主屏顶部 —— 否则某次 ⌘Tab 在另一块屏弹出后，面板"停"在那块屏，
    /// 热区跟着跑过去，主屏顶部就再也唤不出来了。
    /// 注意"系统主显示器"与"刘海屏"在多屏下不是同一块：外接屏被设为主屏时，
    /// 刘海在内置屏上，想顶刘海呼出要显式选「内置屏」。
    @Published var hotZoneScreen: HotZoneScreen = .menuBar {
        didSet { d.set(hotZoneScreen.rawValue, forKey: Key.hotZoneScreen) }
    }

    /// ⌘Tab 呼出：接管系统应用切换器的快捷键，在鼠标位置唤出悬浮条。
    /// 靠 CGEventTap 实现，需要辅助功能权限。
    @Published var cmdTabEnabled: Bool = false {
        didSet { d.set(cmdTabEnabled, forKey: Key.cmdTabEnabled) }
    }

    /// 从悬浮条隐藏的 App（bundle id → 显示名）。只是不出现在标签里，
    /// 不退出也不动它们的窗口；在设置的「已隐藏的 App」里可释放。
    /// 存字典而不是纯 id 集合：App 一旦退出，名字就只能靠这里留档了。
    @Published var hiddenApps: [String: String] = [:] {
        didSet { d.set(hiddenApps, forKey: Key.hiddenApps) }
    }

    /// 界面整体缩放（悬浮条 + 预览面板）。0.8–1.3：
    /// 再小图标和文字糊成一团，再大预览会顶到屏幕半高，都失去意义。
    /// 缩放的是布局常量本身而不是 scaleEffect 渲染变换 ——
    /// 后者不会改变 GeometryReader 上报的命中区域，点击会错位。
    @Published var uiScale: Double = 1.0 {
        didSet {
            // 双保险钳制：滑杆之外（比如手改 defaults）也别越界
            let clamped = min(max(uiScale, 0.8), 1.3)
            if clamped != uiScale { uiScale = clamped; return }
            d.set(uiScale, forKey: Key.uiScale)
        }
    }

    /// 启动后自动去 GitHub Releases 看一眼有没有新版本（每小时最多一次）
    @Published var autoCheckUpdates: Bool = true {
        didSet { d.set(autoCheckUpdates, forKey: Key.autoCheckUpdates) }
    }

    /// 用户点过「跳过这个版本」的版本号。静默检查时不再为它弹窗，
    /// 手动点「检查更新…」仍然会提示。
    @Published var ignoredVersion: String = "" {
        didSet { d.set(ignoredVersion, forKey: Key.ignoredVersion) }
    }

    /// 悬浮条停靠边。默认顶部（原版外观）；改成底部就能当 Dock 用。
    @Published var dockEdge: DockEdge = .top {
        didSet { d.set(dockEdge.rawValue, forKey: Key.dockEdge) }
    }

    /// 固定到任务栏的 App（顺序即显示顺序）。没在运行也常驻在条上，点一下启动。
    @Published var dockPins: [PinnedApp] = [] {
        didSet { Self.save(dockPins, key: Key.dockPins, to: d) }
    }

    /// 固定到开始菜单的 App（顺序即网格顺序）。和任务栏各管各的，同 Windows。
    @Published var startPins: [PinnedApp] = [] {
        didSet { Self.save(startPins, key: Key.startPins, to: d) }
    }

    /// 开始菜单「已固定」下面的文件夹（顺序即显示顺序）
    @Published var startFolders: [StartFolder] = [] {
        didSet {
            if let data = try? JSONEncoder().encode(startFolders) { d.set(data, forKey: Key.startFolders) }
        }
    }

    /// 最近使用的 App（bundle id，最新在前，最多 8 个）：开始菜单「最近使用」
    @Published var recentApps: [String] = [] {
        didSet { d.set(recentApps, forKey: Key.recentApps) }
    }

    /// 只显示图标（Dock 风格大图标，名字放到悬停提示里）。关掉 = 图标 + 名称的标签。
    @Published var iconOnly: Bool = false {
        didSet { d.set(iconOnly, forKey: Key.iconOnly) }
    }

    /// 条最左边显示开始按钮（Windows 风格开始菜单）。默认关：保持原版外观。
    @Published var showStartButton: Bool = false {
        didSet { d.set(showStartButton, forKey: Key.showStartButton) }
    }

    /// 只显示有窗口的 App：运行中但一个窗口都没有的（关完窗口还挂着的 Safari、访达…）不上条。
    /// 最小化的窗口也算窗口；固定到任务栏的不受影响。需要辅助功能权限，没有时不过滤。
    @Published var onlyWindowedApps: Bool = true {
        didSet { d.set(onlyWindowedApps, forKey: Key.onlyWindowedApps) }
    }

    /// 隐藏系统 Dock（把系统 Dock 设成自动隐藏 + 超长延迟，关掉时还原）
    @Published var hideSystemDock: Bool = false {
        didSet { d.set(hideSystemDock, forKey: Key.hideSystemDock) }
    }

    /// 不挡窗口（Windows 任务栏同款）：条常驻，并把盖到条上的窗口挪开 / 缩短，
    /// 让出条占的那一条带状区域；有 App 全屏时条自动藏起来。需要辅助功能权限。
    /// 默认开：条当任务栏用时"盖住窗口底部"是最常见的抱怨；想要原版的藏起来 + 顶边唤出就关掉它。
    @Published var avoidWindows: Bool = true {
        didSet { d.set(avoidWindows, forKey: Key.avoidWindows) }
    }

    /// 点前台 App 的标签 = 把它的窗口全部最小化；再点一次（或点预览）恢复。同 Windows 任务栏。
    @Published var clickToMinimize: Bool = true {
        didSet { d.set(clickToMinimize, forKey: Key.clickToMinimize) }
    }

    /// 开始菜单「所有应用」的排序方式
    @Published var startMenuSort: StartMenuSort = .name {
        didSet { d.set(startMenuSort.rawValue, forKey: Key.startMenuSort) }
    }

    /// 每个 App 第一次被开始菜单索引看到的时间（bundle id → 秒），「最近加入」排序用。
    /// 不发布：只有索引扫描在读写，变了也不需要重绘任何东西。
    var appFirstSeen: [String: Double] {
        get { d.dictionary(forKey: Key.appFirstSeen) as? [String: Double] ?? [:] }
        set { d.set(newValue, forKey: Key.appFirstSeen) }
    }

    /// 开启「隐藏系统 Dock」之前系统 Dock 的原值，关掉时照原样写回。
    /// nil = 那个 key 原本就没写过（还原时删掉而不是写一个值进去）。
    var savedDockAutohide: Bool? {
        get { d.object(forKey: Key.savedDockAutohide) as? Bool }
        set { d.set(newValue, forKey: Key.savedDockAutohide) }
    }
    var savedDockDelay: Double? {
        get { d.object(forKey: Key.savedDockDelay) as? Double }
        set { d.set(newValue, forKey: Key.savedDockDelay) }
    }
    /// 原值有没有存过（区分"存过、原本就没写"和"还没存"）
    var hasSavedSystemDock: Bool {
        get { d.bool(forKey: "savedSystemDockValid") }
        set { d.set(newValue, forKey: "savedSystemDockValid") }
    }

    /// 最近使用记一笔（去重、置顶、截断）
    func noteRecent(_ bundleID: String) {
        guard !bundleID.isEmpty, recentApps.first != bundleID else { return }
        var next = recentApps
        next.removeAll { $0 == bundleID }
        next.insert(bundleID, at: 0)
        if next.count > 8 { next.removeLast(next.count - 8) }
        recentApps = next
    }

    private static func save(_ pins: [PinnedApp], key: String, to d: UserDefaults) {
        if let data = try? JSONEncoder().encode(pins) { d.set(data, forKey: key) }
    }

    private static func load(_ key: String, from d: UserDefaults) -> [PinnedApp]? {
        guard let data = d.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode([PinnedApp].self, from: data)
    }

    /// 改名前叫 TopTab（bundle id `com.zxwzz.toptab`），设置存在旧的偏好域里。
    /// 第一次以 Xtopbar 启动时把旧设置（固定项、隐藏列表、各种开关）搬过来，只搬一次，
    /// 新域里已经有的 key 不覆盖。非沙盒 App 可以直接读别的域。
    private static func migrateLegacyDefaults(_ d: UserDefaults) {
        let flag = "migratedFromTopTab"
        guard !d.bool(forKey: flag) else { return }
        d.set(true, forKey: flag)
        guard let old = d.persistentDomain(forName: "com.zxwzz.toptab") else { return }
        for (key, value) in old where d.object(forKey: key) == nil {
            d.set(value, forKey: key)
        }
    }

    private init() {
        Self.migrateLegacyDefaults(d)
        if d.object(forKey: Key.hideDelay) != nil { hideDelay = d.double(forKey: Key.hideDelay) }
        if d.object(forKey: Key.previewEnabled) != nil { previewEnabled = d.bool(forKey: Key.previewEnabled) }
        if d.object(forKey: Key.hideMinimized) != nil { hideMinimizedWindows = d.bool(forKey: Key.hideMinimized) }
        if let raw = d.string(forKey: Key.glassStyle), let s = GlassStyle(rawValue: raw) { glassStyle = s }
        if d.object(forKey: Key.idleOpacity) != nil { idleOpacity = d.double(forKey: Key.idleOpacity) }
        if d.object(forKey: Key.showStatusItem) != nil { showStatusItem = d.bool(forKey: Key.showStatusItem) }
        if d.object(forKey: Key.barEnabled) != nil { barEnabled = d.bool(forKey: Key.barEnabled) }
        if d.object(forKey: Key.animations) != nil { animationsEnabled = d.bool(forKey: Key.animations) }
        if d.object(forKey: Key.hotZoneWidth) != nil { hotZoneWidth = d.double(forKey: Key.hotZoneWidth) }
        if let raw = d.string(forKey: Key.hotZoneScreen), let s = HotZoneScreen(rawValue: raw) { hotZoneScreen = s }
        if d.object(forKey: Key.cmdTabEnabled) != nil { cmdTabEnabled = d.bool(forKey: Key.cmdTabEnabled) }
        if let map = d.dictionary(forKey: Key.hiddenApps) as? [String: String] { hiddenApps = map }
        if d.object(forKey: Key.uiScale) != nil { uiScale = min(max(d.double(forKey: Key.uiScale), 0.8), 1.3) }
        if d.object(forKey: Key.autoCheckUpdates) != nil { autoCheckUpdates = d.bool(forKey: Key.autoCheckUpdates) }
        ignoredVersion = d.string(forKey: Key.ignoredVersion) ?? ""
        if let raw = d.string(forKey: Key.dockEdge), let e = DockEdge(rawValue: raw) { dockEdge = e }
        if let pins = Self.load(Key.dockPins, from: d) { dockPins = pins }
        if let pins = Self.load(Key.startPins, from: d) { startPins = pins }
        if let data = d.data(forKey: Key.startFolders),
           let folders = try? JSONDecoder().decode([StartFolder].self, from: data) { startFolders = folders }
        if let list = d.stringArray(forKey: Key.recentApps) { recentApps = list }
        if d.object(forKey: Key.iconOnly) != nil { iconOnly = d.bool(forKey: Key.iconOnly) }
        if d.object(forKey: Key.showStartButton) != nil { showStartButton = d.bool(forKey: Key.showStartButton) }
        if d.object(forKey: Key.onlyWindowedApps) != nil { onlyWindowedApps = d.bool(forKey: Key.onlyWindowedApps) }
        if d.object(forKey: Key.hideSystemDock) != nil { hideSystemDock = d.bool(forKey: Key.hideSystemDock) }
        if d.object(forKey: Key.avoidWindows) != nil { avoidWindows = d.bool(forKey: Key.avoidWindows) }
        if d.object(forKey: Key.clickToMinimize) != nil { clickToMinimize = d.bool(forKey: Key.clickToMinimize) }
        if let raw = d.string(forKey: Key.startMenuSort), let s = StartMenuSort(rawValue: raw) { startMenuSort = s }

        // 老系统上把存下来的「液态玻璃」降级成毛玻璃，避免设置面板显示一个用不了的选项
        if !GlassStyle.liquidAvailable, glassStyle == .liquid { glassStyle = .frosted }
    }

    /// 自动隐藏延迟的可选档位（秒）；0 表示常驻
    static let delayOptions: [(label: String, value: Double)] = [
        ("0.2 秒（預設）", 0.2),
        ("0.4 秒（快）", 0.4),
        ("0.8 秒", 0.8),
        ("1.5 秒", 1.5),
        ("3 秒", 3.0),
        ("4 秒", 4.0),
        ("不自動隱藏", 0.0)
    ]
}

/// 共享布局度量：设计基准值（1.0 档）× 界面缩放。
///
/// 缩放乘在**布局常量本身**上，而不是给视图套 `scaleEffect` ——
/// scaleEffect 只是渲染变换，GeometryReader 上报的命中区域仍是未缩放坐标，
/// 窗口层拿它做点击判定会错位（预览卡片、标签都是窗口层命中）。
///
/// 视图侧无需显式传参：TabBarView / PreviewView 都 @ObservedObject prefs，
/// uiScale 变化触发 body 重算，这里读到的就是新值。
enum TTLayout {
    @MainActor static var scale: CGFloat { CGFloat(Preferences.shared.uiScale) }

    /// 缩放一个长度
    @MainActor static func s(_ v: CGFloat) -> CGFloat { v * scale }

    /// 悬浮条高度：Dock 风格（只显示图标）用大图标，标签风格保持原来的 42pt
    @MainActor static var barHeight: CGFloat { s(Preferences.shared.iconOnly ? 58 : 42) }

    /// 缩放一个字号（取半 pt 对齐，避免奇奇怪怪的亚像素位置）
    @MainActor static func font(_ v: CGFloat) -> CGFloat { (v * scale * 2).rounded() / 2 }
}
