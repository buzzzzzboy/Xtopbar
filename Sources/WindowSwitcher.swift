import AppKit
import SwiftUI
import Combine
import ApplicationServices

/// AX 窗口元素 → 窗口服务器编号。私有但稳定的 HIServices 符号（AltTab / yabai 都靠它），
/// 最小化窗口不在屏上，只有这条路能拿到它确切的 CG 编号（抓缩略图、提窗定位都要用）。
@_silgen_name("_AXUIElementGetWindow")
@discardableResult
private func _AXUIElementGetWindow(_ element: AXUIElement, _ id: inout CGWindowID) -> AXError

// MARK: - 窗口列表

/// 切换器里的一个窗口（值类型，可跨并发域）
struct SwitcherWindow: Identifiable, Sendable, Equatable {
    /// 窗口服务器编号：缩略图像素的来源，也是切过去时最可靠的定位锚点。
    /// 最小化窗口万一拿不到编号，用 `SwitcherWindows.syntheticBase` 起的合成编号（没有缩略图）
    let id: UInt32
    let pid: pid_t
    var title: String
    /// CG 坐标（原点左上），和 AX 的窗口坐标同一个坐标系
    let frame: CGRect
    var isMinimized: Bool = false
}

/// 视窗切换器的取数逻辑：当前桌面在屏的窗口 + 所有最小化的窗口。
///
/// **在屏窗口**正好就是窗口服务器 `optionOnScreenOnly` 给的集合（隐藏的 App、其它桌面上的
/// 都不在里面），而且它的顺序是**前→后的层级**，也就是「最近用过」的顺序 ——
/// Windows Alt+Tab 要的正是这个，不用自己记 MRU。层级列表里会混进辅助表面
/// （输入法候选框、状态气泡、透明遮罩），所以：
/// 1. 同步粗筛：layer 0、不透明、够大、属于普通 App（`.regular`），立刻就能出面板；
/// 2. 异步精筛（`refine`）：拿 AX 窗口列表对一遍，AX 里对不上的表面丢掉，
///    顺便换上 AX 的完整标题（CG 的窗口名常被截断，没有录屏权限时干脆是空的）。
///
/// **最小化窗口**窗口服务器的在屏列表里没有，只能问 AX（`AXMinimized`）。AX 是同步阻塞的、
/// 每个 App 都要问一遍，不能卡在按下 ⌥Tab 的那一刻 —— 所以面板先用上一次问到的结果顶上，
/// `refine` 回来再校正（排在在屏窗口后面，同 Windows）。
enum SwitcherWindows {

    /// 拿不到 CG 编号的最小化窗口用的合成编号起点（与 ScreenCaptureEngine 的约定一致：
    /// `WindowBridge.focusWindow` 见到 ≥ 这个值的编号就不按编号定位）
    static let syntheticBase: UInt32 = 0xF000_0000

    static func onScreen(excluding ownPID: pid_t) -> [SwitcherWindow] {
        let opts: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]] else { return [] }
        var regular: [pid_t: Bool] = [:]
        var out: [SwitcherWindow] = []
        for info in list {
            guard (info[kCGWindowLayer as String] as? Int) == 0,
                  let pid = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                  pid != ownPID,
                  let id = info[kCGWindowNumber as String] as? UInt32,
                  let b = info[kCGWindowBounds as String] as? [String: NSNumber] else { continue }
            let alpha = (info[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1
            guard alpha > 0.01 else { continue }
            let frame = CGRect(x: b["X"]?.doubleValue ?? 0, y: b["Y"]?.doubleValue ?? 0,
                               width: b["Width"]?.doubleValue ?? 0,
                               height: b["Height"]?.doubleValue ?? 0)
            // 同预览的粗筛门槛（ScreenCaptureEngine.looksLikeWindow）
            guard frame.width >= 150, frame.height >= 110 else { continue }
            let isRegular: Bool
            if let known = regular[pid] {
                isRegular = known
            } else {
                isRegular = NSRunningApplication(processIdentifier: pid)?.activationPolicy == .regular
                regular[pid] = isRegular
            }
            guard isRegular else { continue }
            out.append(SwitcherWindow(id: id, pid: pid,
                                      title: info[kCGWindowName as String] as? String ?? "",
                                      frame: frame))
        }
        return out
    }

    /// 要问最小化窗口的 App：普通 App、没被 ⌘H 隐藏、不是自己
    @MainActor
    static func candidatePIDs(excluding ownPID: pid_t) -> [pid_t] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && !$0.isHidden && $0.processIdentifier != ownPID }
            .map(\.processIdentifier)
    }

    struct AXSnap: Sendable {
        let frame: CGRect
        let title: String
        let minimized: Bool
        /// 用户认知里的窗口（role / subrole / 尺寸三重判定，同预览）
        let real: Bool
        /// 窗口服务器编号；私有接口没给就是 nil
        let windowID: UInt32?
    }

    /// AX 精筛在屏窗口 + 重新列一遍最小化窗口。
    ///
    /// 在屏：每个 CG 窗口都要在同一个 App 的**未最小化** AX 窗口里领到一个几何一致的座位
    /// （同几何的多个窗口按个数领，Chrome 多窗口常常完全重叠），领不到的是辅助表面，丢掉。
    /// AX 问不出来（超时 / 没权限）或回空（Electron 系偶发「success + 空数组」）时
    /// 不精筛、原样保留 —— 宁可多一张卡，也不能把真窗口藏掉。
    ///
    /// 最小化：`pids`（按传入顺序）里每个 App 的 AXMinimized 真窗口。
    /// 返回 nil = 没有辅助功能权限，什么都没问。
    static func refine(onScreen windows: [SwitcherWindow],
                       pids candidates: [pid_t]) async -> (visible: [SwitcherWindow], minimized: [SwitcherWindow])? {
        guard AXIsProcessTrusted() else { return nil }
        var pids = candidates
        for win in windows where !pids.contains(win.pid) { pids.append(win.pid) }
        var axByPID: [pid_t: [AXSnap]] = [:]
        await withTaskGroup(of: (pid_t, [AXSnap]?).self) { group in
            for pid in pids { group.addTask { (pid, axWindows(pid)) } }
            for await (pid, list) in group {
                if let list, !list.isEmpty { axByPID[pid] = list }
            }
        }

        let axVisible = axByPID.mapValues { list in list.filter { !$0.minimized } }
        var pools = axVisible
        let visible = windows.compactMap { (win: SwitcherWindow) -> SwitcherWindow? in
            guard axVisible[win.pid]?.isEmpty == false, var pool = pools[win.pid] else { return win }
            guard let index = pool.firstIndex(where: { sameFrame($0.frame, win.frame) }) else {
                TTLog("switcher drop surface pid=\(win.pid) id=\(win.id) frame=\(win.frame)")
                return nil
            }
            let snap = pool.remove(at: index)
            pools[win.pid] = pool
            var out = win
            if !snap.title.isEmpty { out.title = snap.title }
            return out
        }

        var minimized: [SwitcherWindow] = []
        var synthetic = syntheticBase
        for pid in candidates {
            guard let snaps = axByPID[pid] else { continue }
            var offscreen = OffscreenPool(pid: pid)
            for snap in snaps where snap.minimized && snap.real {
                let id: UInt32
                if let known = snap.windowID {
                    id = known
                } else if let matched = offscreen.take(near: snap.frame) {
                    id = matched
                } else {
                    id = synthetic
                    synthetic &+= 1
                }
                minimized.append(SwitcherWindow(id: id, pid: pid, title: snap.title,
                                                frame: snap.frame, isMinimized: true))
            }
        }
        return (visible, minimized)
    }

    /// 一个 App 的 AX 窗口（只要 role = AXWindow 的；nil = 没问出来）
    private static func axWindows(_ pid: pid_t) -> [AXSnap]? {
        // 同一个 App 的 AX 查询必须排队（见 WindowBridge.axGate）
        WindowBridge.axGate(for: pid) {
            let app = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(app, 0.5)
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
                  let list = value as? [AXUIElement] else { return nil }
            return list.compactMap { (win: AXUIElement) -> AXSnap? in
                guard let role = ScreenCaptureEngine.stringAttr(win, kAXRoleAttribute as CFString),
                      role == "AXWindow",
                      let frame = ScreenCaptureEngine.axFrame(of: win) else { return nil }
                let subrole = ScreenCaptureEngine.stringAttr(win, kAXSubroleAttribute as CFString) ?? ""
                var minimizedValue: CFTypeRef?
                AXUIElementCopyAttributeValue(win, kAXMinimizedAttribute as CFString, &minimizedValue)
                let minimized = (minimizedValue as? Bool) ?? (minimizedValue as? NSNumber)?.boolValue ?? false
                var cgID: CGWindowID = 0
                let gotID = _AXUIElementGetWindow(win, &cgID) == .success && cgID != 0
                return AXSnap(frame: frame,
                              title: ScreenCaptureEngine.stringAttr(win, kAXTitleAttribute as CFString) ?? "",
                              minimized: minimized,
                              real: ScreenCaptureEngine.isRealWindow(role: role, subrole: subrole,
                                                                     size: frame.size),
                              windowID: gotID ? cgID : nil)
            }
        }
    }

    /// 私有接口拿不到编号时的兜底：该 pid 不在屏的 layer-0 表面里按几何配一个
    private struct OffscreenPool {
        private var seats: [(id: UInt32, frame: CGRect)]

        init(pid: pid_t) {
            guard let list = CGWindowListCopyWindowInfo(
                [.optionAll, .excludeDesktopElements], kCGNullWindowID
            ) as? [[String: Any]] else {
                seats = []
                return
            }
            seats = list.compactMap { (info: [String: Any]) -> (id: UInt32, frame: CGRect)? in
                guard (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid,
                      (info[kCGWindowLayer as String] as? Int) == 0,
                      (info[kCGWindowIsOnscreen as String] as? Bool) != true,
                      let id = info[kCGWindowNumber as String] as? UInt32,
                      let b = info[kCGWindowBounds as String] as? [String: NSNumber] else { return nil }
                let frame = CGRect(x: b["X"]?.doubleValue ?? 0, y: b["Y"]?.doubleValue ?? 0,
                                   width: b["Width"]?.doubleValue ?? 0,
                                   height: b["Height"]?.doubleValue ?? 0)
                return (id: id, frame: frame)
            }
        }

        mutating func take(near frame: CGRect) -> UInt32? {
            guard let index = seats.firstIndex(where: { SwitcherWindows.sameFrame($0.frame, frame) }) else {
                return nil
            }
            return seats.remove(at: index).id
        }
    }

    fileprivate static func sameFrame(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) <= 8 && abs(a.minY - b.minY) <= 8
            && abs(a.width - b.width) <= 8 && abs(a.height - b.height) <= 8
    }
}

// MARK: - 格状排版（纯运算，可离线核对）

/// 卡片排成几行几列、整体缩到多大。
///
/// 先按原尺寸能塞几列就塞几列，行数随之而定；整块高过可用高度就整体缩小
/// （每次 ×0.9，最小 `minScale`），直到放得下。列数最后按行数**均分**：
/// 7 张卡在一行最多放 6 张的屏上排成 4 + 3，而不是 6 + 1。
struct SwitcherGrid: Equatable {
    let columns: Int
    let rows: Int
    let scale: CGFloat

    static func compute(count: Int, available: CGSize, card: CGSize,
                        spacing: CGFloat, padding: CGFloat,
                        minScale: CGFloat = 0.45) -> SwitcherGrid {
        guard count > 0 else { return SwitcherGrid(columns: 1, rows: 1, scale: 1) }
        var scale: CGFloat = 1
        while true {
            let w = card.width * scale, h = card.height * scale, gap = spacing * scale
            let fit = Int(((available.width - padding * 2 + gap) / (w + gap)).rounded(.down))
            let maxColumns = max(1, min(count, fit))
            let rows = (count + maxColumns - 1) / maxColumns
            let columns = (count + rows - 1) / rows
            let height = padding * 2 + CGFloat(rows) * h + CGFloat(rows - 1) * gap
            if height <= available.height || scale <= minScale {
                return SwitcherGrid(columns: columns, rows: rows, scale: scale)
            }
            scale = max(minScale, scale * 0.9)
        }
    }

    /// 第 `row` 行的卡片下标范围
    func range(row: Int, count: Int) -> Range<Int> {
        let start = min(row * columns, count)
        return start..<min(start + columns, count)
    }
}

/// 键盘移动选中（纯下标运算）
enum SwitcherNav {
    /// 左右 / Tab：走一格，到头绕回
    static func step(_ index: Int, by delta: Int, count: Int) -> Int {
        guard count > 0 else { return 0 }
        return ((index + delta) % count + count) % count
    }

    /// 上下：跳一整行。下一行不够长就落到最后一张；最后一行再往下回到第一行同一列，
    /// 第一行再往上去最后一行同一列（那一列不存在就落到最后一张）。
    static func vertical(_ index: Int, down: Bool, columns: Int, count: Int) -> Int {
        guard count > 0, columns > 0 else { return 0 }
        let rows = (count + columns - 1) / columns
        let column = index % columns
        if down {
            let target = index + columns
            if target < count { return target }
            return index / columns < rows - 1 ? count - 1 : column
        }
        let target = index - columns
        if target >= 0 { return target }
        return min((rows - 1) * columns + column, count - 1)
    }
}

// MARK: - 模型 / 视图

struct SwitcherCard: Identifiable {
    let id: UInt32
    let index: Int
    let title: String
    let icon: NSImage?
    var image: CGImage?
    var isMinimized: Bool = false
}

@MainActor
final class SwitcherModel: ObservableObject {
    @Published var cards: [SwitcherCard] = []
    @Published var selected: Int = 0
    @Published var grid = SwitcherGrid(columns: 1, rows: 1, scale: 1)
}

/// 卡片命中区域上报（key = 卡片下标）
struct SwitcherFramesKey: PreferenceKey {
    static var defaultValue: [Int: CGRect] = [:]
    static func reduce(value: inout [Int: CGRect], nextValue: () -> [Int: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}

/// 布局常量（1.0 档基准 × 界面缩放；格子再整体乘 `SwitcherGrid.scale`）
@MainActor
enum SwitcherLayout {
    private static func s(_ v: CGFloat) -> CGFloat { TTLayout.s(v) }

    static var thumbWidth: CGFloat { s(220) }
    static var thumbHeight: CGFloat { s(138) }
    static var headerHeight: CGFloat { s(18) }
    static var headerGap: CGFloat { s(7) }
    static var cardPadding: CGFloat { s(8) }
    static var spacing: CGFloat { s(8) }
    static var padding: CGFloat { s(16) }

    /// 一张卡片（含内边距）原尺寸
    static var cardSize: CGSize {
        CGSize(width: thumbWidth + cardPadding * 2,
               height: headerHeight + headerGap + thumbHeight + cardPadding * 2)
    }

    /// 缩略图抓取尺寸：卡片尺寸的 2 倍（Retina）
    static var thumbSize: CGSize { CGSize(width: thumbWidth * 2, height: thumbHeight * 2) }

    static func panelSize(_ grid: SwitcherGrid) -> CGSize {
        let card = cardSize
        let gap = spacing * grid.scale
        return CGSize(
            width: padding * 2 + CGFloat(grid.columns) * card.width * grid.scale
                + CGFloat(grid.columns - 1) * gap,
            height: padding * 2 + CGFloat(grid.rows) * card.height * grid.scale
                + CGFloat(grid.rows - 1) * gap)
    }
}

struct SwitcherCardView: View {
    let card: SwitcherCard
    let selected: Bool
    let scale: CGFloat

    var body: some View {
        let radius = TTLayout.s(10) * scale
        VStack(alignment: .leading, spacing: SwitcherLayout.headerGap * scale) {
            HStack(spacing: TTLayout.s(6) * scale) {
                if let icon = card.icon {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: TTLayout.s(16) * scale, height: TTLayout.s(16) * scale)
                }
                Text(card.title)
                    // 字重固定（同预览卡片）：选中只换底色，不让标题宽度跳
                    .font(.system(size: TTLayout.font(11) * scale, weight: .medium))
                    .foregroundStyle(Color.primary.opacity(selected ? 1 : 0.8))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
            }
            .frame(height: SwitcherLayout.headerHeight * scale)

            ZStack {
                RoundedRectangle(cornerRadius: TTLayout.s(6) * scale, style: .continuous)
                    .fill(Color.primary.opacity(0.06))
                if let image = card.image {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .transition(.opacity)
                } else if let icon = card.icon {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: TTLayout.s(48) * scale, height: TTLayout.s(48) * scale)
                        .opacity(0.45)
                }
            }
            .frame(width: SwitcherLayout.thumbWidth * scale, height: SwitcherLayout.thumbHeight * scale)
            .clipShape(RoundedRectangle(cornerRadius: TTLayout.s(6) * scale, style: .continuous))
            .overlay(alignment: .bottomLeading) {
                if card.isMinimized {
                    Text("已最小化")
                        .font(.system(size: TTLayout.font(9) * scale, weight: .medium))
                        .padding(.horizontal, TTLayout.s(5) * scale)
                        .padding(.vertical, TTLayout.s(1.5) * scale)
                        .background(.thinMaterial, in: Capsule())
                        .foregroundStyle(Color.primary.opacity(0.7))
                        .padding(TTLayout.s(5) * scale)
                }
            }
            .animation(.easeOut(duration: 0.14), value: card.image == nil)
        }
        .padding(SwitcherLayout.cardPadding * scale)
        .frame(width: SwitcherLayout.cardSize.width * scale,
               height: SwitcherLayout.cardSize.height * scale,
               alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(selected ? Color.accentColor.opacity(0.22) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(selected ? Color.accentColor.opacity(0.9) : Color.clear, lineWidth: 2)
        )
        // 选中框跟着键盘走要"立刻"，只给极短的颜色过渡
        .animation(.easeOut(duration: 0.08), value: selected)
        .background(
            GeometryReader { geo in
                Color.clear.preference(
                    key: SwitcherFramesKey.self,
                    value: [card.index: geo.frame(in: .named(SwitcherView.space))]
                )
            }
        )
    }
}

struct SwitcherView: View {
    static let space = "xtopbar.switcher"

    @ObservedObject var model: SwitcherModel
    @ObservedObject var prefs: Preferences
    var onCardFrames: ([Int: CGRect]) -> Void

    var body: some View {
        let grid = model.grid
        let size = SwitcherLayout.panelSize(grid)
        VStack(spacing: SwitcherLayout.spacing * grid.scale) {
            ForEach(0..<grid.rows, id: \.self) { row in
                // 最后一行不满时居中（同 Windows Alt+Tab）
                HStack(spacing: SwitcherLayout.spacing * grid.scale) {
                    ForEach(Array(model.cards[grid.range(row: row, count: model.cards.count)])) { card in
                        SwitcherCardView(card: card,
                                         selected: card.index == model.selected,
                                         scale: grid.scale)
                    }
                }
            }
        }
        .padding(SwitcherLayout.padding)
        .frame(width: size.width, height: size.height)
        .background(GlassBackdrop(style: prefs.glassStyle, cornerRadius: TTLayout.s(18)))
        .coordinateSpace(name: SwitcherView.space)
        .onPreferenceChange(SwitcherFramesKey.self) { frames in
            onCardFrames(frames)
        }
    }
}

// MARK: - 控制器

/// ⌥Tab 视窗切换器（Windows Alt+Tab / DockDoor 同款）：
/// 屏幕中央铺开当前桌面所有窗口的缩略图，按住 ⌥ 连按 Tab 选，松开 ⌥ 切过去。
///
/// - 快按快放 = 切回上一个窗口（层级第二个）；⌥⇧Tab 反向
/// - 会话中 ←→ 走一格、↑↓ 跳一行，Return 立刻切，Esc 取消
/// - 鼠标移到哪张卡就选哪张，点一下直接切
///
/// 和悬浮条完全独立：条关着也能用，不受「只显示有視窗的 App」「隱藏此 App」影响。
@MainActor
final class WindowSwitcherController {

    private let prefs = Preferences.shared
    private let engine = ScreenCaptureEngine.shared
    private let tap = WindowSwitcherTap()
    private let model = SwitcherModel()
    private let panel: FloatingPanel
    private var hosting: FirstMouseHostingView<SwitcherView>?
    private var cancellables = Set<AnyCancellable>()

    /// 当前会话的窗口（下标 = 卡片下标）：在屏的在前（层级顺序），最小化的在后
    private var windows: [SwitcherWindow] = []
    /// 上一次 AX 问到的最小化窗口。按下 ⌥Tab 时先拿它顶上（AX 慢，不能现问），
    /// 这次会话的 `refine` 回来再校正并刷新它
    private var minimizedCache: [SwitcherWindow] = []
    private var cardFrames: [Int: CGRect] = [:]
    private var active = false
    /// 会话编号：会话结束 / 重开后，旧会话的异步回包（缩略图、精筛）要能认出来丢掉
    private var session = 0
    /// 面板在哪块屏上居中（会话开始时鼠标所在的屏，期间不跟着漂）
    private var screen: NSScreen?

    /// 延迟上屏：快按快放（≤60ms）直接切，不让面板闪一下
    private var showWork: DispatchWorkItem?
    private var pointerTimer: Timer?
    /// 鼠标真动过才接管选中 —— 面板弹出时指针恰好压在某张卡上，不能把键盘预选的抢走
    private var mouseAtOpen: NSPoint = .zero
    private var mouseMoved = false
    private var lastHovered: Int?
    private var pendingPress: Int?

    /// 开着但钩子没装上（还没有辅助功能权限）：隔几秒再试，授权后不用重启
    private var retryTimer: Timer?

    init() {
        panel = FloatingPanel(contentRect: NSRect(x: 0, y: 0, width: 400, height: 220))
        // 比悬浮条（.statusBar）和它的预览高一层，盖在所有东西上面
        panel.level = .popUpMenu
        panel.hasShadow = true

        let view = SwitcherView(
            model: model,
            prefs: .shared,
            onCardFrames: { [weak self] frames in self?.cardFrames = frames }
        )
        let host = FirstMouseHostingView(rootView: view)
        host.frame = NSRect(origin: .zero, size: panel.frame.size)
        host.autoresizingMask = [.width, .height]
        panel.contentView = host
        hosting = host

        // 两段式点击（同预览）：按下先选中，抬起在同一张卡上才切
        panel.onPress = { [weak self] locationInWindow in
            guard let self, self.active,
                  let index = self.hit(self.viewPoint(fromWindow: locationInWindow)) else { return false }
            self.pendingPress = index
            self.model.selected = index
            return true
        }
        panel.onRelease = { [weak self] locationInWindow in
            guard let self else { return }
            let index = self.hit(self.viewPoint(fromWindow: locationInWindow))
            let pressed = self.pendingPress
            self.pendingPress = nil
            guard let pressed, index == pressed else { return }
            self.commit()
        }

        tap.onActivate = { [weak self] reverse in self?.activate(reverse: reverse) }
        tap.onKey = { [weak self] key in self?.handle(key) }
        tap.onOptionReleased = { [weak self] in self?.commit() }
    }

    func start() {
        prefs.$windowSwitcherEnabled
            .dropFirst()
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] on in
                guard let self, !self.apply(), on else { return }
                // 用户刚打开但钩子装不上：弹回去并提示，别让设置里显示"已开启"
                self.prefs.windowSwitcherEnabled = false
                Self.alertInstallFailed()
            }
            .store(in: &cancellables)
        // 启动时装不上（权限还没给）不弹窗：默认就是开的，首次启动的授权提示由悬浮条负责，
        // 这里只在后台重试，授权后自动生效
        apply()
        // 先把最小化窗口问一遍，第一次按 ⌥Tab 就能列出来
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            self?.refreshMinimizedCache()
        }
    }

    /// 后台重问一遍最小化窗口（不在会话中时用）
    private func refreshMinimizedCache() {
        guard prefs.windowSwitcherEnabled, WindowBridge.isTrusted else { return }
        let pids = SwitcherWindows.candidatePIDs(excluding: getpid())
        Task { [weak self] in
            let result = await Task.detached(priority: .utility) {
                await SwitcherWindows.refine(onScreen: [], pids: pids)
            }.value
            guard let self, let result else { return }
            self.minimizedCache = result.minimized
        }
    }

    /// 缓存里还作数的最小化窗口：App 还在、没被隐藏，而且没有已经回到屏上
    private func cachedMinimized(besides onScreen: [SwitcherWindow]) -> [SwitcherWindow] {
        let live = Set(SwitcherWindows.candidatePIDs(excluding: getpid()))
        let shownIDs = Set(onScreen.map(\.id))
        return minimizedCache.filter { win in
            live.contains(win.pid) && !shownIDs.contains(win.id)
                && !onScreen.contains { $0.pid == win.pid && SwitcherWindows.sameFrame($0.frame, win.frame) }
        }
    }

    /// 开关收敛点。返回 false = 开着但钩子没装上。
    @discardableResult
    private func apply() -> Bool {
        guard prefs.windowSwitcherEnabled else {
            stopRetry()
            end()
            tap.stop()
            return true
        }
        if tap.start() {
            stopRetry()
            return true
        }
        scheduleRetry()
        return false
    }

    private func scheduleRetry() {
        guard retryTimer == nil else { return }
        let timer = Timer(timeInterval: 3.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.prefs.windowSwitcherEnabled else { return }
                guard WindowBridge.isTrusted, self.tap.start() else { return }
                self.stopRetry()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        retryTimer = timer
    }

    private func stopRetry() {
        retryTimer?.invalidate()
        retryTimer = nil
    }

    private static func alertInstallFailed() {
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = "無法開啟 ⌥Tab 視窗切換器"
            alert.informativeText = "安裝鍵盤事件鉤子需要「輔助使用」權限。\n請先在系統設定中勾選 Xtopbar，再回到設定裡重新開啟這個開關。"
            alert.addButton(withTitle: "去授權")
            alert.addButton(withTitle: "取消")
            NSApp.activate(ignoringOtherApps: true)
            if alert.runModal() == .alertFirstButtonReturn {
                WindowBridge.requestAccessibilityPermission()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    WindowBridge.openAccessibilitySettings()
                }
            }
        }
    }

    // MARK: - 会话

    /// 第一次按下 ⌥Tab：列窗口、预选上一个（⌥⇧Tab 预选最后一个）、准备上屏
    private func activate(reverse: Bool) {
        guard prefs.windowSwitcherEnabled else { return }
        if active {
            handle(.tab(reverse: reverse))
            return
        }
        let onScreen = SwitcherWindows.onScreen(excluding: getpid())
        let list = onScreen + cachedMinimized(besides: onScreen)
        TTLog("switcher open \(onScreen.count) on screen + \(list.count - onScreen.count) minimized: "
              + "\(list.map { "\($0.pid):\($0.title)\($0.isMinimized ? "(min)" : "")" })")
        guard !list.isEmpty else {
            // 屏上什么都没有：也许只是缓存还没有最小化窗口，补问一遍，下次就有了
            refreshMinimizedCache()
            return
        }

        session &+= 1
        active = true
        tap.sessionActive = true
        windows = list
        mouseAtOpen = NSEvent.mouseLocation
        mouseMoved = false
        lastHovered = nil
        pendingPress = nil
        screen = NSScreen.screens.first { NSMouseInRect(mouseAtOpen, $0.frame, false) }
            ?? NSScreen.main ?? NSScreen.screens.first
        // 第 0 个是当前最前面的窗口；快按快放要回到的是第 1 个
        model.selected = list.count < 2 ? 0 : (reverse ? list.count - 1 : 1)
        rebuildCards()
        layoutPanel()

        let mySession = session
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.active, self.session == mySession else { return }
            self.panel.alphaValue = 1
            self.panel.orderFrontRegardless()
        }
        showWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06, execute: work)

        startPointerTracking()
        fetchThumbnails(list.map(\.id), session: mySession)
        refine(onScreen: onScreen, session: mySession)
    }

    private func handle(_ key: WindowSwitcherTap.Key) {
        guard active, !windows.isEmpty else { return }
        let count = windows.count
        let columns = model.grid.columns
        switch key {
        case .tab(let reverse):
            model.selected = SwitcherNav.step(model.selected, by: reverse ? -1 : 1, count: count)
        case .left:
            model.selected = SwitcherNav.step(model.selected, by: -1, count: count)
        case .right:
            model.selected = SwitcherNav.step(model.selected, by: 1, count: count)
        case .up:
            model.selected = SwitcherNav.vertical(model.selected, down: false, columns: columns, count: count)
        case .down:
            model.selected = SwitcherNav.vertical(model.selected, down: true, columns: columns, count: count)
        case .commit:
            commit()
        case .cancel:
            end()
        }
    }

    /// 松开 ⌥ / Return / 点卡片：切到选中的窗口
    private func commit() {
        guard active else { return }
        let target = windows.indices.contains(model.selected) ? windows[model.selected] : nil
        end()
        guard let target else { return }
        TTLog("switcher commit pid=\(target.pid) id=\(target.id) title=\"\(target.title)\"")
        // 提窗要等激活重排落地（WindowBridge 里有几百毫秒的等待），挪到后台，别卡住主线程
        Task.detached(priority: .userInitiated) {
            WindowBridge.focusWindow(pid: target.pid, axIndex: nil, frame: target.frame,
                                     title: target.title, cgID: target.id)
        }
    }

    /// 收场：面板立刻消失（键盘动作不做出场动画）
    private func end() {
        guard active else { return }
        active = false
        tap.sessionActive = false
        session &+= 1
        showWork?.cancel()
        showWork = nil
        pointerTimer?.invalidate()
        pointerTimer = nil
        pendingPress = nil
        panel.orderOut(nil)
        windows = []
        model.cards = []
    }

    // MARK: - 呈现

    private func rebuildCards() {
        var images: [UInt32: CGImage] = [:]
        for card in model.cards { if let image = card.image { images[card.id] = image } }
        var apps: [pid_t: (name: String, icon: NSImage?)] = [:]
        model.cards = windows.enumerated().map { (index, win) -> SwitcherCard in
            let app: (name: String, icon: NSImage?)
            if let known = apps[win.pid] {
                app = known
            } else {
                let running = NSRunningApplication(processIdentifier: win.pid)
                let name = running?.bundleURL.flatMap { AppNames.localized(url: $0) }
                    ?? running?.localizedName ?? ""
                app = (name, running?.icon)
                apps[win.pid] = app
            }
            return SwitcherCard(id: win.id,
                                index: index,
                                title: win.title.isEmpty ? app.name : win.title,
                                icon: app.icon,
                                // 缓存里有就先顶上（不管多旧），新图回来再换
                                image: images[win.id] ?? engine.cached(win.id, maxAge: 0),
                                isMinimized: win.isMinimized)
        }
    }

    /// 按卡片数排格子，整块在屏幕可用区居中
    private func layoutPanel() {
        guard let screen = screen ?? NSScreen.screens.first else { return }
        let visible = screen.visibleFrame
        let grid = SwitcherGrid.compute(
            count: windows.count,
            available: CGSize(width: visible.width * 0.92, height: visible.height * 0.88),
            card: SwitcherLayout.cardSize,
            spacing: SwitcherLayout.spacing,
            padding: SwitcherLayout.padding)
        model.grid = grid
        let size = SwitcherLayout.panelSize(grid)
        hosting?.frame = NSRect(origin: .zero, size: size)
        let frame = NSRect(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2,
                           width: size.width, height: size.height).integral
        panel.setFrame(frame, display: true)
    }

    /// 抓缩略图：先把 SC 句柄补齐（有最小化窗口时连不在屏的一起），再每个窗口各抓一张，
    /// 谁先回来先换上。最小化窗口 SC 也抓得到（抓的是最小化前的内容）
    private func fetchThumbnails(_ wanted: [UInt32], session mySession: Int) {
        guard ScreenCaptureEngine.hasPermission else {
            ScreenCaptureEngine.requestPermissionIfNeeded()
            return
        }
        let ids = wanted.filter { $0 < SwitcherWindows.syntheticBase }
        guard !ids.isEmpty else { return }
        let includeOffscreen = windows.contains { $0.isMinimized && ids.contains($0.id) }
        let size = SwitcherLayout.thumbSize
        let engine = self.engine
        Task { [weak self] in
            await engine.adoptWindows(includeOffscreen: includeOffscreen)
            guard let self, self.session == mySession else { return }
            for id in ids where engine.cached(id, maxAge: 1.0) == nil {
                Task { [weak self] in
                    guard let image = await engine.capture(id, maxSize: size) else { return }
                    guard let self, self.session == mySession,
                          let index = self.model.cards.firstIndex(where: { $0.id == id }) else { return }
                    self.model.cards[index].image = image.value
                }
            }
        }
    }

    /// AX 回来后：丢掉辅助表面、换上完整标题、换上这次问到的最小化窗口；
    /// 选中尽量留在原来那个窗口上，新冒出来的卡片补抓缩略图
    private func refine(onScreen: [SwitcherWindow], session mySession: Int) {
        let pids = SwitcherWindows.candidatePIDs(excluding: getpid())
        Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                await SwitcherWindows.refine(onScreen: onScreen, pids: pids)
            }.value
            guard let self, let result else { return }
            self.minimizedCache = result.minimized
            guard self.active, self.session == mySession else { return }
            let fresh = result.visible + result.minimized
            guard fresh != self.windows else { return }
            let selectedID = self.windows.indices.contains(self.model.selected)
                ? self.windows[self.model.selected].id : nil
            guard !fresh.isEmpty else {
                self.end()
                return
            }
            let known = Set(self.windows.map(\.id))
            self.windows = fresh
            self.model.selected = fresh.firstIndex { $0.id == selectedID }
                ?? min(self.model.selected, fresh.count - 1)
            self.rebuildCards()
            self.layoutPanel()
            self.fetchThumbnails(fresh.map(\.id).filter { !known.contains($0) }, session: mySession)
        }
    }

    // MARK: - 鼠标

    private func startPointerTracking() {
        pointerTimer?.invalidate()
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pointerTick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        pointerTimer = timer
    }

    private func pointerTick() {
        guard active else { return }
        // 兜底：漏掉了 ⌥ 松开的事件（安全输入框、钩子被系统临时停用）也要能收场，
        // 否则面板会一直挂着、键盘也一直被吞
        if !CGEventSource.flagsState(.combinedSessionState).contains(.maskAlternate) {
            commit()
            return
        }
        let mouse = NSEvent.mouseLocation
        if !mouseMoved {
            guard hypot(mouse.x - mouseAtOpen.x, mouse.y - mouseAtOpen.y) > 3 else { return }
            mouseMoved = true
        }
        guard panel.isVisible else { return }
        let hovered = hit(viewPoint(fromScreen: mouse))
        // 只在指针换到另一张卡时才改选中：指针停着不动时，键盘照样能走
        guard hovered != lastHovered else { return }
        lastHovered = hovered
        if let hovered { model.selected = hovered }
    }

    private func hit(_ point: NSPoint) -> Int? {
        cardFrames.first { $0.value.contains(point) }?.key
    }

    /// 窗口坐标（原点左下）→ SwiftUI 坐标（原点左上）
    private func viewPoint(fromWindow p: NSPoint) -> NSPoint {
        NSPoint(x: p.x, y: panel.frame.height - p.y)
    }

    /// 屏幕坐标（原点左下）→ SwiftUI 坐标（原点左上）
    private func viewPoint(fromScreen p: NSPoint) -> NSPoint {
        NSPoint(x: p.x - panel.frame.minX, y: panel.frame.maxY - p.y)
    }

    // MARK: - 调试

    /// `--test-switcher`：把格子排版和键盘移动的几组样例写进日志，再列一次当前窗口
    func diagnose() {
        let card = CGSize(width: 236, height: 179)
        for (count, width, height) in [(1, 1470.0, 900.0), (3, 1470.0, 900.0), (7, 1470.0, 900.0),
                                       (12, 1470.0, 900.0), (30, 1470.0, 900.0), (60, 1280.0, 700.0)] {
            let grid = SwitcherGrid.compute(count: count, available: CGSize(width: width, height: height),
                                            card: card, spacing: 8, padding: 16)
            let rows = (0..<grid.rows).map { grid.range(row: $0, count: count).count }
            TTLog("switcher grid n=\(count) in \(Int(width))×\(Int(height)) → "
                  + "\(grid.columns) 列 × \(grid.rows) 行 scale=\(String(format: "%.2f", grid.scale)) 每行 \(rows)")
        }
        // 7 张排成 4 + 3：从 0 一路往下、往上各走几步
        var down: [Int] = [0], up: [Int] = [0]
        for _ in 0..<3 {
            down.append(SwitcherNav.vertical(down.last!, down: true, columns: 4, count: 7))
            up.append(SwitcherNav.vertical(up.last!, down: false, columns: 4, count: 7))
        }
        TTLog("switcher nav 7 張 4 列：↓ \(down)  ↑ \(up)  ← 0→\(SwitcherNav.step(0, by: -1, count: 7))")
        let list = SwitcherWindows.onScreen(excluding: getpid())
        TTLog("switcher 目前桌面 \(list.count) 個視窗：\(list.map { "\($0.pid) \"\($0.title)\" \($0.frame)" })")
        TTLog("switcher 最小化（快取）\(minimizedCache.count) 個：\(minimizedCache.map { "\($0.pid) #\($0.id) \"\($0.title)\"" })")
    }
}
