//
//  SettingsView.swift
//  SoundSense iOS
//
//  设置页:校准偏移量滑块 + 关于。
//

import SwiftUI

struct SettingsView: View {
    @ObservedObject var viewModel: MeterViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            content
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("完成") { dismiss() }
                        .foregroundColor(MeterTheme.waveColor)
                }
            }
        }
    }

    /// 把内容拆成独立 computed property,降低 body 类型推断复杂度
    private var content: some View {
        ScrollView {
            VStack(spacing: 24) {
                CalibrationCard(viewModel: viewModel)
                AboutCard()
            }
            .padding(20)
        }
        .background(MeterTheme.backgroundGradient.ignoresSafeArea())
    }
}

// MARK: - 校准卡片

private struct CalibrationCard: View {
    @ObservedObject var viewModel: MeterViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("校准")
                .font(.title3.bold())
                .foregroundColor(.white)

            Text("iOS 麦克风采集的是数字分贝(dBFS),需要加上偏移量才能换算成真实声压级(SPL)。")
                .font(.system(size: 13))
                .foregroundColor(MeterTheme.secondaryText)

            offsetRow
            sliderRow

            Button {
                viewModel.calibrationOffset = 0
            } label: {
                Text("重置为 0")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(RoundedRectangle(cornerRadius: 12).fill(MeterTheme.cardBackground))
            }

            Text("校准方法:用一台标准声级计与手机同位置测量,调节偏移量直到 App 显示值与标准计一致。")
                .font(.system(size: 12))
                .foregroundColor(MeterTheme.secondaryText)
        }
        .modifier(CardStyle())
    }

    private var offsetRow: some View {
        HStack {
            Text("偏移量").foregroundColor(.white.opacity(0.85))
            Spacer()
            Text(String(format: "%+.1f dB", viewModel.calibrationOffset))
                .font(.system(size: 22, weight: .semibold, design: .monospaced))
                .foregroundColor(MeterTheme.waveColor)
        }
    }

    private var sliderRow: some View {
        VStack(spacing: 8) {
            Slider(value: Binding(
                get: { Double(viewModel.calibrationOffset) },
                set: { viewModel.calibrationOffset = Float($0) }
            ), in: -30...60, step: 0.5)
            .tint(MeterTheme.waveColor)
            scaleLabels
        }
    }

    private var scaleLabels: some View {
        HStack {
            Text("-30"); Spacer(); Text("0"); Spacer(); Text("+60")
        }
        .font(.caption2)
        .foregroundColor(MeterTheme.secondaryText)
    }
}

// MARK: - 关于卡片

private struct AboutCard: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("关于闻声").font(.title3.bold()).foregroundColor(.white)
            row(title: "版本", value: appVersionString())
            row(title: "算法", value: "IEC 61672 A 计权 + 4096 点 FFT")
            row(title: "精度", value: "1 kHz 参考点 < 0.1 dB")
            Text("核心算法基于 Accelerate/vDSP,符合 IEC 61672-1 国际标准。")
                .font(.system(size: 12))
                .foregroundColor(MeterTheme.secondaryText)
                .padding(.top, 4)
        }
        .modifier(CardStyle())
    }

    private func row(title: String, value: String) -> some View {
        HStack {
            Text(title).font(.system(size: 14)).foregroundColor(MeterTheme.secondaryText)
            Spacer()
            Text(value).font(.system(size: 14)).foregroundColor(.white.opacity(0.9))
                .multilineTextAlignment(.trailing)
        }
    }

    private func appVersionString() -> String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "\(v) (\(b))"
    }
}

// MARK: - 共用卡片样式

private struct CardStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(20)
            .background(
                RoundedRectangle(cornerRadius: 20)
                    .fill(MeterTheme.cardBackground)
                    .overlay(RoundedRectangle(cornerRadius: 20).stroke(MeterTheme.cardBorder, lineWidth: 1))
            )
    }
}
