//
//  MacSettingsView.swift
//  SoundSenseMac
//
//  macOS 设置页:校准偏移量 + 关于。
//

import SwiftUI

struct MacSettingsView: View {
    @ObservedObject var viewModel: MeterViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 20) {
            HStack {
                Text("设置")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundColor(.white)
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .foregroundColor(.white.opacity(0.5))
                }
                .buttonStyle(.plain)
            }

            ScrollView(.vertical) {
                VStack(spacing: 16) {
                    calibrationCard
                    aboutCard
                }
            }
        }
        .padding(20)
        .background(MeterTheme.backgroundGradient.ignoresSafeArea())
        .frame(width: 480, height: 460)
    }

    private var calibrationCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("校准")
                .font(.system(size: 15, weight: .bold))
                .foregroundColor(.white)

            Text("macOS 麦克风采集的是数字分贝(dBFS),需要加上偏移量才能换算成真实声压级(SPL)。")
                .font(.system(size: 12))
                .foregroundColor(MeterTheme.secondaryText)

            HStack {
                Text("偏移量").foregroundColor(.white.opacity(0.85))
                Spacer()
                Text(String(format: "%+.1f dB", viewModel.calibrationOffset))
                    .font(.system(size: 18, weight: .semibold, design: .monospaced))
                    .foregroundColor(MeterTheme.waveColor)
            }

            VStack(spacing: 6) {
                Slider(value: Binding(
                    get: { Double(viewModel.calibrationOffset) },
                    set: { viewModel.calibrationOffset = Float($0) }
                ), in: -30...60, step: 0.5)
                .tint(MeterTheme.waveColor)
                HStack {
                    Text("-30"); Spacer(); Text("0"); Spacer(); Text("+60")
                }
                .font(.caption2)
                .foregroundColor(MeterTheme.secondaryText)
            }

            Button {
                viewModel.calibrationOffset = 0
            } label: {
                Text("重置为 0")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(RoundedRectangle(cornerRadius: 10).fill(MeterTheme.cardBackground))
            }
            .buttonStyle(.plain)

            Text("校准方法:用一台标准声级计与电脑同位置测量,调节偏移量直到 App 显示值与标准计一致。")
                .font(.system(size: 11))
                .foregroundColor(MeterTheme.secondaryText)
        }
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(MeterTheme.cardBackground)
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(MeterTheme.cardBorder, lineWidth: 1))
        )
    }

    private var aboutCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("关于闻声")
                .font(.system(size: 15, weight: .bold))
                .foregroundColor(.white)
            row(title: "版本", value: appVersionString())
            row(title: "算法", value: "IEC 61672 A 计权 + 4096 点 FFT")
            row(title: "精度", value: "1 kHz 参考点 < 0.1 dB")
            Text("核心算法基于 Accelerate/vDSP,符合 IEC 61672-1 国际标准。")
                .font(.system(size: 11))
                .foregroundColor(MeterTheme.secondaryText)
                .padding(.top, 4)
        }
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(MeterTheme.cardBackground)
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(MeterTheme.cardBorder, lineWidth: 1))
        )
    }

    private func row(title: String, value: String) -> some View {
        HStack {
            Text(title).font(.system(size: 13)).foregroundColor(MeterTheme.secondaryText)
            Spacer()
            Text(value).font(.system(size: 13)).foregroundColor(.white.opacity(0.9))
        }
    }

    private func appVersionString() -> String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "\(v) (\(b))"
    }
}
