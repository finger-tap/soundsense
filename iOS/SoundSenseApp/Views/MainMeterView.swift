//
//  MainMeterView.swift
//  SoundSense iOS
//
//  iOS 主屏:大数字 SPL + dB 标尺 + 声波条 + 频谱图 + 等级徽章 + 起停按钮。
//  固定布局(不滚动):所有信息在任何机型上一屏可见。
//

import SwiftUI
import Photos
import SoundSenseCore

struct MainMeterView: View {
    @StateObject private var viewModel = MeterViewModel()
    @State private var showingSettings = false
    @State private var showingShare = false
    @State private var showingHistory = false
    @State private var showingSourceTest = false
    /// 保存结果浮层文案(自动消失)
    @State private var toast: String?
    @State private var toastTask: Task<Void, Never>?

    var body: some View {
        GeometryReader { geo in
            // —— 百分比布局:所有关键尺寸随屏幕等比缩放,夹上下限防极端 ——
            let H = geo.size.height
            let W = geo.size.width
            let clamp = { (v: CGFloat, lo: CGFloat, hi: CGFloat) in
                max(lo, min(hi, v))
            }
            // 主读数字号:屏高 10.5%(SE≈60 / 14ProMax≈88)
            let heroSize = clamp(H * 0.105, 48, 88)
            // 横向边距:屏宽 4.5%(390pt 屏 ≈ 18)
            let marginX = clamp(W * 0.045, 14, 24)
            // 卡片高度:屏高 8.8%(SE≈52 / ProMax≈74)
            let cardH = clamp(H * 0.088, 44, 66)

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
                            // 声源定位与测量互斥:进入前先停掉主测量
                            if viewModel.engine.state == .running {
                                viewModel.stop()
                            }
                            showingSourceTest = true
                        } label: {
                            Image(systemName: "location")
                                .font(.body)
                                .foregroundColor(.white.opacity(0.8))
                                .frame(width: 38, height: 38)
                        }
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
                    .padding(.horizontal, marginX)
                    .padding(.top, 4)

                    // —— 状态提示(固定在顶部,任何机型都可见) ——
                    Group {
                        statusText
                            .padding(.top, 2)

                        Spacer(minLength: 8)
                    }

                    // —— 主读数:大数字 + dB 标尺 ——
                    VStack(spacing: 2) {
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
                        .padding(.horizontal, marginX + 4)
                        .padding(.top, 8)

                    // —— 等级徽章 / 实时统计 / 暴露警告(分组以规避 ViewBuilder 10 子视图上限) ——
                    Group {
                        LevelBadge(level: viewModel.noiseLevel)
                            .padding(.top, 12)

                        // —— 实时统计(测量中显示) ——
                        if let live = viewModel.liveStats {
                            LiveStatsBar(stats: live, isRecording: viewModel.isRecording)
                                .padding(.horizontal, marginX)
                                .padding(.top, 10)
                        }

                        // —— 噪声暴露警告 ——
                        if viewModel.exposureWarning {
                            ExposureWarningBanner(threshold: viewModel.warningThreshold)
                                .padding(.horizontal, marginX)
                                .padding(.top, 8)
                        }
                    }

                    Spacer(minLength: 8)

                    // —— 声波 / 频谱(各占一行,紧凑高度,小屏也一屏放下) ——
                    VStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 4) {
                            sectionLabel("声波")
                            WaveformView(values: viewModel.history,
                                         color: viewModel.noiseLevel?.color ?? MeterTheme.waveColor)
                                .frame(height: cardH)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10).padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 12)
                                .fill(MeterTheme.cardBackground)
                        )

                        VStack(alignment: .leading, spacing: 4) {
                            sectionLabel("频谱")
                            if let result = viewModel.engine.latestResult {
                                SpectrumView(spectrum: result.spectrum,
                                             frequencies: result.frequencies)
                                    .frame(height: cardH)
                                    .clipped()
                            } else {
                                Text("等待测量")
                                    .font(.system(size: 11))
                                    .foregroundColor(MeterTheme.secondaryText)
                                    .frame(height: cardH)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10).padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 12)
                                .fill(MeterTheme.cardBackground)
                        )
                    }
                    .padding(.horizontal, marginX)

                    Spacer(minLength: 6)

                    // —— 底部操作区(固定) ——
                    VStack(spacing: 10) {
                        // 导出报告:仅"停止后"显示;直接弹分享面板
                        // (面板第二排内置自定义"保存到相册"选项)
                        if viewModel.lastStats != nil,
                           viewModel.engine.state != .running,
                           viewModel.engine.state != .starting {
                            Button {
                                showingShare = true
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: "square.and.arrow.up")
                                        .font(.system(size: 12, weight: .semibold))
                                    Text("导出报告")
                                        .font(.system(size: 13, weight: .semibold))
                                }
                                .foregroundColor(.white.opacity(0.9))
                                .padding(.horizontal, 16).padding(.vertical, 8)
                                .background(Capsule().fill(Color.white.opacity(0.12)))
                            }
                            .buttonStyle(.plain)
                            .transition(.opacity)
                        }
                        controlButton
                    }
                    .padding(.horizontal, marginX * 2.2)
                    .padding(.bottom, 10)
                    .animation(.easeInOut(duration: 0.2), value: viewModel.engine.state)
                }

                // —— 保存结果浮层 ——
                if let message = toast {
                    VStack {
                        Spacer()
                        Text(message)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(.white)
                            .padding(.horizontal, 16).padding(.vertical, 10)
                            .background(Capsule().fill(Color.black.opacity(0.75)))
                            .padding(.bottom, 96)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                    .allowsHitTesting(false)
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
        .sheet(isPresented: $showingSourceTest) {
            SourceTestFlowView(calibrationOffset: viewModel.calibrationOffset)
        }
        .sheet(isPresented: $showingShare) {
            if let stats = viewModel.lastStats {
                ReportShareSheet(stats: stats,
                                 deviceName: viewModel.deviceName,
                                 calibrationOffset: viewModel.calibrationOffset)
            }
        }
        // 监听"保存到相册"活动的结果,弹浮层反馈
        .onReceive(NotificationCenter.default
            .publisher(for: Notification.Name("reportSaveToPhotosResult"))) { note in
            if let message = note.userInfo?["message"] as? String {
                showToast(message)
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
            .font(MeterTheme.sectionLabel(10))
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
                    .font(.system(size: 15, weight: .bold))
                Text(viewModel.engine.state == .running ? "停止" : "开始测量")
                    .font(.system(size: 15, weight: .semibold))
            }
            .foregroundColor(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 13)
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

    /// 浮层提示,2 秒后自动消失
    private func showToast(_ message: String) {
        withAnimation { toast = message }
        toastTask?.cancel()
        toastTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }
            withAnimation { toast = nil }
        }
    }

    // MARK: - 工具

    private func splText(_ spl: Float) -> String {
        guard spl.isFinite, spl > -80 else { return "--" }
        return String(format: "%.1f", spl)
    }
}
