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
        let track = NowPlaying.shared.track
        return TaskbarWidgetMetrics.width(widget.kind, iconOnly: prefs.iconOnly,
                                          barBaseHeight: TTLayout.barBaseHeight, folderName: name,
                                          hasTrack: track != nil,
                                          titleWidth: track.map { nowPlayingTitleWidth($0.title) },
                                          nameWidth: name.map { labelWidth($0.isEmpty ? "未命名" : $0) })
    }

    /// 12pt medium 的字量出来的宽（未缩放），+3 余量同 `nowPlayingTitleWidth`
    static func labelWidth(_ text: String) -> CGFloat {
        let font = NSFont.systemFont(ofSize: 12, weight: .medium)
        return ceil((text as NSString).size(withAttributes: [.font: font]).width) + 3
    }

    /// 歌名在小工具里的宽（未缩放），字体同 `NowPlayingWidgetView`。+3：字号按缩放取半 pt 时
    /// 会比等比例略大（例如 90% 下 10.8 → 11），留一点余量免得刚好量满被截成「…」
    static func nowPlayingTitleWidth(_ title: String) -> CGFloat {
        labelWidth(title.isEmpty ? "未在播放" : title)
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
            SystemStatsWidgetView(catalog: catalog, prefs: prefs)
        case .folder(let id):
            FolderWidgetView(folderID: id, catalog: catalog, prefs: prefs)
        }
    }
}

/// 资料夹：2×2 迷你图标（同开始菜单的资料夹格），标签样式下旁边加名字。不显示数字，和「背景執行」小方块区分
struct FolderWidgetView: View {
    let folderID: UUID
    @ObservedObject var catalog: AppCatalog
    @ObservedObject var prefs: Preferences

    private var folder: StartFolder? { prefs.startFolders.first { $0.id == folderID } }
    private var name: String { folder.map { $0.name.isEmpty ? "未命名" : $0.name } ?? "資料夾" }

    var body: some View {
        let side = TTLayout.barHeight * (prefs.iconOnly ? 0.62 : 0.6)
        let spacing = TTLayout.s(2)
        let icons = (folder.map(FolderWidgetCard.apps(in:)) ?? []).prefix(4).map { AppLibrary.shared.icon(for: $0.url) }
        HStack(spacing: TTLayout.s(6)) {
            FolderIconSquare(icons: Array(icons), mini: (side - spacing * 3) / 2, spacing: spacing,
                             side: side, cornerRadius: TTLayout.s(7))
            if !prefs.iconOnly {
                Text(name)
                    .font(.system(size: TTLayout.font(12), weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .padding(.horizontal, TTLayout.s(prefs.iconOnly ? 0 : 8))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .widgetHover(catalog)
        .help(name)
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
        Group {
            if hasTrack {
                HStack(spacing: 0) {
                    skipKey("backward.fill", id: widget.prevHitID)
                    playArea
                    skipKey("forward.fill", id: widget.nextHitID)
                }
            } else {
                // 没有曲目：缩成「播放器图标 + ▶」一小颗，整颗都是播放键，不画用不到的切歌键
                playArea
            }
        }
        .foregroundStyle(Color.primary)
    }

    /// 中间的播放 / 暂停区：封面 + 歌名 + ▶。整颗的宽度按歌名量出来的宽定（见 `TaskbarWidgets.baseWidth`）
    private var playArea: some View {
        HStack(spacing: TTLayout.s(6)) {
            cover
            if hasTrack && !prefs.iconOnly {
                Text(title)
                    .font(.system(size: TTLayout.font(12), weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Image(systemName: nowPlaying.track?.playing == true ? "pause.fill" : "play.fill")
                .font(.system(size: TTLayout.font(12), weight: .semibold))
                .frame(width: TTLayout.s(14))
        }
        .padding(.horizontal, TTLayout.s(8))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .widgetHover(catalog)
        .help(help)
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
        let size = TTLayout.s(prefs.iconOnly ? (hasTrack ? 36 : 30) : 18)
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

    /// 切歌键：半个条高宽、整条高（只在有曲目时画）
    private func skipKey(_ symbol: String, id: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: TTLayout.font(10), weight: .semibold))
            .frame(width: TTLayout.barHeight / 2, height: TTLayout.barHeight)
            .widgetHover(catalog)
            .background(
                GeometryReader { geo in
                    Color.clear.preference(key: TabFramesKey.self,
                                           value: [id: geo.frame(in: .named(TabBarView.space))])
                }
            )
    }
}

/// CPU／記憶體：标签样式下两组「标签 + 百分比」上排、迷你横条下排；只显示图标样式下两条竖条，数字进悬停提示。
/// 超过 80% 用系统橘，不闪。显示着才取样（onAppear / onDisappear 引用计数）
struct SystemStatsWidgetView: View {
    @ObservedObject var catalog: AppCatalog
    @ObservedObject var prefs: Preferences
    @ObservedObject var stats = SystemStats.shared

    var body: some View {
        Group {
            if prefs.iconOnly {
                HStack(spacing: TTLayout.s(5)) {
                    verticalBar(stats.cpu)
                    verticalBar(stats.memory)
                }
            } else {
                HStack(spacing: TTLayout.s(10)) {
                    group("CPU", stats.cpu)
                    group("記憶體", stats.memory)
                }
                .padding(.horizontal, TTLayout.s(8))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .widgetHover(catalog)
        .help("CPU \(percent(stats.cpu))　記憶體 \(percent(stats.memory))　按一下開啟「活動監視器」")
        .onAppear { stats.retain() }
        .onDisappear { stats.release() }
    }

    private func percent(_ v: Double) -> String { "\(Int((v * 100).rounded()))%" }

    private func tint(_ v: Double) -> Color { v >= SystemStatsMath.warningThreshold ? .orange : .primary }

    private func group(_ label: String, _ value: Double) -> some View {
        VStack(alignment: .leading, spacing: TTLayout.s(3)) {
            HStack(spacing: TTLayout.s(4)) {
                Text(label)
                    .font(.system(size: TTLayout.font(10), weight: .medium))
                    .foregroundStyle(.secondary)
                Text(percent(value))
                    .font(.system(size: TTLayout.font(10.5), weight: .semibold).monospacedDigit())
                    .foregroundStyle(tint(value))
                    // 定宽：数字位数变了整组也不跳
                    .frame(width: TTLayout.s(28), alignment: .trailing)
            }
            Capsule().fill(Color.primary.opacity(0.12))
                .overlay(alignment: .leading) {
                    GeometryReader { geo in
                        Capsule().fill(tint(value).opacity(value >= SystemStatsMath.warningThreshold ? 1 : 0.7))
                            .frame(width: max(geo.size.width * value, TTLayout.s(3)))
                    }
                }
                .frame(height: TTLayout.s(3))
        }
        .fixedSize()
    }

    private func verticalBar(_ value: Double) -> some View {
        let height = TTLayout.s(26)
        return Capsule().fill(Color.primary.opacity(0.12))
            .overlay(alignment: .bottom) {
                Capsule().fill(tint(value).opacity(value >= SystemStatsMath.warningThreshold ? 1 : 0.7))
                    .frame(height: max(height * value, TTLayout.s(4)))
            }
            .frame(width: TTLayout.s(7), height: height)
    }
}

/// 小工具的右键菜单（同标签右键的自绘菜单）：正在播放多一项开启播放器；共用「移到」/ 设定 / 移除
@MainActor
enum TaskbarWidgetMenu {
    static func items(for widget: TaskbarWidget, catalog: AppCatalog) -> [TaskbarMenuItem] {
        var items: [TaskbarMenuItem] = []
        if case .nowPlaying = widget.kind {
            let np = NowPlaying.shared
            if let player = np.player ?? Preferences.shared.nowPlayingSource.player {
                items.append(TaskbarMenuItem(title: "開啟 \(player == .music ? "音樂" : player.title)",
                                             symbol: "arrow.up.forward.app") { np.openPlayer() })
                items.append(.separator)
            }
        }
        let moves = TaskbarWidgetSlot.allCases.map { slot in
            TaskbarMenuItem(title: slot.title, checked: slot == widget.slot) {
                catalog.moveTaskbarWidget(widget.id, to: slot)
            }
        }
        items.append(TaskbarMenuItem(title: "移到", symbol: "arrow.left.arrow.right", children: moves))
        items.append(TaskbarMenuItem(title: "在設定中調整…", symbol: "gearshape") {
            SettingsWindowController.shared.show(page: .dock)
        })
        items.append(.separator)
        items.append(TaskbarMenuItem(title: "從工作列移除", symbol: "minus.circle") {
            catalog.removeTaskbarWidget(widget.id)
        })
        return items
    }
}
