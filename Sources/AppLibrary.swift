import AppKit
import Combine

/// 一个已安装的 App（开始菜单「所有应用」/ 搜索结果的一行）
struct LibraryApp: Identifiable, Equatable, Hashable {
    let bundleID: String
    let url: URL
    let name: String
    /// 第一次装上的时间（「最近加入」排序用）。扫描时先填目录的加入时间，
    /// 回到主线程后换成持久化的首次出现时间（见 `AppLibrary.applyFirstSeen`）
    var added: Date? = nil
    /// 最近一次安装 / 更新的时间（「最近更新」排序用）
    var updated: Date? = nil

    var id: String { bundleID }

    var pinned: PinnedApp { PinnedApp(bundleID: bundleID, path: url.path, name: name) }
}

/// 已安装 App 索引：扫常见的 Applications 目录，给开始菜单用。
///
/// 不用 Spotlight（NSMetadataQuery）：索引被关掉 / 重建中时会返回空，
/// 而开始菜单的"所有应用"必须稳定。直接扫目录，几百个 .app 也只要几十毫秒，
/// 而且在后台线程做，不卡界面。
@MainActor
final class AppLibrary: ObservableObject {

    static let shared = AppLibrary()

    @Published private(set) var apps: [LibraryApp] = []

    private var lastScan = Date.distantPast
    private var scanning = false
    private var iconCache: [String: NSImage] = [:]

    private init() {}

    /// 扫描根目录（每个都往下翻 `maxDepth` 层，Utilities 这类子目录不用单列）。
    /// ~/Applications 放用户自装的（比如 Chrome 的 Web App）。
    nonisolated static var roots: [URL] {
        var list = [
            "/Applications",
            "/System/Applications",
            "/System/Library/CoreServices/Applications",
            // macOS 13+ 的 Safari 住在 Cryptex 里（跟着快速安全响应单独更新），
            // /Applications/Safari.app 只是指过来的符号链接
            "/System/Cryptexes/App/System/Applications"
        ].map { URL(fileURLWithPath: $0) }
        list.append(FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Applications"))
        return list
    }

    /// 不在上面任何目录里、但开始菜单必须有的 App：访达住在 CoreServices 根下，
    /// 那一层还有一堆后台服务 .app（Dock、SystemUIServer…），不能整个目录扫进来。
    nonisolated static var extraApps: [URL] {
        ["/System/Library/CoreServices/Finder.app"].map { URL(fileURLWithPath: $0) }
    }

    /// 兜底：系统自带、放哪儿随系统版本变的 App，直接按 bundle id 问 LaunchServices 在哪。
    /// 目录扫描漏掉（位置又搬了、符号链接解析失败）时靠这一层补上。
    nonisolated static let essentialBundleIDs = ["com.apple.finder", "com.apple.Safari"]

    /// 根目录往下最多翻几层找 .app：/Applications/厂商/套件/版本/X.app 这种也能找到。
    /// 再深基本就是某个 App 的资源目录了，翻下去只是白费时间。
    nonisolated static let maxDepth = 4

    /// 套在别的 App 包里面的独立 App：Xcode 的 Simulator、Instruments、
    /// Accessibility Inspector、FileMerge… 都藏在这两个位置。
    /// 只认这两个目录 —— 包里其它地方（Helpers、LoginItems）放的是辅助进程，不该上开始菜单。
    nonisolated static let embeddedAppDirs = ["Contents/Applications", "Contents/Developer/Applications"]

    /// Info.plist 里的布尔开关：有的写成 <true/>，有的写成字符串 "1" / "YES"
    nonisolated private static func flag(_ value: Any?) -> Bool {
        if let b = value as? Bool { return b }
        if let s = value as? String { return ["1", "yes", "true"].contains(s.lowercased()) }
        return false
    }

    /// 超过 maxAge 秒没扫过就后台重扫一次（开始菜单每次打开都会调）
    func refreshIfStale(maxAge: TimeInterval = 60) {
        guard !scanning, Date().timeIntervalSince(lastScan) > maxAge else { return }
        scanning = true
        Task.detached(priority: .utility) {
            let found = AppLibrary.scan()
            await MainActor.run {
                let lib = AppLibrary.shared
                lib.scanning = false
                lib.lastScan = Date()
                let merged = lib.applyFirstSeen(found)
                if merged != lib.apps { lib.apps = merged }
                TTLog("AppLibrary 掃描完成 \(found.count) 個 App")
            }
        }
    }

    /// 「最近加入」要的是**第一次装上**的时间，可目录的加入时间在 App 每次更新
    /// （整个 .app 被换掉）后都会刷新。所以第一次见到某个 App 时把时间记下来，
    /// 之后一直用记下的那个 —— 更新过的 App 不会因此跳到「最近加入」最前面。
    /// （功能刚上线时没有历史，只能先用目录的加入时间当起点。）
    private func applyFirstSeen(_ apps: [LibraryApp]) -> [LibraryApp] {
        let prefs = Preferences.shared
        var firstSeen = prefs.appFirstSeen
        var changed = false
        let result = apps.map { app -> LibraryApp in
            var app = app
            let current = (app.added ?? Date()).timeIntervalSince1970
            let stored = firstSeen[app.bundleID] ?? current
            let first = min(stored, current)
            if firstSeen[app.bundleID] != first {
                firstSeen[app.bundleID] = first
                changed = true
            }
            app.added = Date(timeIntervalSince1970: first)
            return app
        }
        if changed { prefs.appFirstSeen = firstSeen }
        return result
    }

    /// 纯文件系统扫描：根目录下 `maxDepth` 层以内的 .app，外加套在 App 包里的独立 App；
    /// 按 bundle id 去重，按名称排序
    nonisolated static func scan() -> [LibraryApp] {
        let fm = FileManager.default
        var seen = Set<String>()
        var result: [LibraryApp] = []

        func consider(_ url: URL, embedded: Bool = false) {
            guard url.pathExtension == "app" else { return }
            // 符号链接先解析到真身再读 Bundle：/Applications/Safari.app 就是一个指向
            // Cryptex 的链接，拿链接本身去读靠不住，Safari 就是这么漏掉的
            let real = url.resolvingSymlinksInPath()
            guard let bundle = Bundle(url: real),
                  let bid = bundle.bundleIdentifier,
                  !seen.contains(bid) else { return }
            let info = bundle.infoDictionary ?? [:]
            // 纯后台进程（一点界面都没有），开始菜单里点了什么也看不到
            if flag(info["LSBackgroundOnly"]) { return }
            // 套在别的 App 里的只收正经带窗口的；菜单栏小工具那类辅助进程不收
            //（顶层的菜单栏 App 照收 —— 那是用户自己装、想从开始菜单打开的）
            if embedded, flag(info["LSUIElement"]) { return }
            seen.insert(bid)
            // 显示名按 macOS 系统语言取（见 AppNames）；App 没做本地化就用访达里看到的文件名
            var name = AppNames.localized(url: real) ?? fm.displayName(atPath: url.path)
            if name.hasSuffix(".app") { name = String(name.dropLast(4)) }
            // 加入时间：放进所在目录的时刻（拖进 /Applications、安装器装进来）；
            // 更新时间：再和包本身、Info.plist 的修改时间取最新 —— App 更新会换掉整个包
            let values = try? real.resourceValues(
                forKeys: [.addedToDirectoryDateKey, .creationDateKey, .contentModificationDateKey])
            let added = values?.addedToDirectoryDate ?? values?.creationDate
            let plistDate = (try? real.appendingPathComponent("Contents/Info.plist")
                .resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            let updated = [added, values?.contentModificationDate, plistDate].compactMap { $0 }.max()
            result.append(LibraryApp(bundleID: bid, url: real, name: name,
                                     added: added, updated: updated))

            // 包里还套着独立 App 的话一起收。只翻一层：套娃里的套娃不再往里钻
            guard !embedded else { return }
            for dir in embeddedAppDirs {
                guard let inner = try? fm.contentsOfDirectory(
                    at: real.appendingPathComponent(dir), includingPropertiesForKeys: nil,
                    options: [.skipsHiddenFiles]) else { continue }
                inner.forEach { consider($0, embedded: true) }
            }
        }

        for root in roots {
            // skipsPackageDescendants：不钻进 .app / .bundle 这些包里（包里的独立 App 由 consider 专门处理）
            guard let walker = fm.enumerator(
                at: root, includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
            // 用 nextObject 逐个取，不用 for-in：for-in 走快速枚举会成批预取，
            // skipDescendants 就来不及拦住已经取出来的那批子项
            while let item = walker.nextObject() as? URL {
                if item.pathExtension == "app" {
                    consider(item)
                    walker.skipDescendants()   // 指向 .app 的符号链接不算包，这里显式别往里钻
                } else if walker.level >= maxDepth {
                    walker.skipDescendants()
                }
            }
        }
        extraApps.filter { fm.fileExists(atPath: $0.path) }.forEach { consider($0) }
        for bid in essentialBundleIDs where !seen.contains(bid) {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bid) { consider(url) }
        }
        return result.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// 按 bundle id 找已安装的 App（最近使用 / 固定项解析用）
    func app(bundleID: String) -> LibraryApp? {
        apps.first { $0.bundleID == bundleID }
    }

    /// 图标（按路径缓存；NSWorkspace 取图标是同步的，但有系统缓存，很快）
    func icon(for url: URL) -> NSImage {
        if let cached = iconCache[url.path] { return cached }
        let image = NSWorkspace.shared.icon(forFile: url.path)
        image.size = NSSize(width: 64, height: 64)
        iconCache[url.path] = image
        return image
    }

    func search(_ query: String) -> [LibraryApp] {
        AppLibrary.search(query, in: apps)
    }

    /// 搜索：名称前缀 > 名称里某个词的前缀 > 名称包含 > bundle id 包含。
    /// 忽略大小写和变音符号。纯函数，不碰 UI，可离线回归（`--test-pins` 会打一次）。
    nonisolated static func search(_ query: String, in apps: [LibraryApp]) -> [LibraryApp] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return apps }
        let opts: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]

        func score(_ app: LibraryApp) -> Int? {
            let name = app.name
            if let r = name.range(of: q, options: opts) {
                if r.lowerBound == name.startIndex { return 0 }
                let before = name[name.index(before: r.lowerBound)]
                if before == " " || before == "-" || before == "." { return 1 }
                return 2
            }
            if app.bundleID.range(of: q, options: opts) != nil { return 3 }
            return nil
        }

        var scored: [(app: LibraryApp, score: Int)] = []
        for app in apps {
            if let s = score(app) { scored.append((app, s)) }
        }
        scored.sort { a, b in
            if a.score != b.score { return a.score < b.score }
            return a.app.name.localizedStandardCompare(b.app.name) == .orderedAscending
        }
        return scored.map { $0.app }
    }
}
