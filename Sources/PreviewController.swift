import AppKit
import SwiftUI
import CoreGraphics

struct PreviewItem: Identifiable {
    let id: UInt32
    let index: Int
    let title: String
    let frame: CGRect
    let isMinimized: Bool
    let image: CGImage?
}

/// 指针落在哪张卡的哪个部位
struct PreviewSpot: Equatable {
    let index: Int
    /// true = 关闭按钮，false = 卡片本体
    let onClose: Bool
}

/// 关闭按钮的命中区域上报（和卡片的 key 都是卡片下标）
struct PreviewCloseFramesKey: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}

@MainActor
final class PreviewModel: ObservableObject {
    @Published var appName: String = ""
    @Published var icon: NSImage?
    @Published var items: [PreviewItem] = []
    @Published var hint: String = ""
    /// 每次重新拉取窗口就 +1：视图据此重播一次入场"弹一下"的小动效
    @Published var generation: Int = 0

    // MARK: 交互态
    /// 指针悬停的卡片 / 关闭按钮
    @Published var hovered: PreviewSpot?
    /// 正在按下的卡片（按下只给反馈，抬起才执行）
    @Published var pressed: PreviewSpot?
    /// 刚点中、正在回弹确认的卡片
    @Published var confirmed: Int?

    func clearInteraction() {
        hovered = nil
        pressed = nil
        confirmed = nil
    }
}

struct PreviewCard: View {
    let item: PreviewItem
    let icon: NSImage?
    /// 入场错峰用（第几张卡片），只影响动画延迟，不影响布局
    var appearIndex: Int = 0

    /// 指针在这张卡上
    var hovered: Bool = false
    /// 正在按下
    var pressed: Bool = false
    /// 刚被点中（回弹确认）
    var confirmed: Bool = false
    /// 指针在关闭按钮上
    var closeHovered: Bool = false
    /// 是否提供关闭按钮。没辅助功能权限就关不掉，别给个按了没反应的按钮
    var canClose: Bool = false

    @State private var shown = false

    /// 指针在这张卡的任何部位（含关闭按钮）
    private var hot: Bool { hovered || pressed }

    var body: some View {
        VStack(spacing: TTLayout.s(5)) {
            ZStack {
                RoundedRectangle(cornerRadius: TTLayout.s(8), style: .continuous)
                    .fill(Color.primary.opacity(hot ? 0.13 : 0.07))
                if let image = item.image {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .padding(TTLayout.s(2))
                        .transition(.opacity)
                } else if let icon {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: TTLayout.s(34), height: TTLayout.s(34))
                        .opacity(0.35)
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .frame(width: PreviewLayout.cardWidth, height: PreviewLayout.imageHeight)
            .clipShape(RoundedRectangle(cornerRadius: TTLayout.s(8), style: .continuous))
            // 缩略图后到时淡入，避免"啪"地一下替换掉图标占位
            .animation(.easeOut(duration: 0.14), value: item.image == nil)
            .overlay(alignment: .bottomLeading) {
                if item.isMinimized {
                    Text("已最小化")
                        .font(.system(size: TTLayout.font(9), weight: .medium))
                        .padding(.horizontal, TTLayout.s(5)).padding(.vertical, TTLayout.s(1.5))
                        .background(.thinMaterial, in: Capsule())
                        .foregroundStyle(Color.primary.opacity(0.7))
                        .padding(TTLayout.s(5))
                }
            }
            // 选中环：悬停细环，按下加粗，确认时最亮
            .overlay(
                RoundedRectangle(cornerRadius: TTLayout.s(8), style: .continuous)
                    .strokeBorder(borderColor, lineWidth: borderWidth)
            )
            .overlay(alignment: .topLeading) {
                if canClose { closeButton }
            }
            // 缩放只作用在缩略图本身：卡片外框始终是 1:1，
            // 这样窗口层拿到的命中区域在整个入场动画期间都是准的。
            .scaleEffect(shown ? 1 : 0.94, anchor: .top)
            // "按下去"的反馈：幅度很小、曲线是 easeOut 不是弹簧。
            // 弹簧在这种高频交互里会拖出尾巴，看着"黏"；干脆的动作要短、要停得住。
            // 点中之后不再弹回来（原来会放大到 1.035），只留边框闪一下。
            .scaleEffect(pressed ? 0.975 : 1)
            // 悬停时浮起来一层，比只换边框更有"够得到"的感觉
            .shadow(color: .black.opacity(pressed ? 0.04 : (hot ? 0.16 : 0)),
                    radius: hot ? 6 : 0, y: hot ? 2 : 0)
            .animation(.easeOut(duration: 0.1), value: pressed)
            .animation(.easeOut(duration: 0.12), value: hovered)

            Text(item.title)
                // 字重固定：semibold 会让标题宽 1~2pt，截断位置跟着跳，
                // 鼠标在几张卡之间扫过时看得见抖动。选中感交给不透明度 + 颜色。
                .font(.system(size: TTLayout.font(10), weight: .medium))
                .foregroundStyle(hot ? Color.primary : Color.primary.opacity(0.7))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: PreviewLayout.cardWidth)
                .animation(.easeOut(duration: 0.1), value: hot)
        }
        .opacity(shown ? 1 : 0)
        .background(
            GeometryReader { geo in
                Color.clear.preference(
                    key: TabFramesKey.self,
                    value: [String(item.index): geo.frame(in: .named(PreviewView.space))]
                )
            }
        )
        .onAppear {
            // 错峰只留一点点：0.018s × 下标。原来 0.035 的错峰加上弹簧尾巴，
            // 最后一张卡要 ~0.4s 才站定，扫过去像在等它。
            withAnimation(.easeOut(duration: 0.13)
                .delay(Double(appearIndex) * 0.018)) {
                shown = true
            }
        }
    }

    /// 左上角关闭按钮。动作在窗口层处理（SwiftUI 手势在非激活浮窗里命中不稳），
    /// 这里只负责画和上报命中区域。
    private var closeButton: some View {
        ZStack {
            Circle()
                .fill(closeHovered ? Color.red : Color.black.opacity(0.45))
            Image(systemName: "xmark")
                .font(.system(size: TTLayout.font(8), weight: .heavy))
                .foregroundStyle(.white)
        }
        .frame(width: TTLayout.s(17), height: TTLayout.s(17))
        .overlay(Circle().strokeBorder(Color.white.opacity(0.5), lineWidth: 0.5))
        .contentShape(Circle())
        .background(
            GeometryReader { geo in
                Color.clear.preference(
                    key: PreviewCloseFramesKey.self,
                    value: [String(item.index): geo.frame(in: .named(PreviewView.space))]
                )
            }
        )
        .padding(TTLayout.s(6))
        // 悬停 / 按下卡片时才浮现，平时不挡缩略图
        .opacity(hot ? 1 : 0)
        .animation(.easeOut(duration: 0.12), value: hot)
    }

    private var borderColor: Color {
        if confirmed { return Color.accentColor.opacity(0.95) }
        if pressed { return Color.accentColor.opacity(0.85) }
        if hot { return Color.accentColor.opacity(0.5) }
        return Color.primary.opacity(0.12)
    }

    private var borderWidth: CGFloat {
        if pressed || confirmed { return 1.8 }
        if hot { return 1.2 }
        return 0.5
    }
}

/// 预览面板的布局常量。全部是"1.0 档"的基准值，实际值乘界面缩放。
/// 缩放乘在布局常量上而不是套 scaleEffect：卡片的命中区域由 GeometryReader
/// 上报给窗口层做点击判定，渲染变换不会改变上报值，点了会偏。
@MainActor
enum PreviewLayout {
    private static func s(_ v: CGFloat) -> CGFloat { TTLayout.s(v) }

    static var cardWidth: CGFloat { s(186) }
    static var imageHeight: CGFloat { s(116) }
    static var spacing: CGFloat { s(9) }
    static var padding: CGFloat { s(11) }
    static let maxCards = 5

    /// 缩略图抓取尺寸：卡片尺寸的 2 倍（Retina）
    static var thumbSize: CGSize {
        CGSize(width: cardWidth * 2, height: imageHeight * 2)
    }
}

struct PreviewView: View {
    static let space = "toptab.preview"

    @ObservedObject var model: PreviewModel
    @ObservedObject var prefs: Preferences
    var onCardFrames: ([String: CGRect]) -> Void
    var onCloseFrames: ([String: CGRect]) -> Void

    /// 整块预览的入场弹性（锚在顶部，跟"从主面板下方落下"的方向一致）
    @State private var popped = true

    private var visibleItems: [PreviewItem] { Array(model.items.prefix(PreviewLayout.maxCards)) }
    private var overflow: Int { max(0, model.items.count - PreviewLayout.maxCards) }

    private var computedSize: CGSize {
        PreviewView.size(for: model.items.count,
                         hasOverflow: overflow > 0,
                         hint: model.hint)
    }

    /// 面板尺寸。
    ///
    /// 没有窗口的 App 根本不弹预览（`PreviewController.show` 里直接 return），
    /// 所以这里只需要算「有卡片」的尺寸；hint 是卡片下方那行橙色提示的高度。
    /// 内部常量一律走 PreviewLayout（已含界面缩放）。
    static func size(for itemCount: Int, hasOverflow: Bool, hint: String) -> CGSize {
        let n = max(1, min(itemCount, PreviewLayout.maxCards))
        let cards = CGFloat(n) * PreviewLayout.cardWidth + CGFloat(n - 1) * PreviewLayout.spacing
        let overflowWidth: CGFloat = hasOverflow ? TTLayout.s(74) : 0
        let hintHeight: CGFloat = hint.isEmpty ? 0 : TTLayout.s(18)

        let contentWidth = cards + overflowWidth
        return CGSize(width: PreviewLayout.padding * 2 + contentWidth,
                      height: PreviewLayout.padding * 2 + TTLayout.s(16) + TTLayout.s(6)
                              + PreviewLayout.imageHeight + TTLayout.s(5) + TTLayout.s(14) + hintHeight)
    }

    var body: some View {
        cardList
            .padding(PreviewLayout.padding)
            .frame(width: computedSize.width, height: computedSize.height, alignment: .topLeading)
            .background(GlassBackdrop(style: prefs.glassStyle, cornerRadius: TTLayout.s(14)))
            .coordinateSpace(name: PreviewView.space)
            // 弹性入场退成"几乎察觉不到的托一下"：原来 0.96 + 弹簧回弹，
            // 每次换标签都先缩一下再弹起来，扫标签时反而显得拖沓。
            .scaleEffect(popped ? 1 : 0.99, anchor: .top)
            .onChange(of: model.generation) { _, _ in
                popped = false
                DispatchQueue.main.async {
                    withAnimation(.easeOut(duration: 0.12)) { popped = true }
                }
            }
            .onPreferenceChange(TabFramesKey.self) { frames in
                onCardFrames(frames)
            }
            .onPreferenceChange(PreviewCloseFramesKey.self) { frames in
                onCloseFrames(frames)
            }
    }

    private var cardList: some View {
        VStack(alignment: .leading, spacing: TTLayout.s(6)) {
            HStack(spacing: TTLayout.s(5)) {
                if let icon = model.icon {
                    Image(nsImage: icon).resizable().frame(width: TTLayout.s(14), height: TTLayout.s(14))
                }
                Text(model.appName)
                    .font(.system(size: TTLayout.font(11), weight: .semibold))
                    .lineLimit(1)
                Spacer(minLength: 0)
                if model.items.count > 1 {
                    Text("\(model.items.count) 个窗口")
                        .font(.system(size: TTLayout.font(10)))
                        .foregroundStyle(Color.primary.opacity(0.55))
                }
            }
            .padding(.horizontal, TTLayout.s(2))

            HStack(spacing: PreviewLayout.spacing) {
                ForEach(Array(visibleItems.enumerated()), id: \.element.id) { offset, item in
                    PreviewCard(item: item,
                                icon: model.icon,
                                appearIndex: offset,
                                hovered: model.hovered?.index == offset,
                                pressed: model.pressed?.index == offset,
                                confirmed: model.confirmed == offset,
                                closeHovered: model.hovered?.index == offset
                                                && model.hovered?.onClose == true,
                                canClose: WindowBridge.isTrusted)
                }
                if overflow > 0 {
                    VStack {
                        Text("+\(overflow)")
                            .font(.system(size: TTLayout.font(13), weight: .semibold))
                        Text("更多")
                            .font(.system(size: TTLayout.font(9)))
                    }
                    .foregroundStyle(Color.primary.opacity(0.6))
                    .frame(width: TTLayout.s(64), height: PreviewLayout.imageHeight)
                    .background(
                        RoundedRectangle(cornerRadius: TTLayout.s(8), style: .continuous)
                            .fill(Color.primary.opacity(0.06))
                    )
                }
            }

            if !model.hint.isEmpty, !visibleItems.isEmpty {
                Text(model.hint)
                    .font(.system(size: TTLayout.font(10)))
                    .foregroundStyle(Color.orange.opacity(0.9))
                    .padding(.horizontal, TTLayout.s(2))
            }
        }
    }
}

/// 预览浮层：主面板下方弹出的窗口缩略图条
@MainActor
final class PreviewController {

    private let engine = ScreenCaptureEngine.shared
    private let model = PreviewModel()
    private let panel: FloatingPanel
    private var hosting: FirstMouseHostingView<PreviewView>?

    private var cardFrames: [String: CGRect] = [:]
    private var closeFrames: [String: CGRect] = [:]
    private var currentPID: pid_t?
    private var currentWindows: [WindowInfo] = []
    /// 按下但还没抬起的部位：抬起来要落在同一个部位才算点击
    private var pendingPress: PreviewSpot?
    /// 请求令牌：切换标签后旧请求的回包要能识别并丢弃
    private var token = 0

    /// 重新拉取窗口（关闭窗口后用）需要的现场
    private var lastEntry: AppEntry?
    private var lastAnchor: NSRect = .zero
    private var lastMainFrame: NSRect = .zero
    private var lastHideMinimized = false

    var isVisible: Bool { panel.isVisible }
    var frame: NSRect { panel.frame }

    /// 点击缩略图回调
    var onSelectWindow: ((pid_t, WindowInfo) -> Void)?

    init() {
        panel = FloatingPanel(contentRect: NSRect(x: 0, y: 0, width: 420, height: 170))
        panel.level = .statusBar
        panel.hasShadow = true

        let view = PreviewView(
            model: model,
            prefs: .shared,
            onCardFrames: { [weak self] frames in self?.cardFrames = frames },
            onCloseFrames: { [weak self] frames in self?.closeFrames = frames }
        )
        let host = FirstMouseHostingView(rootView: view)
        host.frame = NSRect(origin: .zero, size: panel.frame.size)
        host.autoresizingMask = [.width, .height]
        panel.contentView = host
        hosting = host

        // 两段式点击：按下只给反馈，抬起才执行。
        // SwiftUI 手势在非激活浮窗里命中不稳，所以判定还是放在窗口层。
        panel.onPress = { [weak self] locationInWindow in
            guard let self else { return false }
            let spot = self.hit(at: self.viewPoint(fromWindow: locationInWindow))
            self.model.pressed = spot
            self.pendingPress = spot
            // 点在空白处：清掉按压态但不消费这次点击
            return spot != nil
        }
        panel.onRelease = { [weak self] locationInWindow in
            guard let self else { return }
            let spot = self.hit(at: self.viewPoint(fromWindow: locationInWindow))
            let pressed = self.pendingPress
            self.model.pressed = nil
            self.pendingPress = nil
            // 拖出去再松手不算点击
            guard let pressed, spot == pressed else { return }
            self.confirm(pressed)
        }
    }

    // MARK: - 坐标 / 命中

    /// 窗口坐标（原点左下）→ SwiftUI 坐标（原点上左）
    private func viewPoint(fromWindow p: NSPoint) -> NSPoint {
        NSPoint(x: p.x, y: panel.frame.height - p.y)
    }

    /// 屏幕坐标（原点左下）→ SwiftUI 坐标（原点上左）
    private func viewPoint(fromScreen p: NSPoint) -> NSPoint {
        NSPoint(x: p.x - panel.frame.minX, y: panel.frame.maxY - p.y)
    }

    /// 命中优先级：关闭按钮 > 卡片。关闭按钮在卡片内，必须先判它。
    private func hit(at point: NSPoint) -> PreviewSpot? {
        for (key, rect) in closeFrames where rect.insetBy(dx: -2, dy: -2).contains(point) {
            if let index = Int(key) { return PreviewSpot(index: index, onClose: true) }
        }
        for (key, rect) in cardFrames where rect.contains(point) {
            if let index = Int(key) { return PreviewSpot(index: index, onClose: false) }
        }
        return nil
    }

    /// 由主面板的鼠标轮询驱动（10Hz）。
    ///
    /// 不用 SwiftUI `.onHover`：预览是非激活浮窗，onHover 的到达时机不可靠；
    /// 而按下 / 抬起的判定本来就在窗口层，两者共用一套坐标更不容易错位。
    func updatePointer(screenPoint: NSPoint) {
        guard panel.isVisible else { return }
        let spot = hit(at: viewPoint(fromScreen: screenPoint))
        if model.hovered != spot { model.hovered = spot }
    }

    // MARK: - 动作

    private func window(at index: Int) -> WindowInfo? {
        currentWindows.indices.contains(index) ? currentWindows[index] : nil
    }

    /// 点中了：**立刻执行**。
    ///
    /// 早先这里先让卡片弹 0.1 秒再切窗口，看着"有反馈"，代价是每次切换都硬生生
    /// 慢 100ms —— 恰恰是用户说的"不够干脆"。反馈改由视图层的按下态承担
    /// （mouseDown 就变色，松手就切），动作本身松手即发生。
    private func confirm(_ target: PreviewSpot) {
        // 点中后卡片边框闪一下，纯视觉，不参与动作时序
        model.confirmed = target.index
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.14) { [weak self] in
            self?.model.confirmed = nil
        }

        if target.onClose {
            closeWindow(at: target.index)
        } else {
            activateWindow(at: target.index)
        }
    }

    private func activateWindow(at index: Int) {
        guard let pid = currentPID, let win = window(at: index) else { return }
        TTLog("activate idx=\(index) title=\"\(win.title)\" ax=\(String(describing: win.axIndex))")
        onSelectWindow?(pid, win)
    }

    /// 关闭窗口。
    ///
    /// **卡片即点即消失（乐观 UI）**：早先要等「AX 关闭 → 200ms → 全量重枚举 → 重建」
    /// 整条链跑完卡片才走，约 0.6~1 秒 —— 窗口其实早就关了，看着就是"点了没反应"。
    /// 现在按下红叉立刻把卡片摘掉（剩不到 2 张就直接收预览），真正的关闭在后台跑；
    /// 万一没关掉，reload 会把卡片放回来并给提示，账最终还是对得平。
    ///
    /// 真正的关闭走窗口自己的关闭按钮（等价于点红点），不会误关别的窗口。
    /// `WindowBridge.closeWindow` 内部用"窗口数量有没有减少"验过一遍，
    /// 这里再拿窗口服务器做二次确认：幽灵表面（微信挂屏幕外的主界面那类）
    /// 本来就不存在，不该报错吓人。
    private func closeWindow(at index: Int) {
        guard let pid = currentPID, let win = window(at: index) else { return }
        guard WindowBridge.isTrusted else {
            model.hint = "开启「辅助功能」权限后才能关闭窗口"
            return
        }
        TTLog("close idx=\(index) title=\"\(win.title)\" ax=\(String(describing: win.axIndex))")
        let myToken = token
        let target = win
        // 兜底点击是落在屏幕坐标上的，得告诉桥接层哪些矩形是自己面板，
        // 免得红点被预览面板压住时一厢情愿地点进自己的卡片里
        let avoid = [panel.frame, lastMainFrame].map { Self.cgRect($0) }

        // 乐观移除：不等后台结果，先让界面动起来
        removeItem(at: index)
        if model.items.count < 2 { hide() }

        Task { [weak self] in
            let ok = await Task.detached(priority: .userInitiated) {
                WindowBridge.closeWindow(pid: pid, axIndex: target.axIndex,
                                         frame: target.frame, title: target.title,
                                         avoid: avoid)
            }.value
            guard let self else { return }
            // 无论预览还在不在都刷新一遍引擎快照（等关闭动画落地）：
            // 面板已收时也要让缓存里别留着刚关掉的幽灵，下次悬停才干净
            try? await Task.sleep(nanoseconds: 200_000_000)
            await self.engine.refresh(minInterval: 0, pids: [pid])
            guard self.token == myToken, self.currentPID == pid else { return }
            guard !ok else { return }
            // 没关掉：把卡片放回来（引擎刚重枚举过，状态是新的）
            self.reload()
            // 窗口服务器里还在，才叫真的没关掉
            guard WindowBridge.windowExists(pid: pid, frame: target.frame) else { return }
            self.model.hint = "没能关掉这个窗口（App 没有响应关闭请求）"
            TTLog("close failed idx=\(index) title=\"\(target.title)\"")
        }
    }

    /// 摘掉第 `index` 张卡片并把后面的卡片重新编号。
    /// 下标是命中测试的 key，删完必须连续，不然指针会指错卡。
    private func removeItem(at index: Int) {
        guard model.items.indices.contains(index) else { return }
        currentWindows.remove(at: index)
        model.items.remove(at: index)
        for i in index..<model.items.count {
            let old = model.items[i]
            model.items[i] = PreviewItem(id: old.id, index: i, title: old.title,
                                         frame: old.frame, isMinimized: old.isMinimized,
                                         image: old.image)
        }
        // 下标整体左移，旧的悬停/按压态全部作废；鼠标轮询会立刻重建悬停
        model.hovered = nil
        model.pressed = nil
        model.confirmed = nil
    }

    /// 用上次的现场重新枚举并刷新卡片
    private func reload() {
        guard let entry = lastEntry else { return }
        show(for: entry, anchorInScreen: lastAnchor,
             mainPanelFrame: lastMainFrame, hideMinimized: lastHideMinimized)
    }

    /// AppKit 窗口坐标（原点左下）→ CG 屏幕坐标（原点上左）
    private static func cgRect(_ r: NSRect) -> CGRect {
        let height = NSScreen.screens.map(\.frame.maxY).max() ?? NSScreen.main?.frame.height ?? 0
        return CGRect(x: r.minX, y: height - r.maxY, width: r.width, height: r.height)
    }

    // MARK: - 呈现

    func show(for entry: AppEntry,
              anchorInScreen: NSRect,
              mainPanelFrame: NSRect,
              hideMinimized: Bool) {
        token &+= 1
        let myToken = token

        lastEntry = entry
        lastAnchor = anchorInScreen
        lastMainFrame = mainPanelFrame
        lastHideMinimized = hideMinimized

        currentPID = entry.pid
        model.appName = entry.name
        model.icon = entry.icon
        model.hint = ""
        model.clearInteraction()
        model.generation &+= 1

        let all = engine.windows(of: entry.pid)
        let windows = hideMinimized ? all.filter { !$0.isMinimized } : all
        currentWindows = windows

        // 先记一笔再分流：空列表 / 无权限也是有用的信号，不能只在成功路径打日志
        TTLog("preview \(entry.name) raw=\(all.count) shown=\(windows.count) "
              + "perm=\(ScreenCaptureEngine.hasPermission) "
              + "titles=\(all.map(\.title))")

        // 预览只在「多窗口、需要挑选」时才有意义：单窗口的 App 点标签本身就切过去了，
        // 再弹一张预览纯属打扰。窗口数 < 2 一律不弹（空态面板若还在屏上顺手收掉）。
        guard windows.count >= 2 else {
            if panel.isVisible { hide() }
            TTLog("preview \(entry.name) → \(windows.count) 个窗口，不弹")
            return
        }

        // 先用缓存立刻铺满 —— 命中缓存时这里就是「零延迟」
        model.items = windows.enumerated().map { idx, win in
            PreviewItem(id: win.id,
                        index: idx,
                        title: win.title.isEmpty ? "窗口 \(idx + 1)" : win.title,
                        frame: win.frame,
                        isMinimized: win.isMinimized,
                        image: engine.cached(win.id, maxAge: 4.0))
        }

        present(anchorInScreen: anchorInScreen, mainPanelFrame: mainPanelFrame)

        // 多窗口但没辅助功能权限时，点击只能把 App 拉到前台 —— 无法指定具体窗口，
        // 表现出来就是"点哪个都回到第一个窗口"。这里明说一句，别让用户以为是坏的。
        if windows.count > 1, !WindowBridge.isTrusted {
            model.hint = "开启「辅助功能」权限后才能切到指定窗口"
        }

        guard ScreenCaptureEngine.hasPermission else {
            model.hint = "开启「屏幕录制」权限后可显示窗口缩略图"
            ScreenCaptureEngine.requestPermissionIfNeeded()
            return
        }

        fetchMissingThumbnails(windows, token: myToken)
    }

    /// 缺图 / 图过期的卡片并行补抓，谁先回来先更新，不阻塞面板显示
    private func fetchMissingThumbnails(_ windows: [WindowInfo], token myToken: Int) {
        let size = PreviewLayout.thumbSize
        let engine = self.engine
        for (idx, win) in windows.enumerated() where engine.cached(win.id, maxAge: 4.0) == nil {
            Task { [weak self] in
                guard let image = await engine.capture(win.id, maxSize: size) else { return }
                guard let self, self.token == myToken else { return }
                guard self.model.items.indices.contains(idx),
                      self.model.items[idx].id == win.id else { return }
                let old = self.model.items[idx]
                self.model.items[idx] = PreviewItem(id: old.id, index: old.index,
                                                    title: old.title, frame: old.frame,
                                                    isMinimized: old.isMinimized,
                                                    image: image.value)
            }
        }
    }

    func hide() {
        guard panel.isVisible else { return }
        token &+= 1
        currentPID = nil
        currentWindows = []
        pendingPress = nil
        model.clearInteraction()
        // 淡出而不是直接消失
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.11
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.currentPID == nil else { return }
                // 顺序很重要：先把窗口移出屏幕，再复位 alpha。
                // 反过来（先 alpha=1 再 orderOut）中间会有一帧把不透明的面板画出来，
                // 就是"消失时闪一下"的来源。
                self.panel.orderOut(nil)
                self.panel.alphaValue = 1
            }
        }
    }

    private func present(anchorInScreen: NSRect, mainPanelFrame: NSRect) {
        // 以主面板所在屏为准（NSScreen.main 跟着键盘焦点漂，多屏下会夹错边界）
        let screen = NSScreen.screens.first { $0.frame.intersects(mainPanelFrame) }
            ?? NSScreen.main ?? NSScreen.screens[0]
        let size = PreviewView.size(for: model.items.count,
                                    hasOverflow: model.items.count > PreviewLayout.maxCards,
                                    hint: model.hint)
        let visible = screen.visibleFrame

        // 条在上半屏 → 主面板正下方；条停在底部（Dock）→ 主面板正上方
        let upward = DockGeometry.opensUpward(barFrame: mainPanelFrame, visible: visible)
        let target = DockGeometry.popupFrame(size: size, anchorX: anchorInScreen.midX,
                                             alignLeft: false, barFrame: mainPanelFrame,
                                             visible: visible, gap: 8)

        // 内容自适应窗口大小（autoresizingMask 已设），所以先改内容再改窗口
        hosting?.frame = NSRect(origin: .zero, size: size)

        guard panel.isVisible else {
            // 首次出现：淡入 + 从主面板一侧 10pt 处滑出（向下弹就往下滑，向上弹就往上升）
            var start = target
            start.origin.y += upward ? -10 : 10
            panel.alphaValue = 0
            panel.setFrame(start, display: false)
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.18
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().setFrame(target, display: true)
                panel.animator().alphaValue = 1
            }
            return
        }

        // 已在屏上（换标签 / 数量变化）：直接归位，动画交给卡片入场，
        // 免得窗口位移和内容刷新叠在一起看着晃。
        panel.alphaValue = 1
        panel.setFrame(target, display: true)
    }
}
