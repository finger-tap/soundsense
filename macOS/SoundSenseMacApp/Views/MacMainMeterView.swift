//
//  MacMainMeterView.swift
//  SoundSenseMac
//
//  macOS 主窗(精致版):
//    - 中央:环形仪表 + 超大分贝数字(视觉焦点,等级色联动)
//    - 等级色带贯穿全屏
//    - 声波 + 频谱 + 趋势图(毛玻璃卡片)
//    - 点"开始检测"才请求麦克风
//

import SwiftUI
import AppKit
import SoundSenseCore

struct MacMainMeterView: View {
    @ObservedObject var viewModel: MeterViewModel
    @Environment(\.openURL) private var openURL
    @State private var showingSettings = false
    @State private var showingHistory = false

    /// 当前等级色(贯穿数字、仪表、按钮)
    private var levelColor: Color {
        viewModel.noiseLevel?.color ?? MeterTheme.waveColor
    }

    var body: some View {
        ZStack {
            // 内容:顶部固定 + 中间可滚动 + 底部固定(按钮永远可见)
            VStack(spacing: 0) {
                // 顶部标题栏(固定,不滚动)+ 可拖动区域
                headerBar
                    .frame(maxWidth: 840)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 28).padding(.top, 18).padding(.bottom, 8)

                // 中间内容(窗口太小时可滚动)
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 18) {
                        // 中央视觉焦点
                        centerMeter

                        // 等级文字
                        levelLabel

                        // 实时统计(测量中显示)
                        if let live = viewModel.liveStats {
                            LiveStatsBar(stats: live, isRecording: viewModel.isRecording)
                                .padding(.horizontal, 28)
                                .transition(.opacity)
                        }

                        // 噪声暴露警告
                        if viewModel.exposureWarning {
                            ExposureWarningBanner()
                                .padding(.horizontal, 28)
                                .transition(.opacity)
                        }

                        // 三卡片:声波 / 频谱 / 趋势
                        VStack(spacing: 12) {
                            HStack(spacing: 12) {
                                Card(title: "声波") {
                                    WaveformView(values: viewModel.history, color: levelColor)
                                        .frame(height: 56)
                                }
                                Card(title: "频谱") {
                                    if let r = viewModel.engine.latestResult {
                                        SpectrumView(spectrum: r.spectrum, frequencies: r.frequencies)
                                            .frame(height: 56)
                                            .clipped()
                                    } else { EmptyHint().frame(height: 56) }
                                }
                            }
                            Card(title: "历史趋势") {
                                TrendChart(values: viewModel.history, color: levelColor)
                                    .frame(height: 70)
                                    .clipped()
                            }
                        }
                        .padding(.horizontal, 28)

                        // 状态提示(放滚动区内,按钮下方)
                        statusLine.padding(.horizontal, 28).padding(.top, 2)
                    }
                    .padding(.top, 6)
                    .padding(.bottom, 16)
                    .frame(maxWidth: 820)
                    .frame(maxWidth: .infinity)
                }

                // 底部按钮(固定,永远可见,不随滚动消失)
                HStack(spacing: 12) {
                    controlButton
                    // 停止后,如果有统计数据,显示"导出报告"按钮
                    if let stats = viewModel.lastStats {
                        exportReportButton(stats: stats)
                    }
                }
                .frame(maxWidth: 620)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 28).padding(.bottom, 22).padding(.top, 6)
            }

            // 设置 / 历史浮层(ZStack 覆盖,瞬间弹出,不用慢吞吞的 sheet)
            if showingSettings {
                SettingsOverlay(viewModel: viewModel,
                                isPresented: $showingSettings)
            }
            if showingHistory {
                HistoryOverlay(store: viewModel.historyStore,
                               deviceName: viewModel.deviceName,
                               calibrationOffset: viewModel.calibrationOffset,
                               isPresented: $showingHistory)
            }
        }
        // 整个 ZStack 撑满窗口(背景色覆盖到窗口边缘,无白边)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea()
        .background(BackgroundView(accent: levelColor))
        .onChange(of: viewModel.engine.latestResult) { r in
            if let r = r { viewModel.consume(r) }
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

    // MARK: - 子组件

    private var headerBar: some View {
        HStack {
            HStack(spacing: 10) {
                Text("闻声").font(.system(size: 16, weight: .semibold)).foregroundColor(.white)
                Text("SOUNDSENSE").font(.system(size: 10, weight: .medium, design: .monospaced))
                    .tracking(1.2)
                    .foregroundColor(MeterTheme.tertiaryText)
            }
            Spacer()
            Button {
                showingHistory = true
            } label: {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 15)).foregroundColor(MeterTheme.secondaryText)
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(.white.opacity(showingHistory ? 0.12 : 0)))
                    .accessibilityLabel("测量历史")
            }
            .buttonStyle(.plain)
            .keyboardShortcut("h", modifiers: .command)
            .help("测量历史 (⌘H)")
            Button { showingSettings = true } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 15)).foregroundColor(MeterTheme.secondaryText)
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(.white.opacity(showingSettings ? 0.12 : 0)))
                    .accessibilityLabel("设置")
            }
            .buttonStyle(.plain)
            .keyboardShortcut(",", modifiers: .command)
            .help("设置 (⌘,)")
        }
    }

    /// 中央主读数:大数字 + dB 标尺(仪器面板式)
    private var centerMeter: some View {
        VStack(spacing: 10) {
            Text(splText(viewModel.currentSPL))
                .font(.system(size: 84, weight: .heavy, design: .rounded))
                .foregroundColor(MeterTheme.primaryText).monospacedDigit()
                .accessibilityLabel("当前声压级")
                .accessibilityValue(viewModel.currentSPL.isFinite && viewModel.currentSPL > -80
                                    ? String(format: "%.1f %@", viewModel.currentSPL, weightingUnit)
                                    : "无信号")
            Text(weightingUnit)
                .font(.system(size: 13, weight: .medium, design: .monospaced))
                .foregroundColor(MeterTheme.secondaryText)
            DBRulerGauge(spl: viewModel.currentSPL, levelColor: levelColor)
                .frame(maxWidth: 480)
                .padding(.top, 6)
        }
    }

    private var levelLabel: some View {
        Group {
            if let lv = viewModel.noiseLevel {
                HStack(spacing: 8) {
                    Text(lv.emoji).font(.system(size: 15))
                    Text(lv.label).font(.system(size: 15, weight: .semibold)).foregroundColor(lv.color)
                    Text("·").foregroundColor(.white.opacity(0.3))
                    Text(lv.detail).font(.system(size: 12)).foregroundColor(MeterTheme.secondaryText)
                }
            } else {
                Text("待机中").font(.system(size: 13)).foregroundColor(MeterTheme.secondaryText)
            }
        }
    }

    private var statusLine: some View {
        HStack(spacing: 6) {
            statusDot
            Text(statusMessage).font(.system(size: 11.5)).foregroundColor(MeterTheme.secondaryText)
            if viewModel.engine.state == .denied {
                Button("打开麦克风设置") {
                    openMicrophoneSettings()
                }
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundColor(MeterTheme.waveColor)
                .buttonStyle(.plain)
            } else if !viewModel.hasAudioInput {
                Button("检查系统输入设备") {
                    openSoundSettings()
                }
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundColor(MeterTheme.waveColor)
                .buttonStyle(.plain)
            }
            Spacer()
        }
    }

    private var statusDot: some View {
        let pulse = viewModel.engine.state == .running
        let dotColor: Color = {
            if !viewModel.hasAudioInput { return MeterTheme.brass }
            switch viewModel.engine.state {
            case .running: return levelColor
            case .failed(_), .denied: return MeterTheme.riskColor
            default: return Color.white.opacity(0.35)
            }
        }()
        return Circle()
            .fill(dotColor)
            .frame(width: 7, height: 7)
            .shadow(color: pulse ? levelColor.opacity(0.7) : .clear, radius: pulse ? 5 : 0)
            .scaleEffect(pulse ? 1.0 : 0.85)
            .animation(pulse ? .easeInOut(duration: 0.8).repeatForever(autoreverses: true) : .default, value: viewModel.engine.state)
    }

    private var statusMessage: String {
        guard viewModel.hasAudioInput else {
            return AudioMeterEngine.noInputDeviceMessage
        }
        switch viewModel.engine.state {
        case .stopped: return "点击下方按钮开始测量环境噪音"
        case .starting: return "正在启动麦克风..."
        case .running: return "正在测量 · 对着麦克风发声观察数值"
        case .denied: return "麦克风被拒 → 系统设置 → 隐私与安全 → 麦克风"
        case .failed(let m): return "启动失败:\(m)"
        }
    }

    private var controlButton: some View {
        let running = viewModel.engine.state == .running
        let starting = viewModel.engine.state == .starting
        return Button {
            Task {
                if running {
                    viewModel.stop()
                } else {
                    await viewModel.start()
                }
            }
        } label: {
            HStack(spacing: 8) {
                if starting {
                    ProgressView().controlSize(.small).tint(.white)
                } else {
                    Image(systemName: running ? "stop.fill" : "mic.fill")
                        .font(.system(size: 13, weight: .bold))
                }
                Text(starting ? "正在启动..." : (running ? "停止检测" : "开始检测"))
                    .font(.system(size: 14, weight: .semibold))
            }
            .foregroundColor(.white)
            .frame(maxWidth: .infinity).padding(.vertical, 12)
            .background(
                Capsule().fill(running ? MeterTheme.dangerActionGradient
                                       : MeterTheme.primaryActionGradient)
            )
            .shadow(color: (running ? MeterTheme.riskColor : MeterTheme.waveColor).opacity(0.28),
                    radius: 10, y: 4)
        }
        .buttonStyle(.plain)
        .disabled(starting || showingSettings || showingHistory || !viewModel.hasAudioInput)
        .opacity((starting || showingSettings || showingHistory || !viewModel.hasAudioInput) ? 0.62 : 1)
        .keyboardShortcut(.space, modifiers: [])
        .help(running ? "停止检测 (空格)" : "开始检测 (空格)")
    }

    /// 导出报告按钮(停止检测后出现)
    private func exportReportButton(stats: MeasurementStats) -> some View {
        Button {
            ReportExporter.export(stats: stats,
                                   deviceName: viewModel.deviceName,
                                   calibrationOffset: viewModel.calibrationOffset)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "square.and.arrow.up")
                    .font(.system(size: 12, weight: .semibold))
                Text("导出报告")
                    .font(.system(size: 13, weight: .semibold))
            }
            .foregroundColor(.white)
            .frame(maxWidth: .infinity).padding(.vertical, 12)
            .background(
                Capsule()
                    .fill(Color.white.opacity(0.075))
                    .overlay(Capsule().stroke(MeterTheme.hairline, lineWidth: 1))
            )
        }
        .buttonStyle(.plain)
        .transition(.opacity)
    }

    private func splText(_ spl: Float) -> String {
        guard spl.isFinite, spl > -80 else { return "--" }
        return String(format: "%.1f", spl)
    }

    private var weightingUnit: String {
        viewModel.weighting == .c ? "dB(C)" : "dB(A)"
    }

    private func openMicrophoneSettings() {
        guard let url = URL(string:
                "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") else {
            return
        }
        openURL(url)
    }

    private func openSoundSettings() {
        guard let url = URL(string:
                "x-apple.systempreferences:com.apple.Sound-Settings.extension") else {
            return
        }
        openURL(url)
    }
}

// MARK: - 背景(石墨底 + 随等级色的极淡光晕)

private struct BackgroundView: View {
    let accent: Color
    var body: some View {
        ZStack {
            MeterTheme.backgroundGradient
            // 极淡的等级色氛围光(克制,不抢读数)
            RadialGradient(
                colors: [accent.opacity(0.11), .clear],
                center: UnitPoint(x: 0.5, y: 0.12), startRadius: 20, endRadius: 680
            )
        }
        .ignoresSafeArea()
        .animation(.easeInOut(duration: 0.6), value: accent)
    }
}

// MARK: - 卡片(石墨面板 + 发丝线)

private struct Card<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(MeterTheme.sectionLabel(10))
                .tracking(1.5)
                .foregroundColor(.white.opacity(0.42)).textCase(.uppercase)
                .padding(.bottom, 2)
            content
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(MeterTheme.panelGradient)
                .overlay(RoundedRectangle(cornerRadius: 14)
                    .stroke(MeterTheme.hairline, lineWidth: 1))
        )
    }
}

private struct EmptyHint: View {
    var body: some View {
        Text("等待数据").font(.system(size: 11)).foregroundColor(MeterTheme.tertiaryText)
            .frame(maxWidth: .infinity).frame(height: 56)
    }
}

// MARK: - 历史趋势折线图

struct TrendChart: View {
    let values: [Float]
    var color: Color = .cyan
    // SPL 量程(校准后的声压级)
    private let minDB: Float = 30
    private let maxDB: Float = 100

    var body: some View {
        Canvas { ctx, size in
            // 参考线(40/60/80 dB SPL)
            for db in [40, 60, 80] {
                let y = CGFloat(1 - (Float(db) - minDB) / (maxDB - minDB)) * size.height
                var l = Path(); l.move(to: CGPoint(x: 0, y: y)); l.addLine(to: CGPoint(x: size.width, y: y))
                ctx.stroke(l, with: .color(.white.opacity(0.05)), style: StrokeStyle(lineWidth: 1, dash: [2, 4]))
            }
            guard values.count >= 2 else {
                ctx.draw(Text("等待数据").font(.system(size: 10)).foregroundColor(MeterTheme.tertiaryText),
                         at: CGPoint(x: size.width/2, y: size.height/2))
                return
            }
            var path = Path()
            let n = values.count
            for (i, v) in values.enumerated() {
                let x = CGFloat(i)/CGFloat(n-1) * size.width
                let c = max(minDB, min(maxDB, v))
                let y = CGFloat(1 - (c - minDB)/(maxDB - minDB)) * size.height
                if i == 0 { path.move(to: CGPoint(x: x, y: y)) } else { path.addLine(to: CGPoint(x: x, y: y)) }
            }
            ctx.stroke(path, with: .color(color), lineWidth: 2)

            var fill = path
            fill.addLine(to: CGPoint(x: size.width, y: size.height))
            fill.addLine(to: CGPoint(x: 0, y: size.height))
            fill.closeSubpath()
            ctx.fill(fill, with: .linearGradient(
                Gradient(colors: [color.opacity(0.3), color.opacity(0)]),
                startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
        }
    }
}
