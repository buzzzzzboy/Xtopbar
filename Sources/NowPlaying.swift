import AppKit
import Combine

/// 开始菜单底栏的「现正播放」：Spotify / Apple Music。
///
/// - 曲目信息：两家自己广播的分布式通知（不用任何授权，切歌 / 暂停就会发）。
/// - 播放控制：模拟键盘的媒体键（播放 / 下一首 / 上一首），只要辅助功能授权（条本来就要）。
///   不用 Apple Event：「自动化」授权在 macOS 27 上会卡住不弹框，发出去只会等到超时。
///   代价是媒体键发给系统认定的「正在播放」的 App，两个播放器都开着时控制的是最后放过的那个。
/// - 封面：Spotify 用通知里的曲目 ID 向 Spotify 公开的 oEmbed 接口要；Apple Music 没有
///   不需授权的来源，显示 App 图标。
///
/// 不用 MediaRemote：macOS 15.4 起第三方 App 读不到它了。
enum MediaPlayer: String, CaseIterable {
    case spotify, music

    var bundleID: String {
        switch self {
        case .spotify: return "com.spotify.client"
        case .music:   return "com.apple.Music"
        }
    }

    var title: String {
        switch self {
        case .spotify: return "Spotify"
        case .music:   return "Apple Music"
        }
    }

    var notification: Notification.Name {
        switch self {
        case .spotify: return Notification.Name("com.spotify.client.PlaybackStateChanged")
        case .music:   return Notification.Name("com.apple.Music.playerInfo")
        }
    }

    var isRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }

    var appURL: URL? { NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) }
}

/// 现正播放来源：自动（谁在放就显示谁）或固定一个
enum NowPlayingSource: String, CaseIterable, Identifiable {
    case auto, spotify, music

    var id: String { rawValue }

    var title: String {
        switch self {
        case .auto:    return "自動"
        case .spotify: return "Spotify"
        case .music:   return "Apple Music"
        }
    }

    var player: MediaPlayer? {
        switch self {
        case .auto:    return nil
        case .spotify: return .spotify
        case .music:   return .music
        }
    }
}

struct NowPlayingTrack: Equatable {
    var title: String
    var artist: String
    var playing: Bool
    /// Spotify 的曲目 ID（spotify:track:…），拿封面用；Apple Music 没有
    var trackID: String? = nil
}

@MainActor
final class NowPlaying: ObservableObject {
    static let shared = NowPlaying()

    /// 当前显示哪个播放器（固定来源时恒为它；自动时是在放的 / 最近放过的 / 开着的那个）
    @Published private(set) var player: MediaPlayer?
    @Published private(set) var track: NowPlayingTrack?
    @Published private(set) var artwork: NSImage?

    private var states: [MediaPlayer: NowPlayingTrack] = [:]
    private var lastActive: MediaPlayer?
    private var artworkKey: String?
    private var artworkCache: [String: NSImage] = [:]

    private init() {
        for p in MediaPlayer.allCases {
            DistributedNotificationCenter.default().addObserver(
                forName: p.notification, object: nil, queue: .main
            ) { [weak self] note in
                let info = note.userInfo ?? [:]
                MainActor.assumeIsolated { self?.handle(p, info) }
            }
        }
        // 播放器退出：它的状态作废
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let id = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
            MainActor.assumeIsolated {
                guard let self, let p = MediaPlayer.allCases.first(where: { $0.bundleID == id }) else { return }
                self.states[p] = nil
                self.recompute()
            }
        }
        Preferences.shared.$nowPlayingSource
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.recompute() }
            .store(in: &cancellables)
    }

    private var cancellables = Set<AnyCancellable>()

    /// 开始菜单打开时：播放器可能在菜单关着时退出了，重新算一遍
    func menuDidOpen() { recompute() }

    // MARK: - 控制

    func playPause() {
        let p = player ?? Preferences.shared.nowPlayingSource.player ?? lastActive ?? .spotify
        // 没在运行：媒体键会被系统发给别的 App（没人在放时甚至会拉起「音乐」），先把它开起来
        guard p.isRunning else { return launch(p) }
        MediaKey.post(.play)
    }

    func next() { MediaKey.post(.next) }
    func previous() { MediaKey.post(.previous) }

    /// 点曲目信息：切到播放器
    func openPlayer() {
        guard let p = player ?? Preferences.shared.nowPlayingSource.player, let url = p.appURL else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    private func launch(_ p: MediaPlayer) {
        guard let url = p.appURL else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    // MARK: - 状态

    /// 收到播放器通知（userInfo 形如 ["Player State": "Playing", "Name": …, "Artist": …, "Track ID": …]）
    func handle(_ p: MediaPlayer, _ info: [AnyHashable: Any]) {
        let state = (info["Player State"] as? String) ?? ""
        if state == "Stopped" {
            states[p] = nil
        } else {
            let t = NowPlayingTrack(title: info["Name"] as? String ?? "",
                                    artist: info["Artist"] as? String ?? "",
                                    playing: state == "Playing",
                                    trackID: info["Track ID"] as? String)
            states[p] = t
            if t.playing { lastActive = p }
        }
        recompute()
    }

    private func recompute() {
        let next: MediaPlayer?
        if let pinned = Preferences.shared.nowPlayingSource.player {
            next = pinned
        } else if case let playing = MediaPlayer.allCases.filter({ states[$0]?.playing == true }),
                  let pick = playing.first(where: { $0 == lastActive }) ?? playing.first {
            // 两个都在放：优先最近开始放的那个
            next = pick
        } else if let last = lastActive, states[last] != nil {
            next = last
        } else {
            next = MediaPlayer.allCases.first { states[$0] != nil } ?? MediaPlayer.allCases.first { $0.isRunning }
        }
        if next != player { player = next }
        let t = next.flatMap { states[$0] }
        if t != track { track = t }
        loadArtwork()
    }

    /// Spotify 封面：https://open.spotify.com/oembed?url=<曲目链接> → thumbnail_url
    private func loadArtwork() {
        guard player == .spotify, let raw = track?.trackID,
              let id = raw.split(separator: ":").last.map(String.init), !id.isEmpty else {
            artworkKey = nil
            if artwork != nil { artwork = nil }
            return
        }
        guard id != artworkKey else { return }
        artworkKey = id
        if let cached = artworkCache[id] { artwork = cached; return }
        artwork = nil
        var q = URLComponents(string: "https://open.spotify.com/oembed")!
        q.queryItems = [URLQueryItem(name: "url", value: "https://open.spotify.com/track/\(id)")]
        guard let api = q.url else { return }
        Task { [weak self] in
            guard let (json, _) = try? await URLSession.shared.data(from: api),
                  let obj = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
                  let thumb = (obj["thumbnail_url"] as? String).flatMap(URL.init(string:)),
                  let (data, _) = try? await URLSession.shared.data(from: thumb),
                  let image = NSImage(data: data) else { return }
            await MainActor.run {
                guard let self else { return }
                self.artworkCache[id] = image
                if self.artworkKey == id { self.artwork = image }
            }
        }
    }
}

/// 模拟键盘媒体键（NX_KEYTYPE_*，系统定义事件 subtype 8），发到 HID 层。
/// 系统会转给当前的「正在播放」App，和按键盘上的 ⏯ ⏭ ⏮ 一样。需要辅助功能授权
enum MediaKey: Int32 {
    case play = 16      // NX_KEYTYPE_PLAY
    case next = 17      // NX_KEYTYPE_NEXT
    case previous = 18  // NX_KEYTYPE_PREVIOUS

    static func post(_ key: MediaKey) {
        for down in [true, false] {
            let state: Int32 = down ? 0xA : 0xB
            let event = NSEvent.otherEvent(
                with: .systemDefined, location: .zero,
                modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(state) << 8),
                timestamp: 0, windowNumber: 0, context: nil, subtype: 8,
                data1: Int((key.rawValue << 16) | (state << 8)), data2: -1)
            event?.cgEvent?.post(tap: .cghidEventTap)
        }
        TTLog("nowPlaying 媒体键 \(key)")
    }
}
