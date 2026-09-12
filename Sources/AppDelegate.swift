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

        // 调试用：`--test-hotzone=1` 重放"在 1 号屏上用过一次 ⌘Tab"，
        // 看热区是否仍留在设置指定的那块屏上
        if let arg = CommandLine.arguments.first(where: { $0.hasPrefix("--test-hotzone") }) {
            let index = Int(arg.split(separator: "=").last ?? "0") ?? 0
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                controller.diagnoseHotZone(pointerOnScreen: index)
            }
        }

        // 调试用：`--test-cycle=6` 把 ⌘Tab 会话的循环序列走一遍，
        // 看高亮是不是一格一格连着的（而不是在图标之间横跳）
        if let arg = CommandLine.arguments.first(where: { $0.hasPrefix("--test-cycle") }) {
            let presses = Int(arg.split(separator: "=").last ?? "6") ?? 6
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                controller.diagnoseCycle(presses: presses)
            }
        }

        // 调试用：`--test-quickswitch` 模拟"⌘Tab 呼出 → 选完"，
        // 验证条是不是当场消失、以及会不会被顶部唤出区立刻拉回来
        if CommandLine.arguments.contains("--test-quickswitch") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                controller.diagnoseQuickSwitch()
            }
        }

        // 在线更新：启动 3 秒后静默看一眼 GitHub Releases（不需要任何自建服务器）。
        // 没有新版本就什么都不做，有新版本才弹窗。
        if CommandLine.arguments.contains("--update-install") {
            // 调试用：跳过弹窗，直接把新版本装上，验证整条更新链路
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                Updater.shared.checkAndInstallAutomatically()
            }
        } else if CommandLine.arguments.contains("--check-update") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                Updater.shared.check(silent: false)
            }
        } else if Preferences.shared.autoCheckUpdates {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                Updater.shared.check(silent: true)
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        catalog.stop()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
