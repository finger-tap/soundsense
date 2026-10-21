//
//  SettingsView.swift
//  SoundSense iOS
//
//  设置页:校准偏移量滑块 + 关于。
//

import SwiftUI
import UIKit
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
                .disabled(viewModel.engine.state == .running || viewModel.engine.state == .starting)
                Text("A 计权模拟人耳感受,适合日常噪音;C 计权保留低频能量,适合音响、空调、机械等低频噪音。")
                    .font(.system(size: 12))
                    .foregroundColor(MeterTheme.secondaryText)
                if viewModel.engine.state == .running || viewModel.engine.state == .starting {
                    Text("测量中已锁定计权方式,停止后可切换。")
                        .font(.system(size: 12))
                        .foregroundColor(MeterTheme.brass)
                }
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

                Toggle(isOn: Binding(
                    get: { viewModel.systemNotificationsEnabled },
                    set: { newValue in
                        viewModel.systemNotificationsEnabled = newValue
                        if newValue { NoiseAlertNotifier.requestAuthorization() }
                    }
                )) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("超限时发系统通知")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(.white.opacity(0.85))
                        Text("关闭时仅 App 内横幅提醒(默认)。开启后会在第一次测量时请求通知权限。")
                            .font(.system(size: 11))
                            .foregroundColor(MeterTheme.secondaryText)
                    }
                }
                .tint(MeterTheme.waveColor)
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
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("校准")
                .font(.title3.bold())
                .foregroundColor(.white)

            Text("iOS 麦克风采集的是数字分贝(dBFS),需要加上偏移量才能换算成真实声压级(SPL)。默认 +120 dB 是数字 MEMS 麦克风的典型值(±6 dB),精确值请用下方向导对照标准声级计实测。")
                .font(.system(size: 13))
                .foregroundColor(MeterTheme.secondaryText)

            offsetRow
            sliderRow

            HStack(spacing: 8) {
                presetButton(label: "内建麦克风", offset: CalibrationDefaults.iosBuiltIn)
                presetButton(label: "外接麦克风", offset: CalibrationDefaults.external)
            }

            Button {
                viewModel.calibrationOffset = CalibrationDefaults.iosBuiltIn
            } label: {
                Text("恢复默认 (+120 dB)")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(RoundedRectangle(cornerRadius: 12).fill(MeterTheme.cardBackground))
            }

            liveCalibration

            Text("校准方法:用一台标准声级计与手机同位置测量(计权方式一致),点按钮调偏移量直到 App 显示值与标准计一致。有 94 dB/1 kHz 声校准器时,把手机麦对准校准器,调到显示 94。")
                .font(.system(size: 12))
                .foregroundColor(MeterTheme.secondaryText)
        }
        .modifier(CardStyle())
    }

    /// 实时校准向导:测量运行中显示当前读数,对照参考计微调
    @ViewBuilder
    private var liveCalibration: some View {
        if viewModel.engine.state == .running {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("实时校准")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.white)
                    Spacer()
                    Text(String(format: "%+.1f dB", viewModel.calibrationOffset))
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(MeterTheme.secondaryText)
                }
                Text(viewModel.currentSPL.isFinite && viewModel.currentSPL > -80
                     ? String(format: "%.1f", viewModel.currentSPL)
                     : "--")
                    .font(.system(size: 40, weight: .bold, design: .monospaced))
                    .foregroundColor(MeterTheme.waveColor)
                    .frame(maxWidth: .infinity)
                HStack(spacing: 8) {
                    adjustButton("-1", -1)
                    adjustButton("-0.5", -0.5)
                    adjustButton("+0.5", 0.5)
                    adjustButton("+1", 1)
                }
                Text("把参考声级计放在手机同一位置,微调直到两边读数一致。校准即时生效,建议在正式测量前完成。")
                    .font(.system(size: 12))
                    .foregroundColor(MeterTheme.secondaryText)
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 12).fill(MeterTheme.cardBackground))
        } else {
            VStack(alignment: .leading, spacing: 10) {
                Text("提示:启动麦克风后,可对照标准声级计在当前页面实时微调偏移量。")
                    .font(.system(size: 12))
                    .foregroundColor(MeterTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)

                if viewModel.engine.state == .starting {
                    HStack(spacing: 8) {
                        ProgressView().tint(MeterTheme.waveColor)
                        Text("正在启动麦克风...")
                            .font(.system(size: 12))
                            .foregroundColor(MeterTheme.secondaryText)
                    }
                } else if viewModel.engine.state == .denied {
                    Button {
                        openMicrophoneSettings()
                    } label: {
                        Label("前往系统设置开启麦克风", systemImage: "gearshape")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(RoundedRectangle(cornerRadius: 10)
                                .fill(MeterTheme.riskColor.opacity(0.82)))
                    }
                    .buttonStyle(.plain)
                } else if !viewModel.hasAudioInput {
                    Label("未检测到麦克风，请连接后重试", systemImage: "mic.slash")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(MeterTheme.brass)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Button {
                        Task { await viewModel.start() }
                    } label: {
                        Label("启动麦克风开始校准", systemImage: "mic.fill")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(RoundedRectangle(cornerRadius: 10)
                                .fill(MeterTheme.primaryActionGradient))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func openMicrophoneSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        openURL(url)
    }

    private func adjustButton(_ label: String, _ delta: Float) -> some View {
        Button {
            viewModel.calibrationOffset += delta
        } label: {
            Text(label)
                .font(.system(size: 15, weight: .semibold, design: .monospaced))
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(RoundedRectangle(cornerRadius: 10).fill(.white.opacity(0.08)))
        }
        .buttonStyle(.plain)
    }

    private func presetButton(label: String, offset: Float) -> some View {
        let selected = abs(viewModel.calibrationOffset - offset) < 0.05
        return Button {
            viewModel.calibrationOffset = offset
        } label: {
            VStack(spacing: 2) {
                HStack(spacing: 4) {
                    if selected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    Text(label).font(.system(size: 13, weight: .medium))
                }
                Text(String(format: "+%.0f dB", offset))
                    .font(.system(size: 11, design: .monospaced))
                    .opacity(0.7)
            }
            .foregroundColor(selected ? MeterTheme.waveColor : .white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(MeterTheme.cardBackground)
                    .overlay(RoundedRectangle(cornerRadius: 10)
                        .stroke(selected ? MeterTheme.waveColor.opacity(0.55) : MeterTheme.cardBorder,
                                lineWidth: 1))
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(label) \(String(format: "%+.0f dB", offset))")
        .accessibilityAddTraits(selected ? .isSelected : [])
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
            ), in: 80...140, step: 0.5)
            .tint(MeterTheme.waveColor)
            scaleLabels
        }
    }

    private var scaleLabels: some View {
        HStack {
            Text("80"); Spacer(); Text("110"); Spacer(); Text("140")
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
            row(title: "算法", value: "IEC 61672 A/C 计权 · F/S 检波 · FFT")
            row(title: "精度", value: "计权曲线 < 0.5 dB;绝对值取决于校准")
            row(title: "峰值口径", value: "时间计权最大值,非 Lpeak")
            row(title: "隐私", value: "测量与录音仅保存在本机")
            Link(destination: URL(string: "https://github.com/finger-tap/soundsense")!) {
                HStack {
                    Label("开源项目 · MIT License", systemImage: "chevron.left.forwardslash.chevron.right")
                        .font(.system(size: 13, weight: .medium))
                    Spacer()
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 11, weight: .semibold))
                }
                .foregroundColor(MeterTheme.waveColor)
                .padding(.top, 2)
            }
            Text("计权曲线按 IEC 61672-1 设计,但本应用不是经型式批准的 Class 1/2 声级计。")
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
                    .fill(MeterTheme.panelGradient)
                    .overlay(RoundedRectangle(cornerRadius: 20).stroke(MeterTheme.cardBorder, lineWidth: 1))
            )
    }
}
