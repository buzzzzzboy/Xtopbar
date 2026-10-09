import AppKit
import Combine

/// Chromium 系浏览器（Chrome / Edge / Brave / Vivaldi…）的用户设定档。
/// 右键条上的浏览器 →「開啟設定檔」→ 用那个设定档开一扇新窗口（同 Chrome 自己 Dock 菜单里的设定档列表）。
///
/// 设定档列表读的是浏览器数据目录下的 `Local State`（JSON）里的 `profile.info_cache`，
/// 顺序按 `profile.profiles_order`（浏览器设定档选单里的顺序）。
enum BrowserProfiles {
    struct Profile: Identifiable, Hashable {
        /// 数据目录下的子目录名（"Default"、"Profile 1"…），即 --profile-directory 的值
        let directory: String
        let name: String
        /// 用户在浏览器里给这个设定档挑的主题色（0xAARRGGBB）；没挑 / 灰白黑这种分不出来的为 nil
        var color: UInt32? = nil
        var id: String { directory }
    }

    /// bundle id → ~/Library/Application Support 下的数据目录
    private static let dataDirs: [String: String] = [
        "com.google.Chrome": "Google/Chrome",
        "com.google.Chrome.beta": "Google/Chrome Beta",
        "com.google.Chrome.dev": "Google/Chrome Dev",
        "com.google.Chrome.canary": "Google/Chrome Canary",
        "org.chromium.Chromium": "Chromium",
        "com.microsoft.edgemac": "Microsoft Edge",
        "com.microsoft.edgemac.Beta": "Microsoft Edge Beta",
        "com.microsoft.edgemac.Dev": "Microsoft Edge Dev",
        "com.microsoft.edgemac.Canary": "Microsoft Edge Canary",
        "com.brave.Browser": "BraveSoftware/Brave-Browser",
        "com.brave.Browser.beta": "BraveSoftware/Brave-Browser-Beta",
        "com.brave.Browser.nightly": "BraveSoftware/Brave-Browser-Nightly",
        "com.vivaldi.Vivaldi": "Vivaldi",
        "com.operasoftware.Opera": "com.operasoftware.Opera",
    ]

    /// 读 `Local State` 要过 TCC「其他 App 的数据」保护（kTCCServiceSystemPolicyAppDataDetailed）：
    /// 第一次读会弹授权框，授权框弹着时读文件的那条线程会一直卡住。所以绝不能在主线程
    /// （SwiftUI 建菜单时）读 —— 菜单只拿缓存，读文件丢到后台队列，读到了下次刷新菜单就有了。
    private static let lock = NSLock()
    private static let queue = DispatchQueue(label: "xtopbar.browser-profiles", qos: .utility)
    /// bundle id → 最近一次读到的设定档（读不到 / 被拒是空数组）
    private static var cache: [String: [Profile]] = [:]
    /// bundle id → 上次去读的时间：右键菜单和条的刷新都会来问，按它节流
    private static var lastLoad: [String: Date] = [:]
    private static let reloadInterval: TimeInterval = 30

    /// 读到的设定档和缓存里不一样时（主线程）发一次：条据此重建，右键菜单拿到新列表
    static let changed = PassthroughSubject<Void, Never>()

    static func isBrowser(_ bundleID: String) -> Bool { dataDirs[bundleID] != nil }

    /// 至少读到过一次某个浏览器的 Local State（用户在弹窗里点了允许，或给了完整磁盘访问）
    private static var everRead = false

    /// 设置页「完整磁碟取用」那行的状态：读得到浏览器数据就算有。
    /// 没读到过就看有没有完整磁盘访问 —— 打开 TCC.db 只有它才行，被拒是直接 EPERM、不弹窗，
    /// 所以主线程每秒问一次也不会卡（Local State 那边第一次读会弹窗卡住线程，绝不能在这里读）
    static var hasDataAccess: Bool {
        lock.lock()
        let read = everRead
        lock.unlock()
        if read { return true }
        guard let handle = FileHandle(forReadingAtPath: "/Library/Application Support/com.apple.TCC/TCC.db")
        else { return false }
        try? handle.close()
        return true
    }

    /// 菜单用：只读缓存，不碰文件。至少两个设定档才有意义（只有一个时就是普通的「开新窗口」）；
    /// 不是 Chromium 系浏览器 / 还没读到返回空
    static func profiles(for bundleID: String) -> [Profile] {
        guard isBrowser(bundleID) else { return [] }
        prefetch(bundleID)
        lock.lock(); defer { lock.unlock() }
        let profiles = cache[bundleID] ?? []
        return profiles.count >= 2 ? profiles : []
    }

    /// 条刷新时顺手调：浏览器一上条就在后台把设定档读好，右键时菜单里已经有了。
    /// 30 秒内读过就不再读（用户新增 / 改名设定档最多晚 30 秒反映）
    static func prefetch(_ bundleID: String) {
        guard let dir = dataDirs[bundleID] else { return }
        let now = Date()
        lock.lock()
        if let last = lastLoad[bundleID], now.timeIntervalSince(last) < reloadInterval {
            lock.unlock(); return
        }
        lastLoad[bundleID] = now
        lock.unlock()
        queue.async {
            let url = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/\(dir)/Local State")
            let profiles = parse(url)
            lock.lock()
            let old = cache[bundleID]
            cache[bundleID] = profiles
            if !profiles.isEmpty { everRead = true }
            lock.unlock()
            if old != profiles { DispatchQueue.main.async { changed.send() } }
        }
    }

    private static func parse(_ url: URL) -> [Profile] {
        guard let data = try? Data(contentsOf: url) else {
            TTLog("browser profiles: cannot read \(url.path)")
            return []
        }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let profile = root["profile"] as? [String: Any],
              let info = profile["info_cache"] as? [String: [String: Any]]
        else { return [] }
        // 访客 / 临时设定档、被藏起来的不列
        let visible = info.filter { _, v in
            (v["is_ephemeral"] as? Bool) != true && (v["is_omitted_from_profile_list"] as? Bool) != true
        }
        let order = (profile["profiles_order"] as? [String]) ?? []
        let sorted = visible.keys.sorted { a, b in
            switch (order.firstIndex(of: a), order.firstIndex(of: b)) {
            case let (i?, j?): return i < j
            case (_?, nil): return true
            case (nil, _?): return false
            default: return a.localizedStandardCompare(b) == .orderedAscending
            }
        }
        return sorted.map { dir in
            let v = visible[dir] ?? [:]
            let name = (v["name"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                ?? (v["gaia_name"] as? String) ?? dir
            return Profile(directory: dir, name: name, color: themeColor(v))
        }
    }

    /// 设定档的主题色：Chrome 存成有符号的 SkColor（ARGB）整数。
    /// `profile_highlight_color` 是窗口框的颜色，没有就退到头像底色。
    /// 默认主题是灰 / 白 / 黑 —— 每个设定档都一样，当标签色分不出谁是谁，算没设
    private static func themeColor(_ info: [String: Any]) -> UInt32? {
        guard let raw = (info["profile_highlight_color"] as? Int) ?? (info["default_avatar_fill_color"] as? Int)
        else { return nil }
        let argb = UInt32(truncatingIfNeeded: raw)
        let r = Int((argb >> 16) & 0xFF), g = Int((argb >> 8) & 0xFF), b = Int(argb & 0xFF)
        guard max(r, g, b) - min(r, g, b) >= 24 else { return nil }
        return argb | 0xFF00_0000
    }

    /// 窗口属于哪个设定档（预览卡片上的标签用）
    struct WindowProfile: Equatable {
        /// 去掉「 - Google Chrome - 设定档」后的网页标题
        let page: String
        /// 设定档名称：对得上 Local State 里的设定档就用它的名字（同右键菜单），否则用标题里那段原文
        let name: String
        /// 在设定档列表里的位置（没有主题色时定标签颜色用）；对不上为 nil
        let order: Int?
        /// 浏览器里设的主题色（0xAARRGGBB）；对不上 / 没设为 nil
        var color: UInt32? = nil
    }

    /// 从窗口标题认出设定档。有 ≥ 2 个设定档时浏览器会把设定档名放进窗口标题：
    /// Chrome / Brave 是「网页 - Google Chrome - 设定档」（登录了账号是「账号名 (设定档名)」），
    /// Edge 是「网页 - 设定档 - Microsoft Edge」—— 后者只能靠 Local State 里读到的名字去对。
    /// 只读缓存，不碰文件（主线程调）。认不出返回 nil
    static func windowProfile(title: String, appName: String, bundleID: String) -> WindowProfile? {
        guard isBrowser(bundleID), !title.isEmpty else { return nil }
        lock.lock()
        let known = cache[bundleID] ?? []
        lock.unlock()
        // 名字长的先对：「Shane」和「Shane 工作」同时存在时别对错
        let byLength = known.enumerated().sorted { $0.element.name.count > $1.element.name.count }

        if let r = title.range(of: " - \(appName) - ", options: .backwards) {
            let suffix = String(title[r.upperBound...]).trimmingCharacters(in: .whitespaces)
            guard !suffix.isEmpty else { return nil }
            let match = byLength.first { suffix.contains($0.element.name) }
            return WindowProfile(page: String(title[..<r.lowerBound]),
                                 name: match?.element.name ?? suffix,
                                 order: match?.offset,
                                 color: match?.element.color)
        }
        if known.count >= 2, title.hasSuffix(" - \(appName)") {
            let rest = title.dropLast(" - \(appName)".count)
            for (i, p) in byLength where rest.hasSuffix(" - \(p.name)") {
                return WindowProfile(page: String(rest.dropLast(" - \(p.name)".count)),
                                     name: p.name, order: i, color: p.color)
            }
        }
        return nil
    }

    /// 用指定设定档开一扇新窗口。浏览器已经在跑时，新起的进程会把参数转给正在跑的那个后退出
    /// （等价于 `open -na "Google Chrome" --args --profile-directory=...`）；没在跑就直接用这个设定档启动。
    static func open(_ profile: Profile, bundleID: String, appURL: URL?) {
        guard let url = appURL ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        else { return }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        config.createsNewApplicationInstance = true
        config.arguments = ["--profile-directory=\(profile.directory)"]
        TTLog("open profile \(profile.directory) of \(bundleID)")
        NSWorkspace.shared.openApplication(at: url, configuration: config) { _, error in
            if let error { TTLog("open profile error=\(error)") }
        }
    }
}
