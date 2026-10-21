//
//  MacMonitorOverlay.swift
//  SoundSenseMac
//
//  macOS 长时间噪音监听：阈值设置、事件抓拍、实时状态与历史时间线。
//

import SwiftUI
import SoundSenseCore

struct MacMonitorOverlay: View {
    @StateObject private var vm: MacMonitorViewModel
    @Binding var isPresented: Bool
    @Environment(\.openURL) private var openURL

    init(calibrationOffset: Float,
         inputDeviceUID: String?,
         weighting: Weighting,
         timeWeighting: TimeWeighting,
         isPresented: Binding<Bool>) {
        _isPresented = isPresented
        _vm = StateObject(wrappedValue: MacMonitorViewModel(
            calibrationOffset: calibrationOffset,
            inputDeviceUID: inputDeviceUID,
            weighting: weighting,
            timeWeighting: timeWeighting))
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.52)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                header
                Divider().overlay(MeterTheme.hairline)
                if vm.phase == .running {
                    running
                } else {
                    idle
                }
            }
            .frame(width: 760, height: 600)
            .background(
                RoundedRectangle(cornerRadius: 20)
                    .fill(MeterTheme.panelGradient)
                    .overlay(RoundedRectangle(cornerRadius: 20)
                        .stroke(MeterTheme.hairline, lineWidth: 1))
            )
            .shadow(color: .black.opacity(0.55), radius: 36, y: 14)
        }
        .onAppear {
            _ = vm.engine.refreshInputAvailability()
        }
        .onDisappear {
            if vm.phase == .running || vm.engine.state == .starting {
                Task { await vm.stop() }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(MeterTheme.waveColor.opacity(0.13))
                    .frame(width: 34, height: 34)
                Image(systemName: "moon.zzz.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(MeterTheme.waveColor)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("噪音监听")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundColor(.white)
                Text("异常声自动抓拍 · 事件时间线 · 位置推测")
                    .font(.system(size: 10.5))
                    .foregroundColor(MeterTheme.tertiaryText)
            }
            Spacer()
            if vm.phase == .running {
                HStack(spacing: 6) {
                    Circle()
                        .fill(MeterTheme.riskColor)
                        .frame(width: 7, height: 7)
                    Text("监听中")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.white.opacity(0.8))
                }
                .padding(.horizontal, 10)
                .frame(height: 24)
                .background(Capsule().fill(MeterTheme.riskColor.opacity(0.10)))
            }
            Button(action: close) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.white.opacity(0.55))
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(.white.opacity(0.08)))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("关闭噪音监听")
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 16)
    }

    // MARK: - 待机

    private var idle: some View {
        HStack(alignment: .top, spacing: 22) {
            VStack(alignment: .leading, spacing: 16) {
                Text("整晚值守，自动留下异常片段")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundColor(.white)
                Text("监听会持续学习环境底噪（L90）。出现高于基线的脚步声、拖动声、说话或低频冲击时，自动保存前后数秒录音并标注类型。")
                    .font(.system(size: 12))
                    .foregroundColor(MeterTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)

                VStack(spacing: 10) {
                    monitorFeature("waveform.path.ecg", "事件抓拍", "前 2 秒 + 事件 + 后 3 秒")
                    monitorFeature("tag", "自动分类", "冲击 / 连续 / 混合 / 不确定")
                    monitorFeature("location.north.line", "位置推测", "结合方向倾向测试，仅提供一致性提示")
                }

                if let session = vm.liveSession, session.endTime != nil {
                    HStack(spacing: 9) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(MeterTheme.waveColor)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("上一次监听已结束")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundColor(.white.opacity(0.82))
                            Text("\(session.leqMetricLabel) \(String(format: "%.1f", session.overallLaeq)) dB · \(session.totalEventCount) 个事件，可在记录页查看")
                                .font(.system(size: 10))
                                .foregroundColor(MeterTheme.tertiaryText)
                        }
                    }
                    .padding(11)
                    .background(RoundedRectangle(cornerRadius: 10)
                        .fill(MeterTheme.waveColor.opacity(0.07)))
                }

                Label("macOS 监听依赖闻声保持运行；关闭本窗口或退出 App 会结束本次会话。",
                      systemImage: "info.circle")
                    .font(.system(size: 10))
                    .foregroundColor(MeterTheme.tertiaryText)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer()
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .leading, spacing: 14) {
                Text("监听设置")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(.white)

                VStack(alignment: .leading, spacing: 7) {
                    HStack {
                        Text("相对背景阈值")
                            .font(.system(size: 11))
                            .foregroundColor(.white.opacity(0.75))
                        Spacer()
                        Text("+\(Int(vm.thresholdOver)) dB")
                            .font(.system(size: 12, weight: .semibold, design: .monospaced))
                            .foregroundColor(MeterTheme.waveColor)
                    }
                    Slider(value: $vm.thresholdOver, in: 5...20, step: 1)
                        .tint(MeterTheme.waveColor)
                    Text("数值越低越敏感；普通住宅建议 +8～+12 dB。")
                        .font(.system(size: 9.5))
                        .foregroundColor(MeterTheme.tertiaryText)
                }

                Divider().overlay(MeterTheme.hairline)

                Toggle(isOn: $vm.absoluteEnabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("夜间绝对阈值")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.white.opacity(0.8))
                        Text("取较低阈值，提高低强度异常声检出")
                            .font(.system(size: 9.5))
                            .foregroundColor(MeterTheme.tertiaryText)
                    }
                }
                .toggleStyle(.switch)
                .tint(MeterTheme.waveColor)

                if vm.absoluteEnabled {
                    HStack {
                        Text("绝对阈值")
                            .font(.system(size: 10.5))
                            .foregroundColor(MeterTheme.secondaryText)
                        Spacer()
                        Stepper(value: $vm.absoluteDB, in: 35...60, step: 1) {
                            Text("\(Int(vm.absoluteDB)) dB")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(MeterTheme.waveColor)
                        }
                        .frame(width: 130)
                    }
                }

                if !vm.engine.hasAudioInput {
                    Label("未检测到麦克风", systemImage: "mic.slash")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundColor(MeterTheme.brass)
                }

                if let error = vm.startError {
                    HStack(alignment: .top, spacing: 7) {
                        Image(systemName: "exclamationmark.triangle.fill")
                        Text(error)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .font(.system(size: 10.5))
                    .foregroundColor(MeterTheme.riskColor)
                    .padding(9)
                    .background(RoundedRectangle(cornerRadius: 9)
                        .fill(MeterTheme.riskColor.opacity(0.08)))
                }

                if let note = vm.audioRecoveryNote {
                    Label(note, systemImage: "arrow.clockwise.circle")
                        .font(.system(size: 10.5))
                        .foregroundColor(MeterTheme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 4)

                Button {
                    Task { await vm.start() }
                } label: {
                    HStack(spacing: 8) {
                        if vm.engine.state == .starting {
                            ProgressView().controlSize(.small).tint(.white)
                        } else {
                            Image(systemName: "moon.zzz.fill")
                        }
                        Text(vm.engine.state == .starting ? "正在启动..." : "开始监听")
                            .font(.system(size: 13, weight: .semibold))
                    }
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .background(RoundedRectangle(cornerRadius: 11)
                        .fill(MeterTheme.primaryActionGradient))
                }
                .buttonStyle(.plain)
                .disabled(vm.engine.state == .starting || !vm.engine.hasAudioInput)
                .opacity(vm.engine.hasAudioInput ? 1 : 0.55)

                if !vm.engine.hasAudioInput {
                    Button("检查系统输入设备") {
                        openSoundSettings()
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundColor(MeterTheme.waveColor)
                    .frame(maxWidth: .infinity)
                }
            }
            .padding(18)
            .frame(width: 278)
            .background(
                RoundedRectangle(cornerRadius: 15)
                    .fill(.white.opacity(0.045))
                    .overlay(RoundedRectangle(cornerRadius: 15)
                        .stroke(.white.opacity(0.07), lineWidth: 1))
            )
        }
        .padding(24)
    }

    private func monitorFeature(_ icon: String, _ title: String,
                                _ detail: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(MeterTheme.waveColor)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.white.opacity(0.82))
                Text(detail)
                    .font(.system(size: 9.5))
                    .foregroundColor(MeterTheme.tertiaryText)
            }
            Spacer()
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 9)
            .fill(.white.opacity(0.035)))
    }

    // MARK: - 运行中

    private var running: some View {
        HStack(spacing: 20) {
            VStack(spacing: 18) {
                VStack(spacing: 3) {
                    Text(vm.currentLaeq.isFinite
                         ? String(format: "%.1f", vm.currentLaeq) : "--")
                        .font(.system(size: 64, weight: .heavy, design: .rounded))
                        .foregroundColor(.white)
                        .monospacedDigit()
                    Text("当前 LAeq dB")
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundColor(MeterTheme.tertiaryText)
                }

                HStack(spacing: 10) {
                    liveStat(vm.baseline.isFinite
                             ? String(format: "%.1f", vm.baseline) : "--",
                             label: "背景基线")
                    liveStat("\(vm.eventCount)", label: "异常事件")
                    liveStat(vm.absoluteEnabled ? "\(Int(vm.absoluteDB))" : "+\(Int(vm.thresholdOver))",
                             label: vm.absoluteEnabled ? "绝对阈值" : "相对阈值")
                }

                if let note = vm.lastEventNote {
                    HStack(spacing: 8) {
                        Image(systemName: "bell.badge.fill")
                            .foregroundColor(MeterTheme.waveColor)
                        Text("最近事件：\(note)")
                            .font(.system(size: 10.5))
                            .foregroundColor(MeterTheme.secondaryText)
                        Spacer()
                    }
                    .padding(11)
                    .background(RoundedRectangle(cornerRadius: 10)
                        .fill(MeterTheme.waveColor.opacity(0.07)))
                }

                if let note = vm.audioRecoveryNote {
                    Label(note, systemImage: "arrow.clockwise.circle")
                        .font(.system(size: 10.5))
                        .foregroundColor(MeterTheme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer()

                Button {
                    Task { await vm.stop() }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "stop.fill")
                        Text("停止监听")
                            .font(.system(size: 13, weight: .semibold))
                    }
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .background(RoundedRectangle(cornerRadius: 11)
                        .fill(MeterTheme.dangerActionGradient))
                }
                .buttonStyle(.plain)
            }
            .frame(width: 260)

            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("实时事件")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(.white)
                    Spacer()
                    Text("最多保存 \(MacMonitorViewModel.maxEventsPerSession) 段录音；事件继续记录")
                        .font(.system(size: 9.5))
                        .foregroundColor(MeterTheme.tertiaryText)
                }

                if let events = vm.liveSession?.events, !events.isEmpty {
                    ScrollView(showsIndicators: false) {
                        VStack(spacing: 8) {
                            ForEach(Array(events.reversed())) { event in
                                liveEventRow(event)
                            }
                        }
                    }
                } else {
                    VStack(spacing: 10) {
                        Image(systemName: "waveform.badge.magnifyingglass")
                            .font(.system(size: 28))
                            .foregroundColor(MeterTheme.tertiaryText)
                        Text("正在学习环境底噪...")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(MeterTheme.secondaryText)
                        Text("检测到持续异常声后，会自动出现在这里")
                            .font(.system(size: 10))
                            .foregroundColor(MeterTheme.tertiaryText)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: 15)
                    .fill(.white.opacity(0.035))
                    .overlay(RoundedRectangle(cornerRadius: 15)
                        .stroke(.white.opacity(0.06), lineWidth: 1))
            )
        }
        .padding(24)
    }

    private func liveStat(_ value: String, label: String) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.system(size: 18, weight: .bold, design: .rounded))
                .foregroundColor(MeterTheme.waveColor)
                .monospacedDigit()
            Text(label)
                .font(.system(size: 9))
                .foregroundColor(MeterTheme.tertiaryText)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 10)
            .fill(.white.opacity(0.045)))
    }

    private func liveEventRow(_ event: MonitorEvent) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon(for: event.type))
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(MeterTheme.waveColor)
                .frame(width: 24, height: 24)
                .background(Circle().fill(MeterTheme.waveColor.opacity(0.12)))
            VStack(alignment: .leading, spacing: 2) {
                Text(Self.timeFormatter.string(from: event.time))
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundColor(.white.opacity(0.82))
                Text("\(SourceTendencyAnalyzer.typeText(event.type)) · \(event.guess)")
                    .font(.system(size: 9.5))
                    .foregroundColor(MeterTheme.tertiaryText)
            }
            Spacer()
            Text(String(format: "%.1f dB", event.peakSPL))
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundColor(MeterTheme.waveColor)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 9)
            .fill(.white.opacity(0.035)))
    }

    private func icon(for type: NoiseType) -> String {
        switch type {
        case .impact: return "figure.walk"
        case .continuous: return "text.bubble.fill"
        case .mixed: return "speaker.wave.2.fill"
        case .unknown: return "questionmark"
        }
    }

    private func close() {
        Task {
            await vm.stop()
            isPresented = false
        }
    }

    private func openSoundSettings() {
        guard let url = URL(string:
                "x-apple.systempreferences:com.apple.Sound-Settings.extension") else {
            return
        }
        openURL(url)
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()
}

// MARK: - 监听历史详情

struct MacMonitorSessionDetailSheet: View {
    let session: MonitorSession
    let store: MonitorSessionStore
    @Environment(\.dismiss) private var dismiss
    @StateObject private var player = RecordingPlayer()

    var body: some View {
        VStack(spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("监听时间线")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundColor(.white)
                    Text("\(Self.dateFormatter.string(from: session.startTime)) · \(session.totalEventCount) 个异常事件")
                        .font(.system(size: 10))
                        .foregroundColor(MeterTheme.tertiaryText)
                }
                Spacer()
                Button("完成") { dismiss() }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(MeterTheme.waveColor)
            }

            HStack(spacing: 10) {
                stat(String(format: "%.1f", session.overallLaeq), "总 \(session.leqMetricLabel)")
                stat(String(format: "%.1f", session.maxSPL), session.peakMetricLabel)
                stat("\(session.totalEventCount)", "事件")
            }

            if session.captureIncomplete {
                Label("采集或分析链路曾中断/积压；最终 Leq/峰值来自全帧统计，事件时间线可能不完整。",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 10.5))
                    .foregroundColor(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(9)
                    .background(RoundedRectangle(cornerRadius: 9)
                        .fill(Color.orange.opacity(0.10)))
            }

            if session.droppedEventCount > 0 {
                Label("仅保留最近 \(session.events.count) 条事件明细；累计 \(session.totalEventCount) 条，事件峰值统计不受影响。",
                      systemImage: "clock.arrow.circlepath")
                    .font(.system(size: 10.5))
                    .foregroundColor(MeterTheme.secondaryText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(9)
                    .background(RoundedRectangle(cornerRadius: 9)
                        .fill(.white.opacity(0.05)))
            }

            ScrollView(showsIndicators: false) {
                VStack(spacing: 8) {
                    if session.events.isEmpty {
                        Text("本次监听没有捕捉到异常事件")
                            .font(.system(size: 12))
                            .foregroundColor(MeterTheme.secondaryText)
                            .padding(.top, 30)
                    } else {
                        ForEach(session.events) { event in
                            eventRow(event)
                        }
                    }
                }
            }

            if !session.events.isEmpty {
                MacRecordingPlayerBar(player: player)
            }

            Button {
                ReportExporter.exportMonitorHTML(session: session, store: store)
            } label: {
                Label("导出监听报告", systemImage: "doc.richtext")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity, minHeight: 40)
                    .background(RoundedRectangle(cornerRadius: 10)
                        .fill(MeterTheme.primaryActionGradient))
            }
            .buttonStyle(.plain)
        }
        .padding(20)
        .frame(width: 720, height: 600)
        .background(MeterTheme.backgroundGradient)
        .onDisappear { player.stop() }
    }

    private func eventRow(_ event: MonitorEvent) -> some View {
        Button {
            guard let clip = event.clipFile else { return }
            player.load(url: store.clipURL(sessionID: session.id, clipFile: clip))
            player.togglePlayPause()
        } label: {
            HStack(spacing: 11) {
                Image(systemName: icon(for: event.type))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(MeterTheme.waveColor)
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(MeterTheme.waveColor.opacity(0.12)))
                Text(Self.dateFormatter.string(from: event.time))
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundColor(.white.opacity(0.75))
                    .frame(width: 62, alignment: .leading)
                Text("\(SourceTendencyAnalyzer.typeText(event.type)) · \(event.guess)")
                    .font(.system(size: 10.5))
                    .foregroundColor(MeterTheme.secondaryText)
                Spacer()
                Text(String(format: "%.1f dB", event.peakSPL))
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundColor(MeterTheme.waveColor)
                Text(event.clipFile == nil ? "无录音" : "回放")
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundColor(MeterTheme.tertiaryText)
                    .frame(width: 42, alignment: .trailing)
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 9)
                .fill(.white.opacity(0.035))
                .overlay(RoundedRectangle(cornerRadius: 9)
                    .stroke(.white.opacity(0.05), lineWidth: 1)))
        }
        .buttonStyle(.plain)
        .disabled(event.clipFile == nil)
    }

    private func icon(for type: NoiseType) -> String {
        switch type {
        case .impact: return "figure.walk"
        case .continuous: return "text.bubble.fill"
        case .mixed: return "speaker.wave.2.fill"
        case .unknown: return "questionmark"
        }
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.system(size: 17, weight: .semibold, design: .rounded))
                .foregroundColor(MeterTheme.waveColor)
                .monospacedDigit()
            Text(label)
                .font(.system(size: 9))
                .foregroundColor(MeterTheme.tertiaryText)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: 10)
            .fill(.white.opacity(0.04)))
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm:ss"
        return formatter
    }()
}
