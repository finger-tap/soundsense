//
//  WatchMeterView.swift
//  SoundSenseWatch
//
//  独立 watchOS 主视图:中央大数字 SPL + 外圈等级色环 + 底部迷你声波条。
//  抬腕即测:App 进入前台(.active)自动启动,进入后台自动停止
//  (watchOS 后台会挂起 AVAudioEngine,因此显式管理生命周期)。
//

import SwiftUI
import SoundSenseCore

struct WatchMeterView: View {
    @StateObject private var viewModel = WatchMeterViewModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ZStack {
            // 背景
            MeterTheme.backgroundGradient.ignoresSafeArea()

            VStack(spacing: 4) {
                // —— 外圈色环 + 中央大数字 ——
                ZStack {
                    levelRing
                        .frame(width: 120, height: 120)

                    VStack(spacing: 1) {
                        Text(splText(viewModel.currentSPL))
                            .font(.system(size: 30, weight: .bold, design: .rounded))
                            .foregroundColor(.white)
                            .monospacedDigit()
                        Text("dB(A)")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundColor(MeterTheme.secondaryText)
                    }
                }
                .padding(.top, 6)

                // —— 等级文字 ——
                if let level = viewModel.noiseLevel {
                    HStack(spacing: 4) {
                        Text(level.emoji).font(.system(size: 11))
                        Text(level.label)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(level.color)
                    }
                } else {
                    Text(statusText)
                        .font(.system(size: 11))
                        .foregroundColor(MeterTheme.secondaryText)
                }

                // —— 迷你声波条 ——
                miniWaveform
                    .frame(height: 28)
                    .padding(.horizontal, 8)

                // —— 迷你频谱 ——
                if let result = viewModel.engine.latestResult {
                    WatchSpectrumView(spectrum: result.spectrum,
                                      frequencies: result.frequencies)
                        .frame(height: 32)
                        .padding(.horizontal, 8)
                }
            }
            .padding(.bottom, 4)
        }
        // 抬腕即测:进入前台自动启动
        .onChange(of: scenePhase) { newPhase in
            switch newPhase {
            case .active:
                Task { await viewModel.start() }
            case .inactive, .background:
                viewModel.stop()
            default:
                break
            }
        }
        .onChange(of: viewModel.engine.latestResult) { result in
            if let result = result {
                viewModel.consume(result)
            }
        }
    }

    // MARK: - 子视图

    /// 外圈等级色环:根据 SPL 在 0~1 填充
    private var levelRing: some View {
        Canvas { context, size in
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let radius = min(size.width, size.height) / 2 - 6
            let lineWidth: CGFloat = 6

            // 背景圆环
            var track = Path()
            track.addArc(center: center,
                         radius: radius,
                         startAngle: .degrees(0),
                         endAngle: .degrees(360),
                         clockwise: false)
            context.stroke(track,
                           with: .color(.white.opacity(0.1)),
                           style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))

            // 进度环
            let progress = clampedProgress(viewModel.currentSPL)
            let color = viewModel.noiseLevel?.color ?? MeterTheme.waveColor
            var arc = Path()
            arc.addArc(center: center,
                       radius: radius,
                       startAngle: .degrees(-90),
                       endAngle: .degrees(-90 + progress * 360),
                       clockwise: false)
            context.stroke(arc,
                           with: .color(color),
                           style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
        }
    }

    private var miniWaveform: some View {
        Canvas { context, size in
            let values = viewModel.history
            guard !values.isEmpty else { return }
            let count = values.count
            let barWidth = size.width / CGFloat(count) * 0.7
            let gap = size.width / CGFloat(count) * 0.3
            let color = viewModel.noiseLevel?.color ?? MeterTheme.waveColor
            for (i, v) in values.enumerated() {
                let normalized = CGFloat(max(0, min(1, (v - 20) / 80)))
                let h = max(1, normalized * size.height)
                let x = CGFloat(i) * (barWidth + gap)
                let y = (size.height - h) / 2
                let rect = CGRect(x: x, y: y, width: barWidth, height: h)
                context.fill(Path(roundedRect: rect, cornerRadius: barWidth / 2),
                             with: .color(color.opacity(0.4 + 0.6 * Double(i) / Double(max(1, count - 1)))))
            }
        }
    }

    // MARK: - 工具

    private func splText(_ spl: Float) -> String {
        guard spl.isFinite, spl > -80 else { return "--" }
        return String(format: "%.0f", spl)
    }

    private func clampedProgress(_ spl: Float) -> Double {
        let minDB: Float = 20, maxDB: Float = 120
        let c = max(minDB, min(maxDB, spl))
        return Double((c - minDB) / (maxDB - minDB))
    }

    private var statusText: String {
        switch viewModel.engine.state {
        case .stopped: return "抬腕即测"
        case .starting: return "启动中…"
        case .running: return "测量中"
        case .denied: return "需麦克风权限"
        case .failed: return "启动失败"
        }
    }
}
