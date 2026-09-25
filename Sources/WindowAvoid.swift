import AppKit

/// 「不挡窗口」的纯几何：窗口要怎么挪 / 缩，才不压到条上。
///
/// 全部用 CG / AX 的全局坐标（原点在主屏左上，y 向下），和 AX 读写窗口位置同一套，
/// 不用来回翻转。纯函数，不碰 AX，`--test-pins` 会打一组样例。
enum AvoidGeometry {

    /// 窗口压到条了就返回挪开后的 frame，不需要动（或者不该动）就返回 nil。
    ///
    /// - bar: 条停靠时的 frame（常驻位置，不是 ⌘Tab 弹在鼠标处的那个）
    /// - gap: 窗口和条之间留的缝（跟条离屏幕边的距离一样）
    ///
    /// 只管「边缘落在条那一侧的带状区域里」的窗口 —— 也就是贴着屏幕边铺开 / 放大的那种。
    /// 被用户故意拖出屏幕外的、整个窗口都缩在带子里的，一律不碰；
    /// 左右跟条错开的窗口本来就没被挡，也不碰。
    static func adjusted(window w: CGRect, bar: CGRect, gap: CGFloat, edge: DockEdge,
                         screen: CGRect, visible: CGRect) -> CGRect? {
        guard w.maxX > bar.minX, w.minX < bar.maxX, w.intersects(screen) else { return nil }

        switch edge {
        case .bottom:
            let limit = bar.minY - gap                 // 窗口底边最多到这里
            guard w.maxY > limit + 0.5,                // 压到了
                  w.maxY <= screen.maxY + 1,           // 不是被拖出屏幕底边的
                  w.minY < limit else { return nil }   // 不是整个缩在带子里的
            let shift = w.maxY - limit
            // 先整体上移；顶到可用区上沿（菜单栏下方）还不够，就把高度压短
            let top = max(w.minY - shift, min(w.minY, visible.minY))
            let height = limit - top
            guard height >= 120 else { return nil }
            return CGRect(x: w.minX, y: top, width: w.width, height: height)

        case .top:
            let limit = bar.maxY + gap                 // 窗口顶边至少从这里开始
            guard w.minY < limit - 0.5,
                  w.minY >= visible.minY - 1,          // 菜单栏下方开始的正常窗口
                  w.maxY > limit else { return nil }
            let shift = limit - w.minY
            // 整体下移；超出可用区下沿就把高度压短（原本就伸到下沿以外的，保持原来的底边）
            let bottom = min(w.maxY + shift, max(w.maxY, visible.maxY))
            let height = bottom - limit
            guard height >= 120 else { return nil }
            return CGRect(x: w.minX, y: limit, width: w.width, height: height)
        }
    }

    /// NSScreen 坐标（原点左下）→ CG 全局坐标（原点主屏左上）
    @MainActor static func cgRect(_ r: NSRect) -> CGRect {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? r.maxY
        return CGRect(x: r.minX, y: primaryHeight - r.maxY, width: r.width, height: r.height)
    }

    // MARK: - 拒绝改尺寸的窗口

    /// 有最小尺寸 / 不接受外部改尺寸的窗口：改了也原样弹回。记下弹回后的几何，
    /// 一段时间内不再对同一个几何动手，免得每一轮巡检都跟它较劲（窗口会一直抖）。
    private static let lock = NSLock()
    private static var refused: [String: Date] = [:]
    private static let refuseTTL: TimeInterval = 15

    private static func key(pid: pid_t, frame: CGRect) -> String {
        "\(pid):\(Int(frame.minX)),\(Int(frame.minY)),\(Int(frame.width)),\(Int(frame.height))"
    }

    static func noteRefused(pid: pid_t, frame: CGRect) {
        lock.lock(); defer { lock.unlock() }
        refused[key(pid: pid, frame: frame)] = Date()
        if refused.count > 64 {
            let now = Date()
            refused = refused.filter { now.timeIntervalSince($0.value) < refuseTTL }
        }
    }

    static func recentlyRefused(pid: pid_t, frame: CGRect) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let at = refused[key(pid: pid, frame: frame)] else { return false }
        return Date().timeIntervalSince(at) < refuseTTL
    }
}
