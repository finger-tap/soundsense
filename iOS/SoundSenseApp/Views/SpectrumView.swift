//
//  SpectrumView.swift
//  SoundSense iOS
//
//  频谱图:读取 MeterResult.spectrum(FFT 前半段幅度谱),
//  按对数频率轴聚合成若干频段柱显示。
//

import SwiftUI
import SoundSenseCore

struct SpectrumView: View {

    /// 输入频谱(FFT 幅度谱 |X[k]|,长度 = fftSize/2)
    let spectrum: [Float]
    /// 对应频率轴
    let frequencies: [Float]

    /// 聚合后的频段数
    private let bandCount = 32
    /// 显示的最大频率
    private let maxFrequency: Float = 16000

    var body: some View {
        GeometryReader { geo in
            Canvas { context, size in
                let bands = aggregatedBands()
                guard !bands.isEmpty else { return }
                let count = bands.count
                let barWidth = size.width / CGFloat(count) * 0.78
                let gap = size.width / CGFloat(count) * 0.22

                // 计算 max 用分贝域,避免单个尖峰压扁其他柱
                let dbBands = bands.map { band -> Float in
                    let sum = band.reduce(0, +)
                    let avg = sum / Float(max(1, band.count))
                    return 20 * log10(max(avg, 1e-7))
                }
                let minDB: Float = -80
                let maxDB: Float = -10

                for (i, db) in dbBands.enumerated() {
                    let normalized = CGFloat(max(0, min(1, (db - minDB) / (maxDB - minDB))))
                    let barHeight = max(2, normalized * size.height)
                    let x = CGFloat(i) * (barWidth + gap)
                    let y = size.height - barHeight
                    let rect = CGRect(x: x, y: y, width: barWidth, height: barHeight)
                    let path = Path(roundedRect: rect, cornerRadius: 2)
                    let color = bandColor(normalized: Double(normalized))
                    context.fill(path, with: .color(color))
                }
            }
        }
    }

    /// 把全频谱按对数频率轴聚合成 bandCount 个频段。
    /// 低频段可能窄于 FFT bin 间距(48 kHz/4096 点 ≈ 11.7 Hz),
    /// 空段由 SpectrumBands 用相邻 bin 插值填充,否则会显示成恒贴底死柱。
    private func aggregatedBands() -> [[Float]] {
        SpectrumBands.aggregate(spectrum: spectrum,
                                frequencies: frequencies,
                                bandCount: bandCount,
                                minFrequency: 20,
                                maxFrequency: maxFrequency)
    }

    private func bandColor(normalized: Double) -> Color {
        // 低 -> 青,高 -> 暖色
        if normalized < 0.5 {
            return MeterTheme.waveColor
        } else if normalized < 0.8 {
            return Color(red: 1.0, green: 0.85, blue: 0.30)
        } else {
            return Color(red: 1.0, green: 0.45, blue: 0.30)
        }
    }
}
