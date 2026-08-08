#!/usr/bin/swift
// 生成 DisplayMixer 的 App 图标：
//   - 蓝色玻璃渐变圆角底（Apple 系统蓝 #0A84FF → #0040B8）
//   - 顶部玻璃高光 + 细描边
//   - 中心白色 Apple 系统喇叭符号 speaker.fill（无声波）
// 输出标准多分辨率 .iconset，再由 iconutil 转 .icns。

import AppKit
import Foundation

let iconsetDir = URL(fileURLWithPath: "Resources/AppIcon.iconset", isDirectory: true)
try? FileManager.default.createDirectory(at: iconsetDir, withIntermediateDirectories: true)

/// 把 template 图像染成指定颜色并保留透明背景（sourceIn 只在原图像 alpha 处填色）。
func tinted(_ image: NSImage, color: NSColor) -> NSImage {
    let size = image.size
    let out = NSImage(size: size)
    let rect = NSRect(origin: .zero, size: size)
    out.lockFocus()
    // 先画上 template 取得 alpha 形状
    image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1.0)
    // 用目标色只在 alpha 区域重新着色，其余保持透明
    color.setFill()
    rect.fill(using: .sourceIn)
    out.unlockFocus()
    return out
}

func drawIcon(size: Int) -> Data {
    let cgSize = CGSize(width: size, height: size)
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: size,
        pixelsHigh: size,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    )!
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = ctx

    let w = CGFloat(size)
    let radius = w * 0.224

    // 圆角裁剪路径
    let path = NSBezierPath(roundedRect: NSRect(origin: .zero, size: cgSize), xRadius: radius, yRadius: radius)
    path.addClip()

    // 蓝色垂直渐变底
    let top = NSColor(calibratedRed: 0.039, green: 0.518, blue: 1.0, alpha: 1.0)  // #0A84FF
    let bottom = NSColor(calibratedRed: 0.0, green: 0.251, blue: 0.722, alpha: 1.0) // #0040B8
    let gradient = NSGradient(colors: [top, bottom])!
    gradient.draw(in: NSRect(origin: .zero, size: cgSize), angle: 90)

    // 顶部玻璃高光（柔光带）
    let hl = NSBezierPath()
    hl.move(to: NSPoint(x: 0, y: w * 0.74))
    hl.line(to: NSPoint(x: w, y: w * 0.62))
    hl.line(to: NSPoint(x: w, y: w))
    hl.line(to: NSPoint(x: 0, y: w))
    hl.close()
    NSColor.white.withAlphaComponent(0.16).setFill()
    hl.fill()

    // 左下压暗，增加体积感
    let sh = NSBezierPath()
    sh.move(to: NSPoint(x: 0, y: 0))
    sh.line(to: NSPoint(x: w, y: 0))
    sh.line(to: NSPoint(x: w * 0.5, y: w * 0.28))
    sh.close()
    NSColor.black.withAlphaComponent(0.18).setFill()
    sh.fill()

    // 居中白色喇叭符号 speaker.fill（无声波），约占画布 58%
    let symbolSize = w * 0.58
    if let symbol = NSImage(systemSymbolName: "speaker.fill", accessibilityDescription: nil) {
        let config = NSImage.SymbolConfiguration(pointSize: symbolSize, weight: .regular, scale: .large)
        let configured = symbol.withSymbolConfiguration(config) ?? symbol
        let tintedSymbol = tinted(configured, color: .white)
        let origin = CGPoint(x: (w - symbolSize) / 2, y: (w - symbolSize) / 2)
        tintedSymbol.draw(in: NSRect(origin: origin, size: CGSize(width: symbolSize, height: symbolSize)))
    }

    // 玻璃描边
    NSGraphicsContext.restoreGraphicsState()
    NSColor.white.withAlphaComponent(0.30).setStroke()
    let border = NSBezierPath(roundedRect: NSRect(origin: .zero, size: cgSize).insetBy(dx: 0.5, dy: 0.5),
                              xRadius: radius, yRadius: radius)
    border.lineWidth = 1.0
    border.stroke()

    return rep.representation(using: .png, properties: [:])!
}

// 渲染标准 10 张：16/32/64/128/256/512/1024，按 iconutil 命名规范落盘。
let targets: [(render: Int, names: [String])] = [
    (16,  ["icon_16x16.png"]),
    (32,  ["icon_16x16@2x.png", "icon_32x32.png"]),
    (64,  ["icon_32x32@2x.png"]),
    (128, ["icon_128x128.png"]),
    (256, ["icon_128x128@2x.png", "icon_256x256.png"]),
    (512, ["icon_256x256@2x.png", "icon_512x512.png"]),
    (1024,["icon_512x512@2x.png"]),
]

for (render, names) in targets {
    let data = drawIcon(size: render)
    for n in names {
        try! data.write(to: iconsetDir.appendingPathComponent(n))
        print("wrote \(n)")
    }
}

print("iconset done")
