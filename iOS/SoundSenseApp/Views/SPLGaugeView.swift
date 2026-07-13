//
//  SPLGaugeView.swift
//  SoundSense iOS
//
//  圆弧形 SPL 仪表盘,指针随分贝值移动,按等级填色。
//  量程 20~120 dB(覆盖日常到极端噪声)。
//

import SwiftUI

struct SPLGaugeView: View {

    let spl: Float
    let levelColor: Color

    /// 量程
    private let minDB: Float = 20
    private let maxDB: Float = 120
    /// 刻度点
    private let ticks: [Float] = [20, 40, 60, 80, 100, 120]

    var body: some View {
        GeometryReader { geo in
            let size = min(geo.size.width, geo.size.height)
            Canvas { context, canvasSize in
                drawGauge(into: &context, canvasSize: canvasSize)
            }
            .frame(width: size, height: size)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        }
        .aspectRatio(1, contentMode: .fit)
    }

    /// 把整个仪表盘画进 context(拆出来帮助类型推断)
    private func drawGauge(into context: inout GraphicsContext, canvasSize: CGSize) {
        let center = CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2)
        let size = min(canvasSize.width, canvasSize.height)
        let radius = size / 2 * 0.85
        let lineWidth = size * 0.06
        let roundCap = StrokeStyle(lineWidth: lineWidth, lineCap: .round)

        let startAngle = Angle.degrees(-225)
        let endAngle = Angle.degrees(45)

        // 背景轨道
        var track = Path()
        track.addArc(center: center, radius: radius,
                     startAngle: startAngle, endAngle: endAngle, clockwise: false)
        context.stroke(track, with: .color(.white.opacity(0.12)), style: roundCap)

        // 进度弧
        let progress = clampedProgress(spl)
        let progressEndAngle = Angle.degrees(-225 + progress * 270)
        var progressPath = Path()
        progressPath.addArc(center: center, radius: radius,
                            startAngle: startAngle, endAngle: progressEndAngle, clockwise: false)
        context.stroke(progressPath, with: .color(levelColor), style: roundCap)

        // 刻度
        for db in ticks {
            let t = (db - minDB) / (maxDB - minDB)
            let angle = Angle.degrees(-225 + Double(t) * 270)
            let cosA = CGFloat(cos(angle.radians))
            let sinA = CGFloat(sin(angle.radians))
            let inner = CGPoint(x: center.x + cosA * (radius - size * 0.07),
                                y: center.y + sinA * (radius - size * 0.07))
            let outer = CGPoint(x: center.x + cosA * (radius - size * 0.02),
                                y: center.y + sinA * (radius - size * 0.02))
            var tick = Path()
            tick.move(to: inner)
            tick.addLine(to: outer)
            context.stroke(tick, with: .color(.white.opacity(0.4)),
                           style: StrokeStyle(lineWidth: 1.5))

            // 刻度数字
            let labelPoint = CGPoint(x: center.x + cosA * (radius - size * 0.14),
                                     y: center.y + sinA * (radius - size * 0.14))
            context.draw(Text("\(Int(db))")
                            .font(.system(size: size * 0.035, weight: .medium))
                            .foregroundColor(.white.opacity(0.5)),
                         at: labelPoint)
        }
    }

    /// 把 SPL 归一化到 0~1
    private func clampedProgress(_ spl: Float) -> Double {
        let clamped = max(minDB, min(maxDB, spl))
        return Double((clamped - minDB) / (maxDB - minDB))
    }
}
