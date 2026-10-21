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
    /// 固定显示槽位。柱宽由槽位数决定，不从当前数据量反推；
    /// 数据不足时靠右排列，满槽后整体向左滚动。
    var slotCount: Int = 80
    /// 显示量程(SPL:校准后的声压级)
    var minDB: Float = 30
    var maxDB: Float = 100
    /// 主色
    var color: Color = MeterTheme.waveColor

    var body: some View {
        GeometryReader { geo in
            Canvas { context, size in
                let slots = max(1, slotCount)
                let visible = Array(values.suffix(slots))
                guard !visible.isEmpty else { return }

                let slotWidth = size.width / CGFloat(slots)
                let barWidth = max(1, slotWidth * 0.62)
                let startSlot = slots - visible.count

                for (i, value) in visible.enumerated() {
                    let normalized = CGFloat(max(0, min(1, (value - minDB) / (maxDB - minDB))))
                    let barHeight = max(2, normalized * size.height)
                    let x = CGFloat(startSlot + i) * slotWidth
                        + (slotWidth - barWidth) / 2
                    let y = (size.height - barHeight) / 2

                    let rect = CGRect(x: x, y: y, width: barWidth, height: barHeight)
                    let path = Path(roundedRect: rect, cornerRadius: barWidth / 2)
                    // 最近的柱子更亮
                    let opacity = i == visible.count - 1
                        ? 1 : 0.35 + 0.65 * (Double(i) / Double(max(1, visible.count - 1)))
                    context.fill(path, with: .color(color.opacity(opacity)))
                }
            }
        }
        .frame(height: 80)
    }
}
