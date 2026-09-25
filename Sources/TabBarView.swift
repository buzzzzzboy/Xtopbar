import SwiftUI
import AppKit

/// 命中区域上报：SwiftUI 坐标系（原点上左）→ 窗口层做点击判定
struct TabFramesKey: PreferenceKey {
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

/// 开始按钮（条最左边）。点击同样由窗口层命中测试处理，
/// 命中区域用保留 id `AppCatalog.startButtonID` 上报。
struct StartButton: View {
    let iconOnly: Bool
    let isOpen: Bool
    var animated: Bool = true

    @State private var hovering = false

    var body: some View {
        Image(systemName: "square.grid.2x2.fill")
            .font(.system(size: TTLayout.font(iconOnly ? 24 : 15), weight: .semibold))
            .foregroundStyle(
                LinearGradient(colors: [Color(red: 0.25, green: 0.62, blue: 1.0),
                                        Color(red: 0.14, green: 0.42, blue: 0.95)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
            )
            .frame(width: TTLayout.s(iconOnly ? 42 : 30), height: TTLayout.s(iconOnly ? 42 : 30))
            .scaleEffect(hovering && !isOpen ? 1.08 : 1.0)
            .background(
                RoundedRectangle(cornerRadius: TTLayout.s(9), style: .continuous)
                    .fill(Color.primary.opacity(isOpen ? 0.18 : (hovering ? 0.10 : 0)))
            )
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .animation(animated ? .easeOut(duration: 0.11) : nil, value: hovering)
            .animation(animated ? .easeOut(duration: 0.11) : nil, value: isOpen)
            .help("开始")
            .padding(.horizontal, TTLayout.s(3))
            .background(
                GeometryReader { geo in
                    Color.clear.preference(
                        key: TabFramesKey.self,
                        value: [AppCatalog.startButtonID: geo.frame(in: .named(TabBarView.space))]
                    )
                }
            )
    }
}

/// 单个 App 标签（纯视觉，点击由窗口层命中测试处理）
struct AppTab: View {
    let entry: AppEntry
    let isActive: Bool
    /// ⌘Tab 会话中被键盘选中的标签：画描边环（和前台蓝底区分开）
    var keyboardSelected: Bool = false
    var animated: Bool = true
    /// Dock 风格：只画大图标 + 运行小圆点，名字放进悬停提示
    var iconOnly: Bool = false
    /// 是否已固定到开始菜单（决定右键菜单写「固定」还是「取消固定」）
    var startPinned: Bool = false
    /// 开始按钮开着才给「固定到开始菜单」（没开始菜单时这一项没有意义）
    var startMenuEnabled: Bool = false
    /// 指针是否还在整条悬浮条上。窗口被 orderOut 时 onHover 可能收不到
    /// false，用外层信号兜底，免得下次唤出时残留高亮
    var barHovered: Bool = true
    var onHoverChange: (Bool) -> Void = { _ in }
    /// 右键菜单动作的去处
    var catalog: AppCatalog?

    @State private var hovering = false

    /// 只在"指针在标签上"且"指针还在条上"时才热
    private var hot: Bool { hovering && barHovered }

    var body: some View {
        Group {
            if iconOnly { dockCell } else { labelCell }
        }
        .background(
            RoundedRectangle(cornerRadius: TTLayout.s(9), style: .continuous)
                .fill(backgroundColor)
        )
        .overlay(
            RoundedRectangle(cornerRadius: TTLayout.s(9), style: .continuous)
                .strokeBorder(Color.accentColor.opacity(isActive ? 0.55 : 0), lineWidth: 1)
        )
        // ⌘Tab 键盘选中环：白色描边 + 阴影，深浅壁纸都看得清
        .overlay(
            RoundedRectangle(cornerRadius: TTLayout.s(9), style: .continuous)
                .strokeBorder(Color.white.opacity(keyboardSelected ? 0.95 : 0), lineWidth: 2)
                .shadow(color: .black.opacity(keyboardSelected ? 0.45 : 0), radius: 2)
                .animation(animated ? .easeOut(duration: 0.10) : nil, value: keyboardSelected)
        )
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
        .help(entry.isRunning ? entry.name : "\(entry.name)（未运行，点击打开）")
        // 右键单个标签：固定 / 隐藏 / 退出。左键被窗口层截走做命中测试，
        // 右键不拦，自然落到 SwiftUI 的 contextMenu 上
        .contextMenu { tabMenu }
        .background(
            GeometryReader { geo in
                Color.clear.preference(
                    key: TabFramesKey.self,
                    value: [entry.id: geo.frame(in: .named(TabBarView.space))]
                )
            }
        )
    }

    /// Dock 风格：大图标 + 下方运行指示点（同 macOS Dock：有点 = 在运行）
    private var dockCell: some View {
        VStack(spacing: TTLayout.s(3)) {
            Image(nsImage: entry.icon)
                .resizable()
                .interpolation(.high)
                .frame(width: TTLayout.s(36), height: TTLayout.s(36))
                // 只缩放图标本身：frame 是固定的，命中区域不受影响
                .scaleEffect(hot && !isActive ? 1.12 : 1.0)
                .animation(animated ? .spring(response: 0.22, dampingFraction: 0.6) : nil, value: hot)
            runningDot(visible: entry.isRunning)
        }
        .padding(.horizontal, TTLayout.s(6))
        .padding(.top, TTLayout.s(5))
        .padding(.bottom, TTLayout.s(2))
    }

    /// 标签风格：图标 + 名称。固定组里没在运行的名字压淡，在运行的底部带小圆点。
    private var labelCell: some View {
        HStack(spacing: TTLayout.s(6)) {
            Image(nsImage: entry.icon)
                .resizable()
                .interpolation(.high)
                .frame(width: TTLayout.s(18), height: TTLayout.s(18))
                // 只缩放图标本身：frame 是固定的，布局不会变，
                // 上报给窗口层的命中区域也就不受影响。
                .scaleEffect(hot && !isActive ? 1.12 : 1.0)
                .animation(animated ? .spring(response: 0.22, dampingFraction: 0.6) : nil, value: hot)
            Text(entry.name)
                // 字重不能跟着 isActive 变：`.semibold` 比 `.medium` 宽 1~2pt，
                // 会经 BarContentWidthKey 传导出去让整条面板宽度抖动。
                // 高亮现在会随指针频繁进出，这个抖动会变得很明显。
                // 选中态改用满不透明度的文字 + 蓝底 + 描边来表达。
                .font(.system(size: TTLayout.font(12), weight: .medium))
                .foregroundStyle(Color.primary.opacity(isActive ? 1.0 : (entry.isRunning ? 0.85 : 0.55)))
                .lineLimit(1)
                .fixedSize()
        }
        .padding(.horizontal, TTLayout.s(9))
        .padding(.vertical, TTLayout.s(6))
        .overlay(alignment: .bottom) {
            if entry.isPinned { runningDot(visible: entry.isRunning).offset(y: TTLayout.s(-1)) }
        }
    }

    private func runningDot(visible: Bool) -> some View {
        Circle()
            .fill(Color.primary.opacity(visible ? 0.75 : 0))
            .frame(width: TTLayout.s(4), height: TTLayout.s(4))
    }

    /// 顶层保持原版的「隐藏此 App / 退出 App」，固定相关的收进「固定」子菜单
    @ViewBuilder
    private var tabMenu: some View {
        if entry.isRunning {
            if !entry.isPinned {
                Button("隐藏此 App") { catalog?.hide(entry) }
            }
            Button("退出 App", role: .destructive) { catalog?.terminate(entry) }
        } else {
            Button("打开") { catalog?.activate(entry) }
        }
        Divider()
        Menu("固定") {
            if entry.isPinned {
                Button("从任务栏取消固定") { catalog?.unpinFromDock(entry.id) }
                Button("向左移") { catalog?.moveDockPin(entry.id, by: -1) }
                Button("向右移") { catalog?.moveDockPin(entry.id, by: 1) }
            } else {
                Button("固定到任务栏") { catalog?.pinToDock(entry) }
            }
            if startMenuEnabled {
                if startPinned {
                    Button("从开始菜单取消固定") { catalog?.unpinFromStart(entry.id) }
                } else {
                    Button("固定到开始菜单") { catalog?.pinToStart(entry) }
                }
            }
        }
    }

    private var backgroundColor: Color {
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

    @ObservedObject var catalog: AppCatalog
    @ObservedObject var prefs: Preferences
    let onHoverChange: (Bool) -> Void

    /// 内容比面板宽：两端加渐隐，暗示"这里还能滚"
    @State private var overflowing = false

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            content
        }
        .frame(width: catalog.barWidth, height: TTLayout.barHeight)
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
        .background(GlassBackdrop(style: prefs.glassStyle, cornerRadius: TTLayout.s(16)))
        .clipShape(RoundedRectangle(cornerRadius: TTLayout.s(16), style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: TTLayout.s(16), style: .continuous)
                .strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.5)
        )
        .contentShape(RoundedRectangle(cornerRadius: TTLayout.s(16), style: .continuous))
        .onHover { inside in
            if catalog.pointerOverBar != inside { catalog.pointerOverBar = inside }
            onHoverChange(inside)
        }
        .contextMenu { menu }
        // 命中区域坐标系：命名在面板尺寸的外层视图上，AppTab 上报的就是
        // 窗口坐标（原点上左），随滚动实时有效，见文件头注释
        .coordinateSpace(name: TabBarView.space)
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
        .onPreferenceChange(TabFramesKey.self) { frames in
            catalog.tabFrames = frames
        }
    }

    private var content: some View {
        HStack(spacing: 0) {
            if prefs.showStartButton {
                StartButton(iconOnly: prefs.iconOnly,
                            isOpen: catalog.startMenuOpen,
                            animated: prefs.animationsEnabled)
                if !catalog.groups.isEmpty { divider }
            }
            ForEach(Array(catalog.groups.enumerated()), id: \.element.id) { index, group in
                if index > 0 { divider }
                ForEach(Array(group.entries.enumerated()), id: \.element.id) { i, entry in
                    // Dock 风格只在组与组之间画线（固定 | 运行中），组内图标之间留白就够了
                    if i > 0, !prefs.iconOnly { divider }
                    AppTab(entry: entry,
                               // 没在运行的固定项 pid = 0，activePID 取不到 0，不会误亮
                               isActive: catalog.pointerOverBar && entry.pid > 0
                                   && entry.pid == catalog.activePID,
                               keyboardSelected: entry.pid > 0 && entry.pid == catalog.keyboardHighlightPID,
                               animated: prefs.animationsEnabled,
                               iconOnly: prefs.iconOnly,
                               startPinned: prefs.startPins.contains { $0.bundleID == entry.id },
                               startMenuEnabled: prefs.showStartButton,
                               barHovered: catalog.pointerOverBar,
                               onHoverChange: { hovering in
                                   if hovering {
                                       catalog.onTabHover?(entry)
                                   } else {
                                       catalog.onTabHoverEnd?()
                                   }
                               },
                               catalog: catalog)
                    .padding(.horizontal, TTLayout.s(1))
                }
            }
        }
        // 12pt：标签自身有 9pt 内边距，最右那个被高亮时底色会一直铺到标签边缘，
        // 8pt 的容器内边距看起来就"贴边"了；12pt 让左右留白在视觉上等宽。
        .padding(.horizontal, TTLayout.s(12))
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

        Button("设置…") { catalog.host?.openSettings() }
        if prefs.showStartButton {
            Button("打开开始菜单") { catalog.host?.toggleStartMenu() }
        }

        Divider()

        Picker("Dock 位置", selection: $prefs.dockEdge) {
            ForEach(DockEdge.allCases) { edge in
                Text(edge.title).tag(edge)
            }
        }
        Toggle("只显示图标", isOn: $prefs.iconOnly)
        Toggle("只显示有窗口的 App", isOn: $prefs.onlyWindowedApps)
        Toggle("不挡窗口", isOn: $prefs.avoidWindows)

        Menu("自动隐藏") {
            ForEach(Preferences.delayOptions, id: \.value) { item in
                Button(item.label) { prefs.hideDelay = item.value }
            }
        }

        Toggle("窗口预览", isOn: $prefs.previewEnabled)
        Toggle("只显示已打开的窗口", isOn: $prefs.hideMinimizedWindows)

        Divider()

        Menu("权限") {
            Button("请求屏幕录制权限") { catalog.host?.requestScreenCapturePermission() }
            Button("请求辅助功能权限") { catalog.host?.requestAccessibilityPermission() }
        }

        Divider()
        Button("刷新列表") { catalog.refresh() }
        Button("退出 Xtopbar") { NSApp.terminate(nil) }
    }
}
