//
//  MacMainMeterView.swift
//  SoundSenseMac
//
//  macOS 主窗:左侧大数字 SPL + 圆形仪表;右侧声波 + 频谱。
//  底部"开始检测"按钮 —— 点了才请求麦克风权限,符合你预期。
//

import SwiftUI
import SoundSenseCore

struct MacMainMeterView: View {
    @StateObject private var viewModel = MeterViewModel()
    @State private var showingSettings = false

    var body: some View {
        ZStack {
            MeterTheme.backgroundGradient.ignoresSafeArea()

            VStack(spacing: 0) {
                // 顶部栏
                HStack {
                    Text("闻声")
                        .font(.system(size: 20, weight: .bold))
                        .foregroundColor(.white)
                    Spacer()
                    Button {
                        showingSettings = true
                    } label: {
                        Image(systemName: "gearshape.fill")
                            .foregroundColor(.white.opacity(0.8))
                    }
                    .buttonStyle(.plain)
                    .help("设置")
                }
                .padding(.horizontal, 20)
                .padding(.top, 14)

                // 主内容:左右两栏
                HStack(alignment: .center, spacing: 24) {
                    // 左:仪表 + 大数字
                    VStack(spacing: 8) {
                        ZStack {
                            SPLGaugeView(
                                spl: viewModel.currentSPL,
                                levelColor: viewModel.noiseLevel?.color ?? MeterTheme.waveColor
                            )
                            .frame(width: 220, height: 220)

                            VStack(spacing: 2) {
                                Text(splText(viewModel.currentSPL))
                                    .font(.system(size: 52, weight: .bold, design: .rounded))
                                    .foregroundColor(.white)
                                    .monospacedDigit()
                                Text("dB(A)")
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundColor(MeterTheme.secondaryText)
                            }
                        }

                        LevelBadge(level: viewModel.noiseLevel)
                    }
                    .frame(maxWidth: .infinity)

                    // 右:声波 + 频谱
                    VStack(alignment: .leading, spacing: 18) {
                        VStack(alignment: .leading, spacing: 8) {
                            sectionLabel("声波")
                            WaveformView(values: viewModel.history,
                                         color: viewModel.noiseLevel?.color ?? MeterTheme.waveColor)
                        }

                        VStack(alignment: .leading, spacing: 8) {
                            sectionLabel("频谱")
                            if let result = viewModel.engine.latestResult {
                                SpectrumView(spectrum: result.spectrum,
                                             frequencies: result.frequencies)
                            } else {
                                placeholderBar(height: 100)
                            }
                        }

                        Spacer(minLength: 0)
                    }
                    .frame(maxWidth: .infinity)

                    // 状态提示
                    statusText
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                        .padding(.bottom, 8)
                }
                .padding(.horizontal, 20)
                .padding(.top, 10)
                .padding(.bottom, 16)

                // 底部起停按钮
                controlButton
                    .padding(.bottom, 18)
            }
        }
        .sheet(isPresented: $showingSettings) {
            MacSettingsView(viewModel: viewModel)
        }
        .onChange(of: viewModel.engine.latestResult) { result in
            if let result = result {
                viewModel.consume(result)
            }
        }
    }

    // MARK: - 子组件

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .semibold))
            .foregroundColor(MeterTheme.secondaryText)
            .textCase(.uppercase)
    }

    private func placeholderBar(height: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 12)
            .fill(MeterTheme.cardBackground)
            .frame(height: height)
            .overlay(
                Text("等待测量")
                    .font(.system(size: 13))
                    .foregroundColor(MeterTheme.secondaryText)
            )
    }

    private var statusText: some View {
        Group {
            switch viewModel.engine.state {
            case .stopped:
                Text("点击「开始检测」启动麦克风测量")
                    .font(.system(size: 12))
                    .foregroundColor(MeterTheme.secondaryText)
            case .starting:
                Text("正在启动麦克风(首次需授权)...")
                    .font(.system(size: 12))
                    .foregroundColor(MeterTheme.secondaryText)
            case .running:
                Text("正在测量 · 对着麦克风发声观察数值变化")
                    .font(.system(size: 12))
                    .foregroundColor(MeterTheme.waveColor)
            case .denied:
                Text("麦克风权限被拒绝,请到 系统设置 → 隐私与安全 → 麦克风 开启")
                    .font(.system(size: 12))
                    .foregroundColor(.red.opacity(0.9))
            case .failed(let msg):
                Text("启动失败:\(msg)")
                    .font(.system(size: 12))
                    .foregroundColor(.red.opacity(0.9))
            }
        }
    }

    private var controlButton: some View {
        Button {
            Task {
                if viewModel.engine.state == .running {
                    viewModel.stop()
                } else {
                    await viewModel.start()
                }
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: viewModel.engine.state == .running ? "stop.fill" : "mic.fill")
                    .font(.system(size: 16, weight: .bold))
                Text(viewModel.engine.state == .running ? "停止检测" : "开始检测")
                    .font(.system(size: 16, weight: .semibold))
            }
            .foregroundColor(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(
                Capsule().fill(
                    viewModel.engine.state == .running
                    ? Color.red.opacity(0.8)
                    : MeterTheme.waveColor.opacity(0.9)
                )
            )
            .padding(.horizontal, 100)
            .shadow(color: (viewModel.engine.state == .running
                           ? Color.red : MeterTheme.waveColor).opacity(0.4),
                    radius: 10, y: 3)
        }
        .buttonStyle(.plain)
    }

    private func splText(_ spl: Float) -> String {
        guard spl.isFinite, spl > -80 else { return "--" }
        return String(format: "%.1f", spl)
    }
}
