import AppKit
import SwiftUI

/// 调试日志开关：环境变量 XTOPBAR_DEBUG 或存在 /tmp/xtopbar.debug 标记文件。
/// 后者是为 `open Xtopbar.app` 准备的 —— 走 LaunchServices 启动时环境变量传不进去。
func TTLog(_ message: String) {
    guard ProcessInfo.processInfo.environment["XTOPBAR_DEBUG"] != nil
            || FileManager.default.fileExists(atPath: "/tmp/xtopbar.debug") else { return }
    let line = "[\(Date())] \(message)\n"
    let url = URL(fileURLWithPath: "/tmp/xtopbar.log")
    if let handle = try? FileHandle(forWritingTo: url) {
        handle.seekToEndOfFile()
        handle.write(line.data(using: .utf8)!)
        try? handle.close()
    } else {
        try? line.write(to: url, atomically: true, encoding: .utf8)
    }
}

/// 无边框、不抢焦点的悬浮面板
final class FloatingPanel: NSPanel {

    /// 点击命中回调：传入窗口坐标（原点上左由面板侧转换），返回 true 表示已被标签消费
    var onTap: ((NSPoint) -> Bool)?

    /// 两段式点击：mouseDown 只给"按下去"的反馈，mouseUp 才真的执行动作。
    /// 内容层要给按压动效时用它；`onPress` 返回 true 表示命中并接管这次点击。
    var onPress: ((NSPoint) -> Bool)?
    var onRelease: ((NSPoint) -> Void)?
    /// 按下被 `onPress` 接管后的拖动（主面板拖标签排序用）。不设就照常往下传。
    var onDrag: ((NSPoint) -> Void)?
    /// 右键按下：返回 true 表示接管（主面板在标签上弹自绘菜单），不再落到 SwiftUI 的 contextMenu
    var onRightPress: ((NSPoint) -> Bool)?

    private var swallowNextMouseUp = false
    private var handledByPressHook = false
    private var swallowNextRightMouseUp = false

    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        // 悬停提示（SwiftUI .help）默认只在 App 激活时出：Xtopbar 刚启动时是激活的所以有，
        // 一旦开过浮层再把焦点交还前台 App，Xtopbar 就一直处于未激活，提示再也不出来
        allowsToolTipsWhenApplicationIsInactive = true
        isMovable = false
        isMovableByWindowBackground = false
        animationBehavior = .utilityWindow
        isReleasedWhenClosed = false
    }

    /// 能打字的浮层（表情符號選擇器）收起的那一下置位：这时所有面板都不接 key。
    /// 不然 AppKit 会把 key 转给 Xtopbar 自己的另一个面板（悬浮条），键盘留在 Xtopbar 里，
    /// 原来的 App 虽然还在前台却收不到按键（贴上的 ⌘V、之后打的字都落空）
    static var handingKeyBack = false

    override var canBecomeKey: Bool { !Self.handingKeyBack }

    /// 收起接过 key 的浮层（开始菜单、后台资料夹）：orderOut 那一下所有面板都不接 key，
    /// 键盘交还前台 App —— 不然刚从这里打开 / 切过去的 App 到了前台，
    /// key 却被 AppKit 转给悬浮条，打字落到 Xtopbar 里
    func orderOutHandingKeyBack() {
        Self.handingKeyBack = true
        orderOut(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { Self.handingKeyBack = false }
    }
    override var canBecomeMain: Bool { false }

    /// 关键：SwiftUI 在"非激活悬浮窗"里的 tap 手势命中不稳定，
    /// 这里在窗口层直接做命中测试，点击一定落到对应标签。
    override func sendEvent(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown:
            // 两段式优先：预览面板要"按下缩一下 → 抬起才切窗口"，
            // 主面板要"抬起才切 App、按住拖动就排序"
            if let onPress, onPress(event.locationInWindow) {
                handledByPressHook = true
                swallowNextMouseUp = true
                return
            }
            if onTap?(event.locationInWindow) == true {
                swallowNextMouseUp = true
                return
            }
        case .leftMouseDragged where handledByPressHook && onDrag != nil:
            // 按下在本窗口里，拖出窗口外也照样收到拖动事件
            onDrag?(event.locationInWindow)
            return
        case .rightMouseDown:
            if onRightPress?(event.locationInWindow) == true {
                swallowNextRightMouseUp = true
                return
            }
        case .rightMouseUp where swallowNextRightMouseUp:
            swallowNextRightMouseUp = false
            return
        case .leftMouseUp where swallowNextMouseUp:
            swallowNextMouseUp = false
            if handledByPressHook {
                handledByPressHook = false
                onRelease?(event.locationInWindow)
            }
            return
        default:
            break
        }
        super.sendEvent(event)
    }
}

/// SwiftUI 内容宿主：允许"首次点击直达控件"
final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var needsPanelToBecomeKey: Bool { false }
}
