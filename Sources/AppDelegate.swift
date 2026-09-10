import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private let catalog = AppCatalog()
    private var controller: TabBarController?
    private var statusItem: StatusItemController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 不占 Dock、不进 Cmd+Tab，纯悬浮条 + 菜单栏图标
        NSApp.setActivationPolicy(.accessory)

        catalog.start()
        let controller = TabBarController(catalog: catalog)
        self.controller = controller
        controller.start()

        // 菜单栏图标。由 Preferences.showStatusItem 控制显隐。
        statusItem = StatusItemController(prefs: .shared, controller: controller)

        // 调试用：`open TopTab.app --args --settings` 直接拉起设置窗口
        if CommandLine.arguments.contains("--settings") {
            // 延后一拍：applicationDidFinishLaunching 期间窗口还没法正确上屏
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                SettingsWindowController.shared.show()
            }
        }

        // 调试用：验证 SMAppService 注册是否被系统接受（自签名 App 可能被拒）
        if CommandLine.arguments.contains("--test-login") {
            TTLog("LaunchAtLogin 测试前：\(LaunchAtLogin.statusDescription)")
            let on = LaunchAtLogin.set(true)
            TTLog("register → \(on ?? "ok")，status=\(LaunchAtLogin.statusDescription)")
            let off = LaunchAtLogin.set(false)
            TTLog("unregister → \(off ?? "ok")，status=\(LaunchAtLogin.statusDescription)")
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        catalog.stop()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
