//
//  WatchSpectrumView.swift
//  SoundSenseWatch
//
//  适配小屏的迷你频谱:聚合到 16 个频段柱。
//

import SwiftUI
import SoundSenseCore

struct WatchSpectrumView: View {

    let spectrum: [Float]
    let frequencies: [Float]

    private let bandCount = 16
    private let maxFrequency: Float = 8000

    var body: some View {
        Canvas { context, size in
            let dbBands = SpectrumBands.bandLevelsDB(spectrum: spectrum,
                                                     frequencies: frequencies,
                                                     bandCount: bandCount,
                                                     minFrequency: 20,
                                                     maxFrequency: maxFrequency)
            guard !dbBands.isEmpty else { return }
            let minDB: Float = -80
            let maxDB: Float = -10
            let count = dbBands.count
            let barWidth = size.width / CGFloat(count) * 0.7
            let gap = size.width / CGFloat(count) * 0.3

            for (i, db) in dbBands.enumerated() {
                let normalized = CGFloat(max(0, min(1, (db - minDB) / (maxDB - minDB))))
                let barHeight = max(1.5, normalized * size.height)
                let x = CGFloat(i) * (barWidth + gap)
                let y = size.height - barHeight
                let rect = CGRect(x: x, y: y, width: barWidth, height: barHeight)
                let path = Path(roundedRect: rect, cornerRadius: 1)
                context.fill(path, with: .color(MeterTheme.waveColor.opacity(0.35 + 0.65 * Double(normalized))))
            }
        }
    }

}
