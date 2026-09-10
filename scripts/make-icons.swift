//
// 生成 TopTab 的 App 图标（.icns）。
//
//   xcrun swiftc -O -sdk "$(xcrun --sdk macosx --show-sdk-path)" \
//       -o /tmp/make-icons scripts/make-icons.swift
//   /tmp/make-icons <输出目录>
//
// 设计：圆角方形（macOS 图标 824/1024 的规范留白）＋ 蓝紫渐变底，
// 上面是「顶部悬浮条（胶囊）＋ 三个 App 标签块」，与状态栏图标同源。
//
import AppKit

let canvas: CGFloat = 1024
let outputDir = CommandLine.arguments.count > 1
    ? URL(fileURLWithPath: CommandLine.arguments[1])
    : URL(fileURLWithPath: FileManager.default.currentDirectoryPath)

// 背景形状：824×824 居中，圆角 185 —— 接近 macOS 的 squircle 观感
let plate = CGRect(x: 100, y: 100, width: 824, height: 824)
let plateRadius: CGFloat = 185

/// 画 1024 画布的图标。坐标用 top-left 原点（1024 宽高）。
func drawIcon(into ctx: CGContext, size: CGFloat) {
    let s = size / canvas
    ctx.saveGState()
    ctx.scaleBy(x: s, y: s)
    ctx.translateBy(x: 0, y: canvas)
    ctx.scaleBy(x: 1, y: -1)          // → top-left 原点
    ctx.setShouldAntialias(true)

    let shape = CGPath(roundedRect: plate, cornerWidth: plateRadius,
                       cornerHeight: plateRadius, transform: nil)

    // ── 底色渐变：左上亮蓝 → 右下深靛
    ctx.saveGState()
    ctx.addPath(shape)
    ctx.clip()
    let colors = [
        NSColor(srgbRed: 0.352, green: 0.549, blue: 1.000, alpha: 1).cgColor,
        NSColor(srgbRed: 0.180, green: 0.290, blue: 0.839, alpha: 1).cgColor,
        NSColor(srgbRed: 0.086, green: 0.106, blue: 0.404, alpha: 1).cgColor
    ] as CFArray
    let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                              colors: colors,
                              locations: [0, 0.55, 1])!
    ctx.drawLinearGradient(gradient,
                           start: CGPoint(x: plate.minX, y: plate.minY),
                           end: CGPoint(x: plate.maxX, y: plate.maxY),
                           options: [])

    // ── 顶部高光：让平面渐变有点玻璃厚度
    let sheen = [NSColor.white.withAlphaComponent(0.26).cgColor,
                 NSColor.white.withAlphaComponent(0.0).cgColor] as CFArray
    let sheenGradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                   colors: sheen, locations: [0, 1])!
    ctx.drawLinearGradient(sheenGradient,
                           start: CGPoint(x: plate.midX, y: plate.minY),
                           end: CGPoint(x: plate.midX, y: plate.midY + 60),
                           options: [])
    ctx.restoreGState()

    // ── 前景：悬浮条 + 三个标签块
    // 元素组在 824 的盘子里垂直居中：337..687，中心正好落在 512
    let barRect = CGRect(x: 192, y: 337, width: 640, height: 80)
    let barPath = CGPath(roundedRect: barRect, cornerWidth: 40, cornerHeight: 40,
                         transform: nil)
    ctx.addPath(barPath)
    ctx.setFillColor(NSColor.white.withAlphaComponent(0.96).cgColor)
    ctx.fillPath()

    let blockSide: CGFloat = 180
    let blockGap: CGFloat = 50
    let blockY: CGFloat = 507
    let alphas: [CGFloat] = [0.96, 0.66, 0.40]
    for i in 0..<3 {
        let x = 192 + CGFloat(i) * (blockSide + blockGap)
        let rect = CGRect(x: x, y: blockY, width: blockSide, height: blockSide)
        let path = CGPath(roundedRect: rect, cornerWidth: 46, cornerHeight: 46,
                          transform: nil)
        ctx.addPath(path)
        ctx.setFillColor(NSColor.white.withAlphaComponent(alphas[i]).cgColor)
        ctx.fillPath()
    }

    // ── 内描边：模拟玻璃边缘的一道亮线
    ctx.addPath(shape)
    ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.30).cgColor)
    ctx.setLineWidth(3)
    ctx.strokePath()

    ctx.restoreGState()
}

func png(size: CGFloat) -> Data? {
    let px = Int(size)
    guard let ctx = CGContext(data: nil, width: px, height: px,
                              bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return nil }
    drawIcon(into: ctx, size: size)
    guard let cg = ctx.makeImage() else { return nil }
    let rep = NSBitmapImageRep(cgImage: cg)
    rep.size = NSSize(width: size, height: size)
    return rep.representation(using: .png, properties: [:])
}

// macOS iconset 要求的标准尺寸档
let variants: [(name: String, px: CGFloat)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024)
]

let iconset = outputDir.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

for v in variants {
    guard let data = png(size: v.px) else {
        FileHandle.standardError.write("✗ 渲染失败: \(v.name)\n".data(using: .utf8)!)
        exit(1)
    }
    try! data.write(to: iconset.appendingPathComponent("\(v.name).png"))
}

let icns = outputDir.appendingPathComponent("TopTab.icns")
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset.path, "-o", icns.path]
try! task.run()
task.waitUntilExit()

if task.terminationStatus == 0 {
    print("✓ \(icns.path)")
} else {
    FileHandle.standardError.write("✗ iconutil 失败\n".data(using: .utf8)!)
    exit(1)
}
