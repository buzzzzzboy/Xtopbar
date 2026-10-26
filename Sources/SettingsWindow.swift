import SwiftUI
import AppKit
import Combine
import UniformTypeIdentifiers

// MARK: - 窗口

/// 设置窗口。自建 NSWindow 而不是用 SwiftUI 的 `Settings` 场景 ——
/// accessory App（LSUIElement）里 `Settings` 场景无法被 `showSettingsWindow:`
/// 稳定唤出，自建窗口可以直接控制尺寸、复用实例和激活行为。
@MainActor
final class SettingsWindowController {

    static let shared = SettingsWindowController()

    private var window: NSWindow?

    func show() {
        let window = existingOrNewWindow()
        NSApp.activate(ignoringOtherApps: true)
        window.center()
        window.makeKeyAndOrderFront(nil)
        TTLog("settings show frame=\(window.frame) visible=\(window.isVisible) "
              + "level=\(window.level.rawValue) onScreens=\(window.isOnActiveSpace)")
    }

    private func existingOrNewWindow() -> NSWindow {
        if let window { return window }

        let view = SettingsView(prefs: Preferences.shared)
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(x: 0, y: 0, width: 780, height: 680)

        // 同系统设定：侧栏从标题栏底下透上来（fullSizeContentView + 统一工具栏），
        // 标题栏里只留红绿灯，标题由右边内容的 navigationTitle 给
        let window = NSWindow(
            contentRect: hosting.frame,
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Xtopbar 設定"
        window.contentView = hosting
        window.isReleasedWhenClosed = false
        window.toolbar = NSToolbar(identifier: "xtopbar.settings")
        window.toolbarStyle = .unified
        window.titlebarSeparatorStyle = .automatic
        window.setFrameAutosaveName("XtopbarSettings")
        self.window = window
        return window
    }
}

// MARK: - 视图

/// 设置页分类（侧栏）。同系统设定：左边选类别，右边是这一类的分组表单
enum SettingsPage: String, CaseIterable, Identifiable {
    case general, appearance, dock, apps, windows, about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general:    return "一般"
        case .appearance: return "外觀"
        case .dock:       return "Dock 與開始選單"
        case .apps:       return "Apps"
        case .windows:    return "視窗"
        case .about:      return "關於"
        }
    }

    var symbol: String {
        switch self {
        case .general:    return "gearshape"
        case .appearance: return "paintbrush"
        case .dock:       return "dock.rectangle"
        case .apps:       return "app.dashed"
        case .windows:    return "macwindow.on.rectangle"
        case .about:      return "info.circle"
        }
    }
}

struct SettingsView: View {
    @ObservedObject var prefs: Preferences
    @ObservedObject private var updater = Updater.shared
    @State private var page: SettingsPage = .general

    var body: some View {
        NavigationSplitView {
            List(SettingsPage.allCases, selection: $page) { page in
                Label(page.title, systemImage: page.symbol)
                    .tag(page)
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 240)
        } detail: {
            Form {
                switch page {
                case .general:    generalPage
                case .appearance: appearancePage
                case .dock:       dockPage
                case .apps:       appsPage
                case .windows:    windowsPage
                case .about:      aboutPage
                }
            }
            .formStyle(.grouped)
            .navigationTitle(page.title)
        }
        .frame(minWidth: 720, idealWidth: 780, minHeight: 520, idealHeight: 680)
        // 1 秒一拍：授权是纯外部行为，没有通知可听，只能轮询刷新状态图标
        .onReceive(ticker) { _ in captureTick &+= 1 }
    }

    /// 一般：启动、悬浮条总开关、多屏、权限
    @ViewBuilder
    private var generalPage: some View {
        Section("啟動") {
            LaunchAtLoginRow()

            Toggle("在選單列顯示圖示", isOn: $prefs.showStatusItem)
                .toggleStyle(.switch)

            Text("關掉後選單列圖示消失。仍然可以右鍵懸浮條 →「設定…」回到這裡。")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }

        Section("懸浮條") {
            Toggle("啟用懸浮條", isOn: $prefs.barEnabled)
                .toggleStyle(.switch)
        }

        Section("多螢幕") {
            Toggle("在所有螢幕上顯示", isOn: $prefs.allScreens)
                .toggleStyle(.switch)

            Text("接外接螢幕時每塊螢幕各一條：每條只放視窗在那塊螢幕上的 App（固定項每條都有），點圖示切到 / 收起的也是那塊螢幕上的視窗；不擋視窗、全螢幕讓位、頂邊 / 底邊喚出各螢幕各管各的。按螢幕分 App 需要「輔助使用」權限，沒有時每條都顯示全部。")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            if !prefs.allScreens {
                Picker("喚出所在螢幕", selection: $prefs.hotZoneScreen) {
                    ForEach(HotZoneScreen.allCases) { screen in
                        Text(screen.title).tag(screen)
                    }
                }
                .pickerStyle(.radioGroup)

                Text(prefs.hotZoneScreen.subtitle.replacingOccurrences(of: "頂部", with: "邊緣"))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }

        Section("權限") {
            PermissionRow(
                title: "螢幕錄製",
                detail: "抓取視窗縮圖。沒授權時預覽只顯示 App 圖示。",
                granted: ScreenCaptureEngine.hasPermission,
                action: {
                    CGRequestScreenCaptureAccess()
                    ScreenCaptureEngine.requestPermissionIfNeeded()
                    openSettingsPane("Privacy_ScreenCapture")
                }
            )

            PermissionRow(
                title: "輔助使用",
                detail: "列舉每個 App 的真實視窗、點選縮圖精確切到那一個視窗。",
                granted: WindowBridge.isTrusted,
                action: {
                    WindowBridge.requestAccessibilityPermission()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                        WindowBridge.openAccessibilitySettings()
                    }
                }
            )

            PermissionRow(
                title: "完整磁碟取用",
                detail: "讀取瀏覽器的設定檔清單（右鍵 Chrome / Edge 等 →「開啟設定檔」）。macOS 把它算作其他 App 的資料，沒授權時這個選單不會出現。",
                granted: BrowserProfiles.hasDataAccess,
                action: { openSettingsPane("Privacy_AllFiles") }
            )

            Text("改動系統權限後需要重啟 Xtopbar 才會生效。")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }

    /// 外观：位置、显示与隐藏、样式、大小、透明度与动画
    @ViewBuilder
    private var appearancePage: some View {
        Section("位置") {
            Picker("Dock 位置", selection: $prefs.dockEdge) {
                ForEach(DockEdge.allCases) { edge in
                    Text(edge.title).tag(edge)
                }
            }
            .pickerStyle(.segmented)

            Text(prefs.dockEdge.subtitle)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            Toggle("隱藏系統 Dock", isOn: $prefs.hideSystemDock)
                .toggleStyle(.switch)

            Text("把系統 Dock 設為自動隱藏，讓 Xtopbar 接替它的位置；滑鼠頂到螢幕底邊仍可喚出 Dock，會蓋在條上面照常使用。會重啟一次 Dock；關掉即恢復原來的設定。")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }

        Section("顯示與隱藏") {
            Toggle("不擋視窗（常駐，視窗自動讓位）", isOn: $prefs.avoidWindows)
                .toggleStyle(.switch)

            Text("像 Windows 工作列：條一直顯示，壓到條上的視窗會被自動挪開或縮短，不會再蓋住視窗底部（停在頂部時是頂部）。有 App 全螢幕時條自動隱藏，滑鼠頂到螢幕邊緣仍可臨時喚出。需要「輔助使用」權限。")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            Picker("自動隱藏", selection: $prefs.hideDelay) {
                ForEach(Preferences.delayOptions, id: \.value) { option in
                    Text(option.label).tag(option.value)
                }
            }

            HStack {
                Text("喚醒熱區寬度")
                Slider(value: $prefs.hotZoneWidth, in: 60...400, step: 10)
                Text("\(Int(prefs.hotZoneWidth)) pt")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 48, alignment: .trailing)
            }

            Text("停在頂部時：滑鼠頂到螢幕頂部中央多寬的範圍會喚出懸浮條（居中對齊），預設 120 pt ≈ 4 個狀態列圖示；外接螢幕上誤觸頻繁可調小，難喚出可調大。停在底部時：沿整條懸浮條的寬度頂底邊都能喚出，這裡的值只是下限。")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }

        Section("樣式") {
            Toggle("只顯示圖示（Dock 風格）", isOn: $prefs.iconOnly)
                .toggleStyle(.switch)

            Text("開：大圖示 + 執行指示點，名字懸停顯示。關：圖示 + 名稱的標籤。")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            Toggle("App 之間的分隔線", isOn: $prefs.tabDividers)
                .toggleStyle(.switch)
                .disabled(prefs.iconOnly || prefs.barTheme == .liquidGlass)

            Text("圖示 + 名稱樣式下，相鄰 App 之間畫一條細線。關掉不畫線，間距也跟著收緊。固定和執行中兩組之間的線也一起拿掉。Liquid Glass 主題一律不畫。")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            Picker("工作列按鈕", selection: $prefs.taskbarGrouping) {
                ForEach(TaskbarGrouping.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.radioGroup)

            Text(prefs.taskbarGrouping.subtitle
                 + (prefs.taskbarGrouping == .always ? "" : "需要「輔助使用」權限，沒有時一律依 App 合併。"))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            Picker("主題", selection: $prefs.barTheme) {
                ForEach(BarTheme.allCases) { theme in
                    Text(theme.title).tag(theme)
                }
            }
            .pickerStyle(.radioGroup)

            Text(prefs.barTheme.subtitle)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            Picker("背景材質", selection: $prefs.glassStyle) {
                ForEach(GlassStyle.allCases.filter { $0 != .liquid || GlassStyle.liquidAvailable }) { style in
                    Label(style.title, systemImage: style.symbol).tag(style)
                }
            }
            .pickerStyle(.radioGroup)

            Text(prefs.glassStyle.subtitle)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }

        Section("大小") {
            HStack {
                Text("介面縮放")
                Slider(value: $prefs.uiScale, in: 0.8...1.3, step: 0.05)
                Text(String(format: "%.0f%%", prefs.uiScale * 100))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 44, alignment: .trailing)
            }

            Text("懸浮條與視窗預覽的整體大小（80%–130%）。拖曳即時生效；也可以按住開始按鈕旁的分隔線上下拖。")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            HStack {
                Text("圓角")
                Slider(value: $prefs.barCornerRadius, in: Preferences.barCornerRange, step: 1)
                Text(String(format: "%.0f pt", prefs.barCornerRadius))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 44, alignment: .trailing)
            }

            Text("懸浮條四角的弧度：0 是直角，拉到底是膠囊形。")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }

        Section("其他") {
            HStack {
                Text("待機不透明度")
                Slider(value: $prefs.idleOpacity, in: 0.4...1.0)
                Text(String(format: "%.0f%%", prefs.idleOpacity * 100))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 44, alignment: .trailing)
            }

            Toggle("進出場動畫", isOn: $prefs.animationsEnabled)
                .toggleStyle(.switch)
        }
    }

    /// Dock 与开始菜单：点击行为、开始菜单、固定 / 隐藏的 App
    @ViewBuilder
    private var dockPage: some View {
        Section("行為") {
            Toggle("點選前景 App 最小化視窗", isOn: $prefs.clickToMinimize)
                .toggleStyle(.switch)

            Text("點正在前景的 App 圖示：把它的視窗全部最小化；再點一次恢復。視窗預覽裡也能直接點回被最小化的視窗。需要「輔助使用」權限。")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            Toggle("只顯示有視窗的 App", isOn: $prefs.onlyWindowedApps)
                .toggleStyle(.switch)

            Text("執行中但一個視窗都沒有的 App（比如關完視窗還掛著的 Safari、Finder）不顯示；最小化的視窗也算有視窗。固定到工作列的 App 始終顯示。需要「輔助使用」權限。")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }

        Section("開始選單") {
            Toggle("顯示開始按鈕", isOn: $prefs.showStartButton)
                .toggleStyle(.switch)

            Text("條最左邊加一個 Windows 風格的開始按鈕：搜尋、已固定、最近使用、所有應用。")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            LabeledContent("搜尋快捷鍵") {
                HotKeyRecorder(key: $prefs.startSearchHotKey)
            }

            Text("在任何 App 裡按下，直接打開開始選單的搜尋頁；再按一次收起。點按鈕後按下新的組合鍵即可更改（需含 ⌘ / ⌃ / ⌥），按 Esc 取消。若和 Raycast、Spotlight 等用了同一組，可能會被對方搶走。")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            Picker("現正播放", selection: $prefs.nowPlayingSource) {
                ForEach(NowPlayingSource.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)

            Text("開始選單底部的播放控制。自動：誰在播就顯示誰；也可以固定為 Spotify 或 Apple Music。")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }

        Section("表情符號") {
            LabeledContent("表情符號選擇器") {
                HotKeyRecorder(key: $prefs.emojiHotKey)
            }

            Toggle("連按兩下 ⌥ 打開", isOn: $prefs.emojiDoubleOption)
                .toggleStyle(.switch)

            Text("在任何 App 裡按下快捷鍵，或快速連按兩下 ⌥（Option / Alt），彈出 Raycast 式的表情符號選擇器：打字搜尋（中英文都行），方向鍵選、↵ 直接貼進原來的 App，⌘↵ 只拷貝；Tab 切換分類、⌘⇧P 釘選，右鍵可選膚色。直接貼上需要「輔助使用」權限，沒有時 ↵ 只拷貝。")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }

        Section("固定與隱藏的 App") {
            PinnedAppsRow(title: "固定到工作列", pins: $prefs.dockPins, reorderable: true)
            PinnedAppsRow(title: "固定到開始選單", pins: $prefs.startPins, reorderable: true)

            Text("在條上或開始選單裡右鍵任意 App →「固定到工作列 / 開始選單」。固定到工作列的 App 沒在執行也會留在條上，點一下即開啟。")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            HiddenAppsRow(prefs: prefs)
            GroupingOverridesRow(prefs: prefs)
        }
    }

    /// Apps：开始菜单索引扫哪些目录、哪些 App 不进搜索结果
    @ViewBuilder
    private var appsPage: some View {
        Section {
            AppSourcesList(sources: $prefs.appSources)
        } header: {
            Text("App 來源")
        } footer: {
            Text("開始選單的搜尋和「所有應用」從這些資料夾找 App（往下翻 \(AppLibrary.maxDepth) 層）。預設路徑包含 /Applications、~/Applications 和系統內建 App；放在其它地方的 App 用 + 加進來，關掉開關即暫時不掃。")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }

        Section {
            Toggle("在搜尋結果中顯示隱藏的 App", isOn: $prefs.showHiddenInSearch)
                .toggleStyle(.switch)
        } header: {
            Text("隱藏的 App（\(prefs.searchHiddenApps.count)）")
        }

        Section {
            SearchHiddenAppsList(prefs: prefs)
                // 开始菜单还没打开过的话索引是空的，图标出不来
                .onAppear { AppLibrary.shared.refreshIfStale() }
        } footer: {
            Text("在開始選單裡右鍵 App →「從搜尋結果隱藏」：搜尋結果和「建議」不再列出它，「所有應用」裡照常顯示。點 − 取消隱藏。這和右鍵懸浮條標籤的「隱藏此 App」是兩回事。")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }

    /// 视窗：悬停预览、⌥Tab 切换器
    @ViewBuilder
    private var windowsPage: some View {
        Section("視窗預覽") {
            Toggle("視窗預覽", isOn: $prefs.previewEnabled)
                .toggleStyle(.switch)

            Toggle("只顯示已開啟的視窗", isOn: $prefs.hideMinimizedWindows)
                .toggleStyle(.switch)
        }

        Section("視窗切換器") {
            Toggle("⌥Tab 視窗切換器（所有視窗縮圖）", isOn: $prefs.windowSwitcherEnabled)
                .toggleStyle(.switch)

            Text("同 Windows Alt+Tab：按住 ⌥ 按 Tab，螢幕中央鋪開目前桌面所有視窗的縮圖，預選上一個視窗 —— 快按快放即切回上一個視窗；繼續按 Tab（⇧Tab 反向）或用方向鍵挑選，鬆開 ⌥ 切過去；滑鼠移到哪張選哪張、點一下直接切；Return 立刻切換，Esc 取消。最小化的視窗排在最後（標「已最小化」，選了會還原）；不列已隱藏的 App 和其它桌面的視窗。和懸浮條互不影響，需要輔助使用權限（縮圖需要螢幕錄製）。")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }

    /// 关于：版本、更新
    @ViewBuilder
    private var aboutPage: some View {
        Section("關於") {
            HStack(spacing: 12) {
                Image(nsImage: NSApp.applicationIconImage ?? NSImage())
                    .resizable()
                    .frame(width: 48, height: 48)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Xtopbar")
                        .font(.system(size: 14, weight: .semibold))
                    Text("Dock / App 切換條 · v\(appVersion)")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            Text("滑鼠頂到螢幕底邊（或頂部中央）喚出，點選圖示切換 / 開啟 App，懸停看視窗預覽，點最左邊的開始按鈕開啟開始選單。")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            updateRow
        }
    }

    /// 1 秒一次的刷新节拍，用来重新读权限状态（授权是外部行为，没有通知可听）
    @State private var captureTick = 0
    private let ticker = Timer.publish(every: 1.0, on: .main, in: .common).autoconnect()

    private func openSettingsPane(_ anchor: String) {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")!
        NSWorkspace.shared.open(url)
    }

    // MARK: 更新

    /// 在线更新：菜单栏「检查更新…」和这里共用一套逻辑。
    /// 发布信息来自 GitHub Releases，不需要任何自建服务器。
    @ViewBuilder
    private var updateRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Button("檢查更新") { updater.checkInteractively() }
                    .disabled(updater.phase.isBusy)

                if updater.phase.isBusy, case .working(let text) = updater.phase {
                    ProgressView()
                        .controlSize(.small)
                    Text(text)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                } else if updater.phase == .checking {
                    ProgressView().controlSize(.small)
                    Text("正在檢查…")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 8)

                Button("開啟發布頁") { updater.openReleasePage() }
                    .buttonStyle(.link)
                    .font(.system(size: 11))
            }

            switch updater.phase {
            case .upToDate:
                Text("已是最新版本。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            case .available(let release):
                Text("發現新版本 v\(release.version)，目前 v\(appVersion)。")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
            case .failed(let message):
                Text("檢查失敗：\(message)")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            default:
                EmptyView()
            }

            Toggle("自動檢查更新（啟動時及每小時）", isOn: $prefs.autoCheckUpdates)
                .toggleStyle(.switch)
        }
    }

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }
}

// MARK: - 子视图

/// 已隐藏的 App 列表：右键标签「隐藏此 App」的释放入口。
/// 删除一项 → Preferences.hiddenApps 变化 → 控制器订阅里立刻重采，标签即时回来。
private struct HiddenAppsRow: View {
    @ObservedObject var prefs: Preferences

    var body: some View {
        if !prefs.hiddenApps.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("從懸浮條隱藏的 App（\(prefs.hiddenApps.count)）")
                    .font(.system(size: 12, weight: .medium))
                ForEach(prefs.hiddenApps.sorted { $0.value.localizedStandardCompare($1.value) == .orderedAscending }, id: \.key) { bid, name in
                    HStack(spacing: 8) {
                        Text(name)
                            .font(.system(size: 12))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 8)
                        Button("顯示") {
                            var hidden = prefs.hiddenApps
                            hidden.removeValue(forKey: bid)
                            prefs.hiddenApps = hidden
                        }
                        .controlSize(.small)
                    }
                }
                Text("隱藏的 App 不會出現在懸浮條標籤裡，但仍在正常執行。點「顯示」立即釋放。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 2)
        }
    }
}

/// 合并例外列表：右键标签「視窗按鈕 → 一律合併 / 永不合併」设过的 App，点「跟隨全域」改回去
private struct GroupingOverridesRow: View {
    @ObservedObject var prefs: Preferences

    private static func name(_ bid: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bid) else { return bid }
        return AppNames.localized(url: url) ?? FileManager.default.displayName(atPath: url.path)
    }

    var body: some View {
        if !prefs.groupingOverrides.isEmpty {
            let rows = prefs.groupingOverrides.map { (bid: $0.key, name: Self.name($0.key), mode: $0.value) }
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            VStack(alignment: .leading, spacing: 6) {
                Text("合併例外（\(rows.count)）")
                    .font(.system(size: 12, weight: .medium))
                ForEach(rows, id: \.bid) { row in
                    HStack(spacing: 8) {
                        Text(row.name)
                            .font(.system(size: 12))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 8)
                        Text(row.mode == .always ? "一律合併" : "永不合併")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        Button("跟隨全域") {
                            var map = prefs.groupingOverrides
                            map.removeValue(forKey: row.bid)
                            prefs.groupingOverrides = map
                        }
                        .controlSize(.small)
                    }
                }
                Text("在條上右鍵 App →「視窗按鈕」可以讓個別 App 一律合併成一格，或永遠每扇視窗一格，不受「工作列按鈕」設定影響。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 2)
        }
    }
}

/// 「App 來源」列表：第一行是内建的默认路径（不能删、不能关），下面是用户加的目录，
/// 每个带开关；底部 + / − 增删（− 删选中的那行）。同系统设定里「登入項目」那种列表
private struct AppSourcesList: View {
    @Binding var sources: [AppSource]
    @State private var selection: UUID?

    var body: some View {
        VStack(spacing: 0) {
            SourceRow(name: "應用程式", detail: "預設路徑")
                .help(AppLibrary.defaultRoots.map(\.path).joined(separator: "\n"))
            ForEach($sources) { $source in
                Divider()
                SourceRow(name: FileManager.default.displayName(atPath: source.path),
                          detail: (source.path as NSString).abbreviatingWithTildeInPath,
                          missing: !FileManager.default.fileExists(atPath: source.path)) {
                    Toggle("", isOn: $source.enabled)
                        .toggleStyle(.switch)
                        .labelsHidden()
                        .controlSize(.small)
                }
                .background(selection == source.id ? Color.accentColor.opacity(0.18) : .clear)
                .contentShape(Rectangle())
                .onTapGesture { selection = selection == source.id ? nil : source.id }
            }
            Divider()
            HStack(spacing: 0) {
                Button { add() } label: {
                    Image(systemName: "plus").frame(width: 24, height: 20)
                }
                .help("加入資料夾")
                Divider().frame(height: 14)
                Button { remove() } label: {
                    Image(systemName: "minus").frame(width: 24, height: 20)
                }
                .disabled(selection == nil)
                .help("移除選中的資料夾")
                Spacer()
            }
            .buttonStyle(.borderless)
            .padding(.vertical, 4)
        }
    }

    private func add() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "加入"
        panel.message = "選擇要掃描 App 的資料夾"
        // accessory App：不先激活的话面板会躲在别的窗口后面
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK else { return }
        let existing = Set((AppLibrary.defaultRoots.map(\.path) + sources.map(\.path))
            .map { URL(fileURLWithPath: $0).standardizedFileURL.path })
        var added = Set<String>()
        for url in panel.urls {
            let path = url.standardizedFileURL.path
            guard !existing.contains(path), added.insert(path).inserted else { continue }
            sources.append(AppSource(path: path))
        }
    }

    private func remove() {
        guard let selection else { return }
        sources.removeAll { $0.id == selection }
        self.selection = nil
    }
}

private struct SourceRow<Accessory: View>: View {
    let name: String
    let detail: String
    var missing = false
    @ViewBuilder var accessory: () -> Accessory

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: NSWorkspace.shared.icon(for: .folder))
                .resizable()
                .frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text(name)
                    .font(.system(size: 12))
                Text(missing ? "\(detail)（找不到這個資料夾）" : detail)
                    .font(.system(size: 11))
                    .foregroundStyle(missing ? Color.orange : .secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            accessory()
        }
        .padding(.vertical, 5)
    }
}

extension SourceRow where Accessory == EmptyView {
    init(name: String, detail: String) {
        self.init(name: name, detail: detail, accessory: { EmptyView() })
    }
}

/// 「從搜尋結果隱藏」的 App：图标 + 名字 + −。App 已经卸载的话只剩名字（图标给个通用的）
private struct SearchHiddenAppsList: View {
    @ObservedObject var prefs: Preferences
    @ObservedObject private var library = AppLibrary.shared

    var body: some View {
        let items = prefs.searchHiddenApps
            .sorted { $0.value.localizedStandardCompare($1.value) == .orderedAscending }
        if items.isEmpty {
            Text("還沒有。")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        ForEach(items, id: \.key) { bid, name in
            let app = library.app(bundleID: bid)
            HStack(spacing: 8) {
                Group {
                    if let app {
                        Image(nsImage: library.icon(for: app.url)).resizable()
                    } else {
                        Image(nsImage: NSWorkspace.shared.icon(for: .applicationBundle))
                            .resizable()
                            .opacity(0.5)
                    }
                }
                .frame(width: 18, height: 18)
                Text(app?.name ?? name)
                    .font(.system(size: 12))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
                Button {
                    prefs.searchHiddenApps.removeValue(forKey: bid)
                } label: {
                    Image(systemName: "minus.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("取消隱藏")
            }
        }
    }
}

/// 固定的 App 列表（任务栏 / 开始菜单各一份）：移除、上下调整顺序。
/// 改的是 Preferences 里的数组 → 控制器订阅里立刻重采，条上即时反映。
private struct PinnedAppsRow: View {
    let title: String
    @Binding var pins: [PinnedApp]
    var reorderable: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("\(title)（\(pins.count)）")
                .font(.system(size: 12, weight: .medium))
            if pins.isEmpty {
                Text("還沒有。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            ForEach(Array(pins.enumerated()), id: \.element.id) { index, pin in
                HStack(spacing: 8) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: pin.path))
                        .resizable()
                        .frame(width: 16, height: 16)
                    Text(pin.name)
                        .font(.system(size: 12))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 8)
                    if reorderable {
                        Button { move(index, by: -1) } label: { Image(systemName: "chevron.up") }
                            .disabled(index == 0)
                        Button { move(index, by: 1) } label: { Image(systemName: "chevron.down") }
                            .disabled(index == pins.count - 1)
                    }
                    Button("移除") { pins.remove(at: index) }
                }
                .controlSize(.small)
            }
        }
        .padding(.vertical, 2)
    }

    private func move(_ index: Int, by offset: Int) {
        let j = index + offset
        guard pins.indices.contains(index), pins.indices.contains(j) else { return }
        pins.swapAt(index, j)
    }
}

/// 开机自启动开关。SMAppService 的状态是系统侧的，用本地 state 承接，
/// 注册失败时回滚并显示原因。
private struct LaunchAtLoginRow: View {
    @State private var enabled = LaunchAtLogin.isEnabled
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle("開機自動啟動", isOn: $enabled)
                .toggleStyle(.switch)
                .onChange(of: enabled) { _, newValue in
                    if let message = LaunchAtLogin.set(newValue) {
                        error = message
                        enabled = LaunchAtLogin.isEnabled
                    } else {
                        error = nil
                    }
                }

            if let error {
                Text("註冊失敗：\(error)")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                Button("開啟登入項目設定") { LaunchAtLogin.openLoginItemsSettings() }
                    .font(.system(size: 11))
                    .buttonStyle(.link)
            } else if LaunchAtLogin.isEnabled {
                Text(LaunchAtLogin.statusDescription)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct PermissionRow: View {
    let title: String
    let detail: String
    let granted: Bool
    let action: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: granted ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(granted ? Color.green : Color.red)
                .font(.system(size: 14))
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 12, weight: .medium))
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            if !granted {
                Button("授權") { action() }
            }
        }
    }
}

/// 快捷键录制按钮：点一下进入录制，按下组合键即保存；Esc 取消。旁边的 ⓧ 清除
private struct HotKeyRecorder: View {
    @Binding var key: HotKey?
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        HStack(spacing: 6) {
            Button {
                recording ? stop() : start()
            } label: {
                Text(recording ? "請按下快捷鍵…" : key?.display ?? "未設定")
                    .frame(minWidth: 110)
            }
            if key != nil, !recording {
                Button { key = nil } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("清除快捷鍵")
            }
        }
        .onDisappear { stop() }
    }

    private func start() {
        recording = true
        // 录制期间先注销现有快捷键，否则按同一组会直接触发、录不到
        GlobalHotKeys.shared.suspend()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 { stop(); return nil }  // Esc 取消
            if let new = HotKey(event: event) {
                key = new
                stop()
            } else {
                NSSound.beep()  // 没带修饰键：不收
            }
            return nil
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        recording = false
        GlobalHotKeys.shared.resume()
    }
}
