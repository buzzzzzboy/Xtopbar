import Foundation

/// 开始菜单搜索模式的使用记录：每次「搜索后打开了哪个 App」记一笔（同 Raycast）。
///
/// - 没打字时的「建議」按 frecency 排：次数 × 新近程度（一周前的一次 ≈ 今天的半次）
/// - 打字时，以前用相近的词（互为前缀，如「ch」/「chr」）打开过的 App 排到最前，
///   按那些词累计的次数排；其余保持原来的搜索顺序
///
/// 存在 UserDefaults（JSON），只记 LibraryApp.id（App 是 bundle id，设置面板是 pane:…）+ 搜索词
@MainActor
final class SearchHistory {
    static let shared = SearchHistory()

    struct Entry: Codable {
        var count: Int
        var last: Date
        /// 打开它时用过的搜索词（已规范化）→ 次数
        var queries: [String: Int]
    }

    private(set) var entries: [String: Entry] = [:]
    private let key = "startSearchHistory"
    private let maxApps = 200
    private let maxQueriesPerApp = 20

    private init() {
        if let data = UserDefaults.standard.data(forKey: key),
           let saved = try? JSONDecoder().decode([String: Entry].self, from: data) {
            entries = saved
        }
    }

    /// 搜索模式里打开了 App 时调用（query 可为空：从「建議」里直接点开）
    func record(id bundleID: String, query: String, now: Date = Date()) {
        guard !bundleID.isEmpty else { return }
        var e = entries[bundleID] ?? Entry(count: 0, last: now, queries: [:])
        e.count += 1
        e.last = now
        let q = Self.normalize(query)
        if !q.isEmpty {
            e.queries[q, default: 0] += 1
            if e.queries.count > maxQueriesPerApp,
               let rare = e.queries.min(by: { $0.value < $1.value })?.key {
                e.queries.removeValue(forKey: rare)
            }
        }
        entries[bundleID] = e
        // 超量就丢掉 frecency 最低的
        if entries.count > maxApps {
            let drop = entries.keys.sorted { score($0, now: now) < score($1, now: now) }
                .prefix(entries.count - maxApps)
            drop.forEach { entries.removeValue(forKey: $0) }
        }
        if let data = try? JSONEncoder().encode(entries) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    /// frecency：次数 × 衰减（半衰期 7 天）
    func score(_ bundleID: String, now: Date = Date()) -> Double {
        guard let e = entries[bundleID] else { return 0 }
        let days = max(now.timeIntervalSince(e.last), 0) / 86_400
        return Double(e.count) * pow(0.5, days / 7)
    }

    /// 没打字时的建議：有记录的按 frecency 排，新的在前
    func ranked(now: Date = Date()) -> [String] {
        entries.keys.sorted { a, b in
            let sa = score(a, now: now), sb = score(b, now: now)
            return sa != sb ? sa > sb : (entries[a]?.last ?? .distantPast) > (entries[b]?.last ?? .distantPast)
        }
    }

    /// 这个 App 被「相近的词」打开过几次：存的词和当前词互为前缀才算
    func queryHits(_ bundleID: String, query: String) -> Int {
        let q = Self.normalize(query)
        guard !q.isEmpty, let e = entries[bundleID] else { return 0 }
        return e.queries.reduce(0) { sum, item in
            item.key.hasPrefix(q) || q.hasPrefix(item.key) ? sum + item.value : sum
        }
    }

    /// 把搜索结果里「以前用相近的词打开过」的提到最前（稳定排序，其余顺序不变）
    func rerank(_ apps: [LibraryApp], query: String) -> [LibraryApp] {
        let hits = apps.map { queryHits($0.id, query: query) }
        guard hits.contains(where: { $0 > 0 }) else { return apps }
        return apps.indices
            .sorted { hits[$0] != hits[$1] ? hits[$0] > hits[$1] : $0 < $1 }
            .map { apps[$0] }
    }

    static func normalize(_ query: String) -> String {
        query.trimmingCharacters(in: .whitespaces)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }
}
