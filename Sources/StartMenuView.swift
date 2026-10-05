import SwiftUI
import AppKit

/// 开始菜单（Windows 11 同款布局）：
///   搜索框
///   已固定（网格）          所有应用 ›
///   最近使用（两列）
///   ——————————————
///   用户名                    ⚙
///
/// 有搜索词时整块内容换成结果列表（↑↓ 选、回车开，键盘由控制器的事件监听处理）。
struct StartMenuView: View {
    @ObservedObject var model: StartMenuModel
    @ObservedObject var library: AppLibrary
    @ObservedObject var prefs: Preferences
    @ObservedObject var nowPlaying = NowPlaying.shared
    @ObservedObject var presence = WindowPresence.shared
    let catalog: AppCatalog
    let onLaunch: (LibraryApp) -> Void
    let onSettings: () -> Void

    @FocusState var searchFocused: Bool
    @FocusState private var folderNameFocused: Bool

    /// 已固定网格正在拖动的项（nil = 没在拖）
    @State private var pinDrag: PinDrag?
    /// 网格每个格子的位置（按下标，坐标系 `pinSpace`）。按下标而不是按 App 记：
    /// 重排后格子本身不动、只换了内容，布局还没刷新的那一拍里拿到的旧值也不会错
    /// 按网格分开记（首页已固定 / 文件夹弹窗）：弹窗开着时两个网格同时在屏上，
    /// 混在一张表里会互相覆盖
    @State private var pinSlots: [String: [Int: CGRect]] = [:]
    private static let pinSpace = "startPins"

    /// 首页各文件夹格子的位置（坐标系 `homeSpace`），弹窗据此贴着文件夹弹出
    @State private var folderFrames: [UUID: CGRect] = [:]
    /// 文件夹弹窗的实际尺寸（量出来的，用来把弹窗夹在菜单里面）
    @State private var padSize: CGSize = .zero
    private static let homeSpace = "startHome"
    /// 刚在「背景執行」里按了结束的：立刻从列表拿掉，不等下一轮窗口扫描
    @State private var quitting: Set<pid_t> = []

    private struct PinDrag {
        let id: String
        /// 按下点相对格子左上角的偏移：浮起的图标按它跟手，不会一拖就跳到指针中心
        let grab: CGSize
        var location: CGPoint
    }

    /// 拖动让位动画跟系统「减少动态效果」走（不跟条的「進出場動畫」开关）
    private var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    /// 「背景執行」两列
    private var backgroundColumns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: TTLayout.s(8), alignment: .leading), count: 2)
    }

    var body: some View {
        VStack(spacing: 0) {
            searchField
                .padding(.horizontal, TTLayout.s(20))
                .padding(.top, TTLayout.s(18))
                .padding(.bottom, TTLayout.s(10))

            Group {
                if !model.query.isEmpty {
                    searchResults
                } else if model.showAll {
                    allApps
                } else {
                    home
                        .coordinateSpace(name: Self.homeSpace)
                        .overlay { folderPad }
                        .onPreferenceChange(FolderFramesKey.self) { folderFrames = $0 }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

            footer
        }
        .frame(width: StartMenuController.size.width, height: StartMenuController.size.height)
        .background(GlassBackdrop(style: prefs.glassStyle, cornerRadius: TTLayout.s(14)))
        .clipShape(RoundedRectangle(cornerRadius: TTLayout.s(14), style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: TTLayout.s(14), style: .continuous)
                .strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.5)
        )
        .onAppear { searchFocused = true }
        .onChange(of: model.openFolder) { _, id in
            // 文件夹收起（点暗幕 / Esc）：焦点交还搜索框，打字照样能搜
            if id == nil { DispatchQueue.main.async { searchFocused = true } }
        }
        .onChange(of: model.focusToken) { _, _ in
            quitting = []
            // 拖到一半菜单被关掉时手势不会走 onEnded，重新打开时清掉
            pinDrag = nil
            // 下一拍再聚焦：面板刚 makeKey，同一拍里设焦点有时不生效
            DispatchQueue.main.async { searchFocused = true }
        }
    }

    // MARK: - 搜索框

    private var searchField: some View {
        HStack(spacing: TTLayout.s(8)) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("搜尋應用", text: $model.query)
                .textFieldStyle(.plain)
                .font(.system(size: TTLayout.font(14)))
                .focused($searchFocused)
            if !model.query.isEmpty {
                Button { model.query = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, TTLayout.s(12))
        .padding(.vertical, TTLayout.s(8))
        .background(
            RoundedRectangle(cornerRadius: TTLayout.s(18), style: .continuous)
                .fill(Color.primary.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: TTLayout.s(18), style: .continuous)
                .strokeBorder(Color.primary.opacity(searchFocused ? 0.18 : 0.06), lineWidth: 1)
        )
    }

    // MARK: - 首页：已固定 + 最近使用

    private var home: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: TTLayout.s(10)) {
                sectionHeader("已固定") {
                    HStack(spacing: TTLayout.s(6)) {
                        Button { openFolder(catalog.createStartFolder(), rename: true) } label: {
                            HStack(spacing: 2) {
                                Image(systemName: "plus")
                                Text("新增資料夾")
                            }
                            .font(.system(size: TTLayout.font(11), weight: .medium))
                        }
                        .buttonStyle(PillButtonStyle())
                        Button { model.showAll = true } label: {
                            HStack(spacing: 2) {
                                Text("所有應用")
                                Image(systemName: "chevron.right")
                            }
                            .font(.system(size: TTLayout.font(11), weight: .medium))
                        }
                        .buttonStyle(PillButtonStyle())
                    }
                }

                // App 和文件夹混排在同一个网格里（同 Windows 11），一起拖动排序
                if pinnedCells.isEmpty {
                    Text("還沒有固定的應用。右鍵任意應用 →「固定到開始選單」，或者在「所有應用」裡固定。")
                        .font(.system(size: TTLayout.font(11)))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: TTLayout.s(80))
                        .multilineTextAlignment(.center)
                } else {
                    reorderGrid(pinnedCells, current: { pinnedCells },
                                move: catalog.moveStartGridItem) { cell in
                        switch cell {
                        case .app(let app): itemMenu(app)
                        case .folder(let folder): folderMenu(folder)
                        }
                    }
                }

                // 开着但一个窗口都没有的 App：点一下叫出窗口，右键可以结束
                if !backgroundApps.isEmpty {
                    sectionHeader("背景執行") { EmptyView() }
                        .padding(.top, TTLayout.s(8))
                    LazyVGrid(columns: backgroundColumns, spacing: TTLayout.s(2)) {
                        ForEach(backgroundApps, id: \.pid) { item in
                            StartRow(app: item.app, icon: library.icon(for: item.app.url)) { onLaunch(item.app) }
                                .contextMenu {
                                    itemMenu(item.app)
                                    Divider()
                                    Button("結束 App", role: .destructive) {
                                        quitting.insert(item.pid)
                                        catalog.terminate(pid: item.pid, name: item.app.name)
                                    }
                                }
                        }
                    }
                }
            }
            .padding(.horizontal, TTLayout.s(24))
            .padding(.bottom, TTLayout.s(12))
        }
    }

    // MARK: - 可拖动排序的图标网格（已固定 / 文件夹里）

    /// 按住图标拖到别的格子上即可换位置，其它图标实时让位（同 Windows 11）。
    /// 用自己的 DragGesture 而不是系统拖放：图标不会被拖出菜单丢到访达里，
    /// 松手 / 取消也一定能复位。
    /// - Parameters:
    ///   - current: 拖动中现取最新顺序（每挪一格顺序就变了）
    ///   - move: 把第一个格子 id 挪到第二个所在的位置
    private func reorderGrid<Menu: View>(_ cells: [StartCell],
                                        grid: String = "home",
                                        columns: Int = 6,
                                        current: @escaping () -> [StartCell],
                                        move: @escaping (String, String) -> Void,
                                        @ViewBuilder menu: @escaping (StartCell) -> Menu) -> some View {
        let slots = pinSlots[grid] ?? [:]
        return LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: TTLayout.s(4)), count: columns),
                         spacing: TTLayout.s(6)) {
            ForEach(Array(cells.enumerated()), id: \.element.id) { index, cell in
                cellView(cell)
                    .opacity(pinDrag?.id == cell.id ? 0.3 : 1)
                    .background(
                        GeometryReader { geo in
                            Color.clear.preference(key: PinSlotFramesKey.self,
                                                   value: [index: geo.frame(in: .named(Self.pinSpace))])
                        }
                    )
                    .background(folderFrameReporter(cell))
                    .highPriorityGesture(pinDragGesture(cell, grid: grid, current: current, move: move))
                    .contextMenu { menu(cell) }
            }
        }
        .coordinateSpace(name: Self.pinSpace)
        .onPreferenceChange(PinSlotFramesKey.self) { pinSlots[grid] = $0 }
        .overlay(alignment: .topLeading) {
            if let drag = pinDrag,
               let cell = cells.first(where: { $0.id == drag.id }),
               let slot = slots.values.first {
                cellView(cell, lifted: true)
                    .frame(width: slot.width, height: slot.height)
                    .offset(x: drag.location.x - drag.grab.width,
                            y: drag.location.y - drag.grab.height)
                    .allowsHitTesting(false)
            }
        }
    }

    /// 一格：App 图标或文件夹。`lifted` = 拖动时跟着指针走的那份（不响应点击）
    @ViewBuilder
    private func cellView(_ cell: StartCell, lifted: Bool = false) -> some View {
        switch cell {
        case .app(let app):
            StartTile(app: app, icon: library.icon(for: app.url), lifted: lifted) {
                if !lifted { onLaunch(app) }
            }
        case .folder(let folder):
            FolderTile(name: folder.name.isEmpty ? "未命名" : folder.name,
                       icons: resolved(folder.apps).prefix(4).map { library.icon(for: $0.url) },
                       lifted: lifted) {
                if !lifted { openFolder(folder.id) }
            }
        }
    }

    /// 文件夹格子上报位置（坐标系 `homeSpace`），弹窗据此贴着它弹出
    @ViewBuilder
    private func folderFrameReporter(_ cell: StartCell) -> some View {
        if case .folder(let folder) = cell {
            GeometryReader { geo in
                Color.clear.preference(key: FolderFramesKey.self,
                                       value: [folder.id: geo.frame(in: .named(Self.homeSpace))])
            }
        }
    }

    private func pinDragGesture(_ cell: StartCell,
                                grid: String,
                                current: @escaping () -> [StartCell],
                                move: @escaping (String, String) -> Void) -> some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .named(Self.pinSpace))
            .onChanged { value in
                let cells = current()
                let slots = pinSlots[grid] ?? [:]
                if pinDrag == nil {
                    let origin = cells.firstIndex { $0.id == cell.id }.flatMap { slots[$0]?.origin } ?? .zero
                    pinDrag = PinDrag(id: cell.id,
                                      grab: CGSize(width: value.startLocation.x - origin.x,
                                                   height: value.startLocation.y - origin.y),
                                      location: value.location)
                } else {
                    pinDrag?.location = value.location
                }
                // 指针停在哪一格就把拖动项挪过去
                guard let target = slots.first(where: { $0.value.contains(value.location) })?.key,
                      cells.indices.contains(target), cells[target].id != cell.id else { return }
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) {
                    move(cell.id, cells[target].id)
                }
            }
            .onEnded { _ in
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.12)) { pinDrag = nil }
            }
    }

    // MARK: - 文件夹

    @ViewBuilder
    private func folderMenu(_ folder: StartFolder) -> some View {
        Button("開啟") { openFolder(folder.id) }
        Button("重新命名") { openFolder(folder.id, rename: true) }
        Divider()
        Button("刪除資料夾") { catalog.deleteStartFolder(folder.id) }
    }

    /// 文件夹弹窗：盖在首页上，贴着文件夹格子弹出（同 Windows 11 的文件夹）。
    /// 后面垫一层暗幕，点暗幕 / 按 Esc 收起。
    private var folderPad: some View {
        GeometryReader { geo in
            let folder = model.openFolder.flatMap { id in prefs.startFolders.first { $0.id == id } }
            ZStack(alignment: .topLeading) {
                if folder != nil {
                    Color.black.opacity(0.18)
                        .contentShape(Rectangle())
                        .onTapGesture { closeFolder() }
                        .transition(.opacity)
                }
                if let folder {
                    let origin = padOrigin(folder.id, in: geo.size)
                    padCard(folder)
                        .background(
                            GeometryReader { g in Color.clear.preference(key: PadSizeKey.self, value: g.size) }
                        )
                        .padding(.leading, origin.x)
                        .padding(.top, origin.y)
                        .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
                        // 从文件夹格子"长"出来
                        .transition(.scale(scale: 0.9, anchor: padAnchor(folder.id, in: geo.size))
                            .combined(with: .opacity))
                }
            }
            // 收起时暗幕 / 弹窗还在淡出（弹簧动画收尾要一阵子），
            // 淡出中的视图照样吃点击，会让下一次点文件夹没反应。这里一收起就整层不收点击
            .allowsHitTesting(folder != nil)
        }
        .onPreferenceChange(PadSizeKey.self) { if $0 != .zero { padSize = $0 } }
        .animation(reduceMotion ? nil : .spring(response: 0.24, dampingFraction: 0.86), value: model.openFolder)
    }

    private static var padWidth: CGFloat { TTLayout.s(380) }

    /// 以文件夹格子为中心摆，夹在首页范围内（离边留 12pt）
    private func padOrigin(_ id: UUID, in container: CGSize) -> CGPoint {
        let margin = TTLayout.s(12)
        let size = CGSize(width: Self.padWidth, height: padSize.height)
        let tile = folderFrames[id] ?? CGRect(x: container.width / 2, y: container.height / 2, width: 0, height: 0)
        func clamp(_ v: CGFloat, _ lo: CGFloat, _ hi: CGFloat) -> CGFloat { max(lo, min(v, max(lo, hi))) }
        return CGPoint(x: clamp(tile.midX - size.width / 2, margin, container.width - size.width - margin),
                       y: clamp(tile.midY - size.height / 2, margin, container.height - size.height - margin))
    }

    private func padAnchor(_ id: UUID, in container: CGSize) -> UnitPoint {
        guard let tile = folderFrames[id], container.width > 0, container.height > 0 else { return .center }
        return UnitPoint(x: tile.midX / container.width, y: tile.midY / container.height)
    }

    /// 弹窗本体：名字（点一下就能改）+ 删除，下面是可拖动排序的图标网格
    private func padCard(_ folder: StartFolder) -> some View {
        let apps = resolved(folder.apps)
        return VStack(spacing: TTLayout.s(8)) {
            HStack(spacing: TTLayout.s(6)) {
                TextField("資料夾名稱", text: Binding(
                    get: { folder.name },
                    set: { catalog.renameStartFolder(folder.id, to: $0) }
                ))
                .textFieldStyle(.plain)
                .multilineTextAlignment(.center)
                .font(.system(size: TTLayout.font(13), weight: .semibold))
                .focused($folderNameFocused)
                .onSubmit { folderNameFocused = false }
                .padding(.horizontal, TTLayout.s(8))
                .padding(.vertical, TTLayout.s(4))
                .background(
                    RoundedRectangle(cornerRadius: TTLayout.s(6), style: .continuous)
                        .fill(Color.primary.opacity(folderNameFocused ? 0.10 : 0))
                )

                Button {
                    closeFolder()
                    catalog.deleteStartFolder(folder.id)
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: TTLayout.font(11), weight: .medium))
                }
                .buttonStyle(PillButtonStyle())
                .help("刪除資料夾（裡面的應用不受影響）")
            }

            if apps.isEmpty {
                Text("資料夾是空的。右鍵任意應用 →「加入資料夾」→「\(folder.name)」。")
                    .font(.system(size: TTLayout.font(11)))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: TTLayout.s(80))
                    .multilineTextAlignment(.center)
            } else {
                // 超过三行才滚动，少的时候弹窗跟着内容缩
                ScrollView(.vertical, showsIndicators: false) {
                    reorderGrid(apps.map(StartCell.app), grid: "folder", columns: 4,
                                current: { resolved(prefs.startFolders.first { $0.id == folder.id }?.apps ?? []).map(StartCell.app) },
                                move: { catalog.moveInStartFolder(folder.id, $0, to: $1) }) { cell in
                        if case .app(let app) = cell {
                            itemMenu(app)
                            Divider()
                            Button("從「\(folder.name)」中移除") { catalog.removeFromStartFolder(folder.id, app.bundleID) }
                        }
                    }
                }
                // 每格 90pt 高、行距 6pt：n 行 = 96n - 6
                .frame(height: min(CGFloat((apps.count + 3) / 4), 3) * TTLayout.s(96) - TTLayout.s(6))
            }
        }
        .padding(TTLayout.s(14))
        .frame(width: Self.padWidth)
        .background(GlassBackdrop(style: prefs.glassStyle, cornerRadius: TTLayout.s(12)))
        .clipShape(RoundedRectangle(cornerRadius: TTLayout.s(12), style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: TTLayout.s(12), style: .continuous)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.28), radius: 18, y: 6)
        // 弹窗本体要能命中：点空白处不穿透到下面的暗幕把弹窗关掉
        .contentShape(RoundedRectangle(cornerRadius: TTLayout.s(12), style: .continuous))
    }

    private func openFolder(_ id: UUID, rename: Bool = false) {
        pinDrag = nil
        model.openFolder = id
        // 新建 / 重命名：直接进名字输入框（下一拍，等弹窗出来）
        if rename { DispatchQueue.main.async { folderNameFocused = true } }
    }

    private func closeFolder() {
        folderNameFocused = false
        model.openFolder = nil
    }

    // MARK: - 所有应用（A–Z / 最近加入 / 最近更新）

    private var allApps: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader("所有應用") {
                Button { model.showAll = false } label: {
                    HStack(spacing: 2) {
                        Image(systemName: "chevron.left")
                        Text("返回")
                    }
                    .font(.system(size: TTLayout.font(11), weight: .medium))
                }
                .buttonStyle(PillButtonStyle())
            }
            .padding(.horizontal, TTLayout.s(24))
            .padding(.bottom, TTLayout.s(6))

            Picker("排序", selection: $prefs.startMenuSort) {
                ForEach(StartMenuSort.allCases) { sort in
                    Text(sort.title).tag(sort)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
            .padding(.horizontal, TTLayout.s(24))
            .padding(.bottom, TTLayout.s(8))

            if library.apps.isEmpty {
                ProgressView().controlSize(.small)
                    .frame(maxWidth: .infinity, minHeight: TTLayout.s(80))
            } else {
                ScrollView(.vertical) {
                    LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                        ForEach(allAppsSections, id: \.letter) { section in
                            Section {
                                ForEach(section.apps) { app in
                                    StartRow(app: app, icon: library.icon(for: app.url),
                                             subtitle: dateSubtitle(app)) { onLaunch(app) }
                                        .contextMenu { itemMenu(app) }
                                }
                            } header: {
                                Text(section.letter)
                                    .font(.system(size: TTLayout.font(12), weight: .semibold))
                                    .foregroundStyle(.secondary)
                                    .padding(.vertical, TTLayout.s(4))
                                    .padding(.horizontal, TTLayout.s(8))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(.ultraThinMaterial)
                            }
                        }
                    }
                    .padding(.horizontal, TTLayout.s(20))
                    .padding(.bottom, TTLayout.s(12))
                }
            }
        }
    }

    /// 按当前排序方式分组：名称 → 字母；最近加入 / 更新 → 今天、昨天、最近 7 天…
    private var allAppsSections: [StartMenuIndex.Section] {
        switch prefs.startMenuSort {
        case .name:    return StartMenuIndex.sections(library.apps)
        case .added:   return StartMenuIndex.dateSections(library.apps, date: \.added)
        case .updated: return StartMenuIndex.dateSections(library.apps, date: \.updated)
        }
    }

    /// 按时间排序时，每行下面标一下日期（按系统语言格式化）
    private func dateSubtitle(_ app: LibraryApp) -> String? {
        let date: Date?
        switch prefs.startMenuSort {
        case .name:    return nil
        case .added:   date = app.added
        case .updated: date = app.updated
        }
        return date?.formatted(date: .abbreviated, time: .omitted)
    }

    // MARK: - 搜索结果

    private var searchResults: some View {
        let results = model.results
        return Group {
            if results.isEmpty {
                Text(library.apps.isEmpty ? "正在建立應用索引…" : "沒有找到「\(model.query)」")
                    .font(.system(size: TTLayout.font(12)))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: TTLayout.s(120))
            } else {
                ScrollViewReader { proxy in
                    ScrollView(.vertical) {
                        LazyVStack(alignment: .leading, spacing: TTLayout.s(2)) {
                            ForEach(Array(results.enumerated()), id: \.element.id) { i, app in
                                StartRow(app: app, icon: library.icon(for: app.url),
                                         subtitle: i == 0 ? "最佳匹配" : runningSubtitle(app),
                                         selected: i == model.selection) { onLaunch(app) }
                                    .id(app.id)
                                    .contextMenu { itemMenu(app) }
                            }
                        }
                        .padding(.horizontal, TTLayout.s(20))
                        .padding(.bottom, TTLayout.s(12))
                    }
                    .onChange(of: model.selection) { _, index in
                        guard results.indices.contains(index) else { return }
                        proxy.scrollTo(results[index].id)
                    }
                }
            }
        }
    }

    // MARK: - 底栏

    private var footer: some View {
        HStack(spacing: TTLayout.s(10)) {
            NowPlayingBar(nowPlaying: nowPlaying, prefs: prefs)
            Button(action: onSettings) {
                Image(systemName: "gearshape")
                    .font(.system(size: TTLayout.font(14)))
            }
            .buttonStyle(PillButtonStyle())
            .help("Xtopbar 設定")
        }
        .padding(.horizontal, TTLayout.s(24))
        .padding(.vertical, TTLayout.s(12))
        .background(Color.primary.opacity(0.05))
    }

    // MARK: - 数据

    /// 固定到开始菜单的项
    private var pinnedApps: [LibraryApp] { resolved(prefs.startPins) }

    /// 已固定网格：App 和文件夹按统一顺序混排（App 被删掉、解析不到的格子跳过）
    private var pinnedCells: [StartCell] {
        let apps = Dictionary(pinnedApps.map { ($0.bundleID, $0) }, uniquingKeysWith: { a, _ in a })
        let folders = Dictionary(prefs.startFolders.map { (AppCatalog.startFolderKey($0.id), $0) },
                                 uniquingKeysWith: { a, _ in a })
        return catalog.startGridKeys().compactMap { key in
            folders[key].map(StartCell.folder) ?? apps[key].map(StartCell.app)
        }
    }

    /// 固定项 → App。App 被删掉（路径不在、也按 bundle id 找不到）的就不显示了，
    /// 但仍留在偏好里 —— 装回来会自己出现，设置里也能手动移除。
    private func resolved(_ pins: [PinnedApp]) -> [LibraryApp] {
        pins.compactMap { pin -> LibraryApp? in
            if let app = library.app(bundleID: pin.bundleID) { return app }
            if FileManager.default.fileExists(atPath: pin.path) {
                return LibraryApp(bundleID: pin.bundleID, url: pin.url,
                                  name: AppNames.localized(url: pin.url) ?? pin.name)
            }
            return nil
        }
    }

    /// 背景執行：在跑、但一个窗口都没有的 App（判定同「只顯示有視窗的 App」）。
    /// 访达不列 —— 它是桌面本身，没窗口是常态，也不该从这里被结束。
    private var backgroundApps: [(pid: pid_t, app: LibraryApp)] {
        let me = ProcessInfo.processInfo.processIdentifier
        return NSWorkspace.shared.runningApplications
            .filter { app in
                app.activationPolicy == .regular && !app.isTerminated
                    && app.processIdentifier != me
                    && app.bundleIdentifier != "com.apple.finder"
                    && presence.windowless.contains(app.processIdentifier)
                    && !quitting.contains(app.processIdentifier)
            }
            .compactMap { app -> (pid: pid_t, app: LibraryApp)? in
                guard let bid = app.bundleIdentifier, let url = app.bundleURL else { return nil }
                let lib = library.app(bundleID: bid)
                    ?? LibraryApp(bundleID: bid, url: url,
                                  name: app.localizedName ?? url.deletingPathExtension().lastPathComponent)
                return (app.processIdentifier, lib)
            }
            .sorted { $0.app.name.localizedStandardCompare($1.app.name) == .orderedAscending }
    }

    private func runningSubtitle(_ app: LibraryApp) -> String? {
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: app.bundleID)
        return running.isEmpty ? nil : "正在執行"
    }

    // MARK: - 小部件

    private func sectionHeader<Trailing: View>(_ title: String,
                                               @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack {
            Text(title)
                .font(.system(size: TTLayout.font(13), weight: .semibold))
            Spacer()
            trailing()
        }
    }

    @ViewBuilder
    private func itemMenu(_ app: LibraryApp) -> some View {
        Button("開啟") { onLaunch(app) }
        Divider()
        if prefs.startPins.contains(where: { $0.bundleID == app.bundleID }) {
            Button("從開始選單取消固定") { catalog.unpinFromStart(app.bundleID) }
        } else {
            Button("固定到開始選單") { catalog.pinToStart(app.pinned) }
        }
        if prefs.dockPins.contains(where: { $0.bundleID == app.bundleID }) {
            Button("從工作列取消固定") { catalog.unpinFromDock(app.bundleID) }
        } else {
            Button("固定到工作列") { catalog.pinToDock(app.pinned) }
        }
        Menu("加入資料夾") {
            ForEach(prefs.startFolders) { folder in
                Toggle(folder.name, isOn: Binding(
                    get: { catalog.folderContains(folder.id, app.bundleID) },
                    set: { on in
                        if on { catalog.addToStartFolder(folder.id, app.pinned) }
                        else { catalog.removeFromStartFolder(folder.id, app.bundleID) }
                    }
                ))
            }
            if !prefs.startFolders.isEmpty { Divider() }
            Button("新增資料夾") {
                let id = catalog.createStartFolder(with: app.pinned)
                // 在「所有应用」/ 搜索里就原地建好，方便接着往里加；首页才直接进去改名
                if model.showAll || !model.query.isEmpty { return }
                openFolder(id, rename: true)
            }
        }
        Divider()
        Button("在 Finder 中顯示") { NSWorkspace.shared.activateFileViewerSelecting([app.url]) }
    }
}

/// 「所有应用」的字母分组。中文名按拼音首字母归组（「微信」→ W），
/// 数字和其它符号开头的归到「#」，排在最后。
enum StartMenuIndex {
    struct Section {
        let letter: String
        let apps: [LibraryApp]
    }

    static func latinKey(_ name: String) -> String {
        let latin = name.applyingTransform(.toLatin, reverse: false) ?? name
        let plain = latin.applyingTransform(.stripDiacritics, reverse: false) ?? latin
        return plain.uppercased()
    }

    static func letter(for name: String) -> String {
        guard let c = latinKey(name).first, c.isASCII, c.isLetter else { return "#" }
        return String(c)
    }

    static func sections(_ apps: [LibraryApp]) -> [Section] {
        var buckets: [String: [(key: String, app: LibraryApp)]] = [:]
        for app in apps {
            buckets[letter(for: app.name), default: []].append((latinKey(app.name), app))
        }
        let letters = buckets.keys.sorted { a, b in
            if a == "#" { return false }
            if b == "#" { return true }
            return a < b
        }
        return letters.map { letter -> Section in
            let items = buckets[letter, default: []].sorted { a, b in
                a.key.localizedStandardCompare(b.key) == .orderedAscending
            }
            return Section(letter: letter, apps: items.map { $0.app })
        }
    }

    /// 按时间分组（新的在前）：今天 / 昨天 / 最近 7 天 / 最近 30 天 / 今年 / 更早。
    /// 没有时间的（读不到文件日期）排在最后。
    static func dateSections(_ apps: [LibraryApp], date: KeyPath<LibraryApp, Date?>,
                             now: Date = Date(), calendar: Calendar = .current) -> [Section] {
        let sorted = apps.sorted { a, b in
            switch (a[keyPath: date], b[keyPath: date]) {
            case let (x?, y?) where x != y: return x > y
            case (_?, nil): return true
            case (nil, _?): return false
            default: return a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
        }
        let today = calendar.startOfDay(for: now)
        func bucket(_ d: Date?) -> String {
            guard let d else { return "未知" }
            if d >= today { return "今天" }
            if let y = calendar.date(byAdding: .day, value: -1, to: today), d >= y { return "昨天" }
            if let w = calendar.date(byAdding: .day, value: -7, to: today), d >= w { return "最近 7 天" }
            if let m = calendar.date(byAdding: .day, value: -30, to: today), d >= m { return "最近 30 天" }
            if calendar.isDate(d, equalTo: now, toGranularity: .year) { return "今年" }
            return "更早"
        }
        // 已经按时间排好，顺着切段即可（同一段内保持时间顺序）
        var sections: [Section] = []
        for app in sorted {
            let title = bucket(app[keyPath: date])
            if let last = sections.last, last.letter == title {
                sections[sections.count - 1] = Section(letter: title, apps: last.apps + [app])
            } else {
                sections.append(Section(letter: title, apps: [app]))
            }
        }
        return sections
    }
}

/// 已固定网格里的一格：大图标 + 两行名字。
/// 不用 Button：外面挂了拖动排序手势，Button 会在拖完松手时也触发打开；
/// 点按手势在拖动识别后就失效了，不会误开。
private struct StartTile: View {
    let app: LibraryApp
    let icon: NSImage
    /// 拖动时跟着指针走的那份：放大一点、带阴影
    var lifted: Bool = false
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        VStack(spacing: TTLayout.s(6)) {
            Image(nsImage: icon)
                .resizable()
                .interpolation(.high)
                .frame(width: TTLayout.s(40), height: TTLayout.s(40))
            Text(app.name)
                .font(.system(size: TTLayout.font(11)))
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .frame(height: TTLayout.s(28), alignment: .top)
        }
        .padding(.vertical, TTLayout.s(8))
        .padding(.horizontal, TTLayout.s(2))
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: TTLayout.s(8), style: .continuous)
                .fill(Color.primary.opacity(lifted ? 0.12 : hovering ? 0.10 : 0))
        )
        .scaleEffect(lifted ? 1.06 : 1)
        .shadow(color: .black.opacity(lifted ? 0.18 : 0), radius: 8, y: 3)
        .contentShape(Rectangle())
        .onTapGesture(perform: action)
        .onHover { hovering = $0 }
        .help(app.name)
        .accessibilityAddTraits(.isButton)
    }
}

/// 已固定网格里的一个文件夹：2×2 小图标拼成的方块 + 名字，尺寸和 StartTile 对齐。
/// 不用 Button，理由同 StartTile（外面挂了拖动排序手势）
private struct FolderTile: View {
    let name: String
    let icons: [NSImage]
    /// 拖动时跟着指针走的那份：放大一点、带阴影
    var lifted: Bool = false
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        VStack(spacing: TTLayout.s(6)) {
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(TTLayout.s(16)), spacing: TTLayout.s(3)), count: 2),
                      spacing: TTLayout.s(3)) {
                ForEach(icons.indices, id: \.self) { i in
                    Image(nsImage: icons[i])
                        .resizable()
                        .interpolation(.high)
                        .frame(width: TTLayout.s(16), height: TTLayout.s(16))
                }
            }
            .frame(width: TTLayout.s(40), height: TTLayout.s(40))
            .background(
                RoundedRectangle(cornerRadius: TTLayout.s(9), style: .continuous)
                    .fill(Color.primary.opacity(0.09))
            )
            Text(name)
                .font(.system(size: TTLayout.font(11)))
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .frame(height: TTLayout.s(28), alignment: .top)
        }
        .padding(.vertical, TTLayout.s(8))
        .padding(.horizontal, TTLayout.s(2))
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: TTLayout.s(8), style: .continuous)
                .fill(Color.primary.opacity(lifted ? 0.12 : hovering ? 0.10 : 0))
        )
        .scaleEffect(lifted ? 1.06 : 1)
        .shadow(color: .black.opacity(lifted ? 0.18 : 0), radius: 8, y: 3)
        .contentShape(Rectangle())
        .onTapGesture(perform: action)
        .onHover { hovering = $0 }
        .help(name)
        .accessibilityAddTraits(.isButton)
    }
}

/// 已固定网格的一格：App 或文件夹
private enum StartCell: Identifiable {
    case app(LibraryApp)
    case folder(StartFolder)

    /// 和 `AppCatalog.startGridKeys` 的 key 一致：App 是 bundle id，文件夹是 `folder:<uuid>`
    var id: String {
        switch self {
        case .app(let app): return app.bundleID
        case .folder(let folder): return AppCatalog.startFolderKey(folder.id)
        }
    }
}

/// 列表里的一行：图标 + 名字（+ 副标题）
private struct StartRow: View {
    let app: LibraryApp
    let icon: NSImage
    var subtitle: String? = nil
    var selected: Bool = false
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: TTLayout.s(10)) {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: TTLayout.s(28), height: TTLayout.s(28))
                VStack(alignment: .leading, spacing: 1) {
                    Text(app.name)
                        .font(.system(size: TTLayout.font(12), weight: .medium))
                        .lineLimit(1)
                    if let subtitle {
                        Text(subtitle)
                            .font(.system(size: TTLayout.font(10)))
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, TTLayout.s(8))
            .padding(.vertical, TTLayout.s(5))
            .background(
                RoundedRectangle(cornerRadius: TTLayout.s(8), style: .continuous)
                    .fill(selected ? Color.accentColor.opacity(0.28)
                          : Color.primary.opacity(hovering ? 0.10 : 0))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// 首页文件夹格子的位置上报（按文件夹 id）
private struct FolderFramesKey: PreferenceKey {
    static var defaultValue: [UUID: CGRect] = [:]
    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}

/// 文件夹弹窗量出来的尺寸
private struct PadSizeKey: PreferenceKey {
    static var defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        let next = nextValue()
        if next != .zero { value = next }
    }
}

/// 已固定网格各格子的位置上报（按下标）
private struct PinSlotFramesKey: PreferenceKey {
    static var defaultValue: [Int: CGRect] = [:]
    static func reduce(value: inout [Int: CGRect], nextValue: () -> [Int: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}

/// 底栏的现正播放：封面 + 歌名 / 歌手 + 上一首 / 播放暂停 / 下一首。
/// 点歌名切到播放器；右键选来源（自动 / Spotify / Apple Music）。
private struct NowPlayingBar: View {
    @ObservedObject var nowPlaying: NowPlaying
    @ObservedObject var prefs: Preferences

    private var player: MediaPlayer? { nowPlaying.player ?? prefs.nowPlayingSource.player }

    var body: some View {
        HStack(spacing: TTLayout.s(10)) {
            HStack(spacing: TTLayout.s(10)) {
                cover
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.system(size: TTLayout.font(12), weight: .medium))
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.system(size: TTLayout.font(10)))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
            .onTapGesture { nowPlaying.openPlayer() }
            .help(player.map { "開啟 \($0.title)" } ?? "")

            HStack(spacing: TTLayout.s(2)) {
                control("backward.fill", enabled: nowPlaying.track != nil) { nowPlaying.previous() }
                control(nowPlaying.track?.playing == true ? "pause.fill" : "play.fill", enabled: true, large: true) {
                    nowPlaying.playPause()
                }
                control("forward.fill", enabled: nowPlaying.track != nil) { nowPlaying.next() }
            }
        }
        .frame(maxWidth: .infinity)
        .contextMenu {
            Picker("來源", selection: $prefs.nowPlayingSource) {
                ForEach(NowPlayingSource.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.inline)
        }
    }

    private var title: String {
        if let t = nowPlaying.track, !t.title.isEmpty { return t.title }
        return "未在播放"
    }

    private var subtitle: String {
        if let t = nowPlaying.track { return t.artist.isEmpty ? (player?.title ?? "") : t.artist }
        return player.map { $0.isRunning ? $0.title : "按 ▶ 開啟 \($0.title)" } ?? "Spotify / Apple Music"
    }

    @ViewBuilder
    private var cover: some View {
        let size = TTLayout.s(32)
        Group {
            if let art = nowPlaying.artwork {
                Image(nsImage: art).resizable().interpolation(.high).aspectRatio(contentMode: .fill)
            } else if let url = player?.appURL {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().interpolation(.high)
            } else {
                Image(systemName: "music.note")
                    .font(.system(size: TTLayout.font(14)))
                    .foregroundStyle(.secondary)
                    .frame(width: size, height: size)
                    .background(Color.primary.opacity(0.08))
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: TTLayout.s(6), style: .continuous))
    }

    private func control(_ symbol: String, enabled: Bool, large: Bool = false,
                         action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: TTLayout.font(large ? 15 : 12)))
                .frame(width: TTLayout.s(large ? 32 : 26), height: TTLayout.s(28))
                .contentShape(Rectangle())
        }
        .buttonStyle(ControlButtonStyle())
        .disabled(!enabled)
    }
}

/// 播放控制键：无底色，按下 / 悬停时给一层浅底
private struct ControlButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        ControlLabel(configuration: configuration)
    }

    /// 悬停状态得放在真正的 View 里，ButtonStyle 本身存不住 @State
    private struct ControlLabel: View {
        let configuration: ButtonStyleConfiguration
        @Environment(\.isEnabled) private var enabled
        @State private var hovering = false

        var body: some View {
            configuration.label
                .foregroundStyle(enabled ? .primary : .tertiary)
                .background(
                    RoundedRectangle(cornerRadius: TTLayout.s(6), style: .continuous)
                        .fill(Color.primary.opacity(configuration.isPressed ? 0.16 : hovering && enabled ? 0.08 : 0))
                )
                .onHover { hovering = $0 }
        }
    }
}

/// 小胶囊按钮（「所有应用 ›」「‹ 返回」、设置齿轮）
private struct PillButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(
                Capsule().fill(Color.primary.opacity(configuration.isPressed ? 0.16 : 0.08))
            )
            .contentShape(Capsule())
    }
}
