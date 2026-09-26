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
    let catalog: AppCatalog
    let onLaunch: (LibraryApp) -> Void
    let onSettings: () -> Void

    @FocusState var searchFocused: Bool
    @FocusState private var folderNameFocused: Bool

    /// 已固定网格正在拖动的项（nil = 没在拖）
    @State private var pinDrag: PinDrag?
    /// 网格每个格子的位置（按下标，坐标系 `pinSpace`）。按下标而不是按 App 记：
    /// 重排后格子本身不动、只换了内容，布局还没刷新的那一拍里拿到的旧值也不会错
    @State private var pinSlots: [Int: CGRect] = [:]
    private static let pinSpace = "startPins"

    private struct PinDrag {
        let id: String
        /// 按下点相对格子左上角的偏移：浮起的图标按它跟手，不会一拖就跳到指针中心
        let grab: CGSize
        var location: CGPoint
    }

    private var pinColumns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: TTLayout.s(4)), count: 6)
    }
    private var recentColumns: [GridItem] {
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
                } else if let id = model.openFolder,
                          let folder = prefs.startFolders.first(where: { $0.id == id }) {
                    folderView(folder)
                } else {
                    home
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
        .onChange(of: model.focusToken) { _, _ in
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
            TextField("搜索应用", text: $model.query)
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
                    Button { model.showAll = true } label: {
                        HStack(spacing: 2) {
                            Text("所有应用")
                            Image(systemName: "chevron.right")
                        }
                        .font(.system(size: TTLayout.font(11), weight: .medium))
                    }
                    .buttonStyle(PillButtonStyle())
                }

                if pinnedApps.isEmpty {
                    Text("还没有固定的应用。右键任意应用 →「固定到开始菜单」，或者在「所有应用」里固定。")
                        .font(.system(size: TTLayout.font(11)))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: TTLayout.s(80))
                        .multilineTextAlignment(.center)
                } else {
                    reorderGrid(pinnedApps, current: { pinnedApps },
                                move: catalog.moveStartPin) { itemMenu($0) }
                }

                folderSection
                    .padding(.top, TTLayout.s(8))

                if !recentApps.isEmpty {
                    sectionHeader("最近使用") { EmptyView() }
                        .padding(.top, TTLayout.s(8))
                    LazyVGrid(columns: recentColumns, spacing: TTLayout.s(2)) {
                        ForEach(recentApps) { app in
                            StartRow(app: app, icon: library.icon(for: app.url),
                                     subtitle: runningSubtitle(app)) { onLaunch(app) }
                                .contextMenu { itemMenu(app) }
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
    ///   - move: 把第一个 bundle id 挪到第二个所在的位置
    private func reorderGrid<Menu: View>(_ apps: [LibraryApp],
                                        current: @escaping () -> [LibraryApp],
                                        move: @escaping (String, String) -> Void,
                                        @ViewBuilder menu: @escaping (LibraryApp) -> Menu) -> some View {
        LazyVGrid(columns: pinColumns, spacing: TTLayout.s(6)) {
            ForEach(Array(apps.enumerated()), id: \.element.id) { index, app in
                StartTile(app: app, icon: library.icon(for: app.url)) { onLaunch(app) }
                    .opacity(pinDrag?.id == app.id ? 0.3 : 1)
                    .background(
                        GeometryReader { geo in
                            Color.clear.preference(key: PinSlotFramesKey.self,
                                                   value: [index: geo.frame(in: .named(Self.pinSpace))])
                        }
                    )
                    .highPriorityGesture(pinDragGesture(app, current: current, move: move))
                    .contextMenu { menu(app) }
            }
        }
        .coordinateSpace(name: Self.pinSpace)
        .onPreferenceChange(PinSlotFramesKey.self) { pinSlots = $0 }
        .overlay(alignment: .topLeading) {
            if let drag = pinDrag,
               let app = apps.first(where: { $0.id == drag.id }),
               let slot = pinSlots.values.first {
                StartTile(app: app, icon: library.icon(for: app.url), lifted: true) {}
                    .frame(width: slot.width, height: slot.height)
                    .offset(x: drag.location.x - drag.grab.width,
                            y: drag.location.y - drag.grab.height)
                    .allowsHitTesting(false)
            }
        }
    }

    private func pinDragGesture(_ app: LibraryApp,
                                current: @escaping () -> [LibraryApp],
                                move: @escaping (String, String) -> Void) -> some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .named(Self.pinSpace))
            .onChanged { value in
                let apps = current()
                if pinDrag == nil {
                    let origin = apps.firstIndex { $0.id == app.id }.flatMap { pinSlots[$0]?.origin } ?? .zero
                    pinDrag = PinDrag(id: app.id,
                                      grab: CGSize(width: value.startLocation.x - origin.x,
                                                   height: value.startLocation.y - origin.y),
                                      location: value.location)
                } else {
                    pinDrag?.location = value.location
                }
                // 指针停在哪一格就把拖动项挪过去
                guard let target = pinSlots.first(where: { $0.value.contains(value.location) })?.key,
                      apps.indices.contains(target), apps[target].id != app.id else { return }
                withAnimation(prefs.animationsEnabled ? .easeInOut(duration: 0.18) : nil) {
                    move(app.bundleID, apps[target].bundleID)
                }
            }
            .onEnded { _ in
                withAnimation(prefs.animationsEnabled ? .easeOut(duration: 0.12) : nil) { pinDrag = nil }
            }
    }

    // MARK: - 文件夹

    /// 首页「已固定」下面的文件夹区：点文件夹在菜单里打开它
    private var folderSection: some View {
        VStack(alignment: .leading, spacing: TTLayout.s(10)) {
            sectionHeader("文件夹") {
                Button { openFolder(catalog.createStartFolder(), rename: true) } label: {
                    HStack(spacing: 2) {
                        Image(systemName: "plus")
                        Text("新建文件夹")
                    }
                    .font(.system(size: TTLayout.font(11), weight: .medium))
                }
                .buttonStyle(PillButtonStyle())
            }

            if prefs.startFolders.isEmpty {
                Text("把几个应用收进一个文件夹：点「新建文件夹」，或者右键任意应用 →「添加到文件夹」。")
                    .font(.system(size: TTLayout.font(11)))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: TTLayout.s(44))
                    .multilineTextAlignment(.center)
            } else {
                LazyVGrid(columns: pinColumns, spacing: TTLayout.s(6)) {
                    ForEach(prefs.startFolders) { folder in
                        FolderTile(name: folder.name.isEmpty ? "未命名" : folder.name,
                                   icons: resolved(folder.apps).prefix(4).map { library.icon(for: $0.url) }) {
                            openFolder(folder.id)
                        }
                        .contextMenu {
                            Button("打开") { openFolder(folder.id) }
                            Button("重命名") { openFolder(folder.id, rename: true) }
                            Divider()
                            Button("删除文件夹") { catalog.deleteStartFolder(folder.id) }
                        }
                    }
                }
            }
        }
    }

    /// 打开的文件夹：可改名、拖动排序、右键移出
    @ViewBuilder
    private func folderView(_ folder: StartFolder) -> some View {
        let apps = resolved(folder.apps)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: TTLayout.s(8)) {
                Button { model.openFolder = nil } label: {
                    HStack(spacing: 2) {
                        Image(systemName: "chevron.left")
                        Text("返回")
                    }
                    .font(.system(size: TTLayout.font(11), weight: .medium))
                }
                .buttonStyle(PillButtonStyle())

                TextField("文件夹名称", text: Binding(
                    get: { folder.name },
                    set: { catalog.renameStartFolder(folder.id, to: $0) }
                ))
                .textFieldStyle(.plain)
                .font(.system(size: TTLayout.font(13), weight: .semibold))
                .focused($folderNameFocused)
                .padding(.horizontal, TTLayout.s(8))
                .padding(.vertical, TTLayout.s(4))
                .background(
                    RoundedRectangle(cornerRadius: TTLayout.s(6), style: .continuous)
                        .fill(Color.primary.opacity(folderNameFocused ? 0.08 : 0))
                )

                Button {
                    model.openFolder = nil
                    catalog.deleteStartFolder(folder.id)
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: TTLayout.font(11), weight: .medium))
                }
                .buttonStyle(PillButtonStyle())
                .help("删除文件夹（里面的应用不受影响）")
            }
            .padding(.horizontal, TTLayout.s(24))
            .padding(.bottom, TTLayout.s(10))

            ScrollView(.vertical, showsIndicators: false) {
                if apps.isEmpty {
                    Text("文件夹是空的。右键任意应用 →「添加到文件夹」→「\(folder.name)」。")
                        .font(.system(size: TTLayout.font(11)))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: TTLayout.s(80))
                        .multilineTextAlignment(.center)
                } else {
                    reorderGrid(apps,
                                current: { resolved(prefs.startFolders.first { $0.id == folder.id }?.apps ?? []) },
                                move: { catalog.moveInStartFolder(folder.id, $0, to: $1) }) { app in
                        itemMenu(app)
                        Divider()
                        Button("从「\(folder.name)」中移除") { catalog.removeFromStartFolder(folder.id, app.bundleID) }
                    }
                }
            }
            .padding(.horizontal, TTLayout.s(24))
            .padding(.bottom, TTLayout.s(12))
        }
    }

    private func openFolder(_ id: UUID, rename: Bool = false) {
        pinDrag = nil
        model.openFolder = id
        // 新建 / 重命名：直接进名字输入框（下一拍，等文件夹页出来）
        if rename { DispatchQueue.main.async { folderNameFocused = true } }
    }

    // MARK: - 所有应用（A–Z / 最近加入 / 最近更新）

    private var allApps: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader("所有应用") {
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
                Text(library.apps.isEmpty ? "正在建立应用索引…" : "没有找到「\(model.query)」")
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
            Image(systemName: "person.crop.circle.fill")
                .font(.system(size: TTLayout.font(22)))
                .foregroundStyle(.secondary)
            Text(NSFullUserName().isEmpty ? NSUserName() : NSFullUserName())
                .font(.system(size: TTLayout.font(12), weight: .medium))
                .lineLimit(1)
            Spacer()
            Button(action: onSettings) {
                Image(systemName: "gearshape")
                    .font(.system(size: TTLayout.font(14)))
            }
            .buttonStyle(PillButtonStyle())
            .help("Xtopbar 设置")
        }
        .padding(.horizontal, TTLayout.s(24))
        .padding(.vertical, TTLayout.s(12))
        .background(Color.primary.opacity(0.05))
    }

    // MARK: - 数据

    /// 固定到开始菜单的项
    private var pinnedApps: [LibraryApp] { resolved(prefs.startPins) }

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

    /// 最近使用：偏好里的 bundle id 解析成 App；已固定到开始菜单的不重复列
    private var recentApps: [LibraryApp] {
        let pinned = Set(prefs.startPins.map(\.bundleID))
        let me = Bundle.main.bundleIdentifier
        var result: [LibraryApp] = []
        for bid in prefs.recentApps where !pinned.contains(bid) && bid != me {
            if let app = library.app(bundleID: bid) {
                result.append(app)
            } else if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bid) {
                let name = AppNames.localized(url: url)
                    ?? FileManager.default.displayName(atPath: url.path)
                        .replacingOccurrences(of: ".app", with: "")
                result.append(LibraryApp(bundleID: bid, url: url, name: name))
            }
            if result.count == 6 { break }
        }
        return result
    }

    private func runningSubtitle(_ app: LibraryApp) -> String? {
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: app.bundleID)
        return running.isEmpty ? nil : "正在运行"
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
        Button("打开") { onLaunch(app) }
        Divider()
        if prefs.startPins.contains(where: { $0.bundleID == app.bundleID }) {
            Button("从开始菜单取消固定") { catalog.unpinFromStart(app.bundleID) }
        } else {
            Button("固定到开始菜单") { catalog.pinToStart(app.pinned) }
        }
        if prefs.dockPins.contains(where: { $0.bundleID == app.bundleID }) {
            Button("从任务栏取消固定") { catalog.unpinFromDock(app.bundleID) }
        } else {
            Button("固定到任务栏") { catalog.pinToDock(app.pinned) }
        }
        Menu("添加到文件夹") {
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
            Button("新建文件夹") {
                let id = catalog.createStartFolder(with: app.pinned)
                // 在「所有应用」/ 搜索里就原地建好，方便接着往里加；首页才直接进去改名
                if model.showAll || !model.query.isEmpty { return }
                openFolder(id, rename: true)
            }
        }
        Divider()
        Button("在访达中显示") { NSWorkspace.shared.activateFileViewerSelecting([app.url]) }
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

/// 首页的一个文件夹：2×2 小图标拼成的方块 + 名字，尺寸和 StartTile 对齐
private struct FolderTile: View {
    let name: String
    let icons: [NSImage]
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
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
                    .fill(Color.primary.opacity(hovering ? 0.10 : 0))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(name)
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

/// 已固定网格各格子的位置上报（按下标）
private struct PinSlotFramesKey: PreferenceKey {
    static var defaultValue: [Int: CGRect] = [:]
    static func reduce(value: inout [Int: CGRect], nextValue: () -> [Int: CGRect]) {
        value.merge(nextValue()) { _, new in new }
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
