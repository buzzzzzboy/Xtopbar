import AppKit
import CoreGraphics

/// ⌥Tab 拦截器：视窗切换器（Windows Alt+Tab / DockDoor 同款）的键盘入口。
///
/// 会话级 CGEventTap，只认「按住 ⌥、没按 ⌘ / ⌃」时的 Tab，⌘Tab 原样留给系统。
///
/// 语义：
/// - 第一次按下 ⌥Tab（⌥⇧Tab 反向）→ `onActivate`
/// - 会话中（`sessionActive`）键盘整个归切换器：Tab / ⇧Tab、方向键、Return、Esc
///   转成 `onKey`，其它键一律吞掉 —— 按住 ⌥ 时误按的字母会在前台 App 里打出 ∑ ø 之类，
///   切换途中不该漏出去
/// - 松开 ⌥ → `onOptionReleased`（提交选中）
///
/// keyUp 只吞「keyDown 被我们吞过」的那几颗键，普通按键的 keyUp 完全放行
/// （不配对的 keyUp 会让个别输入框进怪状态）。
///
/// 线程约定：runloop source 挂在 main，回调都在主线程。
final class WindowSwitcherTap {

    enum Key {
        /// Tab；按着 ⇧ 时 reverse = true
        case tab(reverse: Bool)
        case left, right, up, down
        /// Return / 数字键盘 Enter：立刻切过去
        case commit
        /// Esc：取消
        case cancel
    }

    /// 第一次按下 ⌥Tab。reverse = 按着 ⇧（⌥⇧Tab 从最后一个往回选）。主线程调用。
    var onActivate: ((_ reverse: Bool) -> Void)?
    /// 会话中的按键。主线程调用。
    var onKey: ((Key) -> Void)?
    /// 会话中松开 ⌥。主线程调用。
    var onOptionReleased: (() -> Void)?

    /// 切换器面板开着（由控制器维护）。只有这时才接管键盘。
    var sessionActive = false

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    /// 吞过 keyDown、还没等到 keyUp 的键
    private var swallowedKeyUps = Set<Int64>()

    var isActive: Bool { tap != nil }

    /// 安装事件钩子。失败多半是没有辅助功能权限（tapCreate 返回 nil）。
    @discardableResult
    func start() -> Bool {
        guard tap == nil else { return true }
        let mask: CGEventMask =
            (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)
            | (1 << CGEventType.flagsChanged.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, refcon in
                let me = Unmanaged<WindowSwitcherTap>.fromOpaque(refcon!).takeUnretainedValue()
                return me.handle(type: type, event: event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            TTLog("WindowSwitcherTap start FAILED (no accessibility permission?)")
            return false
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        self.source = source
        TTLog("WindowSwitcherTap started")
        return true
    }

    func stop() {
        guard let tap, let source else { return }
        CGEvent.tapEnable(tap: tap, enable: false)
        CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        self.tap = nil
        self.source = nil
        swallowedKeyUps.removeAll()
        sessionActive = false
        TTLog("WindowSwitcherTap stopped")
    }

    // 虚拟键码（kVK_*）
    private static let tabKey: Int64 = 48
    private static let returnKey: Int64 = 36
    private static let enterKey: Int64 = 76
    private static let escapeKey: Int64 = 53
    private static let leftKey: Int64 = 123
    private static let rightKey: Int64 = 124
    private static let downKey: Int64 = 125
    private static let upKey: Int64 = 126

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // 超时被系统禁用后必须重新启用，否则功能无声失效
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        let keycode = event.getIntegerValueField(.keyboardEventKeycode)
        let flags = event.flags

        if type == .flagsChanged {
            // 修饰键事件一律放行（吞了前台 App 的修饰键状态会乱），只看 ⌥ 有没有松开。
            // 只认 ⌥：会话中放开 ⇧（⌥⇧Tab 反向走完）不能被当成提交。
            if sessionActive, !flags.contains(.maskAlternate) {
                onOptionReleased?()
            }
            return Unmanaged.passUnretained(event)
        }

        if type == .keyUp {
            if swallowedKeyUps.remove(keycode) != nil { return nil }
            return Unmanaged.passUnretained(event)
        }

        guard type == .keyDown else { return Unmanaged.passUnretained(event) }

        if sessionActive {
            swallowedKeyUps.insert(keycode)
            switch keycode {
            case Self.tabKey:    onKey?(.tab(reverse: flags.contains(.maskShift)))
            case Self.leftKey:   onKey?(.left)
            case Self.rightKey:  onKey?(.right)
            case Self.upKey:     onKey?(.up)
            case Self.downKey:   onKey?(.down)
            case Self.returnKey, Self.enterKey: onKey?(.commit)
            case Self.escapeKey: onKey?(.cancel)
            default:             break   // 会话中的其它键：吞掉，不漏给前台 App
            }
            return nil
        }

        // 只认 ⌥Tab / ⌥⇧Tab。带 ⌘ 的是 ⌘Tab（归系统），带 ⌃ 的留给 App 自己。
        guard keycode == Self.tabKey,
              flags.contains(.maskAlternate),
              !flags.contains(.maskCommand),
              !flags.contains(.maskControl) else {
            return Unmanaged.passUnretained(event)
        }
        swallowedKeyUps.insert(keycode)
        TTLog("WindowSwitcherTap → activate")
        onActivate?(flags.contains(.maskShift))
        return nil
    }
}
