//
//  LiveStatsBar.swift
//  SoundSense
//
//  实时统计栏:测量进行中显示 时长 / 等效声级 LAeq / 峰值。
//  iOS 与 macOS 共用(深色 UI 风格)。
//

#if os(iOS) || os(macOS)

import SwiftUI
import SoundSenseCore

public struct LiveStatsBar: View {
    public let stats: LiveMeasurementStats
    /// 频率计权(A/C),用于正确显示 LAeq / LCeq。
    public var weighting: Weighting
    /// 时间计权(F/S),用于正确显示 LAFmax / LASmax 等峰值口径。
    public var timeWeighting: TimeWeighting
    /// 同步录音进行中:时长旁显示红点提示
    public var isRecording: Bool = false

    public init(stats: LiveMeasurementStats,
                weighting: Weighting,
                timeWeighting: TimeWeighting = .fast,
                isRecording: Bool = false) {
        self.stats = stats
        self.weighting = weighting
        self.timeWeighting = timeWeighting
        self.isRecording = isRecording
    }

    public var body: some View {
        HStack(spacing: 0) {
            statItem(value: formatDuration(stats.duration), label: "时长", recordingDot: isRecording)
            divider
            statItem(value: stats.laeq.isFinite ? String(format: "%.1f", stats.laeq) : "--",
                     label: "\(weighting == .c ? "LCeq" : "LAeq") dB")
            divider
            statItem(value: stats.peak.isFinite ? String(format: "%.1f", stats.peak) : "--",
                     label: "\(peakMetricLabel) dB")
        }
        .overlay(alignment: .topTrailing) {
            if stats.captureIncomplete {
                Label("采集不完整", systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundColor(MeterTheme.brass)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(MeterTheme.panel.opacity(0.96)))
                    .padding(.top, -9)
                    .padding(.trailing, 10)
            }
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

    private func statItem(value: String, label: String, recordingDot: Bool = false) -> some View {
        VStack(spacing: 3) {
            HStack(alignment: .top, spacing: 4) {
                Text(value)
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                    .foregroundColor(.white)
                    .monospacedDigit()
                if recordingDot {
                    Circle()
                        .fill(MeterTheme.riskColor)
                        .frame(width: 6, height: 6)
                        .padding(.top, 3)
                }
            }
            Text(label)
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(0.62))
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label) \(value)")
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let s = Int(seconds)
        if s >= 3600 { return String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60) }
        return String(format: "%02d:%02d", s / 60, s % 60)
    }

    private var peakMetricLabel: String {
        "L\(weighting == .c ? "C" : "A")\(timeWeighting == .slow ? "S" : "F")max"
    }
}

/// 噪声暴露警告横幅(连续超过阈值超过警告时长时显示)
public struct ExposureWarningBanner: View {
    public let threshold: Float

    /// 阈值必须显式传入(用户设置值),不提供默认值——
    /// 避免调用方漏传导致横幅文案与用户设置的阈值脱节(三端漂移的真实教训)。
    public init(threshold: Float) {
        self.threshold = threshold
    }

    public var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 15, weight: .semibold))
            VStack(alignment: .leading, spacing: 1) {
                Text("噪音过高,注意听力防护")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white)
                Text(String(format: "环境已连续 30 秒以上超过 %.0f dB,长时间暴露可能损伤听力", threshold))
                    .font(.system(size: 11.5))
                    .foregroundColor(.white.opacity(0.86))
            }
            Spacer()
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(MeterTheme.riskColor.opacity(0.84))
                .overlay(RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.white.opacity(0.12), lineWidth: 1))
        )
        .transition(.move(edge: .top).combined(with: .opacity))
    }
}

#endif
