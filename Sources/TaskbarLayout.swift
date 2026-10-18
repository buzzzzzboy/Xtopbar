import CoreGraphics

/// 工作列按钮的展开 / 合并（同 Windows Vista「合併工作列按鈕」）：纯逻辑，不碰 AppKit，
/// `--test-pins` 会打一组样例。
///
/// 输入是 App 层的「格」（一个 App 一格，带着它在这条上的窗口），输出是条上真正画的按钮：
/// - 视窗按钮：一扇窗口一格（`AppEntry.window` 非 nil）
/// - 合并按钮：一个 App 的几扇窗口合成一格（`mergedCount ≥ 2`），点了弹窗口列表
/// - App 按钮：没有窗口的固定项（点了启动）/ 窗口还没查到的 / 「依 App 合併」模式
///
/// 宽度全用估算（不等 SwiftUI 量回来）：视窗按钮是固定宽，App 按钮按名字估。
/// 这样合不合并只取决于条的上限宽度，不会「量完 → 重排 → 再量」来回抖。
enum TaskbarLayout {

    /// 一个 App 在这条上的一格：App 层的 entry + 它落在这块屏上的窗口（按 windowID 排好）
    struct Slot {
        let app: AppEntry
        let windows: [WindowSample]
        /// 这个 App 的合并例外：`.always` 一律合成一格 / `.never` 永远展开。nil = 跟随全局
        var override: TaskbarGrouping? = nil

        init(app: AppEntry, windows: [WindowSample], override: TaskbarGrouping? = nil) {
            self.app = app
            self.windows = windows
            self.override = override == .whenFull ? nil : override
        }
    }

    /// 宽度单位一律是「未缩放的 pt」（调用方把条的上限宽度除以界面缩放再传进来）
    struct Metrics {
        /// 视窗按钮标题最多多宽 / 「永不合併」放不下时最窄缩到多少
        let titleCap: CGFloat
        let minTitleCap: CGFloat
        /// 视窗按钮的宽（不含外边距，下同）：跟着标题长度走，标题宽不超过给定的上限
        let windowButton: (_ button: AppEntry, _ titleCap: CGFloat) -> CGFloat
        /// 每个按钮左右的外边距（合计）
        let buttonPadding: CGFloat
        /// 同组相邻两个按钮之间的东西（分隔线 + 边距）；只显示图标时为 0
        let separator: CGFloat
        /// 组与组之间的分隔线
        let groupDivider: CGFloat
        /// 按钮以外的固定开销：左右内边距、开始按钮、调大小分隔线
        let fixed: CGFloat
        /// App 按钮 / 合并按钮的宽（按名字估）
        let appButton: (AppEntry) -> CGFloat
    }

    /// - Returns: 每组展开后的按钮
    static func expand(_ groups: [[Slot]], grouping: TaskbarGrouping,
                       maxWidth: CGFloat, metrics m: Metrics) -> [[AppEntry]] {
        // 每格的状态：
        // - asApp = 当 App 按钮画（一律合并的例外 / 全局「依 App 合併」下没标永不合并的），同原来的行为
        // - merged = 擠滿时被合成的一格（点了弹窗口列表）。只有 ≥ 2 扇窗口、没标永不合并的格才可能合并
        let asApp = groups.map { $0.map { slot in
            slot.override == .always || (grouping == .always && slot.override != .never)
        } }
        var merged = groups.map { $0.map { _ in false } }
        // 每扇窗口的视窗按钮先做好（标题整理、设定档在这一步认出来），宽度按它们量
        let buttons = groups.map { $0.map { slot in slot.windows.map { slot.app.windowButton($0) } } }

        func width(titleCap cap: CGFloat) -> CGFloat {
            var total = m.fixed
            var groupCount = 0
            for (g, slots) in groups.enumerated() {
                var widths: [CGFloat] = []
                for (i, slot) in slots.enumerated() {
                    if slot.windows.isEmpty || merged[g][i] || asApp[g][i] {
                        widths.append(m.appButton(slot.app))
                    } else {
                        widths.append(contentsOf: buttons[g][i].map { m.windowButton($0, cap) })
                    }
                }
                guard !widths.isEmpty else { continue }
                if groupCount > 0 { total += m.groupDivider }
                groupCount += 1
                total += widths.reduce(0, +) + m.buttonPadding * CGFloat(widths.count)
                    + m.separator * CGFloat(widths.count - 1)
            }
            return total
        }

        var cap = m.titleCap
        switch grouping {
        case .whenFull:
            // 放不下：在还没合并的格里挑窗口最多的合掉（一样多挑条上靠右的），合到放得下为止。
            // 全合完还放不下就交给横向滚动
            while width(titleCap: cap) > maxWidth {
                var pick: (g: Int, i: Int, n: Int)?
                for (g, slots) in groups.enumerated() {
                    for (i, slot) in slots.enumerated()
                    where !merged[g][i] && !asApp[g][i] && slot.override != .never && slot.windows.count >= 2 {
                        if pick == nil || slot.windows.count >= pick!.n { pick = (g, i, slot.windows.count) }
                    }
                }
                guard let pick else { break }
                merged[pick.g][pick.i] = true
            }
        case .never:
            // 放不下：所有视窗按钮的标题上限一起往下压（最窄 minTitleCap），找放得下的最大上限；
            // 压到底还放不下交给横向滚动。短标题本来就没顶到上限，压的是长的那几个
            if width(titleCap: cap) > maxWidth {
                var lo = m.minTitleCap, hi = m.titleCap
                if width(titleCap: lo) > maxWidth {
                    cap = lo
                } else {
                    while hi - lo > 1 {
                        let mid = ((lo + hi) / 2).rounded(.down)
                        if width(titleCap: mid) <= maxWidth { lo = mid } else { hi = mid }
                    }
                    cap = lo
                }
            }
        case .always:
            break
        }

        return groups.enumerated().map { g, slots in
            slots.enumerated().flatMap { i, slot -> [AppEntry] in
                if slot.windows.isEmpty || asApp[g][i] { return [slot.app] }
                if merged[g][i] {
                    var copy = slot.app
                    copy.mergedCount = slot.windows.count
                    copy.windowCount = slot.windows.count
                    copy.windowTitle = nil
                    return [copy]
                }
                return buttons[g][i].map { b in
                    var copy = b
                    copy.buttonWidth = m.windowButton(b, cap)
                    copy.titleTruncated = copy.buttonWidth < m.windowButton(b, .greatestFiniteMagnitude)
                    return copy
                }
            }
        }
    }

    /// 同一个 App 的窗口在条上的先后：按窗口编号（≈ 打开的先后），新窗口接在最后。
    /// 前后次序（AX 顺序）变了不重排 —— 点一下就换位置会点错
    static func ordered(_ windows: [WindowSample]) -> [WindowSample] {
        windows.sorted { $0.windowID < $1.windowID }
    }
}
