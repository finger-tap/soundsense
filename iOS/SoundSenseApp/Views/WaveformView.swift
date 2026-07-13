//
//  WaveformView.swift
//  SoundSense iOS
//
//  实时声波条:把最近 N 个 SPL 值画成横向滚动柱状图。
//

import SwiftUI

struct WaveformView: View {

    /// 历史 SPL 数组(最近若干帧)
    let values: [Float]
    /// 显示量程
    var minDB: Float = 20
    var maxDB: Float = 100
    /// 主色
    var color: Color = MeterTheme.waveColor

    var body: some View {
        GeometryReader { geo in
            Canvas { context, size in
                guard !values.isEmpty else { return }
                let count = values.count
                let barWidth = size.width / CGFloat(count) * 0.7
                let gap = size.width / CGFloat(count) * 0.3

                for (i, value) in values.enumerated() {
                    let normalized = CGFloat(max(0, min(1, (value - minDB) / (maxDB - minDB))))
                    let barHeight = max(2, normalized * size.height)
                    let x = CGFloat(i) * (barWidth + gap)
                    let y = (size.height - barHeight) / 2

                    let rect = CGRect(x: x, y: y, width: barWidth, height: barHeight)
                    let path = Path(roundedRect: rect, cornerRadius: barWidth / 2)
                    // 最近的柱子更亮
                    let opacity = 0.35 + 0.65 * (Double(i) / Double(max(1, count - 1)))
                    context.fill(path, with: .color(color.opacity(opacity)))
                }
            }
        }
        .frame(height: 80)
    }
}
