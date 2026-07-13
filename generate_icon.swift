//
//  generate_icon.swift
//  闻声 SoundSense 图标生成器
//
//  用 Core Graphics 绘制声波纹图标，输出多尺寸 PNG。
//

import Foundation
import AppKit
import CoreGraphics

// MARK: - 图标绘制

func drawIcon(size: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()

    guard let ctx = NSGraphicsContext.current?.cgContext else {
        image.unlockFocus()
        return image
    }

    let w = size
    let h = size
    let cx = w / 2
    let cy = h / 2

    // ---- 1. 背景：深色渐变 ----
    // 从左上的深蓝青 -> 右下的深紫，科技感
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let gradColors = [
        CGColor(red: 0.04, green: 0.12, blue: 0.22, alpha: 1.0),  // 深蓝
        CGColor(red: 0.10, green: 0.06, blue: 0.20, alpha: 1.0),  // 深紫
    ] as CFArray
    let grad = CGGradient(colorsSpace: colorSpace, colors: gradColors,
                          locations: [0.0, 1.0])!
    ctx.drawLinearGradient(grad,
                           start: CGPoint(x: 0, y: h),
                           end: CGPoint(x: w, y: 0),
                           options: [])

    // ---- 2. 声波同心圆 ----
    // 5 圈从大到小，透明度从低到高，模拟声波从中心扩散
    let maxRadius = w * 0.42
    let ringCount = 5

    for i in stride(from: ringCount, through: 1, by: -1) {
        let progress = CGFloat(i) / CGFloat(ringCount)  // 1.0 -> 0.2
        let radius = maxRadius * progress
        let alpha = 0.12 + (1.0 - progress) * 0.55  // 外圈淡，内圈浓

        ctx.setStrokeColor(CGColor(red: 0.30, green: 0.85, blue: 0.90, alpha: alpha))
        ctx.setLineWidth(w * 0.018)
        ctx.addEllipse(in: CGRect(x: cx - radius, y: cy - radius,
                                  width: radius * 2, height: radius * 2))
        ctx.strokePath()
    }

    // ---- 3. 中心光点 ----
    // 外层柔光
    let centerGlow = CGGradient(colorsSpace: colorSpace,
                                colors: [
                                    CGColor(red: 0.35, green: 0.92, blue: 0.95, alpha: 0.9),
                                    CGColor(red: 0.35, green: 0.92, blue: 0.95, alpha: 0.0),
                                ] as CFArray,
                                locations: [0.0, 1.0])!
    let glowRadius = w * 0.10
    ctx.drawRadialGradient(centerGlow,
                           startCenter: CGPoint(x: cx, y: cy), startRadius: 0,
                           endCenter: CGPoint(x: cx, y: cy), endRadius: glowRadius * 2,
                           options: [])

    // 中心实心圆
    let dotRadius = w * 0.045
    ctx.setFillColor(CGColor(red: 0.40, green: 0.95, blue: 0.98, alpha: 1.0))
    ctx.fillEllipse(in: CGRect(x: cx - dotRadius, y: cy - dotRadius,
                               width: dotRadius * 2, height: dotRadius * 2))

    // ---- 4. 底部弧形声波（类似声波可视化）----
    // 在中心点下方画几条短弧线，模拟音频波形
    let waveY = cy - w * 0.02
    let waveWidth = w * 0.16
    let waveHeights: [CGFloat] = [0.03, 0.06, 0.09, 0.06, 0.03]
    let barWidth = w * 0.022
    let barGap = w * 0.012
    let totalBars = CGFloat(waveHeights.count)
    let totalWidth = totalBars * barWidth + (totalBars - 1) * barGap
    let startX = cx - totalWidth / 2

    for (i, hRatio) in waveHeights.enumerated() {
        let barH = w * hRatio
        let barX = startX + CGFloat(i) * (barWidth + barGap)
        let barRect = CGRect(x: barX, y: waveY - barH / 2,
                             width: barWidth, height: barH)
        let barRadius = barWidth / 2
        let path = CGPath(roundedRect: barRect, cornerWidth: barRadius,
                          cornerHeight: barRadius, transform: nil)
        ctx.addPath(path)
        ctx.setFillColor(CGColor(red: 0.35, green: 0.90, blue: 0.93, alpha: 0.75))
        ctx.fillPath()
    }

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
    drawIcon(size: CGFloat(size)).draw(in: NSRect(x: 0, y: 0, width: size, height: size))
    NSGraphicsContext.restoreGraphicsState()

    let pngData = rep?.representation(using: .png, properties: [:])
    try! pngData!.write(to: URL(fileURLWithPath: path))
}

// MARK: - 主入口

let outputDir = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : "."

// macOS iconset 需要的尺寸
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

// 先输出一张大图预览
savePNG(drawIcon(size: 1024), size: 1024, to: outputDir + "/icon_preview.png")
print("预览图已保存: \(outputDir)/icon_preview.png")

// 输出 iconset 各尺寸
for (name, px) in sizes {
    let path = outputDir + "/\(name).png"
    savePNG(drawIcon(size: CGFloat(px)), size: px, to: path)
    print("  \(name).png (\(px)×\(px))")
}

print("\n✅ 图标生成完成")
