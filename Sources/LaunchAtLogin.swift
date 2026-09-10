import AppKit
import ServiceManagement

/// 开机自启动。用 SMAppService（macOS 13+），不写 LaunchAgent plist。
///
/// 注意：`SMAppService.mainApp.register()` 会把**当前 App 所在路径**注册进
/// 系统登录项，所以 App 一旦被移动（比如从 build 目录挪到「应用程序」），
/// 需要重新注册一次。这里每次开 App 会做一次自愈性重注册。
@MainActor
enum LaunchAtLogin {

    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static var statusDescription: String {
        switch SMAppService.mainApp.status {
        case .enabled:          return "已启用"
        case .notRegistered:    return "未启用"
        case .requiresApproval: return "等待系统批准（系统设置 → 通用 → 登录项）"
        case .notFound:         return "未找到（把 App 移到「应用程序」后再试）"
        @unknown default:       return "未知状态"
        }
    }

    /// 返回 nil 表示成功，否则是错误描述
    @discardableResult
    static func set(_ enabled: Bool) -> String? {
        do {
            if enabled {
                guard SMAppService.mainApp.status != .enabled else { return nil }
                try SMAppService.mainApp.register()
            } else {
                guard SMAppService.mainApp.status != .notRegistered else { return nil }
                try SMAppService.mainApp.unregister()
            }
            return nil
        } catch {
            TTLog("LaunchAtLogin.set(\(enabled)) failed: \(error)")
            return error.localizedDescription
        }
    }

    /// 已被用户同意过、但系统还在等批准时，引导去登录项面板
    static func openLoginItemsSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")!
        NSWorkspace.shared.open(url)
    }
}
