//
//  MainMeterView.swift
//  SoundSense iOS
//
//  iOS 主屏:大数字 SPL + dB 标尺 + 声波条 + 频谱图 + 等级徽章 + 起停按钮。
//  固定布局(不滚动):所有信息在任何机型上一屏可见。
//

import SwiftUI
import SoundSenseCore

struct MainMeterView: View {
    @StateObject private var viewModel = MeterViewModel()
    @State private var showingSettings = false
    @State private var showingShare = false
    @State private var showingHistory = false

    var body: some View {
        GeometryReader { geo in
            let vSpace = geo.size.height
            // 读数字号随屏高自适应(SE 667pt ~ 50;Pro Max ~ 66)
            let heroSize: CGFloat = max(46, min(66, vSpace / 12))

            ZStack {
                MeterTheme.backgroundGradient.ignoresSafeArea()

                VStack(spacing: 0) {
                    // —— 顶部栏:标题 + 历史 + 设置 ——
                    HStack {
                        Text("闻声")
                            .font(.system(size: 20, weight: .bold))
                            .foregroundColor(.white)
                        Spacer()
                        Button {
                            showingHistory = true
                        } label: {
                            Image(systemName: "clock.arrow.circlepath")
                                .font(.body)
                                .foregroundColor(.white.opacity(0.8))
                                .frame(width: 38, height: 38)
                        }
                        Button {
                            showingSettings = true
                        } label: {
                            Image(systemName: "gearshape.fill")
                                .font(.body)
                                .foregroundColor(.white.opacity(0.8))
                                .frame(width: 38, height: 38)
                        }
                    }
                    .padding(.horizontal, 18)
                    .padding(.top, 4)

                    // —— 状态提示(固定在顶部,任何机型都可见) ——
                    Group {
                        statusText
                            .padding(.top, 2)

                        Spacer(minLength: 8)
                    }

                    // —— 主读数:大数字 + dB 标尺 ——
                    VStack(spacing: 4) {
                        Text(splText(viewModel.currentSPL))
                            .font(.system(size: heroSize, weight: .heavy, design: .rounded))
                            .foregroundColor(.white)
                            .monospacedDigit()
                            .minimumScaleFactor(0.7)
                            .lineLimit(1)
                        Text("dB(A)")
                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                            .foregroundColor(MeterTheme.secondaryText)
                    }

                    DBRulerGauge(spl: viewModel.currentSPL,
                                 levelColor: viewModel.noiseLevel?.color ?? MeterTheme.waveColor)
                        .padding(.horizontal, 22)
                        .padding(.top, 2)

                    // —— 等级徽章 / 实时统计 / 暴露警告(分组以规避 ViewBuilder 10 子视图上限) ——
                    Group {
                        LevelBadge(level: viewModel.noiseLevel)
                            .padding(.top, 10)

                        // —— 实时统计(测量中显示) ——
                        if let live = viewModel.liveStats {
                            LiveStatsBar(stats: live)
                                .padding(.horizontal, 18)
                                .padding(.top, 10)
                        }

                        // —— 噪声暴露警告 ——
                        if viewModel.exposureWarning {
                            ExposureWarningBanner(threshold: viewModel.warningThreshold)
                                .padding(.horizontal, 18)
                                .padding(.top, 8)
                        }
                    }

                    Spacer(minLength: 8)

                    // —— 声波 / 频谱(各占一行,紧凑高度,小屏也一屏放下) ——
                    VStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 3) {
                            sectionLabel("声波")
                            WaveformView(values: viewModel.history,
                                         color: viewModel.noiseLevel?.color ?? MeterTheme.waveColor)
                                .frame(height: 38)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10).padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 12)
                                .fill(MeterTheme.cardBackground)
                        )

                        VStack(alignment: .leading, spacing: 3) {
                            sectionLabel("频谱")
                            if let result = viewModel.engine.latestResult {
                                SpectrumView(spectrum: result.spectrum,
                                             frequencies: result.frequencies)
                                    .frame(height: 38)
                                    .clipped()
                            } else {
                                Text("等待测量")
                                    .font(.system(size: 11))
                                    .foregroundColor(MeterTheme.secondaryText)
                                    .frame(height: 38)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10).padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 12)
                                .fill(MeterTheme.cardBackground)
                        )
                    }
                    .padding(.horizontal, 18)

                    Spacer(minLength: 8)

                    // —— 底部操作区(固定) ——
                    VStack(spacing: 10) {
                        // 导出报告:仅"停止后"显示,重新测量时隐藏
                        if let stats = viewModel.lastStats,
                           viewModel.engine.state != .running,
                           viewModel.engine.state != .starting {
                            Button {
                                showingShare = true
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: "square.and.arrow.up")
                                        .font(.system(size: 12, weight: .semibold))
                                    Text("导出上次报告")
                                        .font(.system(size: 13, weight: .semibold))
                                }
                                .foregroundColor(.white.opacity(0.9))
                                .padding(.horizontal, 16).padding(.vertical, 9)
                                .background(Capsule().fill(Color.white.opacity(0.12)))
                            }
                            .buttonStyle(.plain)
                            .transition(.opacity)
                        }
                        controlButton
                    }
                    .padding(.horizontal, 40)
                    .padding(.bottom, 12)
                    .animation(.easeInOut(duration: 0.2), value: viewModel.engine.state)
                }
            }
        }
        .sheet(isPresented: $showingSettings) {
            SettingsView(viewModel: viewModel)
        }
        .sheet(isPresented: $showingHistory) {
            HistoryView(store: viewModel.historyStore,
                        deviceName: viewModel.deviceName,
                        calibrationOffset: viewModel.calibrationOffset)
        }
        .sheet(isPresented: $showingShare) {
            if let stats = viewModel.lastStats {
                ReportShareSheet(stats: stats,
                                 deviceName: viewModel.deviceName,
                                 calibrationOffset: viewModel.calibrationOffset)
            }
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
            .font(MeterTheme.sectionLabel(9))
            .tracking(1.2)
            .foregroundColor(MeterTheme.secondaryText)
            .textCase(.uppercase)
    }

    private var statusText: some View {
        Group {
            switch viewModel.engine.state {
            case .stopped:
                Text("点击下方按钮开始测量")
                    .font(.system(size: 12))
                    .foregroundColor(MeterTheme.secondaryText)
            case .starting:
                Text("正在启动麦克风...")
                    .font(.system(size: 12))
                    .foregroundColor(MeterTheme.secondaryText)
            case .running:
                Text("正在测量 · 对着麦克风发声")
                    .font(.system(size: 12))
                    .foregroundColor(MeterTheme.waveColor)
            case .denied:
                Text("麦克风权限被拒绝,请到系统设置开启")
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
                Text(viewModel.engine.state == .running ? "停止" : "开始测量")
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
            .shadow(color: (viewModel.engine.state == .running
                           ? Color.red : MeterTheme.waveColor).opacity(0.4),
                    radius: 10, y: 4)
        }
        .buttonStyle(.plain)
    }

    // MARK: - 工具

    private func splText(_ spl: Float) -> String {
        guard spl.isFinite, spl > -80 else { return "--" }
        return String(format: "%.1f", spl)
    }
}
