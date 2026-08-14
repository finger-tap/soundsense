//
//  DBRulerGauge.swift
//  SoundSense
//
//  签名组件:dB 标尺 —— 模拟专业声级计的刻度尺。
//    - 30~120 dB 横向刻度(主刻度每 10 dB,副刻度每 5 dB)
//    - 底部分区色带:按听力风险语义着色(安静 → 有害)
//    - 85 dB 处一道红色风险刻度(长期暴露开始损伤听力)
//    - 指针(发丝线 + 光点)随读数移动,弹簧动画
//  iOS 与 macOS 共用。
//

#if os(iOS) || os(macOS)

import SwiftUI

public struct DBRulerGauge: View {

    public let spl: Float
    public var levelColor: Color = MeterTheme.waveColor

    /// 量程
    private let minDB: Float = 30
    private let maxDB: Float = 120
    /// 长期暴露风险阈值(画红色刻度)
    private let riskDB: Float = 85

    public init(spl: Float, levelColor: Color = MeterTheme.waveColor) {
        self.spl = spl
        self.levelColor = levelColor
    }

    /// 分区色带:范围 → 语义色(与 NoiseLevel 档位一致)
    private let zones: [(from: Float, to: Float, color: Color)] = [
        (30, 50, Color(red: 0.35, green: 0.55, blue: 1.0)),
        (50, 65, Color(red: 0.30, green: 0.82, blue: 0.62)),
        (65, 75, Color(red: 0.96, green: 0.72, blue: 0.29)),
        (75, 90, Color(red: 1.0, green: 0.48, blue: 0.35)),
        (90, 120, Color(red: 1.0, green: 0.27, blue: 0.24)),
    ]

    public var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let baseY: CGFloat = h - 20          // 刻度基线
            let bandBottom: CGFloat = h - 12     // 色带底
            let needleTop: CGFloat = 2

            ZStack(alignment: .topLeading) {
                // 静态部分:刻度 / 数字 / 色带 / 风险刻度
                Canvas { ctx, size in
                    let toX: (Float) -> CGFloat = { db in
                        CGFloat((db - minDB) / (maxDB - minDB)) * size.width
                    }

                    // 分区色带
                    for zone in zones {
                        let x0 = toX(max(minDB, zone.from))
                        let x1 = toX(min(maxDB, zone.to))
                        let rect = CGRect(x: x0, y: baseY, width: max(0, x1 - x0),
                                          height: bandBottom - baseY)
                        ctx.fill(Path(roundedRect: rect, cornerRadius: 1.5),
                                 with: .color(zone.color.opacity(0.55)))
                    }

                    // 副刻度(每 5 dB)
                    var db = minDB
                    while db <= maxDB {
                        let x = toX(db)
                        let isMajor = Int(db) % 10 == 0
                        let isRisk = abs(db - riskDB) < 0.01
                        let tickH: CGFloat = isRisk ? 16 : (isMajor ? 10 : 5)
                        let tickColor: Color = isRisk
                            ? Color(red: 1.0, green: 0.27, blue: 0.24)
                            : Color.white.opacity(isMajor ? 0.45 : 0.22)
                        var tick = Path()
                        tick.move(to: CGPoint(x: x, y: baseY - tickH))
                        tick.addLine(to: CGPoint(x: x, y: baseY))
                        ctx.stroke(tick, with: .color(tickColor),
                                   style: StrokeStyle(lineWidth: isRisk ? 1.5 : 1,
                                                      lineCap: .round))
                        db += 5
                    }

                    // 基线
                    var baseline = Path()
                    baseline.move(to: CGPoint(x: 0, y: baseY))
                    baseline.addLine(to: CGPoint(x: size.width, y: baseY))
                    ctx.stroke(baseline, with: .color(.white.opacity(0.25)),
                               style: StrokeStyle(lineWidth: 1))

                    // 主刻度数字(每 20 dB)+ 风险刻度数字
                    for labelDB in [30, 50, 70, 110] {
                        ctx.draw(Text("\(labelDB)")
                                    .font(MeterTheme.mono(9))
                                    .foregroundColor(.white.opacity(0.45)),
                                 at: CGPoint(x: toX(Float(labelDB)), y: bandBottom + 8))
                    }
                    ctx.draw(Text("85")
                                .font(MeterTheme.mono(9, weight: .semibold))
                                .foregroundColor(Color(red: 1.0, green: 0.35, blue: 0.30)),
                             at: CGPoint(x: toX(riskDB), y: bandBottom + 8))
                }

                // 动态部分:指针(独立图层,弹簧动画)
                let progress = CGFloat(max(0, min(1, (spl - minDB) / (maxDB - minDB))))
                let needleX = progress * w
                let active = spl.isFinite && spl > -80

                Capsule()
                    .fill(active ? levelColor : Color.white.opacity(0.25))
                    .frame(width: 2.5, height: baseY - needleTop - 2)
                    .position(x: needleX, y: needleTop + (baseY - needleTop - 2) / 2)
                Circle()
                    .fill(active ? levelColor : Color.white.opacity(0.25))
                    .frame(width: 7, height: 7)
                    .shadow(color: active ? levelColor.opacity(0.9) : .clear, radius: 4)
                    .position(x: needleX, y: needleTop + 3)
            }
            .animation(.spring(response: 0.38, dampingFraction: 0.85), value: spl)
        }
        .frame(height: 46)
        .accessibilityLabel("当前声压级标尺")
        .accessibilityValue(spl.isFinite && spl > -80
                            ? String(format: "%.0f 分贝", spl) : "无信号")
    }
}

#endif
