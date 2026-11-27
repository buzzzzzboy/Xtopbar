import Foundation

enum WebSearchMode: String, CaseIterable {
    case google = "Google 搜尋"
    case googleAI = "Google AI Mode"

    var prompt: String {
        switch self {
        case .google: return "在 Google 搜尋"
        case .googleAI: return "向 Google AI Mode 提問"
        }
    }

    func searchURL(for query: String) -> URL? {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return nil }

        var components = URLComponents()
        components.scheme = "https"
        components.host = "www.google.com"
        components.path = "/search"
        var items = [URLQueryItem(name: "q", value: query)]
        if self == .googleAI { items.append(URLQueryItem(name: "udm", value: "50")) }
        components.queryItems = items
        // Google 將查詢參數中的 + 解讀成空格。
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return components.url
    }
}
