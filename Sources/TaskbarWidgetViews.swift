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
