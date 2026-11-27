import AppKit
import Carbon.HIToolbox
import SwiftUI

@MainActor
private final class WebSearchModel: ObservableObject {
    @Published var mode: WebSearchMode = .google {
        didSet { openFailed = false }
    }
    @Published var query = "" {
        didSet { openFailed = false }
    }
    @Published var openFailed = false
    @Published var focusToken = 0

    var url: URL? { mode.searchURL(for: query) }
}

private struct WebSearchView: View {
    @ObservedObject var model: WebSearchModel
    @ObservedObject var prefs: Preferences
    let onSubmit: () -> Void

    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: model.mode == .google ? "magnifyingglass" : "sparkles")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 22)
                    .accessibilityHidden(true)
                TextField(model.mode.prompt, text: $model.query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 20))
                    .focused($focused)
                    .onSubmit(onSubmit)
                if !model.query.isEmpty {
                    Button {
                        model.query = ""
                        focused = true
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                            .frame(width: 24, height: 28)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("清除搜尋文字")
                }
            }
            .frame(height: 32)

            Divider().opacity(0.5)

            HStack(spacing: 12) {
                Picker("搜尋方式", selection: $model.mode) {
                    ForEach(WebSearchMode.allCases, id: \.self) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .help("按 Tab 切換搜尋方式")

                Spacer(minLength: 0)

                if model.openFailed {
                    Text("無法開啟瀏覽器，請再試一次。")
                        .font(.system(size: 11))
                        .foregroundStyle(.red)
                }

                Button(action: onSubmit) {
                    Label("在瀏覽器搜尋", systemImage: "arrow.up.right")
                        .labelStyle(.iconOnly)
                        .font(.system(size: 13, weight: .semibold))
                        .frame(width: 24, height: 21)
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.url == nil)
                .help("在預設瀏覽器開啟結果（Return）")
            }
        }
        .padding(.horizontal, 18)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(GlassBackdrop(style: prefs.glassStyle, cornerRadius: 18))
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .overlay {
            RoundedRectangle(cornerRadius: 18)
                .strokeBorder(Color.primary.opacity(0.13), lineWidth: 0.5)
                .allowsHitTesting(false)
        }
        .onAppear { focused = true }
        .onChange(of: model.focusToken) { _, _ in
            DispatchQueue.main.async { focused = true }
        }
        .onChange(of: model.mode) { _, _ in focused = true }
    }
}

@MainActor
final class WebSearchController {
    static let shared = WebSearchController()

    private static let size = CGSize(width: 560, height: 116)
    private let model = WebSearchModel()
    private lazy var panel: FloatingPanel = {
        let frame = NSRect(origin: .zero, size: Self.size)
        let panel = FloatingPanel(contentRect: frame)
        panel.setAccessibilityTitle("Google 搜尋")
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 2)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        let view = WebSearchView(model: model, prefs: .shared, onSubmit: { [weak self] in self?.submit() })
        let host = FirstMouseHostingView(rootView: view)
        host.frame = frame
        host.autoresizingMask = [.width, .height]
        panel.contentView = host
        return panel
    }()
    private var localMonitor: Any?
    private var outsideMonitor: Any?
    private var resignObserver: NSObjectProtocol?

    private var isVisible = false

    private init() {}

    func toggle(on screen: NSScreen? = nil) {
        if isVisible { close() } else { show(on: screen) }
    }

    func show(on screen: NSScreen? = nil) {
        guard !isVisible,
              let screen = screen ?? NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) })
                ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        let size = CGSize(width: min(Self.size.width, visible.width - 24), height: Self.size.height)
        let origin = NSPoint(x: visible.midX - size.width / 2,
                             y: visible.minY + (visible.height - size.height) * 0.63)
        panel.setFrame(NSRect(origin: origin, size: size), display: false)
        model.query = ""
        model.focusToken &+= 1
        isVisible = true
        FloatingPanel.handingKeyBack = false
        panel.makeKeyAndOrderFront(nil)
        installMonitors()
    }

    func close() {
        guard isVisible else { return }
        isVisible = false
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        if let outsideMonitor { NSEvent.removeMonitor(outsideMonitor) }
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        localMonitor = nil
        outsideMonitor = nil
        resignObserver = nil
        panel.orderOutHandingKeyBack()
        model.query = ""
    }

    private func submit() {
        guard let url = model.url else { return }
        if NSWorkspace.shared.open(url) {
            close()
        } else {
            model.openFailed = true
        }
    }

    private func installMonitors() {
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown]) { [weak self] event in
            let handled = MainActor.assumeIsolated { () -> Bool in
                guard let self else { return false }
                if event.type == .keyDown {
                    guard event.window === self.panel else { return false }
                    return self.handleKey(event)
                }
                // 工作列自行處理點擊，以便再次點搜尋按鈕時收起面板。
                if event.window !== self.panel, !(event.window is ActiveGlassPanel) { self.close() }
                return false
            }
            return handled ? nil : event
        }
        outsideMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            DispatchQueue.main.async { self?.close() }
        }
        resignObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification,
                                                                object: panel, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        }
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        let editor = panel.firstResponder as? NSTextView
        if editor?.hasMarkedText() == true { return false }
        let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
        switch (Int(event.keyCode), flags) {
        case (kVK_Escape, []): close()
        case (kVK_Tab, []) where editor != nil:
            if !event.isARepeat { model.mode = model.mode == .google ? .googleAI : .google }
        default: return false
        }
        return true
    }
}
