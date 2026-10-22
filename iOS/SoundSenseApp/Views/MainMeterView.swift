//
//  MainMeterView.swift
//  SoundSense iOS
//
//  iOS 主屏:大数字 SPL + dB 标尺 + 声波条 + 频谱图 + 等级徽章 + 起停按钮。
//  固定布局(不滚动):所有信息在任何机型上一屏可见。
//

import SwiftUI
import UIKit
import Photos
import SoundSenseCore

struct MainMeterView: View {
    @StateObject private var viewModel = MeterViewModel()
    @Environment(\.openURL) private var openURL
    // UI 自动化用:启动参数直接打开浮层(DEBUG 限定,Release 无影响)
    #if DEBUG
    @State private var showingSettings = ProcessInfo.processInfo.arguments.contains("UITEST_OPEN_SETTINGS")
    @State private var showingHistory = ProcessInfo.processInfo.arguments.contains("UITEST_OPEN_HISTORY")
    @State private var showingSourceTest = ProcessInfo.processInfo.arguments.contains("UITEST_OPEN_SOURCETEST")
    #else
    @State private var showingSettings = false
    @State private var showingHistory = false
    @State private var showingSourceTest = false
    #endif
    @State private var showingShare = false
    @State private var showingMonitor = false
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
                RadialGradient(
                    colors: [(viewModel.noiseLevel?.color ?? MeterTheme.waveColor).opacity(0.12), .clear],
                    center: .top,
                    startRadius: 12,
                    endRadius: max(W, H) * 0.72
                )
                .ignoresSafeArea()
                .animation(.easeInOut(duration: 0.5),
                           value: viewModel.noiseLevel?.tier)

                VStack(spacing: 0) {
                    // —— 顶部栏:品牌 + 工具菜单 + 历史 + 设置 ——
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("闻声")
                                .font(.system(size: 20, weight: .bold))
                                .foregroundColor(MeterTheme.primaryText)
                            Text(headerSubtitle)
                                .font(.system(size: 10, weight: .medium, design: .monospaced))
                                .foregroundColor(MeterTheme.tertiaryText)
                        }
                        Spacer()
                        Menu {
                            Button {
                                Task {
                                    await stopMeasurementIfNeeded()
                                    showingMonitor = true
                                }
                            } label: {
                                Label("长时间监听", systemImage: "moon.zzz")
                            }
                            Button {
                                Task {
                                    await stopMeasurementIfNeeded()
                                    showingSourceTest = true
                                }
                            } label: {
                                Label("方向倾向", systemImage: "dot.radiowaves.left.and.right")
                            }
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: "wrench.and.screwdriver")
                                    .font(.system(size: 13, weight: .bold))
                                Text("分析工具")
                                    .font(.system(size: 12, weight: .bold))
                            }
                            .foregroundColor(MeterTheme.waveColor)
                            .padding(.horizontal, 10)
                            .frame(height: 38)
                            .background(
                                Capsule()
                                    .fill(MeterTheme.waveColor.opacity(0.12))
                                    .overlay(Capsule().stroke(
                                        MeterTheme.waveColor.opacity(0.52),
                                        lineWidth: 1.2))
                            )
                        }
                        .accessibilityLabel("测量工具")
                        .accessibilityHint("包含长时间监听和声源方向倾向测试")

                        headerIconButton("clock.arrow.circlepath", label: "测量历史") {
                            showingHistory = true
                        }
                        headerIconButton("gearshape.fill", label: "设置") {
                            showingSettings = true
                        }
                    }
                    .padding(.horizontal, marginX)
                    .padding(.top, 4)

                    // —— 状态提示(固定在顶部,任何机型都可见) ——
                    Group {
                        statusLine
                            .padding(.top, 2)

                        Spacer(minLength: 8)
                    }

                    // —— 主读数:大数字 + dB 标尺 ——
                    VStack(spacing: 2) {
                        Text(splText(viewModel.currentSPL))
                            .font(.system(size: heroSize, weight: .heavy, design: .rounded))
                            .foregroundColor(MeterTheme.primaryText)
                            .monospacedDigit()
                            .minimumScaleFactor(0.7)
                            .lineLimit(1)
                            .accessibilityLabel("当前声压级")
                            .accessibilityValue(viewModel.currentSPL.isFinite && viewModel.currentSPL > -80
                                                ? String(format: "%.1f %@", viewModel.currentSPL, weightingUnit)
                                                : "无信号")
                        Text(weightingUnit)
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
                            LiveStatsBar(stats: live,
                                         weighting: viewModel.weighting,
                                         timeWeighting: viewModel.engine.timeWeighting,
                                         isRecording: viewModel.isRecording)
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
                            sectionHeader("waveform.path.ecg", title: "声波趋势")
                            WaveformView(values: viewModel.history,
                                         color: viewModel.noiseLevel?.color ?? MeterTheme.waveColor)
                                .frame(height: cardH)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10).padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 12)
                                .fill(MeterTheme.panelGradient)
                                .overlay(RoundedRectangle(cornerRadius: 12)
                                    .stroke(MeterTheme.cardBorder, lineWidth: 1))
                        )

                        VStack(alignment: .leading, spacing: 4) {
                            sectionHeader("chart.bar.xaxis", title: "频谱分布")
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
                                .fill(MeterTheme.panelGradient)
                                .overlay(RoundedRectangle(cornerRadius: 12)
                                    .stroke(MeterTheme.cardBorder, lineWidth: 1))
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
                                .foregroundColor(MeterTheme.primaryText)
                                .padding(.horizontal, 16).padding(.vertical, 8)
                                .background(Capsule().fill(MeterTheme.surfaceStrongFill))
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
        .sheet(isPresented: $showingMonitor) {
            MonitorView()
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

    private func sectionHeader(_ icon: String, title: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: 9, weight: .semibold))
            sectionLabel(title)
        }
        .foregroundColor(MeterTheme.secondaryText)
    }

    private func headerIconButton(_ systemName: String, label: String,
                                  action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 16, weight: .medium))
                .foregroundColor(MeterTheme.secondaryText)
                .frame(width: 40, height: 40)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private var headerSubtitle: String {
        let weighting = viewModel.weighting == .c ? "C" : "A"
        return "环境噪音 · \(weighting) 计权"
    }

    private var weightingUnit: String {
        viewModel.weighting == .c ? "dB(C)" : "dB(A)"
    }

    private var statusLine: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(statusColor)
                .frame(width: 6, height: 6)
            Text(statusMessage)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(statusColor)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            if viewModel.engine.state == .denied {
                Button("去设置") {
                    openMicrophoneSettings()
                }
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(MeterTheme.waveColor)
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 30)
        .background(Capsule().fill(MeterTheme.surfaceFill))
        .accessibilityElement(children: .contain)
    }

    private var statusMessage: String {
        guard viewModel.hasAudioInput else {
            return "未检测到麦克风，请连接设备后重试"
        }
        switch viewModel.engine.state {
        case .stopped: return "点击下方按钮开始测量"
        case .starting: return "正在启动麦克风..."
        case .running: return "正在测量 · 保持手机稳定"
        case .denied: return "麦克风权限被拒绝"
        case .failed(let message): return "启动失败:\(message)"
        }
    }

    private var statusColor: Color {
        if !viewModel.hasAudioInput { return MeterTheme.brass }
        switch viewModel.engine.state {
        case .running: return MeterTheme.waveColor
        case .denied, .failed(_): return MeterTheme.riskColor
        case .stopped, .starting: return MeterTheme.secondaryText
        }
    }

    private func stopMeasurementIfNeeded() async {
        if viewModel.engine.state == .running {
            await viewModel.stop()
        }
    }

    private func openMicrophoneSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        openURL(url)
    }

    private var controlButton: some View {
        let isRunning = viewModel.engine.state == .running
        let isStarting = viewModel.engine.state == .starting
        return Button {
            Task {
                if isRunning {
                    await viewModel.stop()
                } else {
                    await viewModel.start()
                }
            }
        } label: {
            HStack(spacing: 10) {
                if isStarting {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .tint(.white)
                        .scaleEffect(0.8)
                } else {
                    Image(systemName: isRunning ? "stop.fill" : "mic.fill")
                        .font(.system(size: 15, weight: .bold))
                }
                Text(isStarting ? "正在启动..." : (isRunning ? "停止测量" : "开始测量"))
                    .font(.system(size: 15, weight: .semibold))
            }
            .foregroundColor(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 13)
            .background(
                Capsule().fill(isRunning
                               ? MeterTheme.dangerActionGradient
                               : MeterTheme.primaryActionGradient)
            )
            .shadow(color: (isRunning ? MeterTheme.riskColor : MeterTheme.waveColor).opacity(0.28),
                    radius: 10, y: 4)
        }
        .buttonStyle(.plain)
        .disabled(isStarting)
        .opacity(isStarting ? 0.78 : 1)
        .accessibilityHint(isRunning ? "停止本次测量并保存记录" : "开始采集环境噪音")
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
