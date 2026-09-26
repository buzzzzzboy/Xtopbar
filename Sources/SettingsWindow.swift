import SwiftUI
import AppKit
import Combine

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
        hosting.frame = NSRect(x: 0, y: 0, width: 560, height: 820)

        let window = NSWindow(
            contentRect: hosting.frame,
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Xtopbar 設定"
        window.contentView = hosting
        window.isReleasedWhenClosed = false
        window.titlebarSeparatorStyle = .automatic
        self.window = window
        return window
    }
}

// MARK: - 视图

struct SettingsView: View {
    @ObservedObject var prefs: Preferences
    @ObservedObject private var updater = Updater.shared

    var body: some View {
        Form {
            generalSection
            dockSection
            barSection
            permissionSection
            aboutSection
        }
        .formStyle(.grouped)
        .frame(minWidth: 520, idealWidth: 560, minHeight: 500, idealHeight: 820)
        // 1 秒一拍：授权是纯外部行为，没有通知可听，只能轮询刷新状态图标
        .onReceive(ticker) { _ in captureTick &+= 1 }
    }

    // MARK: 通用

    private var generalSection: some View {
        Section("一般") {
            LaunchAtLoginRow()

            Toggle("在選單列顯示圖示", isOn: $prefs.showStatusItem)
                .toggleStyle(.switch)

            Text("關掉後選單列圖示消失。仍然可以右鍵懸浮條 →「設定…」回到這裡。")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Dock

    private var dockSection: some View {
        Section("Dock 與開始選單") {
            Picker("Dock 位置", selection: $prefs.dockEdge) {
                ForEach(DockEdge.allCases) { edge in
                    Text(edge.title).tag(edge)
                }
            }
            .pickerStyle(.segmented)

            Text(prefs.dockEdge.subtitle)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            Toggle("顯示開始按鈕", isOn: $prefs.showStartButton)
                .toggleStyle(.switch)

            Text("條最左邊加一個 Windows 風格的開始按鈕：搜尋、已固定、最近使用、所有應用。")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            Picker("現正播放", selection: $prefs.nowPlayingSource) {
                ForEach(NowPlayingSource.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)

            Text("開始選單底部的播放控制。自動：誰在播就顯示誰；也可以固定為 Spotify 或 Apple Music。")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            Toggle("只顯示圖示（Dock 風格）", isOn: $prefs.iconOnly)
                .toggleStyle(.switch)

            Text("開：大圖示 + 執行指示點，名字懸停顯示。關：圖示 + 名稱的標籤。")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            Toggle("只顯示有視窗的 App", isOn: $prefs.onlyWindowedApps)
                .toggleStyle(.switch)

            Text("執行中但一個視窗都沒有的 App（比如關完視窗還掛著的 Safari、Finder）不顯示；最小化的視窗也算有視窗。固定到工作列的 App 始終顯示。需要「輔助使用」權限。")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            Toggle("隱藏系統 Dock", isOn: $prefs.hideSystemDock)
                .toggleStyle(.switch)

            Text("把系統 Dock 設為自動隱藏並把喚出延遲調到極長，讓 Xtopbar 接替它。會重啟一次 Dock；關掉即恢復原來的設定。")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            Toggle("不擋視窗（常駐，視窗自動讓位）", isOn: $prefs.avoidWindows)
                .toggleStyle(.switch)

            Text("像 Windows 工作列：條一直顯示，壓到條上的視窗會被自動挪開或縮短，不會再蓋住視窗底部（停在頂部時是頂部）。有 App 全螢幕時條自動隱藏，滑鼠頂到螢幕邊緣仍可臨時喚出。需要「輔助使用」權限。")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            Toggle("點選前景 App 最小化視窗", isOn: $prefs.clickToMinimize)
                .toggleStyle(.switch)

            Text("點正在前景的 App 圖示：把它的視窗全部最小化；再點一次恢復。視窗預覽裡也能直接點回被最小化的視窗。需要「輔助使用」權限。")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            PinnedAppsRow(title: "固定到工作列", pins: $prefs.dockPins, reorderable: true)
            PinnedAppsRow(title: "固定到開始選單", pins: $prefs.startPins, reorderable: true)

            Text("在條上或開始選單裡右鍵任意 App →「固定到工作列 / 開始選單」。固定到工作列的 App 沒在執行也會留在條上，點一下即開啟。")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }

    // MARK: 悬浮条

    private var barSection: some View {
        Section("懸浮條") {
            Toggle("啟用懸浮條", isOn: $prefs.barEnabled)
                .toggleStyle(.switch)

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

            Picker("喚出所在螢幕", selection: $prefs.hotZoneScreen) {
                ForEach(HotZoneScreen.allCases) { screen in
                    Text(screen.title).tag(screen)
                }
            }
            .pickerStyle(.radioGroup)

            Text(prefs.hotZoneScreen.subtitle.replacingOccurrences(of: "頂部", with: "邊緣")
                 + " ⌘Tab 叫出不受這裡影響，始終在滑鼠位置彈出。")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            Toggle("視窗預覽", isOn: $prefs.previewEnabled)
                .toggleStyle(.switch)

            Toggle("只顯示已開啟的視窗", isOn: $prefs.hideMinimizedWindows)
                .toggleStyle(.switch)

            Picker("自動隱藏", selection: $prefs.hideDelay) {
                ForEach(Preferences.delayOptions, id: \.value) { option in
                    Text(option.label).tag(option.value)
                }
            }

            Toggle("⌘Tab 叫出（快速切換 + 滑鼠挑選）", isOn: $prefs.cmdTabEnabled)
                .toggleStyle(.switch)

            Text("開啟後接管系統 ⌘Tab（需要輔助使用權限）：按下立即在滑鼠位置彈出懸浮條並預選上一個 App —— 快按快放即切回上一個（Windows Alt+Tab）；繼續按 Tab 沿最近使用順序循環，或用滑鼠點選；鬆開 ⌘ 確認，Esc 取消。")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            HiddenAppsRow(prefs: prefs)

            Picker("背景材質", selection: $prefs.glassStyle) {
                ForEach(GlassStyle.allCases.filter { $0 != .liquid || GlassStyle.liquidAvailable }) { style in
                    Label(style.title, systemImage: style.symbol).tag(style)
                }
            }
            .pickerStyle(.radioGroup)

            Text(prefs.glassStyle.subtitle)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            HStack {
                Text("介面縮放")
                Slider(value: $prefs.uiScale, in: 0.8...1.3, step: 0.05)
                Text(String(format: "%.0f%%", prefs.uiScale * 100))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 44, alignment: .trailing)
            }

            Text("懸浮條與視窗預覽的整體大小（80%–130%）。拖曳即時生效。")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

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

    // MARK: 权限

    private var permissionSection: some View {
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

            Text("改動系統權限後需要重啟 Xtopbar 才會生效。")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }

    /// 1 秒一次的刷新节拍，用来重新读权限状态（授权是外部行为，没有通知可听）
    @State private var captureTick = 0
    private let ticker = Timer.publish(every: 1.0, on: .main, in: .common).autoconnect()

    private func openSettingsPane(_ anchor: String) {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")!
        NSWorkspace.shared.open(url)
    }

    // MARK: 关于

    private var aboutSection: some View {
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

            Toggle("啟動後自動檢查更新", isOn: $prefs.autoCheckUpdates)
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
                Text("已隱藏的 App（\(prefs.hiddenApps.count)）")
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
