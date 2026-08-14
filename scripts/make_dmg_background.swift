//
//  make_dmg_background.swift
//  SoundSense
//
//  生成 DMG 安装窗口背景图(1280×800 @2x,对应 640×400 窗口)。
//  风格与 App 一致:石墨底 + 信号青氛围光 + 安装引导文案。
//
//  用法: swift scripts/make_dmg_background.swift 输出.png
//

import Foundation
import AppKit

// ---- 参数 ----
let size = NSSize(width: 1280, height: 800)
let ink = NSColor(red: 0.043, green: 0.063, blue: 0.078, alpha: 1)
let inkLight = NSColor(red: 0.055, green: 0.078, blue: 0.094, alpha: 1)
let teal = NSColor(red: 0.24, green: 0.85, blue: 0.75, alpha: 1)
let tealDim = NSColor(red: 0.24, green: 0.85, blue: 0.75, alpha: 0.35)

let output = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1] : "dmg_background.png"

// ---- 绘制 ----
let image = NSImage(size: size)
image.lockFocus()

// 垂直明度渐变底
let bgRect = NSRect(origin: .zero, size: size)
let gradient = NSGradient(colors: [inkLight, ink])!
gradient.draw(in: bgRect, angle: -90)

// 顶部青色氛围光
let glow = NSGradient(colors: [
    NSColor(red: 0.24, green: 0.85, blue: 0.75, alpha: 0.13),
    NSColor(red: 0.24, green: 0.85, blue: 0.75, alpha: 0),
])!
glow.draw(in: NSBezierPath(ovalIn: NSRect(x: 240, y: 420, width: 800, height: 700)),
          angle: -90)

// 顶部标题
let title = NSAttributedString(string: "闻声 SoundSense", attributes: [
    .font: NSFont.systemFont(ofSize: 56, weight: .heavy),
    .foregroundColor: NSColor.white,
])
title.draw(at: NSPoint(x: 80, y: 660))

let subtitle = NSAttributedString(string: "环境噪音测量 · A/C 计权 · iOS / watchOS / macOS", attributes: [
    .font: NSFont.systemFont(ofSize: 24, weight: .medium),
    .foregroundColor: NSColor.white.withAlphaComponent(0.45),
])
subtitle.draw(at: NSPoint(x: 82, y: 610))

// 迷你 dB 标尺装饰(签名元素)
let rulerY: CGFloat = 545
let x0: CGFloat = 82, x1: CGFloat = 1198
let zones: [(CGFloat, CGFloat, NSColor)] = [
    (0.00, 0.20, NSColor(red: 0.35, green: 0.55, blue: 1.0, alpha: 0.75)),
    (0.20, 0.35, NSColor(red: 0.30, green: 0.82, blue: 0.62, alpha: 0.75)),
    (0.35, 0.45, NSColor(red: 0.96, green: 0.72, blue: 0.29, alpha: 0.75)),
    (0.45, 0.60, NSColor(red: 1.0, green: 0.48, blue: 0.35, alpha: 0.75)),
    (0.60, 1.00, NSColor(red: 1.0, green: 0.27, blue: 0.24, alpha: 0.75)),
]
for (from, to, color) in zones {
    let rect = NSRect(x: x0 + (x1 - x0) * from, y: rulerY,
                      width: (x1 - x0) * (to - from), height: 10)
    color.setFill()
    NSBezierPath(roundedRect: rect, xRadius: 2, yRadius: 2).fill()
}
// 刻度
for i in 0...20 {
    let x = x0 + (x1 - x0) * CGFloat(i) / 20
    let major = i % 2 == 0
    let h: CGFloat = major ? 18 : 9
    let alpha: CGFloat = major ? 0.5 : 0.22
    NSColor.white.withAlphaComponent(alpha).setStroke()
    let line = NSBezierPath()
    line.move(to: NSPoint(x: x, y: rulerY + 12))
    line.line(to: NSPoint(x: x, y: rulerY + 12 + h))
    line.lineWidth = major ? 2 : 1.2
    line.stroke()
}
// 85 dB 风险刻度 + 指针
let riskX = x0 + (x1 - x0) * 0.55
NSColor(red: 1.0, green: 0.35, blue: 0.30, alpha: 1).setStroke()
let risk = NSBezierPath()
risk.move(to: NSPoint(x: riskX, y: rulerY + 12))
risk.line(to: NSPoint(x: riskX, y: rulerY + 40))
risk.lineWidth = 3
risk.stroke()
let needleX = x0 + (x1 - x0) * 0.42
tealDim.setStroke()
let needle = NSBezierPath()
needle.move(to: NSPoint(x: needleX, y: rulerY + 12))
needle.line(to: NSPoint(x: needleX, y: rulerY + 48))
needle.lineWidth = 4
needle.stroke()
teal.setFill()
NSBezierPath(ovalIn: NSRect(x: needleX - 7, y: rulerY + 48, width: 14, height: 14)).fill()

// 底部安装引导(箭头从 App 指向 Applications)
let hint = NSAttributedString(string: "拖动 SoundSense 到 Applications 完成安装", attributes: [
    .font: NSFont.systemFont(ofSize: 28, weight: .semibold),
    .foregroundColor: NSColor.white.withAlphaComponent(0.85),
])
hint.draw(at: NSPoint(x: 640 - hint.size().width / 2, y: 120))

let arrow = NSAttributedString(string: "→", attributes: [
    .font: NSFont.systemFont(ofSize: 64, weight: .bold),
    .foregroundColor: teal.withAlphaComponent(0.8),
])
arrow.draw(at: NSPoint(x: 640 - arrow.size().width / 2, y: 200))

image.unlockFocus()

// ---- 输出 PNG ----
guard let tiff = image.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else {
    FileHandle.standardError.write("生成 PNG 失败".data(using: .utf8)!)
    exit(1)
}
try! png.write(to: URL(fileURLWithPath: output))
print("已生成 \(output) (\(size.width)×\(size.height))")
