import AppKit
import CoreGraphics

/// ⌘Tab 拦截器（AppRing 同款机制）：会话级 CGEventTap 吞掉「按住 ⌘ 时按下 Tab」，
/// 让系统切换器不出现。语义：
/// - 第一次按下 → 立即唤出悬浮条并预选上一个 App
/// - 再按 Tab   → 沿标签视觉顺序前进高亮（到末尾循环）
/// - 松开 ⌘    → 提交当前高亮（快按快放因此等于"切上一个"）
/// - Esc        → 取消
///
/// 为什么用 CGEventTap 而不是 NSEvent 全局监听：⌘Tab 是系统级快捷键，
/// 在任何 App 收到之前就被 Dock 消费了，只有 HID/会话层的 tap 能抢在它前面。
///
/// keyUp 也要拦：只吞 keyDown 的话，App 会收到一个没有配对的 Tab keyUp，
/// 个别对 keyUp 敏感的输入框（如 Vim 模式）会出怪状态。
/// 只在吞过 keyDown（pendingTab）的前提下才吞 keyUp，普通 Tab 完全放行。
///
/// 线程约定：runloop source 挂在 main，所有回调都在主线程执行，
/// 所以这里不加 actor 隔离（C 函数指针回调里没法 await），
/// 但对外仍要求只在主线程创建与读写。
final class CmdTabTap {

    /// 第一次按下（不含自动重复）。主线程调用。
    var onTabDown: (() -> Void)?
    /// 面板弹出后再按的 Tab / 自动重复：沿视觉顺序前进。主线程调用。
    var onTabCycle: (() -> Void)?
    /// 与已拦截的 keyDown 配对的 keyUp。主线程调用。
    var onTabUp: (() -> Void)?
    /// ⌘ 从按下到松开（会话提交的信号）。主线程调用。
    var onCommandReleased: (() -> Void)?
    /// 会话期间按 Esc（仅当 swallowEscape 为 true 时触发，事件被吞掉）。
    var onEscape: (() -> Void)?

    /// 会话进行中才吞 Esc；平时 Esc 属于前台 App。
    var swallowEscape = false

    /// 是否拦截。关掉后 ⌘Tab 原样放行给系统切换器 ——
    /// 悬浮条总开关关闭时必须放行，否则用户白白丢了 ⌘Tab。
    var interceptEnabled: Bool = true

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    /// 已吞过 Tab 的 keyDown、还没等到 keyUp。用它配对吞 keyUp，
    /// 避免把用户正常的 Tab keyUp 也吞掉。
    private var pendingTab = false
    /// 看到过 ⌘ 按下（flagsChanged 或带 ⌘ 的 Tab keyDown）。
    /// 只有它置位后的"⌘ 全松"才报 onCommandReleased。
    /// 已知取舍：会话期间用户又按又松 ⌘（连击）会提前触发一次提交 ——
    /// 这和系统 ⌘Tab 的行为一致（松 ⌘ 即切换），不算异常。
    private var cmdWasDown = false

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
                let me = Unmanaged<CmdTabTap>.fromOpaque(refcon!).takeUnretainedValue()
                return me.handle(type: type, event: event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            TTLog("CmdTabTap start FAILED (no accessibility permission?)")
            return false
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        self.source = source
        TTLog("CmdTabTap started")
        return true
    }

    func stop() {
        guard let tap, let source else { return }
        CGEvent.tapEnable(tap: tap, enable: false)
        CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        self.tap = nil
        self.source = nil
        pendingTab = false
        cmdWasDown = false
        swallowEscape = false
        TTLog("CmdTabTap stopped")
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // 超时被系统禁用后必须重新启用，否则功能无声失效
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        let keycode = event.getIntegerValueField(.keyboardEventKeycode)
        // 48 = Tab（kVK_Tab），53 = Esc（kVK_Escape）

        if type == .flagsChanged {
            // 只认 ⌘ 的按下/松开（绝不吞修饰键事件，吞了前台 App 的 ⌘ 键盘状态会乱）。
            // 不能把 Shift/Control 也算进来：会话中用户放 ⇧（⌘⇧Tab 反向）时
            // "全部修饰键松开"会误判成"⌘ 松开"，提前提交。
            let cmdHeld = event.flags.contains(.maskCommand)
            if cmdHeld { cmdWasDown = true }
            else if cmdWasDown {
                cmdWasDown = false
                onCommandReleased?()
            }
            return Unmanaged.passUnretained(event)
        }

        if type == .keyUp, keycode == 48, pendingTab {
            // 配对吞掉我们自己拦下的那次按下；普通 Tab 的 keyUp 不受影响
            pendingTab = false
            onTabUp?()
            return nil
        }
        if type == .keyDown, keycode == 53, swallowEscape {
            onEscape?()
            return nil   // 会话中 Esc 属于我们（取消），不落到前台 App
        }
        guard type == .keyDown, keycode == 48,
              event.flags.contains(.maskCommand), interceptEnabled else {
            // ⌘ 先松、Tab 后松时 flags 里已经没有 ⌘ —— 这种 keyDown 放行给系统，
            // 但把 pendingTab 清掉，避免之后一个普通 Tab keyUp 被误吞
            if type == .keyDown, keycode == 48 { pendingTab = false }
            return Unmanaged.passUnretained(event)
        }
        // 按住不放会产生 key-repeat：每一发都吞掉（否则系统切换器会漏出来）。
        // 首发弹面板并预选上一个；之后的每一发（含按住自动重复）沿 MRU 前进 ——
        // 和系统切换器"按住 Tab 连按循环"的肌肉记忆一致。
        // 锚点在首发就钉死，重复事件不再重设位置（避免面板跟鼠标漂移）。
        let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
        if !isRepeat {
            pendingTab = true
            cmdWasDown = true
            TTLog("CmdTabTap → down")
            onTabDown?()
        } else {
            onTabCycle?()
        }
        return nil   // 吞掉：Dock 切换器不会出现
    }
}
