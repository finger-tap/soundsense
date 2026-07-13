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
            let bands = aggregatedBands()
            guard !bands.isEmpty else { return }
            let dbBands = bands.map { band -> Float in
                let sum = band.reduce(0, +)
                let avg = sum / Float(max(1, band.count))
                return 20 * log10(max(avg, 1e-7))
            }
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

    private func aggregatedBands() -> [[Float]] {
        guard !spectrum.isEmpty, !frequencies.isEmpty else { return [] }
        let minF: Float = 20
        let maxF: Float = min(maxFrequency, frequencies.last!)
        guard maxF > minF else { return [] }
        let logMin = log10(minF)
        let logMax = log10(maxF)
        var bands: [[Float]] = []
        let step = (logMax - logMin) / Float(bandCount)
        for i in 0..<bandCount {
            let lo = pow(10, logMin + Float(i) * step)
            let hi = pow(10, logMin + Float(i + 1) * step)
            var bucket: [Float] = []
            for (idx, f) in frequencies.enumerated() where f >= lo && f < hi {
                if idx < spectrum.count { bucket.append(spectrum[idx]) }
            }
            bands.append(bucket)
        }
        return bands
    }
}
