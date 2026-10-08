import AppKit

/// 「隐藏系统 Dock」：把系统 Dock 设成自动隐藏，关掉时把原来的值原样写回。
/// 鼠标顶到底边照样能唤出 Dock，它的窗口层级比悬浮条高，会盖在条上面正常用。
///
/// 早先的版本还把唤出延迟调到 1000 秒（等于 Dock 永远不出来），`migrateLegacyDelay` 负责改回来。
///
/// 没有公开 API 能真正"关掉"系统 Dock，业内通行做法就是这两个 defaults：
///   `com.apple.dock autohide`        是否自动隐藏
///   `com.apple.dock autohide-delay`  鼠标到底边后等多久才出来（秒）
/// 写完要 `killall Dock` 让 Dock 重读配置（Dock 会被 launchd 立刻拉起，窗口不受影响）。
///
/// 原值存进 Preferences（`savedDockAutohide` / `savedDockDelay`），**只在第一次开启时存**：
/// 开着的时候再开一次（比如设置被同步回来）不能把"已经被我们改过的值"当原值存下来，
/// 否则关掉时还原的是 1000 秒延迟，系统 Dock 就再也出不来了。
@MainActor
enum SystemDock {

    private static let domain = "com.apple.dock"
    /// 早先版本写进去的唤出延迟（1000 秒 ≈ 永远不出来）
    private static let legacyHiddenDelay: Double = 1000

    static func apply(hide: Bool) {
        let prefs = Preferences.shared
        if hide {
            if !prefs.hasSavedSystemDock {
                prefs.savedDockAutohide = readBool("autohide")
                prefs.savedDockDelay = readDouble("autohide-delay")
                prefs.hasSavedSystemDock = true
            }
            run(["write", domain, "autohide", "-bool", "true"])
            TTLog("SystemDock 隱藏（原值 autohide=\(String(describing: prefs.savedDockAutohide)) "
                  + "delay=\(String(describing: prefs.savedDockDelay))）")
        } else {
            guard prefs.hasSavedSystemDock else { return }
            // 原本没写过的 key 就删掉，而不是写一个默认值进去 —— 还原成"没动过"的样子
            if let v = prefs.savedDockAutohide {
                run(["write", domain, "autohide", "-bool", v ? "true" : "false"])
            } else {
                run(["delete", domain, "autohide"])
            }
            if let v = prefs.savedDockDelay {
                run(["write", domain, "autohide-delay", "-float", String(v)])
            } else {
                run(["delete", domain, "autohide-delay"])
            }
            prefs.savedDockAutohide = nil
            prefs.savedDockDelay = nil
            prefs.hasSavedSystemDock = false
            TTLog("SystemDock 已還原")
        }
        restartDock()
    }

    /// 从早先版本升级上来、开着「隐藏系统 Dock」的：唤出延迟还是 1000 秒，Dock 叫不出来。
    /// 启动时改回用户原来的延迟（原来没设过就删掉这个 key），重启一次 Dock
    static func migrateLegacyDelay() {
        let prefs = Preferences.shared
        guard prefs.hideSystemDock, prefs.hasSavedSystemDock,
              readDouble("autohide-delay") == legacyHiddenDelay else { return }
        if let v = prefs.savedDockDelay {
            run(["write", domain, "autohide-delay", "-float", String(v)])
        } else {
            run(["delete", domain, "autohide-delay"])
        }
        TTLog("SystemDock 舊版 1000 秒喚出延遲已還原")
        restartDock()
    }

    /// 改开关前先确认：Dock 会重启一下（闪一下），得让用户知道发生了什么。
    /// 返回 false = 用户取消。
    static func confirm(hide: Bool) -> Bool {
        let alert = NSAlert()
        alert.messageText = hide ? "隱藏系統 Dock？" : "恢復系統 Dock？"
        alert.informativeText = hide
            ? "會把系統 Dock 設為「自動隱藏」，然後重啟一次 Dock（螢幕底部會閃一下，視窗不受影響）。滑鼠頂到螢幕底邊仍可喚出 Dock。\n\n關掉這個開關會恢復你原來的設定。"
            : "會恢復開啟前的 Dock 自動隱藏設定，並重啟一次 Dock。"
        alert.addButton(withTitle: hide ? "隱藏" : "恢復")
        alert.addButton(withTitle: "取消")
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn
    }

    // MARK: - defaults

    private static func readBool(_ key: String) -> Bool? {
        guard let out = run(["read", domain, key]) else { return nil }
        return out == "1" || out.lowercased() == "true"
    }

    private static func readDouble(_ key: String) -> Double? {
        guard let out = run(["read", domain, key]) else { return nil }
        return Double(out)
    }

    /// 跑一次 /usr/bin/defaults。退出码非 0（比如读一个不存在的 key）返回 nil。
    @discardableResult
    private static func run(_ args: [String]) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        do {
            try p.run()
        } catch {
            TTLog("defaults \(args) 啟動失敗：\(error)")
            return nil
        }
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func restartDock() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        p.arguments = ["Dock"]
        try? p.run()
    }
}
