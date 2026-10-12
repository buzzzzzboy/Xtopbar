import AppKit
import Combine

/// 表情的 Unicode 分类（顺序同 emoji-test.txt 的 group，也是 Emoji.tsv 第二栏的序号）
enum EmojiGroup: Int, CaseIterable, Identifiable {
    case smileys, people, animals, food, travel, activities, objects, symbols, flags

    var id: Int { rawValue }
}

/// 选择器里的表情分类：同 macOS「字元檢視器」（表情與人物合在一起，活動排在旅遊前面）
enum EmojiCategory: String, CaseIterable, Identifiable {
    case smileysPeople, animals, food, activities, travel, objects, symbols, flags

    var id: String { rawValue }

    var groups: Set<EmojiGroup> {
        switch self {
        case .smileysPeople: return [.smileys, .people]
        case .animals:       return [.animals]
        case .food:          return [.food]
        case .activities:    return [.activities]
        case .travel:        return [.travel]
        case .objects:       return [.objects]
        case .symbols:       return [.symbols]
        case .flags:         return [.flags]
        }
    }

    var title: String {
        switch self {
        case .smileysPeople: return "表情符號與人物"
        case .animals:       return "動物與自然"
        case .food:          return "美食佳餚"
        case .activities:    return "活動"
        case .travel:        return "旅遊與地點"
        case .objects:       return "物品"
        case .symbols:       return "符號"
        case .flags:         return "旗幟"
        }
    }

    var symbol: String {
        switch self {
        case .smileysPeople: return "face.smiling"
        case .animals:       return "pawprint"
        case .food:          return "fork.knife"
        case .activities:    return "soccerball"
        case .travel:        return "car"
        case .objects:       return "lightbulb"
        case .symbols:       return "number.square"
        case .flags:         return "flag"
        }
    }
}

/// 膚色：0 = 预设（黄色），1…5 = 🏻🏼🏽🏾🏿
enum EmojiTone {
    static let count = 6
    static let swatches = ["✋", "✋🏻", "✋🏼", "✋🏽", "✋🏾", "✋🏿"]
    static let titles = ["預設", "淺膚色", "中淺膚色", "中等膚色", "中深膚色", "深膚色"]
}

struct Emoji: Hashable, Identifiable {
    /// 不带肤色的本体（也是记录 / 钉选用的 id）。特殊符號也用这个结构，base 就是字元本身
    let base: String
    /// nil = 特殊符號
    let group: EmojiGroup?
    /// 5 个肤色变体；不支持肤色时为空
    let tones: [String]
    /// 显示名：系统语言的 Apple 名称（同 macOS「表情與符號」里看到的），没有就用 CLDR 的
    let name: String
    /// 搜索用的词（已规范化）：名称（各语言）在前，关键字在后
    let names: [String]
    let keywords: [String]

    var id: String { base }
    var supportsTone: Bool { !tones.isEmpty }

    func glyph(tone: Int) -> String {
        guard tone > 0, tones.indices.contains(tone - 1) else { return base }
        return tones[tone - 1]
    }
}

/// 表情资料 + 使用记录 / 钉选 / 肤色偏好。
///
/// 资料来自 App 包里的 Emoji.tsv（scripts/make-emoji-data.py 由 Unicode emoji-test.txt + CLDR 生成）。
/// 系统的 CoreEmoji 里有一份 AppleName.strings（各语言的表情名）：
/// 有的话拿来当显示名，并据此隐藏这台 macOS 还画不出来的新表情（不然显示成方框）
@MainActor
final class EmojiStore: ObservableObject {
    static let shared = EmojiStore()

    /// 全部表情（按 Unicode 分类顺序）。第一次用到才读文件
    private(set) lazy var all: [Emoji] = Self.load()
    private lazy var byBase: [String: Emoji] = Dictionary(all.map { ($0.base, $0) }, uniquingKeysWith: { a, _ in a })
    /// 每个分类的表情（打开分类时直接取，不用每次过滤一遍）
    private(set) lazy var byCategory: [EmojiCategory: [Emoji]] = {
        var out: [EmojiCategory: [Emoji]] = [:]
        for c in EmojiCategory.allCases {
            out[c] = all.filter { $0.group.map(c.groups.contains) ?? false }
        }
        return out
    }()

    @Published var tone: Int {
        didSet { d.set(tone, forKey: Keys.tone) }
    }
    @Published private(set) var pins: [String] {
        didSet { d.set(pins, forKey: Keys.pins) }
    }
    @Published private(set) var history: [String: Use] = [:]

    struct Use: Codable {
        var count: Int
        var last: Date
    }

    private let d = UserDefaults.standard
    private enum Keys {
        static let tone = "emojiSkinTone"
        static let pins = "emojiPins"
        static let history = "emojiHistory"
    }
    private let maxHistory = 120

    private init() {
        tone = min(max(d.integer(forKey: Keys.tone), 0), EmojiTone.count - 1)
        pins = d.stringArray(forKey: Keys.pins) ?? []
        if let data = d.data(forKey: Keys.history),
           let saved = try? JSONDecoder().decode([String: Use].self, from: data) {
            history = saved
        }
    }

    /// 表情或特殊符號
    func item(_ base: String) -> Emoji? { byBase[base] ?? SymbolLibrary.shared.symbol(base) }

    // MARK: - 钉选 / 最近使用

    func isPinned(_ e: Emoji) -> Bool { pins.contains(e.base) }

    func togglePin(_ e: Emoji) {
        if let i = pins.firstIndex(of: e.base) { pins.remove(at: i) } else { pins.append(e.base) }
    }

    var pinned: [Emoji] { pins.compactMap { item($0) } }

    /// 常用：frecency（次数 × 新近程度，半衰期 7 天，同开始菜单的 SearchHistory）
    func frequent(limit: Int) -> [Emoji] {
        let now = Date()
        return history.keys
            .sorted { score($0, now: now) > score($1, now: now) }
            .compactMap { item($0) }
            .prefix(limit)
            .map { $0 }
    }

    func score(_ base: String, now: Date = Date()) -> Double {
        guard let use = history[base] else { return 0 }
        let days = max(now.timeIntervalSince(use.last), 0) / 86_400
        return Double(use.count) * pow(0.5, days / 7)
    }

    func recordUse(_ e: Emoji, now: Date = Date()) {
        var use = history[e.base] ?? Use(count: 0, last: now)
        use.count += 1
        use.last = now
        history[e.base] = use
        if history.count > maxHistory {
            let drop = history.keys.sorted { score($0, now: now) < score($1, now: now) }
                .prefix(history.count - maxHistory)
            drop.forEach { history.removeValue(forKey: $0) }
        }
        saveHistory()
    }

    func forget(_ e: Emoji) {
        history.removeValue(forKey: e.base)
        saveHistory()
    }

    func clearHistory() {
        history.removeAll()
        saveHistory()
    }

    private func saveHistory() {
        if let data = try? JSONEncoder().encode(history) { d.set(data, forKey: Keys.history) }
    }

    // MARK: - 搜索

    /// 每个词都要命中（名称或关键字）。排序：名称全等 > 关键字全等 > 名称开头 > 关键字开头 > 包含，
    /// 同分时常用的在前，再按名称短的在前（「heart」时 ❤️ 红心排在 💘 带箭的心前面），最后按分类顺序
    func search(_ query: String) -> [Emoji] {
        let tokens = Self.normalize(query).split(whereSeparator: \.isWhitespace).map(String.init)
        guard !tokens.isEmpty else { return all }
        // 直接贴了 / 打了表情本身
        if let hit = item(query.trimmingCharacters(in: .whitespaces)) { return [hit] }

        var scored: [(Emoji, Int, Double, Int, Int)] = []
        // 表情在前、特殊符號在后（同分时表情优先）
        for (order, e) in (all + SymbolLibrary.shared.all).enumerated() {
            var total = 0
            for token in tokens {
                let s = Self.score(token, e)
                guard s > 0 else { total = 0; break }
                total += s
            }
            if total > 0 { scored.append((e, total, score(e.base), e.names.map(\.count).min() ?? 0, order)) }
        }
        return scored.sorted {
            if $0.1 != $1.1 { return $0.1 > $1.1 }
            if $0.2 != $1.2 { return $0.2 > $1.2 }
            if $0.3 != $1.3 { return $0.3 < $1.3 }
            return $0.4 < $1.4
        }.map(\.0)
    }

    private static func score(_ token: String, _ e: Emoji) -> Int {
        var best = 0
        for n in e.names {
            if n == token { return 100 }
            if n.hasPrefix(token) { best = max(best, 80) }
            // 英文名按词首比对（「face」命中「grinning face」）
            else if n.contains(" " + token) { best = max(best, 60) }
            else if n.contains(token) { best = max(best, 40) }
        }
        for k in e.keywords {
            if k == token { best = max(best, 85) }
            else if k.hasPrefix(token) { best = max(best, 50) }
            else if best < 20, k.contains(token) { best = 20 }
        }
        return best
    }

    nonisolated static func normalize(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespaces)
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }

    // MARK: - 读文件

    private static func load() -> [Emoji] {
        guard let url = Bundle.main.url(forResource: "Emoji", withExtension: "tsv"),
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            TTLog("emoji: Emoji.tsv 不在 App 包裡")
            return []
        }
        let lang = displayLanguage
        let apple = appleNames()
        // 系统表情名表里没有的新表情 = 这台 macOS 画不出来，藏掉。
        // 只管 13.0 以后的：更早的系统肯定有（♀ ♂ 这种老字符本来就不在名表里）
        let systemNames = appleNames(lproj: "en")

        var result: [Emoji] = []
        result.reserveCapacity(1950)
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let c = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard c.count >= 10, let g = Int(c[1]), let group = EmojiGroup(rawValue: g) else { continue }
            let base = c[0]
            let key = base.replacingOccurrences(of: "\u{FE0F}", with: "")
            if let systemNames, (Double(c[2]) ?? 0) >= 13, systemNames[key] == nil { continue }

            let cldr = (en: c[4], hant: c[6], hans: c[8])
            let fallback: String
            switch lang {
            case .hant: fallback = cldr.hant
            case .hans: fallback = cldr.hans
            case .other: fallback = cldr.en
            }
            var name = apple?[key] ?? (fallback.isEmpty ? cldr.en : fallback)
            if lang == .other { name = name.prefix(1).uppercased() + name.dropFirst() }

            let names = [name, cldr.en, cldr.hant, cldr.hans, systemNames?[key] ?? ""]
                .filter { !$0.isEmpty }.map(normalize)
            let keywords = [c[5], c[7], c[9]]
                .flatMap { $0.split(separator: "|").map { normalize(String($0)) } }
            result.append(Emoji(base: base, group: group,
                                tones: c[3].isEmpty ? [] : c[3].split(separator: " ").map(String.init),
                                name: name,
                                names: unique(names), keywords: unique(keywords)))
        }
        TTLog("emoji: loaded \(result.count) lang=\(lang) appleNames=\(apple?.count ?? 0)")
        return result
    }

    nonisolated static func unique(_ list: [String]) -> [String] {
        var seen = Set<String>()
        return list.filter { seen.insert($0).inserted }
    }

    enum DisplayLanguage { case hant, hans, other }

    /// 介面是繁体中文，所以除非系统明确是简体 / 其它语言，名称都用繁体
    static var displayLanguage: DisplayLanguage {
        let id = Locale.preferredLanguages.first ?? "zh-Hant"
        if id.hasPrefix("zh-Hans") || id == "zh-CN" || id == "zh-SG" { return .hans }
        if id.hasPrefix("zh") { return .hant }
        return .other
    }

    private static let coreEmoji = URL(fileURLWithPath:
        "/System/Library/PrivateFrameworks/CoreEmoji.framework/Versions/A/Resources")

    /// CoreEmoji 的 AppleName.strings：表情（去掉 FE0F）→ 名称。私有框架里的资源，读不到就算了
    private static func appleNames(lproj: String? = nil) -> [String: String]? {
        let candidates: [String]
        if let lproj {
            candidates = [lproj]
        } else {
            switch displayLanguage {
            case .hant:
                let hk = Locale.preferredLanguages.first?.contains("HK") == true
                candidates = hk ? ["zh_HK", "zh_TW"] : ["zh_TW", "zh_HK"]
            case .hans:
                candidates = ["zh_CN"]
            case .other:
                let id = (Locale.preferredLanguages.first ?? "en").replacingOccurrences(of: "-", with: "_")
                let parts = id.split(separator: "_").map(String.init)
                candidates = [id, parts.first.map { "\($0)_\(parts.last ?? "")" }, parts.first].compactMap { $0 }
            }
        }
        for name in candidates {
            let url = coreEmoji.appendingPathComponent("\(name).lproj/AppleName.strings")
            guard let dict = NSDictionary(contentsOf: url) as? [String: String] else { continue }
            var out: [String: String] = [:]
            out.reserveCapacity(dict.count)
            for (k, v) in dict { out[k.replacingOccurrences(of: "\u{FE0F}", with: "")] = v }
            return out
        }
        return nil
    }
}
