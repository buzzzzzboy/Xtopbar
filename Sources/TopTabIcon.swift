import AppKit

/// TopTab 的图形标识。
///
/// 状态栏图标走 **template** 渲染 —— 系统只取 alpha 通道，按当前菜单栏
/// 配色（浅色/深色菜单栏、选中态反白）自动上色，所以这里只画形状不画颜色。
enum TopTabIcon {

    /// 状态栏图标（18×18 pt）：顶部一条悬浮栏，下面三个 App 圆点。
    ///
    /// 试过的形态：「横条 + 三个方块」→ 像床；「屏幕外框 + 顶栏」→ 像文件夹；
    /// 「胶囊 + 三个竖片」→ 像梳子；「胶囊 + 双箭头」→ 两个箭头黏成菱形。
    /// 圆点比方块轻，不会读成家具腿，是这几个里最小巧、最经得起 18pt 缩放的。
    static func statusBar() -> NSImage {
        let side: CGFloat = 18
        let image = rasterize(size: NSSize(width: side, height: side), scale: 2) { _ in
            // 悬浮栏本体
            fill(NSRect(x: 1.0, y: 4.4, width: 16.0, height: 3.0), radius: 1.5)

            // 三个 App 圆点
            for cx in [4.4, 9.0, 13.6] as [CGFloat] {
                circle(centerX: cx, centerY: 12.2, diameter: 2.8)
            }
        }
        image.isTemplate = true
        return image
    }

    // MARK: - 绘制基础设施

    /// 在 top-left 原点坐标系里画图。
    /// AppKit 默认左下原点，这里翻一次 y 轴，写坐标时就能照着想。
    private static func rasterize(size: NSSize,
                                 scale: CGFloat,
                                 _ body: (CGContext) -> Void) -> NSImage {
        let px = Int(size.width * scale)
        let py = Int(size.height * scale)
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: px, pixelsHigh: py,
            bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0
        ) else { return NSImage(size: size) }

        NSGraphicsContext.saveGraphicsState()
        if let ctx = NSGraphicsContext(bitmapImageRep: rep) {
            NSGraphicsContext.current = ctx
            let cg = ctx.cgContext
            cg.scaleBy(x: scale, y: scale)
            cg.translateBy(x: 0, y: size.height)
            cg.scaleBy(x: 1, y: -1)
            cg.setShouldAntialias(true)
            body(cg)
        }
        NSGraphicsContext.restoreGraphicsState()

        let image = NSImage(size: size)
        // 关键：rep 的 size 必须设成点尺寸，否则 2x 位图会被当成 36×36 点，
        // NSStatusItem 拿到一个"巨大"的图，缩放后糊掉甚至不画。
        rep.size = size
        image.addRepresentation(rep)
        return image
    }

    /// 圆角矩形填充（template 图：纯黑 + 全不透明，系统负责上色）
    private static func fill(_ rect: NSRect, radius: CGFloat) {
        NSColor.black.setFill()
        NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
    }

    /// 圆角矩形描边
    private static func stroke(_ rect: NSRect, radius: CGFloat, lineWidth: CGFloat) {
        let path = NSBezierPath(roundedRect: rect.insetBy(dx: lineWidth / 2, dy: lineWidth / 2),
                                xRadius: radius, yRadius: radius)
        path.lineWidth = lineWidth
        NSColor.black.setStroke()
        path.stroke()
    }

    private static func circle(centerX: CGFloat, centerY: CGFloat, diameter: CGFloat) {
        NSColor.black.setFill()
        NSBezierPath(ovalIn: NSRect(x: centerX - diameter / 2,
                                    y: centerY - diameter / 2,
                                    width: diameter, height: diameter)).fill()
    }
}
