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
                    LazyVGrid(columns: pinColumns, spacing: TTLayout.s(6)) {
                        ForEach(pinnedApps) { app in
                            StartTile(app: app, icon: library.icon(for: app.url)) { onLaunch(app) }
                                .contextMenu { itemMenu(app) }
                        }
                    }
                }

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

    // MARK: - 所有应用（A–Z）

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

            if library.apps.isEmpty {
                ProgressView().controlSize(.small)
                    .frame(maxWidth: .infinity, minHeight: TTLayout.s(80))
            } else {
                ScrollView(.vertical) {
                    LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                        ForEach(StartMenuIndex.sections(library.apps), id: \.letter) { section in
                            Section {
                                ForEach(section.apps) { app in
                                    StartRow(app: app, icon: library.icon(for: app.url)) { onLaunch(app) }
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

    /// 固定到开始菜单的项。App 被删掉（路径不在、也按 bundle id 找不到）的就不显示了，
    /// 但仍留在偏好里 —— 装回来会自己出现，设置里也能手动移除。
    private var pinnedApps: [LibraryApp] {
        prefs.startPins.compactMap { pin -> LibraryApp? in
            if let app = library.app(bundleID: pin.bundleID) { return app }
            if FileManager.default.fileExists(atPath: pin.path) {
                return LibraryApp(bundleID: pin.bundleID, url: pin.url, name: pin.name)
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
                let name = FileManager.default.displayName(atPath: url.path)
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
}

/// 已固定网格里的一格：大图标 + 两行名字
private struct StartTile: View {
    let app: LibraryApp
    let icon: NSImage
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
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
                    .fill(Color.primary.opacity(hovering ? 0.10 : 0))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(app.name)
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
