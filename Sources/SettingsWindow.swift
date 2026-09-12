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
        window.title = "TopTab 设置"
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

    var body: some View {
        Form {
            generalSection
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

            Text("鼠标顶到屏幕顶部中央多宽的范围会唤出悬浮条（居中对齐）。默认 120 pt ≈ 4 个状态栏图标；外接屏上误触频繁可调小，难唤出可调大。")
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

            Text("改动系统权限后需要重启 TopTab 才会生效。")
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
                    Text("TopTab")
                        .font(.system(size: 14, weight: .semibold))
                    Text("顶部 App 切换条 · v\(appVersion)")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            Text("鼠标顶到屏幕顶部中央唤出，点击标签切换 App，悬停标签看窗口预览。")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
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
