import AppKit
import CoreText

/// 特殊符號分类：同 macOS「字元檢視器」侧边栏（拉丁文不收）
enum SymbolCategory: String, CaseIterable, Identifiable {
    case parentheses, enclosed, currency, pictographs, bullets, digits, math, punctuation, arrows, letterlike

    var id: String { rawValue }

    var title: String {
        switch self {
        case .parentheses: return "括號"
        case .enclosed:    return "框住的字元"
        case .currency:    return "貨幣符號"
        case .pictographs: return "象形文字"
        case .bullets:     return "項目符號與星號"
        case .digits:      return "數字 - 全部"
        case .math:        return "數學符號"
        case .punctuation: return "標點符號"
        case .arrows:      return "箭頭"
        case .letterlike:  return "類字母符號"
        }
    }

    /// 侧边栏图标：同字元檢視器，直接用一个代表字元
    var icon: String {
        switch self {
        case .parentheses: return "( )"
        case .enclosed:    return "ⓐ"
        case .currency:    return "$"
        case .pictographs: return "✍︎"
        case .bullets:     return "✻"
        case .digits:      return "①"
        case .math:        return "√"
        case .punctuation: return ".,"
        case .arrows:      return "→"
        case .letterlike:  return "№"
        }
    }

    /// 字元檢視器里对应的分类表
    fileprivate var plist: String {
        switch self {
        case .parentheses: return "Parentheses"
        case .enclosed:    return "EnclosedCharacters"
        case .currency:    return "CurrencySymbols"
        case .pictographs: return "Pictographs"
        case .bullets:     return "Bullets"
        case .digits:      return "DigitsAll"
        case .math:        return "MathematicalSymbols"
        case .punctuation: return "Punctuation"
        case .arrows:      return "Arrows"
        case .letterlike:  return "LetterlikeSymbols"
        }
    }
}

/// 特殊符號资料：字元本身来自系统「字元檢視器」的分类表（CharacterPalette.app 里的 Category-*.plist），
/// 名称 / 关键字来自 App 包里的 SymbolNames.tsv（CLDR），CLDR 没有的用 Unicode 英文名。
/// 第一次用到才读，读一次全部分类（几千个字元，几十毫秒）
@MainActor
final class SymbolLibrary {
    static let shared = SymbolLibrary()

    struct Section {
        let title: String?
        let items: [Emoji]
    }

    private(set) lazy var sections: [SymbolCategory: [Section]] = load()
    /// 全部符号（去重，按分类顺序），搜索用
    private(set) lazy var all: [Emoji] = {
        var seen = Set<String>()
        return SymbolCategory.allCases
            .flatMap { sections[$0, default: []].flatMap(\.items) }
            .filter { seen.insert($0.base).inserted }
    }()
    private lazy var byBase: [String: Emoji] = Dictionary(all.map { ($0.base, $0) }, uniquingKeysWith: { a, _ in a })

    func symbol(_ base: String) -> Emoji? { byBase[base] }

    private static let resources = URL(fileURLWithPath:
        "/System/Library/Input Methods/CharacterPalette.app/Contents/Resources")

    private static let sectionTitles = [
        "SectionTitle-RightArrows": "向右箭頭",
        "SectionTitle-LeftArrows": "向左箭頭",
        "SectionTitle-UpArrows": "向上箭頭",
        "SectionTitle-DownArrows": "向下箭頭",
        "SectionTitle-LeftRightArrows": "左右箭頭",
        "SectionTitle-UpDownArrows": "上下箭頭",
        "SectionTitle-MiscArrows": "其他箭頭",
    ]

    private func load() -> [SymbolCategory: [Section]] {
        let start = Date()
        let names = Self.loadNames()
        let font = CTFontCreateWithName("Helvetica" as CFString, 24, nil)
        var seen: [String: Emoji] = [:]
        var result: [SymbolCategory: [Section]] = [:]

        for category in SymbolCategory.allCases {
            let url = Self.resources.appendingPathComponent("Category-\(category.plist).plist")
            guard let root = NSDictionary(contentsOf: url) as? [String: Any],
                  let data = root["CVCategoryData"] as? [String: Any] else { continue }
            var raw: [(String?, String)] = []
            if let list = data["DataArray"] as? [[String: Any]] {
                for part in list {
                    guard let chars = part["Data"] as? String else { continue }
                    let title = (part["CVDataTitle"] as? String).flatMap { Self.sectionTitles[$0] }
                    raw.append((title, chars))
                }
            } else if let chars = data["Data"] as? String {
                raw.append((nil, chars))
            }

            result[category] = raw.compactMap { title, chars in
                var local = Set<String>()
                let items: [Emoji] = chars.split(separator: ",").compactMap { token in
                    guard let char = Self.decode(String(token)), local.insert(char).inserted,
                          Self.canDraw(char, font: font) else { return nil }
                    if let known = seen[char] { return known }
                    let item = Self.makeSymbol(char, names: names)
                    seen[char] = item
                    return item
                }
                return items.isEmpty ? nil : Section(title: title, items: items)
            }
        }
        TTLog("symbols: loaded \(seen.count) in \(Int(Date().timeIntervalSince(start) * 1000))ms")
        return result
    }

    /// 分类表里的一项：字元本身，或 0x2C 这种十六进制码位（逗号、阿拉伯数字等不好直接写的）
    private static func decode(_ token: String) -> String? {
        guard !token.isEmpty else { return nil }
        if token.hasPrefix("0x"), token.count > 2, let v = UInt32(token.dropFirst(2), radix: 16),
           let scalar = Unicode.Scalar(v) {
            return String(Character(scalar))
        }
        return token
    }

    /// 系统字体（含 fallback）画不出来的字元跳过，不然显示成方框
    private static func canDraw(_ s: String, font: CTFont) -> Bool {
        let ns = s as NSString
        let fallback = CTFontCreateForString(font, ns, CFRange(location: 0, length: ns.length))
        return (CTFontCopyPostScriptName(fallback) as String) != "LastResort"
    }

    private typealias Names = [String: [String]]

    /// SymbolNames.tsv：字元 → [en 名, en 关键字, 繁中名, 繁中关键字, 简中名, 简中关键字]
    private static func loadNames() -> Names {
        guard let url = Bundle.main.url(forResource: "SymbolNames", withExtension: "tsv"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return [:] }
        var out: Names = [:]
        for line in text.split(separator: "\n") {
            let c = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard c.count >= 7 else { continue }
            out[c[0]] = Array(c[1...6])
        }
        return out
    }

    private static func makeSymbol(_ char: String, names: Names) -> Emoji {
        // 名表的 key 不带变体选择符（︎ / ️）
        let key = char.unicodeScalars.filter { $0.value != 0xFE0E && $0.value != 0xFE0F }
            .map(String.init).joined()
        let cldr = names[key]
        let unicode = unicodeName(key)
        let display: String
        switch EmojiStore.displayLanguage {
        case .hant: display = cldr?[2].nonEmpty ?? cldr?[0].nonEmpty ?? unicode
        case .hans: display = cldr?[4].nonEmpty ?? cldr?[0].nonEmpty ?? unicode
        case .other: display = cldr?[0].nonEmpty.map { $0.prefix(1).uppercased() + $0.dropFirst() } ?? unicode
        }
        var nameTerms = [display, unicode]
        var keywords: [String] = []
        if let cldr {
            nameTerms += [cldr[0], cldr[2], cldr[4]]
            keywords = [cldr[1], cldr[3], cldr[5]].flatMap { $0.split(separator: "|").map(String.init) }
        }
        return Emoji(base: char, group: nil, tones: [], name: display,
                     names: EmojiStore.unique(nameTerms.filter { !$0.isEmpty }.map(EmojiStore.normalize)),
                     keywords: EmojiStore.unique(keywords.map(EmojiStore.normalize)))
    }

    /// Unicode 英文名（「RIGHTWARDS ARROW」→「Rightwards arrow」）
    private static func unicodeName(_ s: String) -> String {
        let m = NSMutableString(string: s)
        CFStringTransform(m, nil, kCFStringTransformToUnicodeName, false)
        var name = m as String
        // 结果形如 \N{RIGHTWARDS ARROW}，多个码位就有多段
        name = name.replacingOccurrences(of: "\\N{", with: "").replacingOccurrences(of: "}", with: " ")
            .trimmingCharacters(in: .whitespaces).lowercased()
        return name.prefix(1).uppercased() + name.dropFirst()
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
