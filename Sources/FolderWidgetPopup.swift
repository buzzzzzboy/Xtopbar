import AppKit
import SwiftUI

/// 工作列「資料夾」小工具点开的卡片：唯读的 App 格子，点一个就开启并收起。
/// 写法同 `BackgroundFolderController` 的网格（独立浮窗、Esc / 点外面收起），一次只开一张
@MainActor
final class FolderWidgetPopup {
    final class State: ObservableObject {
        @Published var folderID: UUID?
    }

    private let catalog: AppCatalog
    private let state = State()
    private let popup: FloatingPanel
    private let host: FirstMouseHostingView<FolderWidgetCard>
    private var monitors: [Any] = []
    private var resignObserver: NSObjectProtocol?

    /// 卡片要打开了（条据此收掉预览、开始菜单、背景网格）
    var onOpen: (@MainActor () -> Void)?
    var onClose: (@MainActor () -> Void)?
    /// 空资料夹的「在開始選單中編輯」
    var onEditInStartMenu: (@MainActor (UUID) -> Void)?
    /// 有右键菜单开着（同背景网格）
    var menuOpen = false

    var isOpen: Bool { popup.isVisible && state.folderID != nil }
    var openFolderID: UUID? { isOpen ? state.folderID : nil }

    init(catalog: AppCatalog) {
        self.catalog = catalog
        popup = FloatingPanel(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100))
        popup.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        host = FirstMouseHostingView(rootView: FolderWidgetCard(state: state, prefs: Preferences.shared,
                                                                 onOpenApp: { _ in }, onEdit: { _ in }))
        host.autoresizingMask = [.width, .height]
        popup.contentView = host
        host.rootView = FolderWidgetCard(
            state: state, prefs: Preferences.shared,
            onOpenApp: { [weak self] app in
                self?.close()
                self?.catalog.launch(url: app.url, bundleID: app.bundleID)
            },
            onEdit: { [weak self] id in
                self?.close(animated: false)
                self?.onEditInStartMenu?(id)
            })
    }

    func contains(_ point: NSPoint) -> Bool {
        isOpen && popup.frame.insetBy(dx: -1, dy: -1).contains(point)
    }

    /// - Parameters:
    ///   - anchor: 小工具在屏幕上的位置
    ///   - barFrame: 条（面板）的位置，决定往上还是往下弹
    func toggle(folderID: UUID, anchor: NSRect, barFrame: NSRect) {
        if openFolderID == folderID { close(); return }
        close(animated: false)
        guard let folder = Preferences.shared.startFolders.first(where: { $0.id == folderID }) else { return }
        onOpen?()
        state.folderID = folderID
        let size = FolderWidgetCard.size(count: FolderWidgetCard.apps(in: folder).count)
        let screen = NSScreen.screens.first { $0.frame.intersects(barFrame) } ?? NSScreen.main ?? NSScreen.screens[0]
        let target = DockGeometry.popupFrame(size: size, anchorX: anchor.midX, alignLeft: false,
                                             barFrame: barFrame, visible: screen.visibleFrame, gap: 8)
        popup.setFrame(target, display: true)
        host.frame = NSRect(origin: .zero, size: size)
        popup.alphaValue = 0
        FloatingPanel.handingKeyBack = false
        popup.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = Preferences.shared.animationsEnabled ? 0.12 : 0
            popup.animator().alphaValue = 1
        }
        installMonitors()
        TTLog("folderWidget open \(folder.name) frame=\(target)")
    }

    func close(animated: Bool = true) {
        guard popup.isVisible else { state.folderID = nil; return }
        TTLog("folderWidget close")
        removeMonitors()
        state.folderID = nil
        if animated, Preferences.shared.animationsEnabled {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.1
                popup.animator().alphaValue = 0
            } completionHandler: { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.state.folderID == nil else { return }
                    self.popup.orderOutHandingKeyBack()
                }
            }
        } else {
            popup.orderOutHandingKeyBack()
        }
        onClose?()
    }

    // MARK: - Esc / 点外面收起

    private func installMonitors() {
        removeMonitors()
        if let m = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            let swallow = MainActor.assumeIsolated { () -> Bool in
                guard let self, event.keyCode == 53, event.window === self.popup else { return false }
                self.close()
                return true
            }
            return swallow ? nil : event
        }) { monitors.append(m) }

        // 点到自己的其它窗口：条上的小工具除外（它自己会 toggle）
        if let m = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] event in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    let w = event.window
                    let isMenu = (w?.level.rawValue ?? 0) >= NSWindow.Level.popUpMenu.rawValue
                    let onBar = w.map { self.catalog.host?.isBarWindow($0) ?? false } ?? false
                    if w !== self.popup, !isMenu, !onBar { self.close() }
                }
                return event
            }) { monitors.append(m) }

        if let m = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] _ in
                DispatchQueue.main.async { self?.close() }
            }) { monitors.append(m) }

        resignObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: popup, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.menuOpen else { return }
                self.close()
            }
        }
    }

    private func removeMonitors() {
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors.removeAll()
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        resignObserver = nil
    }
}

/// 卡片内容：资料夹名 + App 格子（图标 + 名称）。尺寸固定，不跟「介面縮放」走（同背景网格）
struct FolderWidgetCard: View {
    @ObservedObject var state: FolderWidgetPopup.State
    @ObservedObject var prefs: Preferences
    let onOpenApp: (LibraryApp) -> Void
    let onEdit: (UUID) -> Void

    static let columns = 4
    static let cell = CGSize(width: 76, height: 78)
    static let padding: CGFloat = 12
    static let header: CGFloat = 22

    static func size(count: Int) -> CGSize {
        guard count > 0 else { return CGSize(width: 220, height: 120) }
        let cols = min(count, columns)
        let rows = (count + columns - 1) / columns
        return CGSize(width: CGFloat(cols) * cell.width + padding * 2,
                      height: CGFloat(rows) * cell.height + padding * 2 + header)
    }

    /// 资料夹里还在的 App（同开始菜单 `resolved`：找不到的跳过）
    static func apps(in folder: StartFolder) -> [LibraryApp] {
        folder.apps.compactMap { pin -> LibraryApp? in
            if let app = AppLibrary.shared.app(bundleID: pin.bundleID) { return app }
            guard FileManager.default.fileExists(atPath: pin.path) else { return nil }
            return LibraryApp(bundleID: pin.bundleID, url: pin.url,
                              name: AppNames.localized(url: pin.url) ?? pin.name)
        }
    }

    private var folder: StartFolder? {
        state.folderID.flatMap { id in prefs.startFolders.first { $0.id == id } }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let folder {
                Text(folder.name.isEmpty ? "未命名" : folder.name)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(height: Self.header, alignment: .topLeading)
                let apps = Self.apps(in: folder)
                if apps.isEmpty {
                    VStack(spacing: 10) {
                        Text("資料夾是空的").foregroundStyle(.secondary)
                        Button("在開始選單中編輯") { onEdit(folder.id) }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    LazyVGrid(columns: Array(repeating: GridItem(.fixed(Self.cell.width), spacing: 0),
                                             count: min(apps.count, Self.columns)), spacing: 0) {
                        ForEach(apps) { app in FolderWidgetCell(app: app) { onOpenApp(app) } }
                    }
                }
            }
        }
        .padding(Self.padding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(GlassBackdrop(style: prefs.glassStyle, cornerRadius: 18))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

private struct FolderWidgetCell: View {
    let app: LibraryApp
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        VStack(spacing: 5) {
            Image(nsImage: AppLibrary.shared.icon(for: app.url))
                .resizable().interpolation(.high)
                .frame(width: 40, height: 40)
            Text(app.name)
                .font(.system(size: 11))
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .frame(width: FolderWidgetCard.cell.width, height: FolderWidgetCard.cell.height)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(hovering ? 0.10 : 0))
                .padding(3)
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: action)
        .onHover { hovering = $0 }
        .help(app.name)
    }
}

/// 2×2 迷你图标拼成的资料夹图标：开始菜单的资料夹格和工作列的资料夹小工具共用
struct FolderIconSquare: View {
    let icons: [NSImage]
    /// 单个迷你图标边长
    let mini: CGFloat
    let spacing: CGFloat
    /// 整块方块边长
    let side: CGFloat
    let cornerRadius: CGFloat

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.fixed(mini), spacing: spacing), count: 2), spacing: spacing) {
            ForEach(icons.indices, id: \.self) { i in
                Image(nsImage: icons[i])
                    .resizable()
                    .interpolation(.high)
                    .frame(width: mini, height: mini)
            }
        }
        .frame(width: side, height: side)
        .background(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(Color.primary.opacity(0.09))
        )
    }
}
