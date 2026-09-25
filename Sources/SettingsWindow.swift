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
        window.title = "Xtopbar 设置"
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
        Section("通用") {
            LaunchAtLoginRow()

            Toggle("在菜单栏显示图标", isOn: $prefs.showStatusItem)
                .toggleStyle(.switch)

            Text("关掉后菜单栏图标消失。仍然可以右键悬浮条 →「设置…」回到这里。")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Dock

    private var dockSection: some View {
        Section("Dock 与开始菜单") {
            Picker("Dock 位置", selection: $prefs.dockEdge) {
                ForEach(DockEdge.allCases) { edge in
                    Text(edge.title).tag(edge)
                }
            }
            .pickerStyle(.segmented)

            Text(prefs.dockEdge.subtitle)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            Toggle("只显示图标（Dock 风格）", isOn: $prefs.iconOnly)
                .toggleStyle(.switch)

            Text("开：大图标 + 运行指示点，名字悬停显示。关：图标 + 名称的标签。")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            Toggle("只显示有窗口的 App", isOn: $prefs.onlyWindowedApps)
                .toggleStyle(.switch)

            Text("运行中但一个窗口都没有的 App（比如关完窗口还挂着的 Safari、访达）不显示；最小化的窗口也算有窗口。固定到任务栏的 App 始终显示。需要「辅助功能」权限。")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            Toggle("隐藏系统 Dock", isOn: $prefs.hideSystemDock)
                .toggleStyle(.switch)

            Text("把系统 Dock 设为自动隐藏并把唤出延迟调到极长，让 Xtopbar 接替它。会重启一次 Dock；关掉即恢复原来的设置。")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            PinnedAppsRow(title: "固定到任务栏", pins: $prefs.dockPins, reorderable: true)
            PinnedAppsRow(title: "固定到开始菜单", pins: $prefs.startPins, reorderable: true)

            Text("在条上或开始菜单里右键任意 App →「固定到任务栏 / 开始菜单」。固定到任务栏的 App 没在运行也会留在条上，点一下即打开。")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }

    // MARK: 悬浮条

    private var barSection: some View {
        Section("悬浮条") {
            Toggle("启用悬浮条", isOn: $prefs.barEnabled)
                .toggleStyle(.switch)

            HStack {
                Text("唤醒热区宽度")
                Slider(value: $prefs.hotZoneWidth, in: 60...400, step: 10)
                Text("\(Int(prefs.hotZoneWidth)) pt")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 48, alignment: .trailing)
            }

            Text("停在顶部时：鼠标顶到屏幕顶部中央多宽的范围会唤出悬浮条（居中对齐），默认 120 pt ≈ 4 个状态栏图标；外接屏上误触频繁可调小，难唤出可调大。停在底部时：沿整条悬浮条的宽度顶底边都能唤出，这里的值只是下限。")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            Picker("唤出所在屏幕", selection: $prefs.hotZoneScreen) {
                ForEach(HotZoneScreen.allCases) { screen in
                    Text(screen.title).tag(screen)
                }
            }
            .pickerStyle(.radioGroup)

            Text(prefs.hotZoneScreen.subtitle.replacingOccurrences(of: "顶部", with: "边缘")
                 + " ⌘Tab 呼出不受这里影响，始终在鼠标位置弹出。")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            Toggle("窗口预览", isOn: $prefs.previewEnabled)
                .toggleStyle(.switch)

            Toggle("只显示已打开的窗口", isOn: $prefs.hideMinimizedWindows)
                .toggleStyle(.switch)

            Picker("自动隐藏", selection: $prefs.hideDelay) {
                ForEach(Preferences.delayOptions, id: \.value) { option in
                    Text(option.label).tag(option.value)
                }
            }

            Toggle("⌘Tab 呼出（快速切换 + 鼠标挑选）", isOn: $prefs.cmdTabEnabled)
                .toggleStyle(.switch)

            Text("开启后接管系统 ⌘Tab（需要辅助功能权限）：按下立即在鼠标位置弹出悬浮条并预选上一个 App —— 快按快放即切回上一个（Windows Alt+Tab）；继续按 Tab 沿最近使用顺序循环，或用鼠标点选；松开 ⌘ 确认，Esc 取消。")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            HiddenAppsRow(prefs: prefs)

            Picker("背景材质", selection: $prefs.glassStyle) {
                ForEach(GlassStyle.allCases.filter { $0 != .liquid || GlassStyle.liquidAvailable }) { style in
                    Label(style.title, systemImage: style.symbol).tag(style)
                }
            }
            .pickerStyle(.radioGroup)

            Text(prefs.glassStyle.subtitle)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            HStack {
                Text("界面缩放")
                Slider(value: $prefs.uiScale, in: 0.8...1.3, step: 0.05)
                Text(String(format: "%.0f%%", prefs.uiScale * 100))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 44, alignment: .trailing)
            }

            Text("悬浮条与窗口预览的整体大小（80%–130%）。拖动即时生效。")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            HStack {
                Text("待机不透明度")
                Slider(value: $prefs.idleOpacity, in: 0.4...1.0)
                Text(String(format: "%.0f%%", prefs.idleOpacity * 100))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 44, alignment: .trailing)
            }

            Toggle("进出场动画", isOn: $prefs.animationsEnabled)
                .toggleStyle(.switch)
        }
    }

    // MARK: 权限

    private var permissionSection: some View {
        Section("权限") {
            PermissionRow(
                title: "屏幕录制",
                detail: "抓取窗口缩略图。没授权时预览只显示 App 图标。",
                granted: ScreenCaptureEngine.hasPermission,
                action: {
                    CGRequestScreenCaptureAccess()
                    ScreenCaptureEngine.requestPermissionIfNeeded()
                    openSettingsPane("Privacy_ScreenCapture")
                }
            )

            PermissionRow(
                title: "辅助功能",
                detail: "枚举每个 App 的真实窗口、点击缩略图精确切到那一个窗口。",
                granted: WindowBridge.isTrusted,
                action: {
                    WindowBridge.requestAccessibilityPermission()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                        WindowBridge.openAccessibilitySettings()
                    }
                }
            )

            Text("改动系统权限后需要重启 Xtopbar 才会生效。")
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
        Section("关于") {
            HStack(spacing: 12) {
                Image(nsImage: NSApp.applicationIconImage ?? NSImage())
                    .resizable()
                    .frame(width: 48, height: 48)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Xtopbar")
                        .font(.system(size: 14, weight: .semibold))
                    Text("Dock / App 切换条 · v\(appVersion)")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            Text("鼠标顶到屏幕底边（或顶部中央）唤出，点击图标切换 / 打开 App，悬停看窗口预览，点最左边的开始按钮打开开始菜单。")
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
                Button("检查更新") { updater.checkInteractively() }
                    .disabled(updater.phase.isBusy)

                if updater.phase.isBusy, case .working(let text) = updater.phase {
                    ProgressView()
                        .controlSize(.small)
                    Text(text)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                } else if updater.phase == .checking {
                    ProgressView().controlSize(.small)
                    Text("正在检查…")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 8)

                Button("打开发布页") { updater.openReleasePage() }
                    .buttonStyle(.link)
                    .font(.system(size: 11))
            }

            switch updater.phase {
            case .upToDate:
                Text("已是最新版本。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            case .available(let release):
                Text("发现新版本 v\(release.version)，当前 v\(appVersion)。")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
            case .failed(let message):
                Text("检查失败：\(message)")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            default:
                EmptyView()
            }

            Toggle("启动后自动检查更新", isOn: $prefs.autoCheckUpdates)
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
                Text("已隐藏的 App（\(prefs.hiddenApps.count)）")
                    .font(.system(size: 12, weight: .medium))
                ForEach(prefs.hiddenApps.sorted { $0.value.localizedStandardCompare($1.value) == .orderedAscending }, id: \.key) { bid, name in
                    HStack(spacing: 8) {
                        Text(name)
                            .font(.system(size: 12))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 8)
                        Button("显示") {
                            var hidden = prefs.hiddenApps
                            hidden.removeValue(forKey: bid)
                            prefs.hiddenApps = hidden
                        }
                        .controlSize(.small)
                    }
                }
                Text("隐藏的 App 不会出现在悬浮条标签里，但仍在正常运行。点「显示」立即释放。")
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
                Text("还没有。")
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
            Toggle("开机自动启动", isOn: $enabled)
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
                Text("注册失败：\(error)")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                Button("打开登录项设置") { LaunchAtLogin.openLoginItemsSettings() }
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
                Button("授权") { action() }
            }
        }
    }
}
