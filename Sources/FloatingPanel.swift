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

    private var swallowNextMouseUp = false
    private var handledByPressHook = false

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
        isMovable = false
        isMovableByWindowBackground = false
        animationBehavior = .utilityWindow
        isReleasedWhenClosed = false
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// 关键：SwiftUI 在"非激活悬浮窗"里的 tap 手势命中不稳定，
    /// 这里在窗口层直接做命中测试，点击一定落到对应标签。
    override func sendEvent(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown:
            // 两段式优先：预览面板要"按下缩一下 → 抬起才切窗口"，
            // 主面板保持按下即触发（点标签最快）
            if let onPress, onPress(event.locationInWindow) {
                handledByPressHook = true
                swallowNextMouseUp = true
                return
            }
            if onTap?(event.locationInWindow) == true {
                swallowNextMouseUp = true
                return
            }
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
