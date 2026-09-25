import AppKit

/// App 的显示名，按 **macOS 系统语言** 取。
///
/// Xtopbar 自己没有做本地化（没有任何 .lproj），而 `FileManager.displayName`、
/// `NSRunningApplication.localizedName` 这些系统接口给别的 App 挑本地化名时，
/// 是按**调用方进程**能用的语言来挑的 —— 结果系统设成中文，开始菜单和条上
/// 还是 "Finder"、"Calendar"、"System Settings"。
///
/// 这里绕开它：直接拿用户的系统语言顺序（`Locale.preferredLanguages`）
/// 去匹配目标 App 自己带的本地化资源，读出它在这个语言下的名字。
/// 找不到（App 没做本地化）就返回 nil，调用方退回原来的名字。
enum AppNames {

    private static let lock = NSLock()
    /// 按「路径 + 首选语言」缓存：条每 1.2s 刷新一次，别每次都去读 plist；
    /// 用户中途改了系统语言，key 变了自然重新取
    private static var cache: [String: String?] = [:]

    static func localized(url: URL) -> String? {
        let languages = Locale.preferredLanguages
        let key = url.path + "|" + languages.joined(separator: ",")
        lock.lock()
        if let hit = cache[key] { lock.unlock(); return hit }
        lock.unlock()

        let name = resolve(url: url, languages: languages)
        lock.lock()
        cache[key] = .some(name)
        lock.unlock()
        return name
    }

    private static func resolve(url: URL, languages: [String]) -> String? {
        guard let bundle = Bundle(url: url.resolvingSymlinksInPath()) else { return nil }

        // 1) InfoPlist.loctable：macOS 14 起系统自带 App 把所有语言打进一个 plist
        //    （{ "zh_TW": { "CFBundleDisplayName": "訪達" }, "en": {...}, ... }）
        if let tableURL = bundle.url(forResource: "InfoPlist", withExtension: "loctable"),
           let raw = NSDictionary(contentsOf: tableURL) as? [String: Any] {
            let table = raw.compactMapValues { $0 as? [String: Any] }
            let locs = Bundle.preferredLocalizations(from: Array(table.keys), forPreferences: languages)
            for loc in locs {
                if let name = pick(table[loc]) { return name }
            }
        }

        // 2) 传统的 <语言>.lproj/InfoPlist.strings（第三方 App 基本都是这种）
        let locs = Bundle.preferredLocalizations(from: bundle.localizations, forPreferences: languages)
        for loc in locs {
            if let stringsURL = bundle.url(forResource: "InfoPlist", withExtension: "strings",
                                           subdirectory: nil, localization: loc),
               let dict = NSDictionary(contentsOf: stringsURL) as? [String: Any],
               let name = pick(dict) {
                return name
            }
        }
        return nil
    }

    /// 访达里显示的是 CFBundleDisplayName，没有才用 CFBundleName
    private static func pick(_ dict: [String: Any]?) -> String? {
        for key in ["CFBundleDisplayName", "CFBundleName"] {
            if let s = dict?[key] as? String,
               !s.trimmingCharacters(in: .whitespaces).isEmpty {
                return s
            }
        }
        return nil
    }
}
