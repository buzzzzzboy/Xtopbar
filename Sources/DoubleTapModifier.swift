import AppKit
import CoreGraphics

/// 「连按两下 ⌥」侦测（表情符號選擇器的另一个入口，同 Raycast 的 double-tap 修饰键快捷键）。
///
/// 会话级 CGEventTap，只看不改：所有事件原样放行，绝不吞。
/// 一次「点按」= 单独按下 ⌥ 又在 0.35 秒内放开，期间没按别的键 / 修饰键 / 鼠标；
/// 两次点按间隔 0.4 秒以内 → `onDoubleTap`。所以 ⌥Tab、⌥Space、⌥ 点按、⌥ 打特殊符号都不会误触。
///
/// 需要「辅助使用」权限（和 ⌥Tab 视窗切换器一样），没有时装不上，每 3 秒重试。
/// 线程约定：runloop source 挂在 main，回调在主线程。
final class DoubleTapModifier {
    static let shared = DoubleTapModifier()

    var onDoubleTap: (() -> Void)?

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var retryTimer: Timer?

    /// 这次按下 ⌥ 的时间（nil = ⌥ 没按着，或这次按下已经被别的键弄脏）
    private var downAt: TimeInterval?
    /// 上一次干净点按放开的时间
    private var lastTapAt: TimeInterval?
    /// 上一个 flagsChanged 时 ⌥ 是否按着
    private var altHeld = false

    private static let maxHold: TimeInterval = 0.35
    private static let maxGap: TimeInterval = 0.4

    func setEnabled(_ enabled: Bool) {
        if enabled {
            if !start() { scheduleRetry() }
        } else {
            stopRetry()
            stop()
        }
    }

    @discardableResult
    private func start() -> Bool {
        guard tap == nil else { return true }
        let mask: CGEventMask =
            (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.flagsChanged.rawValue)
            | (1 << CGEventType.leftMouseDown.rawValue) | (1 << CGEventType.rightMouseDown.rawValue)
            | (1 << CGEventType.otherMouseDown.rawValue) | (1 << CGEventType.scrollWheel.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .tailAppendEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: { _, type, event, refcon in
                let me = Unmanaged<DoubleTapModifier>.fromOpaque(refcon!).takeUnretainedValue()
                me.handle(type: type, event: event)
                return Unmanaged.passUnretained(event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            TTLog("DoubleTapModifier start FAILED (no accessibility permission?)")
            return false
        }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        self.source = source
        TTLog("DoubleTapModifier started")
        return true
    }

    private func stop() {
        guard let tap, let source else { return }
        CGEvent.tapEnable(tap: tap, enable: false)
        CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        self.tap = nil
        self.source = nil
        reset()
        TTLog("DoubleTapModifier stopped")
    }

    private func scheduleRetry() {
        guard retryTimer == nil else { return }
        let timer = Timer(timeInterval: 3.0, repeats: true) { [weak self] _ in
            guard let self, AXIsProcessTrusted(), self.start() else { return }
            self.stopRetry()
        }
        RunLoop.main.add(timer, forMode: .common)
        retryTimer = timer
    }

    private func stopRetry() {
        retryTimer?.invalidate()
        retryTimer = nil
    }

    private func reset() {
        downAt = nil
        lastTapAt = nil
    }

    /// 别的钩子把按键吞掉了（⌥Tab 视窗切换器、⌥Space 这类全局快捷键）：这里看不到那颗键，
    /// 会把「⌥ 按下 → 放开」误当成一次干净的点按，所以由它们主动通知作废
    func cancel() {
        reset()
    }

    private func handle(type: CGEventType, event: CGEvent) {
        // 超时被系统禁用后要重新启用，否则无声失效
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return
        }
        guard type == .flagsChanged else {
            // 中间按了别的键 / 点了鼠标：这一串作废
            reset()
            return
        }

        // 按 ⌥ 标志位的变化判断按下 / 放开，不看键码（左右 ⌥ 键码不同，合成事件的键码甚至是 0）
        let now = ProcessInfo.processInfo.systemUptime
        let flags = event.flags
        let alt = flags.contains(.maskAlternate)
        let wasAlt = altHeld
        altHeld = alt
        let others: CGEventFlags = [.maskCommand, .maskControl, .maskShift, .maskSecondaryFn]
        guard flags.intersection(others).isEmpty else {
            // 别的修饰键（或 ⌥ 和别的修饰键一起按）
            reset()
            return
        }

        switch (wasAlt, alt) {
        case (false, true):
            // 按下 ⌥
            downAt = now
        case (true, false):
            // 放开 ⌥
            guard let pressed = downAt, now - pressed <= Self.maxHold else {
                reset()
                return
            }
            downAt = nil
            if let last = lastTapAt, now - last <= Self.maxGap {
                lastTapAt = nil
                TTLog("DoubleTapModifier → fire")
                // 推到下一拍：别在事件钩子回调里做重活（第一次排版慢会让系统以超时为由停用钩子）
                DispatchQueue.main.async { [weak self] in self?.onDoubleTap?() }
            } else {
                lastTapAt = now
            }
        case (true, true):
            // ⌥ 按着时又按了另一颗 ⌥：不算点按
            reset()
        case (false, false):
            break  // Caps Lock 之类
        }
    }
}
