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
                let dbBands = SpectrumBands.bandLevelsDB(spectrum: spectrum,
                                                         frequencies: frequencies,
                                                         bandCount: bandCount,
                                                         minFrequency: 20,
                                                         maxFrequency: maxFrequency)
                guard !dbBands.isEmpty else { return }
                let count = dbBands.count
                let barWidth = size.width / CGFloat(count) * 0.78
                let gap = size.width / CGFloat(count) * 0.22

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

    private func bandColor(normalized: Double) -> Color {
        // 低 -> 青,高 -> 暖色
        if normalized < 0.5 {
            return MeterTheme.waveColor
        } else if normalized < 0.8 {
            return MeterTheme.brass
        } else {
            return MeterTheme.riskColor
        }
    }
}
