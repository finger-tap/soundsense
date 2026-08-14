//
//  SettingsView.swift
//  SoundSense iOS
//
//  设置页:校准偏移量滑块 + 关于。
//

import SwiftUI
import SoundSenseCore

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
                MeasurementCard(viewModel: viewModel)
                HealthCard(viewModel: viewModel)
                AboutCard()
            }
            .padding(20)
        }
        .background(MeterTheme.backgroundGradient.ignoresSafeArea())
    }
}

// MARK: - 测量卡片(计权 / 警告阈值)

private struct MeasurementCard: View {
    @ObservedObject var viewModel: MeterViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("测量")
                .font(.title3.bold())
                .foregroundColor(.white)

            // 频率计权
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("频率计权").foregroundColor(.white.opacity(0.85))
                    Spacer()
                    Text(viewModel.weighting == .a ? "A 计权(环境噪音)" : "C 计权(低频噪音)")
                        .font(.system(size: 12))
                        .foregroundColor(MeterTheme.secondaryText)
                }
                Picker("频率计权", selection: Binding(
                    get: { viewModel.weighting },
                    set: { viewModel.weighting = $0 }
                )) {
                    Text("A").tag(Weighting.a)
                    Text("C").tag(Weighting.c)
                }
                .pickerStyle(.segmented)
                Text("A 计权模拟人耳感受,适合日常噪音;C 计权保留低频能量,适合音响、空调、机械等低频噪音。")
                    .font(.system(size: 12))
                    .foregroundColor(MeterTheme.secondaryText)
            }

            Divider().overlay(MeterTheme.hairline)

            // 警告阈值
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("警告阈值").foregroundColor(.white.opacity(0.85))
                    Spacer()
                    Text(String(format: "%.0f dB", viewModel.warningThreshold))
                        .font(.system(size: 18, weight: .semibold, design: .monospaced))
                        .foregroundColor(MeterTheme.waveColor)
                }
                Slider(value: Binding(
                    get: { Double(viewModel.warningThreshold) },
                    set: { viewModel.warningThreshold = Float($0) }
                ), in: 40...120, step: 1)
                .tint(MeterTheme.waveColor)
                HStack {
                    Text("40"); Spacer(); Text("85"); Spacer(); Text("120")
                }
                .font(.caption2)
                .foregroundColor(MeterTheme.secondaryText)
                Text("连续超过该值 30 秒后提醒。85 dB 是长期暴露的听力安全上限;测卧室可调到 45~50。")
                    .font(.system(size: 12))
                    .foregroundColor(MeterTheme.secondaryText)
            }
        }
        .modifier(CardStyle())
    }
}

// MARK: - 健康卡片(Apple 健康)

private struct HealthCard: View {
    @ObservedObject var viewModel: MeterViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle(isOn: Binding(
                get: { viewModel.healthEnabled },
                set: { newValue in
                    if newValue {
                        Task {
                            let ok = await HealthWriter.requestAuthorization()
                            viewModel.healthEnabled = ok
                        }
                    } else {
                        viewModel.healthEnabled = false
                    }
                }
            )) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("写入健康 App")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundColor(.white)
                    Text("测量超过 1 分钟后,把等效声级写入健康 App 的「环境声级暴露」。数据仅保存在本机。")
                        .font(.system(size: 12))
                        .foregroundColor(MeterTheme.secondaryText)
                }
            }
            .tint(MeterTheme.waveColor)
        }
        .modifier(CardStyle())
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

            Text("iOS 麦克风采集的是数字分贝(dBFS),需要加上偏移量才能换算成真实声压级(SPL)。默认 +93 dB 适用多数 iPhone 麦克风。")
                .font(.system(size: 13))
                .foregroundColor(MeterTheme.secondaryText)

            offsetRow
            sliderRow

            HStack(spacing: 8) {
                presetButton(label: "内建麦克风", offset: 93)
                presetButton(label: "外接麦克风", offset: 85)
            }

            Button {
                viewModel.calibrationOffset = 93
            } label: {
                Text("恢复默认 (+93 dB)")
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

    private func presetButton(label: String, offset: Float) -> some View {
        Button {
            viewModel.calibrationOffset = offset
        } label: {
            VStack(spacing: 2) {
                Text(label).font(.system(size: 13, weight: .medium))
                Text(String(format: "+%.0f dB", offset))
                    .font(.system(size: 11, design: .monospaced))
                    .opacity(0.7)
            }
            .foregroundColor(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 10).fill(MeterTheme.cardBackground))
        }
        .buttonStyle(.plain)
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
            ), in: 60...110, step: 0.5)
            .tint(MeterTheme.waveColor)
            scaleLabels
        }
    }

    private var scaleLabels: some View {
        HStack {
            Text("60"); Spacer(); Text("85"); Spacer(); Text("110")
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
