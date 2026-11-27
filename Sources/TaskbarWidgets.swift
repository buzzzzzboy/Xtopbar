import Foundation
import CoreGraphics

/// 工作列小工具（正在播放 / CPU 与内存 / 开始菜单文件夹）的纯逻辑：模型、槽位排列、估宽、清单编辑。
/// 不碰 AppKit，`scripts/test-widgets.sh` 独立编译跑回归。
///
/// 槽位是固定的六个（见设计文档）：
/// `[1] (开始) [2] (搜索) [3] ┃把手┃ [ [4] 标签… [5] ] [6]`
enum TaskbarWidgetSlot: String, Codable, CaseIterable, Identifiable {
    case beforeStart, afterStart, beforeBar, barLeading, barTrailing, afterBar

    var id: String { rawValue }

    var title: String {
        switch self {
        case .beforeStart: return "開始按鈕左邊"
        case .afterStart:  return "開始與搜尋之間"
        case .beforeBar:   return "搜尋右邊"
        case .barLeading:  return "工作列開頭"
        case .barTrailing: return "工作列結尾"
        case .afterBar:    return "工作列右邊"
        }
    }
}

struct TaskbarWidget: Codable, Identifiable, Equatable {
    enum Kind: Codable, Equatable {
        case nowPlaying, systemStats
        /// 指向开始菜单的 `StartFolder.id`
        case folder(UUID)
    }

    var id = UUID()
    var kind: Kind
    var slot: TaskbarWidgetSlot

    /// 窗口层命中测试的保留 id（同 `AppCatalog.startButtonID`）
    var hitID: String { "__widget__\(id.uuidString)" }
    /// 正在播放两端的上一首 / 下一首
    var prevHitID: String { hitID + "__prev" }
    var nextHitID: String { hitID + "__next" }
}

/// 每个槽里实际要画的小工具（已滤掉看不见的），槽内按偏好里的先后
struct WidgetArrangement: Equatable {
    var beforeStart: [TaskbarWidget] = []
    var afterStart: [TaskbarWidget] = []
    var beforeBar: [TaskbarWidget] = []
    var barLeading: [TaskbarWidget] = []
    var barTrailing: [TaskbarWidget] = []
    var afterBar: [TaskbarWidget] = []

    /// - Parameter hasTabs: 条上没有任何 App 标签时条的玻璃不画，条内两端（4、5）挪到条外：
    ///   4 接在 3 后面，5 排在 6 前面
    static func arrange(_ widgets: [TaskbarWidget], isVisible: (TaskbarWidget) -> Bool,
                        hasTabs: Bool) -> WidgetArrangement {
        var a = WidgetArrangement()
        for widget in widgets where isVisible(widget) {
            switch widget.slot {
            case .beforeStart: a.beforeStart.append(widget)
            case .afterStart:  a.afterStart.append(widget)
            case .beforeBar:   a.beforeBar.append(widget)
            case .barLeading:  a.barLeading.append(widget)
            case .barTrailing: a.barTrailing.append(widget)
            case .afterBar:    a.afterBar.append(widget)
            }
        }
        if !hasTabs {
            a.beforeBar += a.barLeading
            a.afterBar = a.barTrailing + a.afterBar
            a.barLeading = []
            a.barTrailing = []
        }
        return a
    }

    var isEmpty: Bool {
        beforeStart.isEmpty && afterStart.isEmpty && beforeBar.isEmpty
            && barLeading.isEmpty && barTrailing.isEmpty && afterBar.isEmpty
    }

    /// 条左边、条外的小工具（槽 1、2、3）
    var leftOuter: [TaskbarWidget] { beforeStart + afterStart + beforeBar }
}

/// 估宽（未缩放的 pt，不含膠囊外的缝）。同 `TaskbarLayout`：一律估，不等 SwiftUI 量回来
enum TaskbarWidgetMetrics {
    /// 正在播放的歌名一律按上限估：换歌不改条宽，不会引发重新合并
    static let nowPlayingTitleCap: CGFloat = 140
    /// 资料夹名称最宽
    static let folderNameCap: CGFloat = 120

    static func width(_ kind: TaskbarWidget.Kind, iconOnly: Bool, barBaseHeight: CGFloat,
                      folderName: String?) -> CGFloat {
        switch kind {
        case .nowPlaying:
            // 两端 ⏮⏭ 各半个条高 + 中间：左右内距 8+8、封面、间距、（歌名）、状态图标
            let ends = (barBaseHeight / 2) * 2
            if iconOnly { return ends + 16 + 36 + 6 + 14 }
            return ends + 16 + 18 + 6 + nowPlayingTitleCap + 6 + 14
        case .systemStats:
            // 两组「标签 + 100% + 迷你横条 24」；只显示图标 = 两条竖条
            return iconOnly ? (barBaseHeight * 0.8).rounded() : 150
        case .folder:
            if iconOnly { return barBaseHeight }
            let chars = CGFloat((folderName?.isEmpty == false ? folderName! : "未命名").count)
            return barBaseHeight + min(chars * 12, folderNameCap) + 8
        }
    }
}

/// 偏好里那份清单的编辑规则：正在播放、CPU／内存各最多一个，一个资料夹最多一个
enum TaskbarWidgetList {
    static func canAdd(_ kind: TaskbarWidget.Kind, to list: [TaskbarWidget]) -> Bool {
        !list.contains { $0.kind == kind }
    }

    /// 移到目标槽的最后
    static func moving(_ id: UUID, to slot: TaskbarWidgetSlot, in list: [TaskbarWidget]) -> [TaskbarWidget] {
        guard let index = list.firstIndex(where: { $0.id == id }) else { return list }
        var copy = list
        var widget = copy.remove(at: index)
        widget.slot = slot
        copy.append(widget)
        return copy
    }

    /// 同槽内上移（-1）/ 下移（+1）：只和同槽的邻居换位，到头不动
    static func shifting(_ id: UUID, by offset: Int, in list: [TaskbarWidget]) -> [TaskbarWidget] {
        guard offset != 0, let index = list.firstIndex(where: { $0.id == id }) else { return list }
        let slot = list[index].slot
        let sameSlot = list.indices.filter { list[$0].slot == slot }
        guard let pos = sameSlot.firstIndex(of: index) else { return list }
        let target = pos + (offset > 0 ? 1 : -1)
        guard sameSlot.indices.contains(target) else { return list }
        var copy = list
        copy.swapAt(index, sameSlot[target])
        return copy
    }

    /// 资料夹在开始菜单里被删掉：对应的小工具一起移除
    static func pruned(_ list: [TaskbarWidget], existingFolders: Set<UUID>) -> [TaskbarWidget] {
        list.filter {
            if case .folder(let id) = $0.kind { return existingFolders.contains(id) }
            return true
        }
    }
}
