//
//  MainMeterView.swift
//  SoundSense iOS
//
//  iOS 主屏:大数字 SPL + 圆形仪表 + 声波条 + 频谱图 + 等级徽章 + 起停按钮。
//

import SwiftUI
import SoundSenseCore

struct MainMeterView: View {
    @StateObject private var viewModel = MeterViewModel()
    @State private var showingSettings = false
    @State private var showingShare = false

    var body: some View {
        ZStack {
            // 背景
            MeterTheme.backgroundGradient.ignoresSafeArea()

            VStack(spacing: 0) {
                // —— 顶部栏 ——
                HStack {
                    Text("闻声")
                        .font(.system(size: 22, weight: .bold))
                        .foregroundColor(.white)
                    Spacer()
                    Button {
                        showingSettings = true
                    } label: {
                        Image(systemName: "gearshape.fill")
                            .font(.title3)
                            .foregroundColor(.white.opacity(0.8))
                            .frame(width: 40, height: 40)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)

                ScrollView {
                    VStack(spacing: 20) {
                        // —— 仪表盘 + 中央大数字 ——
                        ZStack {
                            SPLGaugeView(
                                spl: viewModel.currentSPL,
                                levelColor: viewModel.noiseLevel?.color ?? MeterTheme.waveColor
                            )
                            .frame(width: 280, height: 280)

                            VStack(spacing: 2) {
                                Text(splText(viewModel.currentSPL))
                                    .font(.system(size: 64, weight: .bold, design: .rounded))
                                    .foregroundColor(.white)
                                    .monospacedDigit()
                                Text("dB(A)")
                                    .font(.system(size: 14, weight: .medium))
                                    .foregroundColor(MeterTheme.secondaryText)
                            }
                        }
                        .padding(.top, 8)

                        // —— 等级徽章 ——
                        LevelBadge(level: viewModel.noiseLevel)

                        // —— 声波条 ——
                        VStack(alignment: .leading, spacing: 8) {
                            sectionLabel("声波")
                            WaveformView(values: viewModel.history,
                                         color: viewModel.noiseLevel?.color ?? MeterTheme.waveColor)
                        }
                        .padding(.horizontal, 20)

                        // —— 频谱图 ——
                        VStack(alignment: .leading, spacing: 8) {
                            sectionLabel("频谱")
                            if let result = viewModel.engine.latestResult {
                                SpectrumView(spectrum: result.spectrum,
                                             frequencies: result.frequencies)
                            } else {
                                placeholderBar(height: 100)
                            }
                        }
                        .padding(.horizontal, 20)

                        // —— 状态提示 ——
                        statusText
                            .padding(.top, 4)
                    }
                    .padding(.bottom, 100)
                }

                Spacer(minLength: 0)
            }

            // —— 底部起停按钮 ——
            VStack(spacing: 10) {
                Spacer()
                // 停止后显示导出报告按钮
                if viewModel.lastStats != nil {
                    Button {
                        showingShare = true
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "square.and.arrow.up")
                                .font(.system(size: 13, weight: .semibold))
                            Text("导出报告")
                                .font(.system(size: 15, weight: .semibold))
                        }
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity).padding(.vertical, 14)
                        .background(Capsule().fill(Color.white.opacity(0.12)))
                        .padding(.horizontal, 40)
                    }
                    .buttonStyle(.plain)
                }
                controlButton
                    .padding(.bottom, 30)
            }
        }
        .sheet(isPresented: $showingSettings) {
            SettingsView(viewModel: viewModel)
        }
        .sheet(isPresented: $showingShare) {
            if let stats = viewModel.lastStats {
                ReportShareSheet(stats: stats,
                                 deviceName: viewModel.deviceName,
                                 calibrationOffset: viewModel.calibrationOffset)
            }
        }
        // 监听引擎状态变化:状态机变化时处理
        .onChange(of: viewModel.engine.state) { newState in
            // 可在此扩展:例如 denied 时弹设置引导。首版仅记录。
            _ = newState
        }
        // 监听最新一帧结果
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
                Text("点击下方按钮开始测量")
                    .font(.system(size: 13))
                    .foregroundColor(MeterTheme.secondaryText)
            case .starting:
                Text("正在启动麦克风...")
                    .font(.system(size: 13))
                    .foregroundColor(MeterTheme.secondaryText)
            case .running:
                Text("正在测量 · 对着麦克风发声")
                    .font(.system(size: 13))
                    .foregroundColor(MeterTheme.waveColor)
            case .denied:
                Text("麦克风权限被拒绝,请到系统设置开启")
                    .font(.system(size: 13))
                    .foregroundColor(.red.opacity(0.9))
            case .failed(let msg):
                Text("启动失败:\(msg)")
                    .font(.system(size: 13))
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
                    .font(.system(size: 18, weight: .bold))
                Text(viewModel.engine.state == .running ? "停止" : "开始测量")
                    .font(.system(size: 17, weight: .semibold))
            }
            .foregroundColor(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(
                Capsule().fill(
                    viewModel.engine.state == .running
                    ? Color.red.opacity(0.8)
                    : MeterTheme.waveColor.opacity(0.9)
                )
            )
            .padding(.horizontal, 40)
            .shadow(color: (viewModel.engine.state == .running
                           ? Color.red : MeterTheme.waveColor).opacity(0.4),
                    radius: 12, y: 4)
        }
    }

    // MARK: - 工具

    private func splText(_ spl: Float) -> String {
        guard spl.isFinite, spl > -80 else { return "--" }
        return String(format: "%.1f", spl)
    }
}
