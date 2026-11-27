import AppKit
import SwiftUI

/// 工作列小工具的现况（MainActor）：偏好里的清单 + 现在看不看得见 → 每个槽要画什么。
/// 纯逻辑在 `TaskbarWidgets.swift`，这里只接上偏好和正在播放的状态
@MainActor
enum TaskbarWidgets {
    static func current(hasTabs: Bool) -> WidgetArrangement {
        let widgets = Preferences.shared.taskbarWidgets
        guard !widgets.isEmpty else { return WidgetArrangement() }
        return WidgetArrangement.arrange(widgets, isVisible: isVisible, hasTabs: hasTabs)
    }

    /// 正在播放：播放器没在跑就整颗藏起来（宽度归零）；其它一律看得见
    static func isVisible(_ widget: TaskbarWidget) -> Bool {
        switch widget.kind {
        case .nowPlaying: return NowPlaying.shared.playerRunning
        case .systemStats, .folder: return true
        }
    }

    /// 这颗小工具的估宽（未缩放的 pt），视图按 `TTLayout.s(baseWidth)` 定宽，和估算一致
    static func baseWidth(_ widget: TaskbarWidget) -> CGFloat {
        let prefs = Preferences.shared
        var name: String?
        if case .folder(let id) = widget.kind { name = prefs.startFolders.first { $0.id == id }?.name }
        return TaskbarWidgetMetrics.width(widget.kind, iconOnly: prefs.iconOnly,
                                          barBaseHeight: TTLayout.barBaseHeight, folderName: name)
    }
}

/// 条的横向版面：条左边条外的东西（槽 1 → 开始 → 槽 2 → 搜索 → 槽 3）、条内两端（槽 4、5）、
/// 条右边条外（槽 6）。条外的每颗东西各带一道缝：左边的缝在它右边（最后一道就是调大小的把手），
/// 右边的缝在它左边
extension TTLayout {
    /// 条外圆（开始 / 搜索）+ 左侧条外小工具，连各自右边的缝
    @MainActor static func leftOuterBaseWidth(_ a: WidgetArrangement) -> CGFloat {
        a.leftOuter.reduce(detachedStartBaseWidth) { $0 + TaskbarWidgets.baseWidth($1) + detachedStartBaseGap }
    }

    @MainActor static func leftOuterWidth(_ a: WidgetArrangement) -> CGFloat {
        a.leftOuter.reduce(detachedStartWidth) { $0 + s(TaskbarWidgets.baseWidth($1)) + detachedStartGap }
    }

    /// 条右边条外的小工具（槽 6），连各自左边的缝
    @MainActor static func rightOuterBaseWidth(_ a: WidgetArrangement) -> CGFloat {
        a.afterBar.reduce(0) { $0 + TaskbarWidgets.baseWidth($1) + detachedStartBaseGap }
    }

    @MainActor static func rightOuterWidth(_ a: WidgetArrangement) -> CGFloat {
        a.afterBar.reduce(0) { $0 + s(TaskbarWidgets.baseWidth($1)) + detachedStartGap }
    }

    /// 条内两端（槽 4、5）：不在滚动内容里，固定在条的玻璃内
    @MainActor static func innerBaseWidth(_ a: WidgetArrangement) -> CGFloat {
        (a.barLeading + a.barTrailing).reduce(0) { $0 + TaskbarWidgets.baseWidth($1) }
    }

    @MainActor static func innerWidth(_ a: WidgetArrangement) -> CGFloat {
        (a.barLeading + a.barTrailing).reduce(0) { $0 + s(TaskbarWidgets.baseWidth($1)) }
    }

    @MainActor static func innerLeadingWidth(_ a: WidgetArrangement) -> CGFloat {
        a.barLeading.reduce(0) { $0 + s(TaskbarWidgets.baseWidth($1)) }
    }

    /// 条左边条外一共几颗（开始 / 搜索圆 + 小工具）：> 0 才有调大小的把手
    @MainActor static func leftOuterCount(_ a: WidgetArrangement) -> Int {
        detachedCount + a.leftOuter.count
    }
}

/// 点到小工具的哪一块：正在播放两端是上一首 / 下一首，其它都算 `.main`
enum WidgetPart { case main, previous, next }

/// 一颗小工具在条上的外壳：按估宽定宽（和 `TTLayout` 的宽度描述对得上），条外的垫一颗胶囊玻璃，
/// 条内的直接画在条的玻璃上。整颗的命中区域用 `widget.hitID` 上报（窗口坐标，同开始按钮）
struct TaskbarWidgetItem: View {
    let widget: TaskbarWidget
    let inBar: Bool
    @ObservedObject var catalog: AppCatalog
    @ObservedObject var prefs: Preferences

    var body: some View {
        let width = TTLayout.s(TaskbarWidgets.baseWidth(widget))
        TaskbarWidgetContent(widget: widget, catalog: catalog, prefs: prefs)
            .frame(width: width, height: TTLayout.barHeight)
            .background {
                if !inBar { GlassBackdrop(style: prefs.glassStyle, cornerRadius: TTLayout.barHeight / 2) }
            }
            .clipShape(Capsule(style: .continuous))
            .contentShape(Capsule(style: .continuous))
            .background(
                GeometryReader { geo in
                    Color.clear.preference(key: TabFramesKey.self,
                                           value: [widget.hitID: geo.frame(in: .named(TabBarView.space))])
                }
            )
    }
}

/// 悬停底：指针一进来立刻亮（不加动画），拖标签时不亮
struct WidgetHover: ViewModifier {
    @ObservedObject var catalog: AppCatalog
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .background {
                if hovering && catalog.pointerOverBar && catalog.drag == nil { GlassPill(kind: .hover) }
            }
            .onHover { hovering = $0 }
    }
}

extension View {
    func widgetHover(_ catalog: AppCatalog) -> some View { modifier(WidgetHover(catalog: catalog)) }
}

/// 按种类分派
struct TaskbarWidgetContent: View {
    let widget: TaskbarWidget
    @ObservedObject var catalog: AppCatalog
    @ObservedObject var prefs: Preferences

    var body: some View {
        switch widget.kind {
        case .nowPlaying:
            NowPlayingWidgetView(widget: widget, catalog: catalog, prefs: prefs)
        case .systemStats:
            placeholder("cpu", "CPU")
        case .folder:
            placeholder("folder", "資料夾")
        }
    }

    private func placeholder(_ symbol: String, _ name: String) -> some View {
        HStack(spacing: TTLayout.s(6)) {
            Image(systemName: symbol)
            if !prefs.iconOnly { Text(name).lineLimit(1) }
        }
        .font(.system(size: TTLayout.font(12), weight: .medium))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .widgetHover(catalog)
    }
}

/// 正在播放：`⏮ │ 封面 + 歌名 + ▶︎ │ ⏭`。中间整块就是播放 / 暂停键（指针一进来立刻亮），
/// 两端各一颗切歌键，各自上报命中区域（先于整颗判断）
struct NowPlayingWidgetView: View {
    let widget: TaskbarWidget
    @ObservedObject var catalog: AppCatalog
    @ObservedObject var prefs: Preferences
    @ObservedObject var nowPlaying = NowPlaying.shared

    private var player: MediaPlayer? { nowPlaying.player ?? prefs.nowPlayingSource.player }
    private var hasTrack: Bool { nowPlaying.track != nil }

    var body: some View {
        HStack(spacing: 0) {
            skipKey("backward.fill", id: widget.prevHitID)
            HStack(spacing: TTLayout.s(6)) {
                cover
                if !prefs.iconOnly {
                    Text(title)
                        .font(.system(size: TTLayout.font(12), weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: TTLayout.s(TaskbarWidgetMetrics.nowPlayingTitleCap), alignment: .leading)
                }
                Image(systemName: nowPlaying.track?.playing == true ? "pause.fill" : "play.fill")
                    .font(.system(size: TTLayout.font(12), weight: .semibold))
                    .frame(width: TTLayout.s(14))
            }
            .padding(.horizontal, TTLayout.s(8))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .widgetHover(catalog)
            .help(help)
            skipKey("forward.fill", id: widget.nextHitID)
        }
        .foregroundStyle(Color.primary)
    }

    private var title: String {
        if let t = nowPlaying.track, !t.title.isEmpty { return t.title }
        return "未在播放"
    }

    private var help: String {
        guard let t = nowPlaying.track else { return player.map { "\($0.title)：未在播放" } ?? "正在播放" }
        return t.artist.isEmpty ? t.title : "\(t.title) — \(t.artist)"
    }

    @ViewBuilder
    private var cover: some View {
        let size = TTLayout.s(prefs.iconOnly ? 36 : 18)
        Group {
            if let art = nowPlaying.artwork {
                Image(nsImage: art).resizable().interpolation(.high).aspectRatio(contentMode: .fill)
            } else if let url = player?.appURL {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().interpolation(.high)
            } else {
                Image(systemName: "music.note").foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: TTLayout.s(prefs.iconOnly ? 8 : 4), style: .continuous))
    }

    /// 切歌键：半个条高宽、整条高；没有曲目时变灰（点了也不动，见 `pressWidget`）
    private func skipKey(_ symbol: String, id: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: TTLayout.font(10), weight: .semibold))
            .frame(width: TTLayout.barHeight / 2, height: TTLayout.barHeight)
            .opacity(hasTrack ? 1 : 0.35)
            .widgetHover(catalog)
            .background(
                GeometryReader { geo in
                    Color.clear.preference(key: TabFramesKey.self,
                                           value: [id: geo.frame(in: .named(TabBarView.space))])
                }
            )
    }
}
