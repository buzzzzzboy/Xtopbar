import AppKit
import IOKit.ps

/// 「系統設定」裡的各個面板（藍牙、顯示器、鍵盤…），让开始菜单搜索能直接跳过去。
///
/// macOS 13 起系统设置的每个面板都是 /System/Library/ExtensionKit/Extensions 下的一个
/// .appex，扩展点是 `com.apple.Settings.extension.ui`。直接扫这个目录读 Info.plist，
/// 打开时用 `x-apple.systempreferences:<bundle id>` 让系统设置跳到对应面板。
/// 面板只随系统更新变，按目录修改时间 + 系统语言缓存，没变就不重读。
enum SettingsPanes {

    nonisolated static let directory = URL(fileURLWithPath: "/System/Library/ExtensionKit/Extensions")
    nonisolated static let extensionPoint = "com.apple.Settings.extension.ui"

    /// Info.plist 里只有内部代号的面板：显示名另外取（见 `overrideNames`）
    nonisolated private static let batteryID = "com.apple.Battery-Settings.extension"
    nonisolated private static let headphonesID = "com.apple.HeadphoneSettings"

    /// 不该出现在搜索里的面板：「待處理項目」只在系统有事要提醒时才有内容
    nonisolated private static let skipped: Set<String> = [
        "com.apple.FollowUpSettings.FollowUpSettingsExtension",
    ]

    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: (key: String, panes: [LibraryApp])?

    /// 所有面板，按显示名排序。纯文件系统读取，可在后台线程调
    nonisolated static func scan() -> [LibraryApp] {
        let fm = FileManager.default
        let modified = (try? directory.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate
        let key = "\(modified?.timeIntervalSince1970 ?? 0)|"
            + Locale.preferredLanguages.joined(separator: ",")
        lock.lock()
        if let cache, cache.key == key { lock.unlock(); return cache.panes }
        lock.unlock()

        guard let items = try? fm.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return [] }

        var seen = Set<String>()
        var result: [LibraryApp] = []
        for url in items where url.pathExtension == "appex" {
            guard let info = NSDictionary(contentsOf: url.appendingPathComponent("Contents/Info.plist"))
                    as? [String: Any],
                  isSettingsPane(info),
                  let bid = info["CFBundleIdentifier"] as? String,
                  !skipped.contains(bid),
                  seen.insert(bid).inserted else { continue }
            let base = displayName(info)
            // 显示名按系统语言（见 AppNames）；英文原名留作别名，「bluetooth」「display」也搜得到
            let names = overrideNames(bid, url)
                ?? [AppNames.localized(url: url) ?? base, englishName(url), base].compactMap { $0 }
            guard let name = names.first else { continue }
            var unique: Set<String> = [name]
            let aliases = names.dropFirst().filter { unique.insert($0).inserted }
            result.append(LibraryApp(bundleID: bid, url: url, name: name,
                                     isSettingsPane: true, aliases: aliases))
        }
        let panes = result.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        if modified != nil {
            lock.lock(); cache = (key, panes); lock.unlock()
        }
        return panes
    }

    /// 打开系统设置并跳到这个面板
    static func open(_ pane: LibraryApp) {
        guard let url = URL(string: "x-apple.systempreferences:" + pane.bundleID) else { return }
        TTLog("open settings pane \(pane.bundleID)")
        NSWorkspace.shared.open(url)
    }

    /// 显示名 + 别名。电池面板的名字在 Localizable 表里，而且桌机上它叫「能源」；
    /// 耳机面板包里没有任何本地化名字（只有接着耳机时系统设置里才出现）
    nonisolated private static func overrideNames(_ bid: String, _ url: URL) -> [String]? {
        switch bid {
        case batteryID:
            let key = hasBattery ? "BATTERY_PREF_TITLE" : "ENERGY_SAVER_PREF_TITLE"
            let fallback = hasBattery ? "Battery" : "Energy"
            return [localizedString(key, table: "Localizable", in: url) ?? fallback,
                    fallback, "Battery", "Energy", "電池", "能源"]
        case headphonesID:
            return ["耳機", "Headphones", "AirPods"]
        default:
            return nil
        }
    }

    /// 这台 Mac 有没有内置电池（笔电）
    nonisolated private static var hasBattery: Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return false }
        return list.contains { source in
            let desc = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any]
            return desc?[kIOPSTypeKey] as? String == kIOPSInternalBatteryType
        }
    }

    /// 从 `<table>.loctable` 按系统语言取一条字符串
    nonisolated private static func localizedString(_ key: String, table: String, in url: URL) -> String? {
        let file = url.appendingPathComponent("Contents/Resources/\(table).loctable")
        guard let raw = NSDictionary(contentsOf: file) as? [String: Any] else { return nil }
        let tables = raw.compactMapValues { $0 as? [String: Any] }
        let locs = Bundle.preferredLocalizations(from: Array(tables.keys),
                                                 forPreferences: Locale.preferredLanguages)
        return locs.lazy.compactMap { tables[$0]?[key] as? String }.first
    }

    nonisolated private static func isSettingsPane(_ info: [String: Any]) -> Bool {
        let ex = (info["EXAppExtensionAttributes"] as? [String: Any])?["EXExtensionPointIdentifier"]
        let ns = (info["NSExtension"] as? [String: Any])?["NSExtensionPointIdentifier"]
        return ex as? String == extensionPoint || ns as? String == extensionPoint
    }

    nonisolated private static func displayName(_ dict: [String: Any]?) -> String? {
        for key in ["CFBundleDisplayName", "CFBundleName"] {
            if let s = dict?[key] as? String, !s.trimmingCharacters(in: .whitespaces).isEmpty { return s }
        }
        return nil
    }

    /// 英文名：Info.plist 里常是内部名，真正的英文显示名在 loctable / en.lproj 里
    nonisolated private static func englishName(_ url: URL) -> String? {
        let res = url.appendingPathComponent("Contents/Resources")
        if let table = NSDictionary(contentsOf: res.appendingPathComponent("InfoPlist.loctable"))
            as? [String: Any],
           let name = displayName(table["en"] as? [String: Any]) {
            return name
        }
        for lproj in ["en", "English", "Base"] {
            let strings = res.appendingPathComponent("\(lproj).lproj/InfoPlist.strings")
            if let name = displayName(NSDictionary(contentsOf: strings) as? [String: Any]) { return name }
        }
        return nil
    }
}
