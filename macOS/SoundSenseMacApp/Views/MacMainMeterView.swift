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
import SoundSenseCore

struct MacMainMeterView: View {
    @StateObject private var viewModel = MeterViewModel()
    @State private var showingSettings = false

    /// 当前等级色(贯穿数字、仪表、按钮)
    private var levelColor: Color {
        viewModel.noiseLevel?.color ?? Color(red: 0.24, green: 0.83, blue: 0.69)
    }

    var body: some View {
        ZStack {
            // 内容:顶部固定 + 中间可滚动 + 底部固定(按钮永远可见)
            VStack(spacing: 0) {
                // 顶部标题栏(固定,不滚动)+ 可拖动区域
                headerBar
                    .padding(.horizontal, 28).padding(.top, 18).padding(.bottom, 8)

                // 中间内容(窗口太小时可滚动)
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 18) {
                        // 中央视觉焦点
                        centerMeter

                        // 等级文字
                        levelLabel

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
                }

                // 底部按钮(固定,永远可见,不随滚动消失)
                HStack(spacing: 12) {
                    controlButton
                    // 停止后,如果有统计数据,显示"导出报告"按钮
                    if let stats = viewModel.lastStats {
                        exportReportButton(stats: stats)
                    }
                }
                .padding(.horizontal, 80).padding(.bottom, 22).padding(.top, 6)
            }

            // 设置浮层(ZStack 覆盖,瞬间弹出,不用慢吞吞的 sheet)
            if showingSettings {
                SettingsOverlay(viewModel: viewModel,
                                isPresented: $showingSettings)
            }
        }
        // 整个 ZStack 撑满窗口(背景色覆盖到窗口边缘,无白边)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea()
        .background(BackgroundView(accent: levelColor))
        .onChange(of: viewModel.engine.latestResult) { r in
            if let r = r { viewModel.consume(r) }
        }
    }

    // MARK: - 子组件

    private var headerBar: some View {
        HStack {
            HStack(spacing: 10) {
                Circle().fill(levelColor).frame(width: 10, height: 10)
                    .shadow(color: levelColor.opacity(0.6), radius: 6)
                Text("闻声").font(.system(size: 16, weight: .semibold)).foregroundColor(.white)
                Text("SoundSense").font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.35)).textCase(.uppercase)
            }
            Spacer()
            Button { showingSettings = true } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 15)).foregroundColor(.white.opacity(0.55))
                    .frame(width: 32, height: 32)
                    .background(Circle().fill(.white.opacity(showingSettings ? 0.12 : 0)))
            }
            .buttonStyle(.plain)
        }
    }

    /// 中央环形仪表 + 大数字
    private var centerMeter: some View {
        ZStack {
            RingGauge(spl: viewModel.currentSPL, color: levelColor)
                .frame(width: 300, height: 300)

            VStack(spacing: 4) {
                Text(splText(viewModel.currentSPL))
                    .font(.system(size: 76, weight: .heavy, design: .rounded))
                    .foregroundColor(.white).monospacedDigit()
                    .shadow(color: levelColor.opacity(0.3), radius: 12)
                Text("dB(A)").font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundColor(.white.opacity(0.5))
            }
        }
    }

    private var levelLabel: some View {
        Group {
            if let lv = viewModel.noiseLevel {
                HStack(spacing: 8) {
                    Text(lv.emoji).font(.system(size: 15))
                    Text(lv.label).font(.system(size: 15, weight: .semibold)).foregroundColor(lv.color)
                    Text("·").foregroundColor(.white.opacity(0.3))
                    Text(lv.detail).font(.system(size: 12)).foregroundColor(.white.opacity(0.45))
                }
            } else {
                Text("待机中").font(.system(size: 13)).foregroundColor(.white.opacity(0.4))
            }
        }
    }

    private var statusLine: some View {
        HStack(spacing: 6) {
            statusDot
            Text(statusMessage).font(.system(size: 11.5)).foregroundColor(.white.opacity(0.5))
            Spacer()
        }
    }

    private var statusDot: some View {
        let pulse = viewModel.engine.state == .running
        let dotColor: Color = {
            switch viewModel.engine.state {
            case .running: return levelColor
            case .failed, .denied: return .red
            default: return Color.white.opacity(0.3)
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
        return Button {
            Task { running ? viewModel.stop() : await viewModel.start() }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: running ? "stop.fill" : "mic.fill")
                    .font(.system(size: 13, weight: .bold))
                Text(running ? "停止检测" : "开始检测")
                    .font(.system(size: 14, weight: .semibold))
            }
            .foregroundColor(.white)
            .frame(maxWidth: .infinity).padding(.vertical, 12)
            .background(
                Capsule().fill(running ? Color.red.opacity(0.85) : levelColor)
            )
            .shadow(color: (running ? Color.red : levelColor).opacity(0.35), radius: 10, y: 4)
        }
        .buttonStyle(.plain)
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
            .background(Capsule().fill(Color.white.opacity(0.12)))
        }
        .buttonStyle(.plain)
        .transition(.opacity)
    }

    private func splText(_ spl: Float) -> String {
        guard spl.isFinite, spl > -80 else { return "--" }
        return String(format: "%.1f", spl)
    }
}

// MARK: - 背景(随等级色微变)

private struct BackgroundView: View {
    let accent: Color
    var body: some View {
        ZStack {
            Color(red: 0.05, green: 0.06, blue: 0.08)
            // 顶部柔和的光晕,颜色跟随等级
            RadialGradient(
                colors: [accent.opacity(0.18), .clear],
                center: .top, startRadius: 20, endRadius: 600
            )
        }
        .ignoresSafeArea()
        .animation(.easeInOut(duration: 0.6), value: accent)
    }
}

// MARK: - 环形仪表

private struct RingGauge: View {
    let spl: Float
    let color: Color
    // SPL 量程(校准后的声压级)
    private let minDB: Float = 20
    private let maxDB: Float = 120

    var body: some View {
        Canvas { ctx, size in
            let center = CGPoint(x: size.width/2, y: size.height/2)
            let radius = min(size.width, size.height)/2 - 14
            let style = StrokeStyle(lineWidth: 10, lineCap: .round)

            // 底环
            var track = Path()
            track.addArc(center: center, radius: radius, startAngle: .degrees(135),
                         endAngle: .degrees(405), clockwise: false)
            ctx.stroke(track, with: .color(.white.opacity(0.07)), style: style)

            // 进度环
            let p = progress(spl)
            let endAngleDeg = 135.0 + Double(p) * 270.0
            var arc = Path()
            arc.addArc(center: center, radius: radius, startAngle: .degrees(135),
                       endAngle: .degrees(endAngleDeg), clockwise: false)
            ctx.stroke(arc, with: .color(color), style: style)

            // 刻度点(20~120 dB SPL,每 20dB 一个)
            for db in [20, 40, 60, 80, 100, 120] {
                let t = CGFloat((Float(db) - minDB) / (maxDB - minDB))
                let angle = Angle.degrees(135 + Double(t) * 270)
                let pt = CGPoint(x: center.x + CGFloat(cos(angle.radians)) * radius,
                                 y: center.y + CGFloat(sin(angle.radians)) * radius)
                ctx.fill(Path(ellipseIn: CGRect(x: pt.x-2, y: pt.y-2, width: 4, height: 4)),
                         with: .color(.white.opacity(0.3)))
            }
        }
        .animation(.easeOut(duration: 0.15), value: spl)
    }

    private func progress(_ spl: Float) -> CGFloat {
        let c = max(minDB, min(maxDB, spl))
        return CGFloat((c - minDB) / (maxDB - minDB))
    }
}

// MARK: - 卡片(毛玻璃)

private struct Card<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 10, weight: .semibold))
                .foregroundColor(.white.opacity(0.45)).textCase(.uppercase)
                .padding(.bottom, 2)
            content
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color(red: 0.09, green: 0.10, blue: 0.13))
                .overlay(RoundedRectangle(cornerRadius: 14)
                    .stroke(.white.opacity(0.08), lineWidth: 1))
        )
    }
}

private struct EmptyHint: View {
    var body: some View {
        Text("等待数据").font(.system(size: 11)).foregroundColor(.white.opacity(0.3))
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
                ctx.draw(Text("等待数据").font(.system(size: 10)).foregroundColor(.white.opacity(0.3)),
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
