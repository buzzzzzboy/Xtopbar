import Foundation

/// 自动分类规则：按 App 名称 / Bundle ID 关键词匹配
enum AppCategory: String, CaseIterable, Identifiable {
    /// 固定到任务栏的 App（不走关键词匹配，classify 永远不会返回它），恒排最前
    case pinned
    case browser
    case terminal
    case development
    case communication
    case documents
    case media
    case utility
    case other

    var id: String { rawValue }

    var title: String {
        switch self {
        case .pinned:        return "已固定"
        case .browser:       return "浏览器"
        case .terminal:      return "终端"
        case .development:   return "开发"
        case .communication: return "通讯"
        case .documents:     return "文档"
        case .media:         return "媒体"
        case .utility:       return "工具"
        case .other:         return "其他"
        }
    }

    var rank: Int {
        switch self {
        case .pinned:        return -1
        case .browser:       return 0
        case .terminal:      return 1
        case .development:   return 2
        case .communication: return 3
        case .documents:     return 4
        case .media:         return 5
        case .utility:       return 6
        case .other:         return 7
        }
    }

    /// 顺序即优先级：越具体的分类越靠前，避免 "QQMusic" 这类被更宽泛的规则抢走
    private static let rules: [(AppCategory, [String])] = [
        (.browser, [
            "safari", "chrome", "firefox", "edge", "brave", "arc", "opera",
            "vivaldi", "orion", "chromium", "browser", "webkit", "maxthon", "duckduckgo"
        ]),
        (.terminal, [
            "iterm", "terminal", "warp", "kitty", "alacritty", "hyper",
            "tabby", "ghostty", "wezterm", "rio", "termius", "royal tsx"
        ]),
        (.media, [
            "music", "spotify", "quicktime", "vlc", "iina", "photos", "podcasts",
            "movist", "infuse", "elmedia", "obs", "audacity", "logic", "garageband",
            "imovie", "finalcut", "final cut", "davinci", "capcut", "bilibili",
            "netease", "kugou", "iqiyi", "youku", "tencentvideo"
        ]),
        (.development, [
            "xcode", "vscode", "code", "cursor", "zed", "sublime", "bbedit", "nova",
            "coteditor", "intellij", "pycharm", "goland", "webstorm", "clion", "rider",
            "datagrip", "android.studio", "transmit", "postman", "insomnia",
            "docker", "orbstack", "sourcetree", "tower", "fork", "gitkraken", "hopper",
            "ida", "simulator", "proxyman", "charles", "surge", "tensorboard"
        ]),
        (.communication, [
            "wechat", "weixin", "dingtalk", "feishu", "lark", "slack", "discord",
            "telegram", "zoom", "tencentmeeting", "wework", "messages", "imessage",
            "whatsapp", "skype", "thunderbird", "mail", "outlook", "spark", "foxmail",
            "teams", "tim", "qq"
        ]),
        (.documents, [
            "notes", "pages", "numbers", "keynote", "word", "excel", "powerpoint",
            "preview", "finder", "pdf", "obsidian", "notion", "bear", "typora",
            "textedit", "skim", "devonthink", "marginnote", "zotero", "figma", "sketch",
            "affinity", "pixelmator", "craft", "ulysses", "scrivener", "textmate"
        ]),
        (.utility, [
            "settings", "preferences", "activity monitor", "disk utility", "console",
            "alfred", "raycast", "cleanmymac", "appcleaner", "1password", "bitwarden",
            "keeper", "stats", "istat", "monitor", "bartender", "daisydisk", "keka",
            "theunarchiver", "betterzip", "amphetamine", "rclone", "transmission",
            "qbittorrent", "utorrent", "downie", "permute", "ndm", "downloadmanager",
            "lunar", "flux", "hazel", "keyboard maestro", "bettertouchtool", "hidden bar"
        ])
    ]

    /// 关键词 → 分类；未命中归入 other
    static func classify(name: String, bundleID: String) -> AppCategory {
        let haystack = (name + " " + bundleID).lowercased()
        for (category, keywords) in rules {
            for kw in keywords where haystack.contains(kw) {
                return category
            }
        }
        return .other
    }
}
