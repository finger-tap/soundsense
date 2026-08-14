//
//  make_dmg_background.swift
//  SoundSense
//
//  生成 DMG 安装窗口背景图(560×360,与窗口内容 1:1)。
//  极简设计:背景全透明,只画一条青色曲线箭头作为"笑脸的嘴"——
//  两个图标(SoundSense.app 和 Applications)充当"眼睛"。
//
//  ══════════ 坐标全部由计算得出(非手拍) ══════════
//  约定:
//   - Finder 窗口坐标:原点左上角,x 向右、y 向下增大
//   - "position of item" = 图标【中心】点(实测锚点是中心,非左上角)
//   - 图标大小 I=96,半宽/半高 h=48
//   - 窗口 W=560, H=360
//
//  眼睛(图标中心,左右对称于窗口中线 280):
//   中心距 D=260 → 左眼中心 (150,120),右眼中心 (410,120)
//   侧边距 = 150-48 = 102(左右相等,整组居中)
//   图标顶边 y=120-48=72(靠上),底边 y=120+48=168
//   两眼内间距 = 410-150-96 = 164(拉宽,让嘴能画出明显微笑)
//
//  嘴(嘴角 = 两眼的"内下角"正下方,留 16pt 空隙):
//   左嘴角 = (左眼右缘, 168+16) = (150+48, 184) = (198, 184)
//   右嘴角 = (右眼左缘, 168+16) = (410-48, 184) = (362, 184)
//   嘴宽 = 362-198 = 164(与两眼内间距一致)
//   弧深 34 → 控制点下探 34*4/3≈45,控制点 y=184+45=229
//
//  本脚本绘图坐标原点在左下(y 向上),换算: 绘图y = 360 - 窗口y
//   嘴角绘图 (198,176)/(362,176),控制点绘图 (253,131)/(307,131)
//   箭头尖落在右嘴角 (362,176),朝右上(Applications)
//   "拖动"文字:普通黑色,居中 x=280,绘图基线 y=110(窗口 y=250)
//
//  用法: swift scripts/make_dmg_background.swift 输出.png
//

import Foundation
import AppKit

// ---- 计算出的参数 ----
let size = NSSize(width: 560, height: 360)
let teal = NSColor(red: 0.24, green: 0.85, blue: 0.75, alpha: 1)

let output = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1] : "dmg_background.png"

let image = NSImage(size: size)
image.lockFocus()

// ---- 微笑嘴(曲线箭头) ----
// 嘴角绘图坐标 (198,176) → (362,176),控制点 (253,131)/(307,131)
let mouth = NSBezierPath()
mouth.move(to: NSPoint(x: 198, y: 176))
mouth.curve(to: NSPoint(x: 362, y: 176),
            controlPoint1: NSPoint(x: 253, y: 131),
            controlPoint2: NSPoint(x: 307, y: 131))
teal.setStroke()
mouth.lineWidth = 10
mouth.lineCapStyle = .round
mouth.lineJoinStyle = .round
mouth.stroke()

// 右端切线方向:P2 - C2 = (362-307, 176-131) = (55, 45)
let dirLen = sqrt(55.0 * 55.0 + 45.0 * 45.0)
let dir = NSPoint(x: 55.0 / dirLen, y: 45.0 / dirLen)
let perp = NSPoint(x: -dir.y, y: dir.x)

// 箭头头部(三角形):尖端正好落在右嘴角 (362,176)
let tip = NSPoint(x: 362, y: 176)
let headLen: CGFloat = 32
let headW: CGFloat = 16
let back = NSPoint(x: tip.x - dir.x * headLen, y: tip.y - dir.y * headLen)
let c1 = NSPoint(x: back.x + perp.x * headW, y: back.y + perp.y * headW)
let c2 = NSPoint(x: back.x - perp.x * headW, y: back.y - perp.y * headW)
let head = NSBezierPath()
head.move(to: tip)
head.line(to: c1)
head.line(to: c2)
head.close()
teal.setFill()
head.fill()

// ---- "拖动"文字标注(普通黑色,不加粗,嘴下方居中) ----
let hint = NSAttributedString(string: "拖动", attributes: [
    .font: NSFont.systemFont(ofSize: 24),
    .foregroundColor: NSColor.black,
])
let hintSize = hint.size()
hint.draw(at: NSPoint(x: 280 - hintSize.width / 2, y: 110))

image.unlockFocus()

// ---- 输出带透明通道的 PNG ----
guard let tiff = image.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else {
    FileHandle.standardError.write("生成 PNG 失败".data(using: .utf8)!)
    exit(1)
}
try! png.write(to: URL(fileURLWithPath: output))
print("已生成 \(output) (\(size.width)×\(size.height), 透明背景)")
