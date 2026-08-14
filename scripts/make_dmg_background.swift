//
//  make_dmg_background.swift
//  SoundSense
//
//  生成 DMG 安装窗口背景图(1120×720 @2x,对应 560×360 小窗口)。
//  风格与 App 一致:石墨底 + 信号青,App 图标 → 大箭头 → Applications,
//  笑脸气泡提示"拖我",底部一行安装提示。
//
//  用法: swift scripts/make_dmg_background.swift 输出.png
//

import Foundation
import AppKit

// ---- 参数(与 release.yml 的窗口/图标位置对应) ----
// 窗口 560×360pt;图标 96pt:App 在 {90,140},Applications 在 {430,140}(窗口坐标)
let size = NSSize(width: 1120, height: 720)
let ink = NSColor(red: 0.043, green: 0.063, blue: 0.078, alpha: 1)
let inkLight = NSColor(red: 0.055, green: 0.078, blue: 0.094, alpha: 1)
let teal = NSColor(red: 0.24, green: 0.85, blue: 0.75, alpha: 1)

let output = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1] : "dmg_background.png"

let image = NSImage(size: size)
image.lockFocus()

// 垂直明度渐变底
let gradient = NSGradient(colors: [inkLight, ink])!
gradient.draw(in: NSRect(origin: .zero, size: size), angle: -90)

// 顶部青色氛围光
let glow = NSGradient(colors: [
    NSColor(red: 0.24, green: 0.85, blue: 0.75, alpha: 0.12),
    NSColor(red: 0.24, green: 0.85, blue: 0.75, alpha: 0),
])!
glow.draw(in: NSBezierPath(ovalIn: NSRect(x: 260, y: 380, width: 600, height: 620)),
          angle: -90)

// ---- 顶部标题 + 迷你 dB 标尺 ----
let title = NSAttributedString(string: "闻声 SoundSense", attributes: [
    .font: NSFont.systemFont(ofSize: 48, weight: .heavy),
    .foregroundColor: NSColor.white,
])
title.draw(at: NSPoint(x: 72, y: 622))

let subtitle = NSAttributedString(string: "环境噪音测量 · A/C 计权 · 三端", attributes: [
    .font: NSFont.systemFont(ofSize: 22, weight: .medium),
    .foregroundColor: NSColor.white.withAlphaComponent(0.45),
])
subtitle.draw(at: NSPoint(x: 74, y: 586))

let rulerY: CGFloat = 530
let x0: CGFloat = 74, x1: CGFloat = 1046
let zones: [(CGFloat, CGFloat, NSColor)] = [
    (0.00, 0.20, NSColor(red: 0.35, green: 0.55, blue: 1.0, alpha: 0.75)),
    (0.20, 0.35, NSColor(red: 0.30, green: 0.82, blue: 0.62, alpha: 0.75)),
    (0.35, 0.45, NSColor(red: 0.96, green: 0.72, blue: 0.29, alpha: 0.75)),
    (0.45, 0.60, NSColor(red: 1.0, green: 0.48, blue: 0.35, alpha: 0.75)),
    (0.60, 1.00, NSColor(red: 1.0, green: 0.27, blue: 0.24, alpha: 0.75)),
]
for (from, to, color) in zones {
    let rect = NSRect(x: x0 + (x1 - x0) * from, y: rulerY,
                      width: (x1 - x0) * (to - from), height: 8)
    color.setFill()
    NSBezierPath(roundedRect: rect, xRadius: 2, yRadius: 2).fill()
}
for i in 0...20 {
    let x = x0 + (x1 - x0) * CGFloat(i) / 20
    let major = i % 2 == 0
    NSColor.white.withAlphaComponent(major ? 0.45 : 0.2).setStroke()
    let tick = NSBezierPath()
    tick.move(to: NSPoint(x: x, y: rulerY + 10))
    tick.line(to: NSPoint(x: x, y: rulerY + 10 + (major ? 14 : 7)))
    tick.lineWidth = major ? 1.8 : 1
    tick.stroke()
}
// 指针
let needleX = x0 + (x1 - x0) * 0.42
NSColor(red: 0.24, green: 0.85, blue: 0.75, alpha: 0.6).setStroke()
let needle = NSBezierPath()
needle.move(to: NSPoint(x: needleX, y: rulerY + 10))
needle.line(to: NSPoint(x: needleX, y: rulerY + 38))
needle.lineWidth = 3.5
needle.stroke()
teal.setFill()
NSBezierPath(ovalIn: NSRect(x: needleX - 6, y: rulerY + 38, width: 12, height: 12)).fill()

// ---- 笑脸气泡:贴在 App 图标正上方,提示"拖我" ----
let faceCenter = NSPoint(x: 180, y: 490)   // App 图标(x≈180px,顶≈440px)上方
let faceR: CGFloat = 44
let bubbleColor = NSColor(red: 0.10, green: 0.13, blue: 0.16, alpha: 1)
bubbleColor.setFill()
let bubble = NSBezierPath(ovalIn: NSRect(x: faceCenter.x - faceR, y: faceCenter.y - faceR,
                                         width: faceR * 2, height: faceR * 2))
bubble.fill()
NSColor.white.withAlphaComponent(0.15).setStroke()
bubble.lineWidth = 2
bubble.stroke()
// 眼睛
NSColor.white.setFill()
NSBezierPath(ovalIn: NSRect(x: faceCenter.x - 18, y: faceCenter.y + 4, width: 10, height: 14)).fill()
NSBezierPath(ovalIn: NSRect(x: faceCenter.x + 8, y: faceCenter.y + 4, width: 10, height: 14)).fill()
// 嘴(微笑弧)
NSColor.white.setStroke()
let mouth = NSBezierPath()
mouth.appendArc(withCenter: NSPoint(x: faceCenter.x, y: faceCenter.y - 6),
                radius: 18, startAngle: 200, endAngle: 340)
mouth.lineWidth = 3
mouth.lineCapStyle = .round
mouth.stroke()
// 气泡小尾巴指向 App 图标
let tail = NSBezierPath()
tail.move(to: NSPoint(x: faceCenter.x - 10, y: faceCenter.y - faceR + 4))
tail.line(to: NSPoint(x: faceCenter.x - 6, y: faceCenter.y - faceR - 16))
tail.line(to: NSPoint(x: faceCenter.x + 10, y: faceCenter.y - faceR + 6))
tail.close()
bubbleColor.setFill()
tail.fill()

// ---- 大箭头:从 App 图标指向 Applications 图标 ----
let arrowY: CGFloat = 340
let arrowEndX: CGFloat = 790
let arrow = NSBezierPath()
arrow.move(to: NSPoint(x: 400, y: arrowY))
arrow.curve(to: NSPoint(x: arrowEndX - 46, y: arrowY + 14),
            controlPoint1: NSPoint(x: 480, y: arrowY + 56),
            controlPoint2: NSPoint(x: 700, y: arrowY + 58))
teal.withAlphaComponent(0.85).setStroke()
arrow.lineWidth = 12
arrow.lineCapStyle = .round
arrow.lineJoinStyle = .round
arrow.stroke()
// 箭头头部(三角形)
let head = NSBezierPath()
head.move(to: NSPoint(x: arrowEndX + 8, y: arrowY + 16))
head.line(to: NSPoint(x: arrowEndX - 52, y: arrowY + 40))
head.line(to: NSPoint(x: arrowEndX - 44, y: arrowY - 8))
head.close()
teal.setFill()
head.fill()

// 箭头上方小字
let dragHint = NSAttributedString(string: "拖过去", attributes: [
    .font: NSFont.systemFont(ofSize: 26, weight: .semibold),
    .foregroundColor: teal.withAlphaComponent(0.9),
])
dragHint.draw(at: NSPoint(x: 560 - dragHint.size().width / 2, y: arrowY + 66))

// ---- 底部安装提示 ----
let bottom = NSAttributedString(string: "把 SoundSense 拖到 Applications 完成安装", attributes: [
    .font: NSFont.systemFont(ofSize: 26, weight: .medium),
    .foregroundColor: NSColor.white.withAlphaComponent(0.8),
])
bottom.draw(at: NSPoint(x: 560 - bottom.size().width / 2, y: 76))

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
