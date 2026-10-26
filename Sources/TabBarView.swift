import SwiftUI
import AppKit

/// 命中区域上报：SwiftUI 坐标系（原点上左）→ 窗口层做点击判定
struct TabFramesKey: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}

/// 标签在内容坐标系里的位置（Liquid Glass 的药丸按它摆）。
/// 和 TabFramesKey 分开：药丸画在滚动内容里，要跟着内容滚，不能用窗口坐标
struct TabContentFramesKey: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}

/// 内容实测宽度上报：面板宽度按它裁，避免算窄了把最右边的标签切掉
struct BarContentWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// 可视区宽度上报（判断内容是否溢出、要不要画边缘渐隐）
struct BarViewportWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// Liquid Glass 主题的标签底：仿 iOS 26/27 tab bar 选中项底下那颗玻璃药丸。
/// macOS 26 起用系统的 glassEffect（反光、折射、深浅色都由系统画）；
/// 更早的系统画个近似的：半透明胶囊 + 上缘反光。悬停那层很淡，两边都自己画。
struct GlassPill: View {
    enum Kind {
        /// 悬停：很淡的一层
        case hover
        /// 前台 App：灰色药丸
        case selected
        /// 按住：放大成透明的放大镜，边缘一圈反光
        case lens
        /// 被拖着排序：拿在手上，带阴影
        case lifted
    }

    let kind: Kind

    var body: some View {
        Group {
            if #available(macOS 26.0, *), kind != .hover {
                native
            } else {
                drawn
            }
        }
        .shadow(color: .black.opacity(shadow), radius: kind == .lens ? 7 : 5, y: kind == .lens ? 2.5 : 1.5)
        // 只放大药丸本身：它垫在标签背后，标签的 frame / 命中区域不受影响
        .scaleEffect(x: kind == .lens ? 1.08 : 1, y: kind == .lens ? 1.18 : 1)
    }

    /// 系统玻璃：平时 regular（同系统控件的玻璃），按住换成更通透的 clear，像一块放大镜
    @available(macOS 26.0, *)
    private var native: some View {
        Color.clear
            .glassEffect(kind == .lens ? .clear : .regular, in: Capsule(style: .continuous))
    }

    private var drawn: some View {
        Capsule(style: .continuous)
            .fill(fill)
            .overlay(
                // 上缘一道细反光，往下淡掉 —— 玻璃的厚度感就靠它
                Capsule(style: .continuous)
                    .strokeBorder(
                        LinearGradient(colors: [Color.white.opacity(rimTop), Color.white.opacity(rimBottom)],
                                       startPoint: .top, endPoint: .bottom),
                        lineWidth: kind == .lens ? 1 : 0.5
                    )
            )
            .overlay {
                // 放大镜：内侧上亮下暗，像一块凸起来的透镜
                if kind == .lens {
                    Capsule(style: .continuous)
                        .fill(LinearGradient(colors: [Color.white.opacity(0.22), .clear, Color.black.opacity(0.06)],
                                             startPoint: .top, endPoint: .bottom))
                        .padding(1)
                }
            }
    }

    private var fill: Color {
        switch kind {
        case .hover:    return Color.primary.opacity(0.06)
        case .selected: return Color.primary.opacity(0.13)
        case .lens:     return Color.white.opacity(0.10)
        case .lifted:   return Color.primary.opacity(0.16)
        }
    }

    private var rimTop: Double {
        switch kind {
        case .hover:    return 0.35
        case .selected: return 0.5
        case .lens:     return 0.85
        case .lifted:   return 0.5
        }
    }

    private var rimBottom: Double { kind == .lens ? 0.35 : 0 }

    private var shadow: Double {
        switch kind {
        case .lens:   return 0.18
        case .lifted: return 0.22
        default:      return 0
        }
    }
}

/// 开始按钮（条最左边）。点击同样由窗口层命中测试处理，
/// 命中区域用保留 id `AppCatalog.startButtonID` 上报。
struct StartButton: View {
    let iconOnly: Bool
    let isOpen: Bool
    var animated: Bool = true
    var theme: BarTheme = .classic
    /// Liquid Glass：拆出条外，自己一颗圆形玻璃（直径 = 条高），整颗圆都是命中区域
    var detached: Bool = false
    var glassStyle: GlassStyle = .liquid

    @State private var hovering = false

    /// Logo（和 App 图标同一张，Resources/Logo.png）。原图是白色，
    /// 这里当 template 只取形状，颜色跟系统外观走：浅色黑、深色白。
    private static let logo: NSImage? = Bundle.main.image(forResource: "Logo")

    var body: some View {
        Group {
            if let logo = Self.logo {
                Image(nsImage: logo)
                    .renderingMode(.template)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(width: TTLayout.s(iconOnly ? 24 : 17), height: TTLayout.s(iconOnly ? 24 : 17))
                    .foregroundStyle(Color.primary)
            } else {
                Image(systemName: "square.grid.2x2.fill")
                    .font(.system(size: TTLayout.font(iconOnly ? 24 : 15), weight: .semibold))
                    .foregroundStyle(Color.primary)
            }
        }
            .frame(width: TTLayout.s(iconOnly ? 42 : 30), height: TTLayout.s(iconOnly ? 42 : 30))
            .scaleEffect(hovering && !isOpen && theme == .classic ? 1.08 : 1.0)
            .modifier(StartBubble(detached: detached, style: glassStyle, highlight: background))
            .contentShape(detached ? AnyShape(Circle()) : AnyShape(Rectangle()))
            .onHover { hovering = $0 }
            .animation(animated ? .easeOut(duration: 0.11) : nil, value: hovering)
            .animation(animated ? .easeOut(duration: 0.11) : nil, value: isOpen)
            .help("開始")
            .background(
                GeometryReader { geo in
                    Color.clear.preference(
                        key: TabFramesKey.self,
                        value: [AppCatalog.startButtonID: geo.frame(in: .named(TabBarView.space))]
                    )
                }
            )
    }

    @ViewBuilder
    private var background: some View {
        switch theme {
        case .classic:
            RoundedRectangle(cornerRadius: TTLayout.s(9), style: .continuous)
                .fill(Color.primary.opacity(isOpen ? 0.18 : (hovering ? 0.10 : 0)))
        case .liquidGlass:
            if isOpen {
                GlassPill(kind: .selected)
            } else if hovering {
                GlassPill(kind: .hover)
            }
        }
    }
}

/// 开始按钮的外框：在条里左右留 3pt，悬停 / 打开的底只垫在图标那块；
/// 拆出去时垫一颗和条同材质的圆形玻璃，悬停 / 打开的底铺满整颗圆
private struct StartBubble<Highlight: View>: ViewModifier {
    let detached: Bool
    let style: GlassStyle
    let highlight: Highlight

    func body(content: Content) -> some View {
        if detached {
            content
                .frame(width: TTLayout.barHeight, height: TTLayout.barHeight)
                .background { highlight }
                .background(GlassBackdrop(style: style, cornerRadius: TTLayout.barHeight / 2))
                .clipShape(Circle())
                .overlay(Circle().strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.5))
        } else {
            content
                .background { highlight }
                .padding(.horizontal, TTLayout.s(3))
        }
    }
}

/// 开始按钮右边那条分隔线兼「调大小」把手：同系统 Dock 的分隔线，按住上下拖改界面缩放。
/// 线本身照旧 1pt，命中区域铺满整条的高度（拖动由窗口层处理，id `AppCatalog.resizeHandleID`）
struct ResizeHandle: View {
    let iconOnly: Bool
    /// 正在拖：线加深，看得出抓住了
    let active: Bool
    /// 开始按钮拆出去了：把手就是那道缝，平时不画线（缝本身就分开了），指到 / 拖着才浮出来
    var detached: Bool = false

    @State private var hovering = false

    var body: some View {
        Rectangle()
            .fill(Color.primary.opacity(active || hovering ? 0.32 : (detached ? 0 : 0.14)))
            .frame(width: 1, height: TTLayout.s(iconOnly ? 30 : 16))
            .padding(.horizontal, detached ? 0 : TTLayout.s(6))
            .frame(width: detached ? TTLayout.detachedStartGap : nil)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .onHover { inside in
                guard inside != hovering else { return }
                hovering = inside
                // 拖动中指针会跑出把手（条在跟着变大小），这时别把光标换回箭头，松手时再还原
                if inside { NSCursor.resizeUpDown.set() } else if !active { NSCursor.arrow.set() }
            }
            .help("上下拖曳調整大小")
            .background(
                GeometryReader { geo in
                    Color.clear.preference(
                        key: TabFramesKey.self,
                        value: [AppCatalog.resizeHandleID: geo.frame(in: .named(TabBarView.space))]
                    )
                }
            )
    }
}

/// 有字才挂悬停提示
private struct OptionalHelp: ViewModifier {
    let text: String?

    func body(content: Content) -> some View {
        if let text { content.help(text) } else { content }
    }
}

/// 单个 App 标签（纯视觉，左右键都由窗口层命中测试处理；右键菜单见 TaskbarMenu）
struct AppTab: View {
    let entry: AppEntry
    /// 前台 App：蓝底 + 描边（不论指针在不在条上，一眼看出谁在前台）
    let isActive: Bool
    var animated: Bool = true
    /// Dock 风格：只画大图标 + 运行小圆点，名字放进悬停提示
    var iconOnly: Bool = false
    /// 指针是否还在整条悬浮条上。窗口被 orderOut 时 onHover 可能收不到
    /// false，用外层信号兜底，免得下次唤出时残留高亮
    var barHovered: Bool = true
    /// 正被拖动排序：抬起一点（淡底 + 阴影），看得出"拿在手上"
    var dragging: Bool = false
    /// 右键菜单开着：不给悬停提示（系统提示窗口会盖在菜单上）
    var suppressHelp: Bool = false
    /// Liquid Glass 的药丸 / 悬停底不画在标签里，由 TabBarView 统一画一颗、在标签之间滑
    var theme: BarTheme = .classic
    var onHoverChange: (Bool) -> Void = { _ in }

    @State private var hovering = false

    /// 只在"指针在标签上"且"指针还在条上"时才热
    private var hot: Bool { hovering && barHovered }

    var body: some View {
        Group {
            if iconOnly { dockCell } else { labelCell }
        }
        .background { background }
        .overlay {
            if theme == .classic {
                RoundedRectangle(cornerRadius: TTLayout.s(9), style: .continuous)
                    .strokeBorder(Color.accentColor.opacity(isActive ? 0.55 : 0), lineWidth: 1)
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: TTLayout.s(9), style: .continuous))
        .onHover { value in
            hovering = value
            onHoverChange(value)
        }
        // 悬停 / 选中高亮都用颜色渐变过渡，不做整体缩放 ——
        // 缩放会挪动上面上报的命中区域，点边角时会偏。
        // 选中态用短弹簧，切换 App 时高亮块"落"下来的手感更活。
        .animation(animated ? .easeOut(duration: 0.11) : nil, value: hot)
        .animation(animated ? .spring(response: 0.26, dampingFraction: 0.74) : nil, value: isActive)
        // 最小化的视窗按钮整格淡一点（同 Windows：一眼看出哪扇收起来了）
        .opacity(entry.window?.minimized == true ? 0.55 : 1)
        // 右键菜单开着时整个拿掉（给空字符串没用，提示照样弹出来盖在菜单上）
        .modifier(OptionalHelp(text: suppressHelp ? nil : helpText))
        .background(
            GeometryReader { geo in
                Color.clear
                    .preference(key: TabFramesKey.self,
                                value: [entry.id: geo.frame(in: .named(TabBarView.space))])
                    .preference(key: TabContentFramesKey.self,
                                value: [entry.id: geo.frame(in: .named(TabBarView.contentSpace))])
            }
        )
    }

    private var helpText: String {
        guard entry.isRunning else { return "\(entry.name)（未執行，點選開啟）" }
        if let w = entry.window {
            let title = w.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let base = title.isEmpty || title == entry.name ? entry.name : "\(entry.name) — \(title)"
            return base + (w.minimized ? "（已最小化）" : "")
        }
        return entry.displayName + (entry.windowCount >= 2 ? "（\(entry.windowCount) 個視窗）" : "")
    }

    /// Dock 风格：大图标 + 下方运行指示点（同 macOS Dock：有点 = 在运行）
    private var dockCell: some View {
        VStack(spacing: TTLayout.s(3)) {
            Image(nsImage: entry.icon)
                .resizable()
                .interpolation(.high)
                .frame(width: TTLayout.s(36), height: TTLayout.s(36))
                .overlay(alignment: .topTrailing) { windowBadge(size: 16) }
            runningDot(visible: entry.isRunning)
        }
        .padding(.horizontal, TTLayout.s(6))
        .padding(.top, TTLayout.s(5))
        .padding(.bottom, TTLayout.s(2))
    }

    /// 标签风格：图标 + 名称。没在运行的固定项只放图标；不画运行小圆点
    /// （标签模式靠有没有名字就能分辨，小圆点反而像多余的装饰）。
    private var labelCell: some View {
        HStack(spacing: TTLayout.s(6)) {
            Image(nsImage: entry.icon)
                .resizable()
                .interpolation(.high)
                .frame(width: TTLayout.s(18), height: TTLayout.s(18))
                .overlay(alignment: .topTrailing) { windowBadge(size: 12) }
            if let profile = entry.profile, entry.window != nil, showsName {
                profileTag(profile)
            }
            if showsName {
                Text(entry.displayName)
                    // 视窗按钮标题顶到上限才截断（同 Vista）；没顶到就跟其它按钮一样按文字撑开
                    // 字重不能跟着 isActive 变：`.semibold` 比 `.medium` 宽 1~2pt，
                    // 会经 BarContentWidthKey 传导出去让整条面板宽度抖动。
                    // 高亮现在会随指针频繁进出，这个抖动会变得很明显。
                    // 选中态改用满不透明度的文字 + 蓝底 + 描边来表达。
                    .font(.system(size: TTLayout.font(12), weight: .medium))
                    .foregroundStyle(Color.primary.opacity(isActive ? 1.0 : (entry.isRunning ? 0.85 : 0.55)))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .fixedSize(horizontal: !entry.titleTruncated, vertical: false)
            }
        }
        // 只有图标时左右也收成 6pt，和上下一样，成一个方块
        .padding(.horizontal, TTLayout.s(showsName ? 9 : 6))
        .padding(.vertical, TTLayout.s(6))
        // 标题太长的视窗按钮才定宽（截断）；其余按标题实际宽度撑开，跟名字一样长
        .frame(width: entry.titleTruncated ? TTLayout.s(entry.buttonWidth) : nil, alignment: .leading)
    }

    /// 浏览器视窗按钮标题前面的设定档标签：配色同悬停预览卡片上的那个
    private func profileTag(_ profile: BrowserProfiles.WindowProfile) -> some View {
        let (fill, text) = PreviewCard.tagColors(profile)
        return Text(profile.name)
            .font(.system(size: TTLayout.font(9), weight: .semibold))
            .foregroundStyle(text)
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(maxWidth: TTLayout.s(AppCatalog.profileTagMaxText))
            .fixedSize()
            .padding(.horizontal, TTLayout.s(5))
            .padding(.vertical, TTLayout.s(1.5))
            .background(fill, in: Capsule())
            // 和标题之间：HStack 的 6 已经有了，再收一点，标签和标题读起来是一组
            .padding(.trailing, TTLayout.s(-1))
    }

    /// 这块屏上开着 ≥ 2 扇窗口：图标右上角画个数字圆圈（多于 9 扇写 9+）。
    /// 挂在图标的 overlay 上并往外挪半个圆，不占布局，标签宽度和上报的命中区域都不变
    @ViewBuilder
    private func windowBadge(size: CGFloat) -> some View {
        if entry.windowCount >= 2 {
            let d = TTLayout.s(size)
            Text(entry.windowCount > 9 ? "9+" : "\(entry.windowCount)")
                .font(.system(size: TTLayout.font(size * 0.62), weight: .bold).monospacedDigit())
                .foregroundStyle(Color.white)
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, entry.windowCount > 9 ? d * 0.18 : 0)
                .frame(minWidth: d, minHeight: d)
                .background(Capsule().fill(Color.accentColor))
                // 白边把圆圈和图标分开，深浅壁纸上都看得清
                .overlay(Capsule().strokeBorder(Color.white.opacity(0.9), lineWidth: 1))
                .offset(x: d * 0.4, y: -d * 0.35)
                .allowsHitTesting(false)
        }
    }

    /// 固定了但没在运行的 App 只放图标（同 Windows 11 任务栏），名字留在悬停提示里
    private var showsName: Bool { entry.isRunning || !entry.isPinned }

    private func runningDot(visible: Bool) -> some View {
        Circle()
            .fill(Color.primary.opacity(visible ? 0.75 : 0))
            .frame(width: TTLayout.s(4), height: TTLayout.s(4))
    }

    @ViewBuilder
    private var background: some View {
        switch theme {
        case .classic:
            RoundedRectangle(cornerRadius: TTLayout.s(9), style: .continuous)
                .fill(backgroundColor)
                .shadow(color: .black.opacity(dragging ? 0.22 : 0), radius: 5, y: 1.5)
        case .liquidGlass:
            // 拖着的标签自己垫一颗浮起来的，跟手走（共用的药丸拖动中不跟，见 TabBarView.pillLayer）
            if dragging { GlassPill(kind: .lifted) }
        }
    }

    private var backgroundColor: Color {
        if dragging { return Color.primary.opacity(0.16) }
        if isActive { return Color.accentColor.opacity(0.32) }
        if hot { return Color.primary.opacity(0.12) }
        return Color.clear
    }
}

/// 顶栏本体
struct TabBarView: View {
    /// 命中区域上报坐标系：直接上报**窗口坐标**（原点上左）。
    /// 不能用内容坐标系：标签多到横向滚动时，内容坐标系里卡片会跟着滚，
    /// 窗口层的命中区域却停在原地 —— 滚过之后再点边角就切错 App。
    /// 窗口坐标则天然随滚动更新（GeometryReader 每帧重报）。
    static let space = "xtopbar.window"
    /// 滚动内容自己的坐标系：Liquid Glass 的药丸画在内容里，按这个摆
    static let contentSpace = "xtopbar.content"

    @ObservedObject var catalog: AppCatalog
    @ObservedObject var prefs: Preferences
    /// 拖分隔线调大小时只有条跟着这个重算（见 LiveScale）
    @ObservedObject var liveScale = LiveScale.shared
    let onHoverChange: (Bool) -> Void

    /// 内容比面板宽：两端加渐隐，暗示"这里还能滚"
    @State private var overflowing = false

    /// Liquid Glass：各标签在内容里的位置、指针停在哪个标签上
    @State private var contentFrames: [String: CGRect] = [:]
    @State private var hoveredTabID: String?

    private var glass: Bool { prefs.barTheme == .liquidGlass }

    var body: some View {
        HStack(spacing: 0) {
            // Liquid Glass：开始按钮单独一颗圆在条左边，中间的缝是调大小的把手
            if TTLayout.detachedStart {
                StartButton(iconOnly: prefs.iconOnly,
                            isOpen: catalog.startMenuOpen,
                            animated: prefs.animationsEnabled,
                            theme: prefs.barTheme,
                            detached: true,
                            glassStyle: prefs.glassStyle)
                ResizeHandle(iconOnly: prefs.iconOnly, active: catalog.isResizing, detached: true)
            }
            bar
        }
        .frame(width: catalog.barWidth, height: TTLayout.barHeight)
        .onHover { inside in
            if catalog.pointerOverBar != inside { catalog.pointerOverBar = inside }
            onHoverChange(inside)
        }
        .contextMenu { menu }
        // 命中区域坐标系：命名在面板尺寸的外层视图上，AppTab 上报的就是
        // 窗口坐标（原点上左），随滚动实时有效，见文件头注释
        .coordinateSpace(name: TabBarView.space)
        .onPreferenceChange(TabFramesKey.self) { frames in
            catalog.tabFrames = frames
        }
    }

    /// 条本体（标签那段）。开始按钮拆出去时宽度扣掉那颗圆和缝
    private var bar: some View {
        let width = catalog.barWidth - TTLayout.detachedStartWidth
        return ScrollView(.horizontal, showsIndicators: false) {
            // 内容比面板窄时（宽度被最小值兜住）居中，不会只在右边留白
            content
                .frame(minWidth: width)
        }
        .frame(width: width, height: TTLayout.barHeight)
        // 溢出时两端渐隐。顺序很关键：fade 打在滚动内容上并立刻
        // compositingGroup 合成一张图，**之后**才垫玻璃 background ——
        // destinationOut 只咬掉内容，玻璃完好；玻璃反过来垫在前面会被咬穿。
        .overlay {
            HStack(spacing: 0) {
                LinearGradient(colors: [Color.black, .clear],
                               startPoint: .leading, endPoint: .trailing)
                    .frame(width: TTLayout.s(22))
                Spacer(minLength: 0)
                LinearGradient(colors: [.clear, Color.black],
                               startPoint: .leading, endPoint: .trailing)
                    .frame(width: TTLayout.s(22))
            }
            .opacity(overflowing ? 1 : 0)
            .blendMode(.destinationOut)
            // 纯视觉层，绝不能拦点击 —— 它盖在两端标签上，
            // 默认命中测试会把溢出时首尾标签的点击吞掉
            .allowsHitTesting(false)
        }
        .compositingGroup()
        .background(GlassBackdrop(style: prefs.glassStyle, cornerRadius: TTLayout.barCornerRadius))
        .clipShape(RoundedRectangle(cornerRadius: TTLayout.barCornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: TTLayout.barCornerRadius, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.5)
        )
        .contentShape(RoundedRectangle(cornerRadius: TTLayout.barCornerRadius, style: .continuous))
        .background(
            GeometryReader { geo in
                Color.clear.preference(key: BarViewportWidthKey.self, value: geo.size.width)
            }
        )
        .onPreferenceChange(BarViewportWidthKey.self) { width in
            let next = width > 1 && catalog.contentWidth > width + 1
            if next != overflowing {
                withAnimation(.easeOut(duration: 0.15)) { overflowing = next }
            }
        }
    }

    private var content: some View {
        HStack(spacing: 0) {
            if prefs.showStartButton, !TTLayout.detachedStart {
                StartButton(iconOnly: prefs.iconOnly,
                            isOpen: catalog.startMenuOpen,
                            animated: prefs.animationsEnabled,
                            theme: prefs.barTheme)
                if !catalog.groups.isEmpty {
                    ResizeHandle(iconOnly: prefs.iconOnly, active: catalog.isResizing)
                }
            }
            ForEach(Array(catalog.groups.enumerated()), id: \.element.id) { index, group in
                if index > 0 {
                    if prefs.showsGroupDivider {
                        divider
                    } else {
                        Color.clear.frame(width: TTLayout.s(prefs.groupGap))
                    }
                }
                // 拖动排序中：这组的组内分隔线先藏起来，标签让位滑动时不会压着线走
                let reordering = catalog.drag?.groupID == group.id
                ForEach(Array(group.entries.enumerated()), id: \.element.id) { i, entry in
                    // Dock 风格只在组与组之间画线（固定 | 运行中），组内图标之间留白就够了
                    if i > 0, !prefs.iconOnly {
                        if prefs.showsTabDividers {
                            divider.opacity(reordering ? 0 : 1)
                        } else {
                            Color.clear.frame(width: TTLayout.s(prefs.tabGap))
                        }
                    }
                    let dragged = catalog.isDragging(entry.id)
                    AppTab(entry: entry,
                               isActive: isActive(entry),
                               animated: prefs.animationsEnabled,
                               iconOnly: prefs.iconOnly,
                               // 拖动中指针扫过的标签不亮悬停底
                               barHovered: catalog.pointerOverBar && catalog.drag == nil,
                               dragging: dragged,
                               suppressHelp: catalog.tabMenuOpen,
                               theme: prefs.barTheme,
                               onHoverChange: { hovering in
                                   if hovering {
                                       hoveredTabID = entry.id
                                   } else if hoveredTabID == entry.id {
                                       hoveredTabID = nil
                                   }
                                   if hovering {
                                       catalog.onTabHover?(entry)
                                   } else {
                                       catalog.onTabHoverEnd?()
                                   }
                               })
                    .padding(.horizontal, TTLayout.s(1))
                    // 被拖的跟手（不加动画），其它的让位 / 落位用弹簧滑过去
                    .offset(x: catalog.dragOffset(for: entry.id))
                    .zIndex(dragged ? 1 : 0)
                    .animation(dragged || !prefs.animationsEnabled ? nil : TabDrag.settle,
                               value: catalog.dragOffset(for: entry.id))
                }
            }
        }
        // 12pt：标签自身有 9pt 内边距，最右那个被高亮时底色会一直铺到标签边缘，
        // 8pt 的容器内边距看起来就"贴边"了；12pt 让左右留白在视觉上等宽。
        .padding(.horizontal, TTLayout.s(12))
        // 垫在标签底下；和标签量位置用的是同一个坐标系（下面命名），原点对得上
        .background(alignment: .topLeading) { pillLayer }
        .coordinateSpace(name: TabBarView.contentSpace)
        .onPreferenceChange(TabContentFramesKey.self) { frames in
            if glass, frames != contentFrames { contentFrames = frames }
        }
        // 实测内容宽度：比手算的字符宽度准，左右内边距才能真正对称
        .background(
            GeometryReader { geo in
                Color.clear.preference(key: BarContentWidthKey.self, value: geo.size.width)
            }
        )
        .onPreferenceChange(BarContentWidthKey.self) { width in
            catalog.reportContentWidth(width)
        }
    }

    /// 没在运行的固定项 pid = 0，activePID 取不到 0，不会误亮。
    /// 视窗按钮只亮前台 App 最前面那扇
    private func isActive(_ entry: AppEntry) -> Bool {
        entry.pid > 0 && entry.pid == catalog.activePID
            && (entry.window == nil || entry.isFrontWindow)
    }

    /// Liquid Glass 的药丸垫在谁底下：按住的 / 刚点过的标签优先（按下去药丸就过去，
    /// 不用等 App 真的切过来），否则跟着前台 App
    private var pillOwner: String? {
        guard glass else { return nil }
        if catalog.drag == nil, let id = catalog.pressedTabID ?? catalog.releasedTabID {
            return id
        }
        for group in catalog.groups {
            if let hit = group.entries.first(where: isActive) { return hit.id }
        }
        return nil
    }

    /// Liquid Glass：整条只有一颗药丸（和一层悬停底），按量到的标签位置摆，
    /// 换位置时用弹簧滑过去。
    @ViewBuilder
    private var pillLayer: some View {
        if glass {
            // 滑动 / 放大镜是这个主题本身，不跟「進出場動畫」开关走（那个管的是条的出现和收起），
            // 只在系统开了「减少动态效果」时才直接跳
            let animated = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            let lens = catalog.pressedTabID != nil && catalog.drag == nil && pillOwner == catalog.pressedTabID
            ZStack(alignment: .topLeading) {
                if let id = hoveredTabID, id != pillOwner, catalog.pointerOverBar, catalog.drag == nil,
                   let rect = contentFrames[id] {
                    GlassPill(kind: .hover)
                        .frame(width: rect.width, height: rect.height)
                        .offset(x: rect.minX, y: rect.minY)
                        .transition(.opacity)
                        .animation(animated ? .spring(response: 0.3, dampingFraction: 0.8) : nil, value: rect)
                }
                // 拖着的正是前台 App：它自己垫着浮起来的那颗，这颗先收起来
                if let id = pillOwner, !catalog.isDragging(id), let rect = contentFrames[id] {
                    GlassPill(kind: lens ? .lens : .selected)
                        .frame(width: rect.width, height: rect.height)
                        .offset(x: rect.minX, y: rect.minY)
                        .transition(.opacity)
                        // 拖动排序中别的标签在让位，药丸要贴着前台那个走，不能慢半拍
                        .animation(animated && catalog.drag == nil
                                   ? .spring(response: 0.42, dampingFraction: 0.72) : nil, value: rect)
                        // 按住 / 放开：鼓成放大镜再弹回去
                        .animation(animated ? .spring(response: 0.28, dampingFraction: 0.62) : nil, value: lens)
                }
            }
            .animation(animated ? .easeOut(duration: 0.15) : nil, value: hoveredTabID == nil)
            .allowsHitTesting(false)
        }
    }

    /// 每两个标签之间都画同一条深线。
    ///
    /// 之前分「分类边界深线 / 组内淡线」两级，但分类是关键词启发式（见
    /// AppCategory），大多数 App 都落到「其他」，结果后半条几乎没有线，
    /// 看起来像坏了。统一成一种线更整齐，也不会误导用户以为它在表达语义。
    private var divider: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.14))
            .frame(width: 1, height: TTLayout.s(prefs.iconOnly ? 30 : 16))
            .padding(.horizontal, TTLayout.s(6))
    }

    @ViewBuilder
    private var menu: some View {
        Text(catalog.host?.permissionSummary() ?? "")

        Button("設定…") { catalog.host?.openSettings() }
        if prefs.showStartButton {
            Button("開啟開始選單") { catalog.host?.toggleStartMenu() }
        }

        Divider()

        Picker("Dock 位置", selection: $prefs.dockEdge) {
            ForEach(DockEdge.allCases) { edge in
                Text(edge.title).tag(edge)
            }
        }
        Toggle("只顯示圖示", isOn: $prefs.iconOnly)
        if !prefs.iconOnly, !glass {
            Toggle("App 之間的分隔線", isOn: $prefs.tabDividers)
        }
        Picker("工作列按鈕", selection: $prefs.taskbarGrouping) {
            ForEach(TaskbarGrouping.allCases) { mode in
                Text(mode.title).tag(mode)
            }
        }
        Toggle("只顯示有視窗的 App", isOn: $prefs.onlyWindowedApps)
        Toggle("不擋視窗", isOn: $prefs.avoidWindows)
        if NSScreen.screens.count > 1 {
            Toggle("在所有螢幕上顯示", isOn: $prefs.allScreens)
        }

        Menu("自動隱藏") {
            ForEach(Preferences.delayOptions, id: \.value) { item in
                Button(item.label) { prefs.hideDelay = item.value }
            }
        }

        Toggle("視窗預覽", isOn: $prefs.previewEnabled)
        Toggle("只顯示已開啟的視窗", isOn: $prefs.hideMinimizedWindows)

        Divider()

        Menu("權限") {
            Button("請求螢幕錄製權限") { catalog.host?.requestScreenCapturePermission() }
            Button("請求輔助使用權限") { catalog.host?.requestAccessibilityPermission() }
        }

        Divider()
        Button("重新整理列表") { catalog.refresh() }
        Button("結束 Xtopbar") { NSApp.terminate(nil) }
    }
}
