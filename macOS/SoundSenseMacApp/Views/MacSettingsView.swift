//
//  MacSettingsView.swift
//  SoundSenseMac
//
//  macOS 设置浮层(替代 sheet,瞬间弹出,自定义滚动条)。
//

import SwiftUI
import AppKit
import SoundSenseCore

struct SettingsOverlay: View {
    @ObservedObject var viewModel: MeterViewModel
    @Binding var isPresented: Bool
    @Environment(\.openURL) private var openURL

    var body: some View {
        ZStack {
            // 半透明遮罩(点击关闭)
            Color.black.opacity(0.45)
                .ignoresSafeArea()
                .onTapGesture {
                    isPresented = false
                }

            // 居中卡片
            VStack(spacing: 0) {
                // 标题栏
                HStack {
                    Text("设置").font(.system(size: 16, weight: .bold)).foregroundColor(.white)
                    Spacer()
                    Button {
                        isPresented = false
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(.white.opacity(0.5))
                            .frame(width: 24, height: 24)
                            .background(Circle().fill(.white.opacity(0.1)))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("关闭")
                }
                .padding(.horizontal, 20).padding(.top, 18).padding(.bottom, 14)

                // 内容(隐藏系统滚动条)
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 16) {
                        calibrationCard
                        measurementCard
                        aboutCard
                    }
                    .padding(.horizontal, 20).padding(.bottom, 20)
                }
            }
            .frame(width: 440, height: 540)
            .background(
                RoundedRectangle(cornerRadius: 18)
                    .fill(MeterTheme.panelGradient)
                    .overlay(RoundedRectangle(cornerRadius: 18)
                        .stroke(.white.opacity(0.1), lineWidth: 1))
            )
            .shadow(color: .black.opacity(0.5), radius: 30, y: 10)
        }
        .onAppear {
            viewModel.refreshAudioInputAvailability()
        }
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification
        )) { _ in
            viewModel.refreshAudioInputAvailability()
        }
    }

    // MARK: - 校准卡片

    private var calibrationCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("校准").font(.system(size: 14, weight: .bold)).foregroundColor(.white)

            Text("麦克风采集的是数字分贝(dBFS),加上偏移量换算成真实声压级(SPL)。默认 +100 dB 是 Mac 内建麦克风的保守估计(±6 dB 离散),可用标准声级计对照校准。")
                .font(.system(size: 11.5)).foregroundColor(MeterTheme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Text("偏移量").font(.system(size: 12)).foregroundColor(.white.opacity(0.8))
                Spacer()
                Text(String(format: "%+.1f dB", viewModel.calibrationOffset))
                    .font(.system(size: 18, weight: .semibold, design: .monospaced))
                    .foregroundColor(MeterTheme.waveColor)
            }

            VStack(spacing: 6) {
                Slider(value: Binding(
                    get: { Double(viewModel.calibrationOffset) },
                    set: { viewModel.calibrationOffset = Float($0) }
                ), in: 80...140, step: 0.5)
                .tint(MeterTheme.waveColor)
                HStack {
                    Text("80").font(.system(size: 9)); Spacer()
                    Text("110").font(.system(size: 9)); Spacer()
                    Text("140").font(.system(size: 9))
                }.foregroundColor(MeterTheme.tertiaryText)
            }

            HStack(spacing: 8) {
                presetButton(label: "Mac 内建麦克风", offset: CalibrationDefaults.macBuiltIn)
                presetButton(label: "外接麦克风", offset: CalibrationDefaults.external)
            }

            Button {
                viewModel.calibrationOffset = CalibrationDefaults.macBuiltIn
            } label: {
                Text("恢复默认 (+100)")
                    .font(.system(size: 12, weight: .medium)).foregroundColor(.white)
                    .frame(maxWidth: .infinity).padding(.vertical, 9)
                    .background(RoundedRectangle(cornerRadius: 9).fill(.white.opacity(0.06)))
            }
            .buttonStyle(.plain)

            liveCalibration
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 13)
                .fill(.white.opacity(0.04))
                .overlay(RoundedRectangle(cornerRadius: 13)
                    .stroke(.white.opacity(0.07), lineWidth: 1))
        )
    }

    /// 实时校准:测量运行中显示当前读数,对照参考计微调
    @ViewBuilder
    private var liveCalibration: some View {
        if viewModel.engine.state == .running {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("实时校准").font(.system(size: 12, weight: .semibold)).foregroundColor(.white)
                    Spacer()
                    Text("当前读数").font(.system(size: 10)).foregroundColor(MeterTheme.tertiaryText)
                    Text(String(format: "%.1f dB", viewModel.currentSPL))
                        .font(.system(size: 14, weight: .semibold, design: .monospaced))
                        .foregroundColor(MeterTheme.waveColor)
                }
                HStack(spacing: 6) {
                    adjustButton("-1", -1)
                    adjustButton("-0.5", -0.5)
                    adjustButton("+0.5", 0.5)
                    adjustButton("+1", 1)
                }
                Text("把标准声级计放在 Mac 同一位置(计权一致),微调直到读数一致;有 94 dB/1 kHz 声校准器则调到显示 94。")
                    .font(.system(size: 10)).foregroundColor(MeterTheme.tertiaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 10).fill(.white.opacity(0.05)))
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Text("提示:启动麦克风后,可对照标准声级计在当前页面实时微调偏移量。")
                    .font(.system(size: 10.5)).foregroundColor(MeterTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                if viewModel.engine.state == .denied {
                    Button("打开系统麦克风设置") {
                        openMicrophoneSettings()
                    }
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(MeterTheme.waveColor)
                    .buttonStyle(.plain)
                } else if !viewModel.hasAudioInput {
                    Label("未检测到麦克风，请连接后重试", systemImage: "mic.slash")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundColor(MeterTheme.brass)
                } else if viewModel.engine.state == .starting {
                    HStack(spacing: 7) {
                        ProgressView().controlSize(.small)
                        Text("正在启动麦克风...")
                            .font(.system(size: 10.5))
                            .foregroundColor(MeterTheme.secondaryText)
                    }
                } else {
                    Button {
                        Task { await viewModel.start() }
                    } label: {
                        Label("启动麦克风开始校准", systemImage: "mic.fill")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .background(RoundedRectangle(cornerRadius: 8)
                                .fill(MeterTheme.primaryActionGradient))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func adjustButton(_ label: String, _ delta: Float) -> some View {
        Button {
            viewModel.calibrationOffset += delta
        } label: {
            Text(label)
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .foregroundColor(.white)
                .frame(maxWidth: .infinity).padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 8).fill(.white.opacity(0.08)))
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
                            .font(.system(size: 10, weight: .semibold))
                    }
                    Text(label).font(.system(size: 12, weight: .medium))
                }
                Text(String(format: "+%.0f dB", offset))
                    .font(.system(size: 10, design: .monospaced))
                    .opacity(0.7)
            }
            .foregroundColor(selected ? MeterTheme.waveColor : .white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 9)
                    .fill(.white.opacity(0.06))
                    .overlay(RoundedRectangle(cornerRadius: 9)
                        .stroke(selected ? MeterTheme.waveColor.opacity(0.55)
                                         : Color.white.opacity(0.07),
                                lineWidth: 1))
            )
        }
        .buttonStyle(.plain)
        .help("\(label)：\(String(format: "+%.0f dB", offset))")
    }

    // MARK: - 测量卡片(计权 / 警告阈值 / 预设)

    private var measurementCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("测量").font(.system(size: 14, weight: .bold)).foregroundColor(.white)

            // 频率计权
            HStack {
                Text("频率计权").font(.system(size: 12)).foregroundColor(.white.opacity(0.8))
                Spacer()
                Picker("", selection: Binding(
                    get: { viewModel.weighting },
                    set: { viewModel.weighting = $0 }
                )) {
                    Text("A(环境噪音)").tag(Weighting.a)
                    Text("C(低频噪音)").tag(Weighting.c)
                }
                .pickerStyle(.segmented)
                .frame(width: 220)
            }
            Text("A 计权模拟人耳感受,适合日常噪音;C 计权保留低频能量,适合音响、空调、机械等低频噪音。")
                .font(.system(size: 10.5)).foregroundColor(MeterTheme.tertiaryText)
                .fixedSize(horizontal: false, vertical: true)

            Divider().overlay(MeterTheme.hairline)

            // 警告阈值
            HStack {
                Text("警告阈值").font(.system(size: 12)).foregroundColor(.white.opacity(0.8))
                Spacer()
                Text(String(format: "%.0f dB", viewModel.warningThreshold))
                    .font(.system(size: 16, weight: .semibold, design: .monospaced))
                    .foregroundColor(MeterTheme.waveColor)
            }
            Slider(value: Binding(
                get: { Double(viewModel.warningThreshold) },
                set: { viewModel.warningThreshold = Float($0) }
            ), in: 40...120, step: 1)
            .tint(MeterTheme.waveColor)
            Text("连续超过该值 30 秒后提醒。85 dB 是长期暴露的听力安全上限;测卧室可调到 45~50。")
                .font(.system(size: 10.5)).foregroundColor(MeterTheme.tertiaryText)
                .fixedSize(horizontal: false, vertical: true)

            Toggle(isOn: Binding(
                get: { viewModel.systemNotificationsEnabled },
                set: { newValue in
                    viewModel.systemNotificationsEnabled = newValue
                    if newValue { NoiseAlertNotifier.requestAuthorization() }
                }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("超限时发系统通知")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.white.opacity(0.85))
                    Text("关闭时仅 App 内横幅提醒(默认)。开启后会在第一次测量时请求通知权限。")
                        .font(.system(size: 10))
                        .foregroundColor(MeterTheme.tertiaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .toggleStyle(.switch)
            .tint(MeterTheme.waveColor)
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 13)
                .fill(.white.opacity(0.04))
                .overlay(RoundedRectangle(cornerRadius: 13)
                    .stroke(.white.opacity(0.07), lineWidth: 1))
        )
    }

    // MARK: - 关于卡片

    private var aboutCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("关于").font(.system(size: 14, weight: .bold)).foregroundColor(.white)
            row(title: "版本", value: appVersionString())
            row(title: "算法", value: "IEC 61672 A/C 计权 · F/S 检波 · FFT")
            row(title: "精度", value: "计权曲线 < 0.5 dB;绝对值取决于校准")
            row(title: "隐私", value: "测量与录音仅保存在本机")
            Divider().background(.white.opacity(0.1))
            Link(destination: URL(string: "https://github.com/finger-tap/soundsense")!) {
                HStack {
                    Label("开源项目 · MIT License",
                          systemImage: "chevron.left.forwardslash.chevron.right")
                        .font(.system(size: 11))
                    Spacer()
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 9, weight: .semibold))
                }
                .foregroundColor(MeterTheme.waveColor)
            }
            Text("核心算法基于 Accelerate/vDSP,符合 IEC 61672-1 国际标准。")
                .font(.system(size: 10.5)).foregroundColor(MeterTheme.tertiaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 13)
                .fill(.white.opacity(0.04))
                .overlay(RoundedRectangle(cornerRadius: 13)
                    .stroke(.white.opacity(0.07), lineWidth: 1))
        )
    }

    private func row(title: String, value: String) -> some View {
        HStack {
            Text(title).font(.system(size: 12)).foregroundColor(MeterTheme.tertiaryText)
            Spacer()
            Text(value).font(.system(size: 12)).foregroundColor(.white.opacity(0.85))
        }
    }

    private func appVersionString() -> String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "\(v) (\(b))"
    }

    private func openMicrophoneSettings() {
        guard let url = URL(string:
                "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") else {
            return
        }
        openURL(url)
    }
}
