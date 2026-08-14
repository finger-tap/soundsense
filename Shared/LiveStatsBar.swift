//
//  LiveStatsBar.swift
//  SoundSense
//
//  实时统计栏:测量进行中显示 时长 / 等效声级 LAeq / 峰值。
//  iOS 与 macOS 共用(深色 UI 风格)。
//

#if os(iOS) || os(macOS)

import SwiftUI

public struct LiveStatsBar: View {
    public let stats: LiveMeasurementStats

    public init(stats: LiveMeasurementStats) {
        self.stats = stats
    }

    public var body: some View {
        HStack(spacing: 0) {
            statItem(value: formatDuration(stats.duration), label: "时长")
            divider
            statItem(value: String(format: "%.1f", stats.laeq), label: "LAeq dB")
            divider
            statItem(value: String(format: "%.1f", stats.peak), label: "峰值 dB")
        }
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color.white.opacity(0.05))
                .overlay(RoundedRectangle(cornerRadius: 14)
                    .stroke(Color.white.opacity(0.08), lineWidth: 1))
        )
    }

    private var divider: some View {
        Rectangle()
            .fill(Color.white.opacity(0.08))
            .frame(width: 1, height: 30)
    }

    private func statItem(value: String, label: String) -> some View {
        VStack(spacing: 3) {
            Text(value)
                .font(.system(size: 16, weight: .semibold, design: .rounded))
                .foregroundColor(.white)
                .monospacedDigit()
            Text(label)
                .font(.system(size: 10))
                .foregroundColor(.white.opacity(0.45))
        }
        .frame(maxWidth: .infinity)
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let s = Int(seconds)
        if s >= 3600 { return String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60) }
        return String(format: "%02d:%02d", s / 60, s % 60)
    }
}

/// 噪声暴露警告横幅(连续超过阈值超过警告时长时显示)
public struct ExposureWarningBanner: View {
    public let threshold: Float

    public init(threshold: Float = MeasurementRecorder.defaultExposureLimit) {
        self.threshold = threshold
    }

    public var body: some View {
        HStack(spacing: 8) {
            Text("⚠️")
                .font(.system(size: 15))
            VStack(alignment: .leading, spacing: 1) {
                Text("噪音过高,注意听力防护")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white)
                Text(String(format: "环境已连续 30 秒以上超过 %.0f dB,长时间暴露可能损伤听力", threshold))
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.75))
            }
            Spacer()
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(red: 1.0, green: 0.25, blue: 0.25).opacity(0.85))
        )
        .transition(.move(edge: .top).combined(with: .opacity))
    }
}

#endif
