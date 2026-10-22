//
//  MonitorView.swift
//  SoundSense iOS
//
//  长时间监听:开始/停止 + 阈值设置 + 运行状态;会话列表与事件时间线详情。
//

import SwiftUI
import UIKit

struct MonitorView: View {
    @StateObject private var vm = MonitorViewModel()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            ZStack {
                MeterTheme.backgroundGradient.ignoresSafeArea()
                if vm.phase == .running {
                    running
                } else {
                    idle
                }
            }
            .navigationTitle("噪音监听")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("关闭") {
                        Task {
                            await vm.stop()
                            dismiss()
                        }
                    }
                    .foregroundColor(MeterTheme.waveColor)
                }
            }
        }
        .navigationViewStyle(.stack)
        .onChange(of: vm.engine.audioRecoveryNote) { _ in
            vm.refreshAudioRecoveryState()
        }
        .onDisappear {
            Task { await vm.stop() }
        }
    }

    // MARK: - 待机

    private var idle: some View {
        VStack(spacing: 18) {
            Image(systemName: "moon.zzz")
                .font(.system(size: 40))
                .foregroundColor(MeterTheme.waveColor)
            Text("整晚值守,自动抓拍异常噪音")
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(.white)
            VStack(alignment: .leading, spacing: 10) {
                Text("超过「背景基线 + \(Int(vm.thresholdOver)) dB」的声音会被自动录下一段,并标注类型与位置推测。")
                Text("锁屏后继续运行;整晚监听建议插电。")
                Text("做过「方向倾向」测试后,位置推测仅会增加一致性提示,不代表精确定位。")
            }
            .font(.system(size: 12))
            .foregroundColor(MeterTheme.secondaryText)
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(MeterTheme.panelGradient)
                    .overlay(RoundedRectangle(cornerRadius: 14)
                        .stroke(MeterTheme.cardBorder, lineWidth: 1))
            )

            thresholdSettings

            if let error = vm.startError {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(MeterTheme.riskColor)
                    Text(error)
                        .font(.system(size: 12))
                        .foregroundColor(MeterTheme.riskColor)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 12)
                    .fill(MeterTheme.riskColor.opacity(0.10)))
            }

            if let note = vm.audioRecoveryNote {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: vm.waitingForAudioRecovery
                          ? "pause.circle.fill" : "waveform.badge.checkmark")
                        .foregroundColor(vm.waitingForAudioRecovery
                                         ? .orange : MeterTheme.waveColor)
                    Text(note)
                        .font(.system(size: 12))
                        .foregroundColor(.white.opacity(0.75))
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 12)
                    .fill(.white.opacity(0.05)))
            }

            Button {
                Task { await vm.start() }
            } label: {
                HStack(spacing: 8) {
                    if vm.engine.state == .starting {
                        ProgressView().tint(.white).scaleEffect(0.8)
                    } else {
                        Image(systemName: "moon.zzz.fill")
                    }
                    Text(vm.engine.state == .starting ? "正在启动..." : "开始监听")
                }
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(.white)
                .frame(maxWidth: .infinity, minHeight: 48)
                .background(RoundedRectangle(cornerRadius: 12)
                    .fill(MeterTheme.primaryActionGradient))
            }
            .buttonStyle(.plain)
            .disabled(vm.engine.state == .starting)
            Spacer()
        }
        .padding(20)
    }

    private var thresholdSettings: some View {
        VStack(spacing: 12) {
            Stepper(value: $vm.thresholdOver, in: 5...20, step: 1) {
                HStack {
                    Text("触发阈值").font(.system(size: 13)).foregroundColor(.white.opacity(0.8))
                    Spacer()
                    Text("背景 +\(Int(vm.thresholdOver)) dB")
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundColor(MeterTheme.waveColor)
                }
            }
            Toggle(isOn: $vm.absoluteEnabled) {
                Text("夜间绝对阈值(更敏感)").font(.system(size: 13)).foregroundColor(.white.opacity(0.8))
            }
            if vm.absoluteEnabled {
                Stepper(value: $vm.absoluteDB, in: 35...60, step: 1) {
                    HStack {
                        Text("绝对阈值").font(.system(size: 13)).foregroundColor(.white.opacity(0.8))
                        Spacer()
                        Text("\(Int(vm.absoluteDB)) dB")
                            .font(.system(size: 13, design: .monospaced))
                            .foregroundColor(MeterTheme.waveColor)
                    }
                }
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(MeterTheme.panelGradient)
                .overlay(RoundedRectangle(cornerRadius: 14)
                    .stroke(MeterTheme.cardBorder, lineWidth: 1))
        )
        .tint(MeterTheme.waveColor)
    }

    // MARK: - 监听中

    private var running: some View {
        VStack(spacing: 22) {
            if let note = vm.audioRecoveryNote {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: vm.waitingForAudioRecovery
                          ? "pause.circle.fill" : "waveform.badge.checkmark")
                        .foregroundColor(vm.waitingForAudioRecovery
                                         ? .orange : MeterTheme.waveColor)
                    Text(note)
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.72))
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 10)
                    .fill(.white.opacity(0.05)))
            }
            HStack(spacing: 8) {
                Circle()
                    .fill(MeterTheme.riskColor)
                    .frame(width: 9, height: 9)
                Text("监听中")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.white)
            }

            VStack(spacing: 4) {
                Text(vm.currentLaeq.isFinite ? String(format: "%.1f dB", vm.currentLaeq) : "--")
                    .font(.system(size: 44, weight: .heavy, design: .rounded))
                    .foregroundColor(.white)
                    .monospacedDigit()
                Text(vm.baseline.isFinite
                     ? String(format: "背景基线 %.1f dB", vm.baseline)
                     : "背景基线学习中...")
                    .font(.system(size: 12))
                    .foregroundColor(MeterTheme.secondaryText)
            }

            VStack(spacing: 4) {
                Text("\(vm.eventCount)")
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                    .foregroundColor(MeterTheme.waveColor)
                    .monospacedDigit()
                Text("已记录异常事件")
                    .font(.system(size: 12))
                    .foregroundColor(MeterTheme.secondaryText)
            }

            if let note = vm.lastEventNote {
                Text("最近:\(note)")
                    .font(.system(size: 12))
                    .foregroundColor(MeterTheme.secondaryText)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 10)
                            .fill(MeterTheme.panelGradient)
                            .overlay(RoundedRectangle(cornerRadius: 10)
                                .stroke(MeterTheme.cardBorder, lineWidth: 1))
                    )
            }

            Spacer()
            Button {
                Task { await vm.stop() }
            } label: {
                Text("停止监听")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity, minHeight: 48)
                    .background(RoundedRectangle(cornerRadius: 12)
                        .fill(MeterTheme.dangerActionGradient))
            }
            .buttonStyle(.plain)
        }
        .padding(20)
    }
}

// MARK: - 时间线详情

struct MonitorSessionDetailView: View {
    let session: MonitorSession
    let store: MonitorSessionStore
    @Environment(\.dismiss) private var dismiss
    @StateObject private var player = RecordingPlayer()
    @State private var sharingHTML = false

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 14) {
                    HStack {
                        stat(String(format: "%.1f", session.overallLaeq), "总 \(session.leqMetricLabel)")
                        stat(String(format: "%.0f", session.maxSPL), session.peakMetricLabel)
                        stat("\(session.totalEventCount)", "事件")
                    }

                    if session.captureIncomplete {
                        Label("采集或分析链路曾中断/积压；最终 Leq/峰值来自全帧统计，事件时间线可能不完整。",
                              systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: 11))
                            .foregroundColor(.orange)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                            .background(RoundedRectangle(cornerRadius: 10)
                                .fill(Color.orange.opacity(0.10)))
                    }

                    if session.droppedClipBlockCount > 0 {
                        Label("有 \(session.droppedClipBlockCount) 个音频块因编码/写盘积压被丢弃，部分事件录音可能缺音；声级统计不受影响。",
                              systemImage: "waveform.badge.exclamationmark")
                            .font(.system(size: 11))
                            .foregroundColor(.orange)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                            .background(RoundedRectangle(cornerRadius: 10)
                                .fill(Color.orange.opacity(0.10)))
                    }

                    if session.droppedEventCount > 0 {
                        Label("仅保留最近 \(session.events.count) 条事件明细；累计 \(session.totalEventCount) 条，事件峰值统计不受影响。",
                              systemImage: "clock.arrow.circlepath")
                            .font(.system(size: 11))
                            .foregroundColor(MeterTheme.secondaryText)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                            .background(RoundedRectangle(cornerRadius: 10)
                                .fill(.white.opacity(0.05)))
                    }

                    if session.events.isEmpty {
                        Text("本次监听没有捕捉到异常事件")
                            .font(.system(size: 13))
                            .foregroundColor(MeterTheme.secondaryText)
                            .padding(.top, 20)
                    } else {
                        VStack(spacing: 8) {
                            ForEach(session.events) { event in
                                eventRow(event)
                            }
                        }
                    }

                    if session.events.contains(where: { $0.clipFile != nil }) {
                        Button {
                            sharingHTML = true
                        } label: {
                            Label("分享监听报告", systemImage: "doc.richtext")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundColor(.white)
                                .frame(maxWidth: .infinity, minHeight: 42)
                                .background(RoundedRectangle(cornerRadius: 10)
                                    .fill(MeterTheme.waveColor.opacity(0.85)))
                        }
                        .buttonStyle(.plain)
                    }

                    RecordingPlayerBar(player: player)
                }
                .padding(16)
            }
            .background(MeterTheme.backgroundGradient.ignoresSafeArea())
            .navigationTitle("监听时间线")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("完成") { dismiss() }
                        .foregroundColor(MeterTheme.waveColor)
                }
            }
        }
        .navigationViewStyle(.stack)
        // 详情页关闭即停:AVAudioPlayer 独立于视图存活,不停会一直响
        .onDisappear { player.stop() }
        .sheet(isPresented: $sharingHTML) {
            MonitorHTMLShareSheet(session: session, store: store)
        }
    }

    private func eventRow(_ event: MonitorEvent) -> some View {
        Button {
            if let clip = event.clipFile {
                player.load(url: store.clipURL(sessionID: session.id, clipFile: clip))
                player.togglePlayPause()
            }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: iconName(event.type))
                    .font(.system(size: 14))
                    .foregroundColor(MeterTheme.waveColor)
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(MeterTheme.waveColor.opacity(0.14)))
                VStack(alignment: .leading, spacing: 2) {
                    Text(Self.tf.string(from: event.time))
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.white)
                    Text("\(SourceTendencyAnalyzer.typeText(event.type)) · \(event.guess)")
                        .font(.system(size: 11))
                        .foregroundColor(MeterTheme.secondaryText)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text(String(format: "%.1f dB", event.peakSPL))
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundColor(MeterTheme.waveColor)
                    Text(event.clipFile != nil ? "点按回放 · \(String(format: "%.0fs", event.duration))" : "无录音")
                        .font(.system(size: 10))
                        .foregroundColor(MeterTheme.secondaryText)
                }
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(MeterTheme.panelGradient)
                    .overlay(RoundedRectangle(cornerRadius: 12)
                        .stroke(MeterTheme.cardBorder, lineWidth: 1))
            )
        }
        .buttonStyle(.plain)
        .disabled(event.clipFile == nil)
        .accessibilityLabel(event.clipFile == nil
                            ? "\(Self.tf.string(from: event.time))，无录音"
                            : "播放 \(Self.tf.string(from: event.time)) 的录音")
    }

    private func iconName(_ type: NoiseType) -> String {
        switch type {
        case .impact: return "figure.walk"
        case .continuous: return "text.bubble"
        case .mixed: return "speaker.wave.2"
        case .unknown: return "questionmark.circle"
        }
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(spacing: 3) {
            Text(value)
                .font(.system(size: 18, weight: .semibold, design: .rounded))
                .foregroundColor(MeterTheme.waveColor)
                .monospacedDigit()
            Text(label)
                .font(.system(size: 10))
                .foregroundColor(MeterTheme.secondaryText)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(MeterTheme.panelGradient)
                .overlay(RoundedRectangle(cornerRadius: 12)
                    .stroke(MeterTheme.cardBorder, lineWidth: 1))
        )
    }

    private static let tf: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()
}

/// HTML 分享
struct MonitorHTMLShareSheet: UIViewControllerRepresentable {
    let session: MonitorSession
    let store: MonitorSessionStore

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let html = MonitorHTMLBuilder.build(session: session) { clip in
            store.clipURL(sessionID: session.id, clipFile: clip)
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(MonitorHTMLBuilder.filename(for: session))
        if let data = html.data(using: .utf8) {
            try? data.write(to: url, options: [.atomic])
        }
        return UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }

    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}
