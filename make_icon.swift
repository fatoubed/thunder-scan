// 生成 1024×1024 的「雷霆扫描」App 图标 PNG：swift make_icon.swift 输出.png
// 样式：深靛蓝渐变底 + 白色取景框四角 + 金黄色闪电（带发光）
import AppKit

let out = CommandLine.arguments[1]
let size: CGFloat = 1024
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                           bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
NSGraphicsContext.current?.imageInterpolation = .high

func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: a)
}

/// 用渐变填充一个 SF Symbol（得到渐变色的符号图）
func gradientSymbol(_ name: String, pointSize: CGFloat, weight: NSFont.Weight, colors: [NSColor], angle: CGFloat) -> NSImage? {
    guard let sym = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
        .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: pointSize, weight: weight)) else { return nil }
    let img = NSImage(size: sym.size)
    img.lockFocus()
    NSGradient(colors: colors)!.draw(in: NSRect(origin: .zero, size: sym.size), angle: angle)
    sym.draw(at: .zero, from: .zero, operation: .destinationIn, fraction: 1)
    img.unlockFocus()
    return img
}

// 1. 底板：圆角方块 + 投影 + 深色渐变
let plate = NSRect(x: 100, y: 100, width: 824, height: 824)
let platePath = NSBezierPath(roundedRect: plate, xRadius: 185, yRadius: 185)
NSGraphicsContext.saveGraphicsState()
let drop = NSShadow()
drop.shadowColor = rgb(0, 0, 0, 0.35)
drop.shadowBlurRadius = 28
drop.shadowOffset = NSSize(width: 0, height: -12)
drop.set()
rgb(20, 22, 60).setFill()
platePath.fill()
NSGraphicsContext.restoreGraphicsState()

NSGraphicsContext.saveGraphicsState()
platePath.addClip()
NSGradient(colors: [rgb(14, 16, 48), rgb(38, 30, 110), rgb(64, 52, 170)])!.draw(in: plate, angle: 60)
// 中心一圈淡淡的电光
NSGradient(colors: [rgb(255, 220, 90, 0.35), rgb(255, 200, 60, 0.0)])!
    .draw(fromCenter: NSPoint(x: 512, y: 512), radius: 0, toCenter: NSPoint(x: 512, y: 512), radius: 420, options: [])
// 顶部高光
NSGradient(colors: [rgb(255, 255, 255, 0.16), rgb(255, 255, 255, 0)])!
    .draw(in: NSRect(x: plate.minX, y: plate.midY + 120, width: plate.width, height: plate.height / 2 - 120), angle: -90)
NSGraphicsContext.restoreGraphicsState()

// 2. 取景框四角（扫描的意思）
let inset: CGFloat = 215, len: CGFloat = 150, lw: CGFloat = 44
let frame = NSRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
let corners = NSBezierPath()
corners.lineWidth = lw
corners.lineCapStyle = .round
corners.lineJoinStyle = .round
for (x, y, dx, dy) in [(frame.minX, frame.minY, 1.0, 1.0), (frame.maxX, frame.minY, -1.0, 1.0),
                       (frame.minX, frame.maxY, 1.0, -1.0), (frame.maxX, frame.maxY, -1.0, -1.0)] as [(CGFloat, CGFloat, CGFloat, CGFloat)] {
    corners.move(to: NSPoint(x: x, y: y + dy * len))
    corners.line(to: NSPoint(x: x, y: y))
    corners.line(to: NSPoint(x: x + dx * len, y: y))
}
rgb(255, 255, 255, 0.92).setStroke()
corners.stroke()

// 3. 闪电：金黄渐变 + 发光
if let bolt = gradientSymbol("bolt.fill", pointSize: 520, weight: .black,
                             colors: [rgb(255, 140, 20), rgb(255, 200, 40), rgb(255, 245, 150)], angle: 90) {
    let s = bolt.size
    let scale = 600 / s.height
    let w = s.width * scale, h = s.height * scale
    let r = NSRect(x: (size - w) / 2, y: (size - h) / 2, width: w, height: h)
    NSGraphicsContext.saveGraphicsState()
    let glow = NSShadow()
    glow.shadowColor = rgb(255, 190, 40, 0.9)
    glow.shadowBlurRadius = 70
    glow.shadowOffset = .zero
    glow.set()
    bolt.draw(in: r)
    NSGraphicsContext.restoreGraphicsState()
    bolt.draw(in: r)
}

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
