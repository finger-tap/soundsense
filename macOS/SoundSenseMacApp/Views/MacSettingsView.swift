//
//  MacSettingsView.swift
//  SoundSenseMac
//
//  macOS 设置浮层(替代 sheet,瞬间弹出,自定义滚动条)。
//

import SwiftUI
import SoundSenseCore

struct SettingsOverlay: View {
    @ObservedObject var viewModel: MeterViewModel
    @Binding var isPresented: Bool

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
            .frame(width: 420, height: 480)
            .background(
                RoundedRectangle(cornerRadius: 18)
                    .fill(MeterTheme.panel)
                    .overlay(RoundedRectangle(cornerRadius: 18)
                        .stroke(.white.opacity(0.1), lineWidth: 1))
            )
            .shadow(color: .black.opacity(0.5), radius: 30, y: 10)
        }
    }

    // MARK: - 校准卡片

    private var calibrationCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("校准").font(.system(size: 14, weight: .bold)).foregroundColor(.white)

            Text("麦克风采集的是数字分贝(dBFS),加上偏移量换算成真实声压级(SPL)。默认 +93 dB 适用多数 Mac 麦克风,可用标准声级计微调。")
                .font(.system(size: 11.5)).foregroundColor(.white.opacity(0.5))
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Text("偏移量").font(.system(size: 12)).foregroundColor(.white.opacity(0.8))
                Spacer()
                Text(String(format: "%+.1f dB", viewModel.calibrationOffset))
                    .font(.system(size: 18, weight: .semibold, design: .monospaced))
                    .foregroundColor(Color(red: 0.24, green: 0.83, blue: 0.69))
            }

            VStack(spacing: 6) {
                Slider(value: Binding(
                    get: { Double(viewModel.calibrationOffset) },
                    set: { viewModel.calibrationOffset = Float($0) }
                ), in: 60...110, step: 0.5)
                .tint(Color(red: 0.24, green: 0.83, blue: 0.69))
                HStack {
                    Text("60").font(.system(size: 9)); Spacer()
                    Text("85").font(.system(size: 9)); Spacer()
                    Text("110").font(.system(size: 9))
                }.foregroundColor(.white.opacity(0.3))
            }

            HStack(spacing: 8) {
                presetButton(label: "Mac 内建麦克风", offset: 93)
                presetButton(label: "外接麦克风", offset: 85)
            }

            Button {
                viewModel.calibrationOffset = 93
            } label: {
                Text("恢复默认 (+93)")
                    .font(.system(size: 12, weight: .medium)).foregroundColor(.white)
                    .frame(maxWidth: .infinity).padding(.vertical, 9)
                    .background(RoundedRectangle(cornerRadius: 9).fill(.white.opacity(0.06)))
            }
            .buttonStyle(.plain)
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 13)
                .fill(.white.opacity(0.04))
                .overlay(RoundedRectangle(cornerRadius: 13)
                    .stroke(.white.opacity(0.07), lineWidth: 1))
        )
    }

    private func presetButton(label: String, offset: Float) -> some View {
        Button {
            viewModel.calibrationOffset = offset
        } label: {
            VStack(spacing: 2) {
                Text(label).font(.system(size: 12, weight: .medium))
                Text(String(format: "+%.0f dB", offset))
                    .font(.system(size: 10, design: .monospaced))
                    .opacity(0.7)
            }
            .foregroundColor(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 9).fill(.white.opacity(0.06)))
        }
        .buttonStyle(.plain)
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
                .font(.system(size: 10.5)).foregroundColor(.white.opacity(0.45))
                .fixedSize(horizontal: false, vertical: true)

            Divider().overlay(MeterTheme.hairline)

            // 警告阈值
            HStack {
                Text("警告阈值").font(.system(size: 12)).foregroundColor(.white.opacity(0.8))
                Spacer()
                Text(String(format: "%.0f dB", viewModel.warningThreshold))
                    .font(.system(size: 16, weight: .semibold, design: .monospaced))
                    .foregroundColor(Color(red: 0.24, green: 0.83, blue: 0.69))
            }
            Slider(value: Binding(
                get: { Double(viewModel.warningThreshold) },
                set: { viewModel.warningThreshold = Float($0) }
            ), in: 40...120, step: 1)
            .tint(Color(red: 0.24, green: 0.83, blue: 0.69))
            Text("连续超过该值 30 秒后提醒。85 dB 是长期暴露的听力安全上限;测卧室可调到 45~50。")
                .font(.system(size: 10.5)).foregroundColor(.white.opacity(0.45))
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
                        .foregroundColor(.white.opacity(0.45))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .toggleStyle(.switch)
            .tint(Color(red: 0.24, green: 0.83, blue: 0.69))
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
            row(title: "算法", value: "IEC 61672 A 计权 · 4096 点 FFT")
            row(title: "精度", value: "1 kHz 参考点 < 0.1 dB")
            Divider().background(.white.opacity(0.1))
            Text("核心算法基于 Accelerate/vDSP,符合 IEC 61672-1 国际标准。")
                .font(.system(size: 10.5)).foregroundColor(.white.opacity(0.4))
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
            Text(title).font(.system(size: 12)).foregroundColor(.white.opacity(0.45))
            Spacer()
            Text(value).font(.system(size: 12)).foregroundColor(.white.opacity(0.85))
        }
    }

    private func appVersionString() -> String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "\(v) (\(b))"
    }
}
