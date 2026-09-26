import AppKit

/// 「隐藏系统 Dock」：把系统 Dock 设成自动隐藏 + 超长唤出延迟（等于永远不出来），
/// 关掉时把原来的两个值原样写回。
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
    /// 唤出延迟：1000 秒 ≈ 永远。不用更大的数：个别系统版本对超大浮点会忽略整条配置
    private static let hiddenDelay = "1000"

    static func apply(hide: Bool) {
        let prefs = Preferences.shared
        if hide {
            if !prefs.hasSavedSystemDock {
                prefs.savedDockAutohide = readBool("autohide")
                prefs.savedDockDelay = readDouble("autohide-delay")
                prefs.hasSavedSystemDock = true
            }
            run(["write", domain, "autohide", "-bool", "true"])
            run(["write", domain, "autohide-delay", "-float", hiddenDelay])
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

    /// 改开关前先确认：Dock 会重启一下（闪一下），得让用户知道发生了什么。
    /// 返回 false = 用户取消。
    static func confirm(hide: Bool) -> Bool {
        let alert = NSAlert()
        alert.messageText = hide ? "隱藏系統 Dock？" : "恢復系統 Dock？"
        alert.informativeText = hide
            ? "會把系統 Dock 設為「自動隱藏」並把喚出延遲調到極長，然後重啟一次 Dock（螢幕底部會閃一下，視窗不受影響）。\n\n關掉這個開關會恢復你原來的設定。"
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
