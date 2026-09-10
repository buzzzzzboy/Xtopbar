import SwiftUI
import AppKit

/// 悬浮条 / 预览面板的背景。
///
/// 材质优先级：
///   1. `NSGlassEffectView`（macOS 26 起的液态玻璃）—— 系统原生，会自动跟随
///      外观（浅色/深色）、「降低透明度」「增强对比度」等辅助功能开关，
///      也会跟系统设置里的 Liquid Glass 强度一起变。不需要自己写任何适配。
///   2. `NSVisualEffectView`（HUD 毛玻璃）—— 旧系统回退。
///   3. 纯色层 —— 用户显式选择，或作为最低保底。
struct GlassBackdrop: NSViewRepresentable {
    var style: GlassStyle = .liquid
    var cornerRadius: CGFloat = 16

    func makeNSView(context: Context) -> BackdropView {
        let view = BackdropView()
        view.frame = .zero
        view.apply(style: style, radius: cornerRadius)
        return view
    }

    func updateNSView(_ nsView: BackdropView, context: Context) {
        nsView.apply(style: style, radius: cornerRadius)
    }
}

/// 材质容器：切换样式时只换子视图，不重建自己，避免闪一下。
final class BackdropView: NSView {

    private var installed: GlassStyle?
    private var radius: CGFloat = 16
    private var glass: NSView?
    private var vibrancy: NSVisualEffectView?
    private var solid: CALayer?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        // NSGlassEffectView 会自己管理内部层级，不强制 frame 也铺满的话
        // 在面板被 setFrame 拉伸后玻璃只覆盖一块小区域。
        glass?.frame = bounds
        vibrancy?.frame = bounds
        solid?.frame = bounds
    }

    func apply(style: GlassStyle, radius: CGFloat) {
        let wanted = style.resolved
        self.radius = radius

        if installed != wanted {
            teardown()
            switch wanted {
            case .liquid:  installGlass()
            case .frosted: installVibrancy()
            case .solid:   installSolid()
            }
            installed = wanted
            TTLog("backdrop → \(wanted.rawValue) (请求 \(style.rawValue))")
        }

        if #available(macOS 26.0, *) {
            (glass as? NSGlassEffectView)?.cornerRadius = radius
        }
        vibrancy?.layer?.cornerRadius = radius
        solid?.cornerRadius = radius
        needsLayout = true
    }

    // MARK: - 三种材质

    private func installGlass() {
        guard #available(macOS 26.0, *) else { return }
        let view = NSGlassEffectView()
        view.style = .regular
        view.cornerRadius = radius
        view.frame = bounds
        view.autoresizingMask = [.width, .height]
        addSubview(view)
        glass = view
    }

    private func installVibrancy() {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        view.wantsLayer = true
        view.layer?.cornerRadius = radius
        view.layer?.masksToBounds = true
        view.frame = bounds
        view.autoresizingMask = [.width, .height]
        addSubview(view)
        vibrancy = view
    }

    private func installSolid() {
        let l = CALayer()
        l.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.94).cgColor
        l.cornerRadius = radius
        l.cornerCurve = .continuous
        l.frame = bounds
        layer?.addSublayer(l)
        solid = l
    }

    private func teardown() {
        glass?.removeFromSuperview()
        vibrancy?.removeFromSuperview()
        solid?.removeFromSuperlayer()
        glass = nil
        vibrancy = nil
        solid = nil
    }
}
