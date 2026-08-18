//
//  generate_icon_a3.swift
//  闻声 SoundSense 图标生成器 · A3 表盘版 (Light + Dark)
//
//  设计来源：docs/logo-concepts/A3_dial_dB_center.png
//  风格：Apple 系统工具（类指南针 App），扁平 + 轻渐变 + 柔和阴影
//  结构：浅蓝白渐变底 / 圆形表盘 / 上弧刻度 8→4 对称 / 指针指向右上 / dB 居于指针下方
//
//  坐标系：NSImage.lockFocus 是 +y 向上（左下原点）。
//          NSImage.draw() 输出 PNG 时会自动垂直翻转，所以"源码 y 大 = 视觉上方"成立。
//          代码里直接按"视觉位置"思考：y > cy = 视觉上方，y < cy = 视觉下方。
//
//  用法：
//    swift generate_icon_a3.swift [输出目录]              # 仅 Light
//    swift generate_icon_a3.swift [输出目录] dark           # Light + Dark
//

import Foundation
import AppKit
import CoreGraphics

// MARK: - 调色板

enum LightPalette {
    static let bgTop    = CGColor(red: 0.910, green: 0.953, blue: 0.988, alpha: 1.0)
    static let bgBottom = CGColor(red: 0.980, green: 0.990, blue: 1.000, alpha: 1.0)
    static let blue     = CGColor(red: 0.036, green: 0.418, blue: 0.910, alpha: 1.0)
    static let deepBlue = CGColor(red: 0.043, green: 0.235, blue: 0.540, alpha: 1.0)
    static let face     = CGColor(red: 1.0,   green: 1.0,   blue: 1.0,   alpha: 1.0)
    static let shadow   = CGColor(red: 0.036, green: 0.418, blue: 0.910, alpha: 0.16)
}

enum DarkPalette {
    // 深色背景：墨蓝到近黑的径向渐变
    static let bgTop    = CGColor(red: 0.130, green: 0.150, blue: 0.200, alpha: 1.0)
    static let bgBottom = CGColor(red: 0.065, green: 0.075, blue: 0.100, alpha: 1.0)
    // 图形元素用亮色系：电光青 + 冷白
    static let blue     = CGColor(red: 0.400, green: 0.750, blue: 1.000, alpha: 1.0)   // 亮蓝刻度
    static let deepBlue = CGColor(red: 0.900, green: 0.940, blue: 1.000, alpha: 1.0)   // 近白指针+文字
    static let face     = CGColor(red: 0.180, green: 0.200, blue: 0.260, alpha: 1.0)   // 深灰表盘面
    static let shadow   = CGColor(red: 0.0,   green: 0.0,   blue: 0.0,   alpha: 0.35)  // 黑色阴影
}

protocol ColorPalette {
    static var bgTop:    CGColor { get }
    static var bgBottom: CGColor { get }
    static var blue:     CGColor { get }
    static var deepBlue: CGColor { get }
    static var face:     CGColor { get }
    static var shadow:   CGColor { get }
}
extension LightPalette: ColorPalette {}
extension DarkPalette: ColorPalette {}

// MARK: - 图标绘制

func drawIcon<P: ColorPalette>(size: CGFloat, palette: P.Type) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    guard let ctx = NSGraphicsContext.current?.cgContext else {
        image.unlockFocus()
        return image
    }

    let s = size
    let cx = s / 2
    let cy = s / 2
    let colorSpace = CGColorSpaceCreateDeviceRGB()

    // ---- 0. 圆角裁剪：macOS 图标规范 ----
    // 图形主体绘制在带边距的圆角矩形内,四角保持透明(裸 icns 不做系统自动
    // 圆角,必须在源图里画出来)。比例参照 Apple 图标网格:边距 ≈ 9.8%,
    // 圆角半径 ≈ 18.05%(1024 画布上约 100pt / 185pt)。
    let iconMargin = s * 0.098
    let iconRect = CGRect(x: iconMargin, y: iconMargin,
                          width: s - iconMargin * 2, height: s - iconMargin * 2)
    let clip = CGPath(roundedRect: iconRect,
                      cornerWidth: s * 0.1805, cornerHeight: s * 0.1805,
                      transform: nil)
    ctx.addPath(clip)
    ctx.clip()

    // ---- 1. 背景：径向渐变 ----
    let bgGrad = CGGradient(colorsSpace: colorSpace,
                            colors: [P.bgBottom, P.bgTop] as CFArray,
                            locations: [0.0, 1.0])!
    ctx.drawRadialGradient(bgGrad,
                           startCenter: CGPoint(x: cx, y: cy), startRadius: 0,
                           endCenter: CGPoint(x: cx, y: cy), endRadius: s * 0.85,
                           options: [])

    // ---- 2. 表盘圆面 + 柔和投影 ----
    let dialR = s * 0.325
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.022),
                  blur: s * 0.055,
                  color: P.shadow)
    ctx.setFillColor(P.face)
    ctx.fillEllipse(in: CGRect(x: cx - dialR, y: cy - dialR,
                               width: dialR * 2, height: dialR * 2))
    ctx.restoreGState()

    // ---- 3. 刻度弧：8 点钟 → 12 点钟 → 4 点钟（左右对称，扫过 240°） ----
    let tickCount = 21
    let sweep: CGFloat = 240
    let startAngle: CGFloat = 210       // 8 点钟方向
    let tickOuter = dialR * 0.96
    let majorLen: CGFloat    = s * 0.060
    let majorWidth: CGFloat   = s * 0.014
    let minorLen: CGFloat    = s * 0.034
    let minorWidth: CGFloat  = s * 0.0085

    for i in 0..<tickCount {
        let t = CGFloat(i) / CGFloat(tickCount - 1)
        let angle = startAngle - sweep * t
        let rad = angle * .pi / 180

        let isMajor = (i % 5 == 0)
        let len = isMajor ? majorLen : minorLen
        let width = isMajor ? majorWidth : minorWidth

        let xOuter = cx + cos(rad) * tickOuter
        let yOuter = cy + sin(rad) * tickOuter
        let xInner = cx + cos(rad) * (tickOuter - len)
        let yInner = cy + sin(rad) * (tickOuter - len)

        ctx.setStrokeColor(P.blue)
        ctx.setLineWidth(width)
        ctx.setLineCap(.butt)
        ctx.move(to: CGPoint(x: xOuter, y: yOuter))
        ctx.addLine(to: CGPoint(x: xInner, y: yInner))
        ctx.strokePath()
    }

    // ---- 4. 指针：从圆心指向右上 ~55° 仰角（约 1 点钟方向） ----
    let needleAngle: CGFloat = 35 * .pi / 180
    let needleLen = dialR * 0.62
    let needleW: CGFloat = s * 0.018

    ctx.saveGState()
    ctx.translateBy(x: cx, y: cy)
    ctx.rotate(by: -needleAngle)
    let needleRect = CGRect(x: -needleW / 2, y: 0,
                            width: needleW, height: needleLen)
    let needlePath = CGPath(roundedRect: needleRect,
                            cornerWidth: needleW / 2, cornerHeight: needleW / 2,
                            transform: nil)
    ctx.addPath(needlePath)
    ctx.setFillColor(P.deepBlue)
    ctx.fillPath()
    ctx.restoreGState()

    // 4.2 轴帽
    let hubR = s * 0.030
    ctx.setFillColor(P.deepBlue)
    ctx.fillEllipse(in: CGRect(x: cx - hubR, y: cy - hubR,
                               width: hubR * 2, height: hubR * 2))

    // ---- 5. "dB" 文字：指针轴帽正下方 ----
    let font = NSFont.systemFont(ofSize: s * 0.140, weight: .semibold)
    let attrs: [NSAttributedString.Key: Any] = [
        .font: font,
        .foregroundColor: NSColor(cgColor: P.deepBlue)!,
    ]
    let text = NSAttributedString(string: "dB", attributes: attrs)
    let textSize = text.size()
    let baselineY = cy - s * 0.300
    let textPoint = NSPoint(x: cx - textSize.width / 2,
                            y: baselineY)
    text.draw(at: textPoint)

    image.unlockFocus()
    return image
}

// MARK: - 输出多尺寸

func savePNG(_ image: NSImage, size: Int, to path: String) {
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
    )
    rep?.size = NSSize(width: size, height: size)

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep!)
    image.draw(in: NSRect(x: 0, y: 0, width: size, height: size))
    NSGraphicsContext.restoreGraphicsState()

    let pngData = rep?.representation(using: .png, properties: [:])
    try! pngData!.write(to: URL(fileURLWithPath: path))
}

// MARK: - 主入口

let args = CommandLine.arguments
let outputDir = args.count > 1 && !args[1].hasPrefix("dark")
    ? args[1]
    : (args.count > 2 ? args[2] : ".")
let makeDark = args.contains("dark")

try? FileManager.default.createDirectory(atPath: outputDir,
                                         withIntermediateDirectories: true)

let sizes: [(name: String, px: Int)] = [
    ("icon_16x16", 16),
    ("icon_16x16@2x", 32),
    ("icon_32x32", 32),
    ("icon_32x32@2x", 64),
    ("icon_128x128", 128),
    ("icon_128x128@2x", 256),
    ("icon_256x256", 256),
    ("icon_256x256@2x", 512),
    ("icon_512x512", 512),
    ("icon_512x512@2x", 1024),
]

// === Light 版本 ===
print("📐 生成 Light 版...")
savePNG(drawIcon(size: 1024, palette: LightPalette.self), size: 1024,
        to: outputDir + "/A3_master_1024.png")
print("  A3_master_1024.png")

for (name, px) in sizes {
    let path = outputDir + "/\(name).png"
    savePNG(drawIcon(size: CGFloat(px), palette: LightPalette.self), size: px, to: path)
    print("  \(name).png (\(px)x\(px))")
}

// === Dark 版本 ===
if makeDark {
    print("\n🌙 生成 Dark 版...")
    let darkDir = outputDir + "_dark"
    try? FileManager.default.createDirectory(atPath: darkDir,
                                             withIntermediateDirectories: true)

    savePNG(drawIcon(size: 1024, palette: DarkPalette.self), size: 1024,
            to: darkDir + "/A3_dark_1024.png")
    print("  A3_dark_1024.png")

    for (name, px) in sizes {
        let path = darkDir + "/\(name).png"
        savePNG(drawIcon(size: CGFloat(px), palette: DarkPalette.self), size: px, to: path)
        print("  \(name).png (\(px)x\(px))")
    }

    // 打包 Dark icns
    let iconsetDir = darkDir + "/AppIcon_A3_Dark.iconset"
    try? FileManager.default.createDirectory(atPath: iconsetDir,
                                             withIntermediateDirectories: true)
    for (name, px) in sizes {
        let src = darkDir + "/\(name).png"
        let dst = iconsetDir + "/\(name).png"
        try? FileManager.default.copyItem(atPath: src, toPath: dst)
    }
    // 复制母版作为 1024
    try? FileManager.default.copyItem(atPath: darkDir + "/A3_dark_1024.png",
                                      toPath: iconsetDir + "/A3_dark_1024.png")

    print("\n✅ Light + Dark 全部生成完成")
    print("  Light: \(outputDir)/")
    print("  Dark:  \(darkDir)/")
} else {
    print("\n✅ A3 Light 表盘图标生成完成")
    print("  输出: \(outputDir)/")
}
