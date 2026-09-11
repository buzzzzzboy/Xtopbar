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
        case .liquid:  return "液态玻璃"
        case .frosted: return "毛玻璃"
        case .solid:   return "纯色"
        }
    }

    var subtitle: String {
        switch self {
        case .liquid:  return "macOS 26/27 原生材质，随系统外观与「降低透明度」自动调节"
        case .frosted: return "经典 HUD 毛玻璃，所有系统版本都可用"
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

    private init() {
        if d.object(forKey: Key.hideDelay) != nil { hideDelay = d.double(forKey: Key.hideDelay) }
        if d.object(forKey: Key.previewEnabled) != nil { previewEnabled = d.bool(forKey: Key.previewEnabled) }
        if d.object(forKey: Key.hideMinimized) != nil { hideMinimizedWindows = d.bool(forKey: Key.hideMinimized) }
        if let raw = d.string(forKey: Key.glassStyle), let s = GlassStyle(rawValue: raw) { glassStyle = s }
        if d.object(forKey: Key.idleOpacity) != nil { idleOpacity = d.double(forKey: Key.idleOpacity) }
        if d.object(forKey: Key.showStatusItem) != nil { showStatusItem = d.bool(forKey: Key.showStatusItem) }
        if d.object(forKey: Key.barEnabled) != nil { barEnabled = d.bool(forKey: Key.barEnabled) }
        if d.object(forKey: Key.animations) != nil { animationsEnabled = d.bool(forKey: Key.animations) }
        if d.object(forKey: Key.hotZoneWidth) != nil { hotZoneWidth = d.double(forKey: Key.hotZoneWidth) }

        // 老系统上把存下来的「液态玻璃」降级成毛玻璃，避免设置面板显示一个用不了的选项
        if !GlassStyle.liquidAvailable, glassStyle == .liquid { glassStyle = .frosted }
    }

    /// 自动隐藏延迟的可选档位（秒）；0 表示常驻
    static let delayOptions: [(label: String, value: Double)] = [
        ("0.2 秒（默认）", 0.2),
        ("0.4 秒（快）", 0.4),
        ("0.8 秒", 0.8),
        ("1.5 秒", 1.5),
        ("3 秒", 3.0),
        ("4 秒", 4.0),
        ("不自动隐藏", 0.0)
    ]
}
