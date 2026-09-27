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
    @State private var showingSessions = false

    var body: some View {
        NavigationView {
            Group {
                if vm.phase == .running {
                    running
                } else {
                    idle
                }
            }
            .background(MeterTheme.backgroundGradient.ignoresSafeArea())
            .navigationTitle("噪音监听")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("记录") { showingSessions = true }
                        .foregroundColor(MeterTheme.waveColor)
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("关闭") {
                        vm.stop()
                        dismiss()
                    }
                    .foregroundColor(MeterTheme.waveColor)
                }
            }
        }
        .navigationViewStyle(.stack)
        .sheet(isPresented: $showingSessions) {
            MonitorSessionListView(store: vm.store)
        }
        .onChange(of: vm.engine.latestResult) { result in
            if let result = result { vm.consume(result) }
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
                Text("做过「声源定位」测试后,位置推测会更准。")
            }
            .font(.system(size: 12))
            .foregroundColor(.white.opacity(0.6))
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 14).fill(MeterTheme.cardBackground))

            thresholdSettings

            Button {
                Task { await vm.start() }
            } label: {
                Text("开始监听")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity, minHeight: 48)
                    .background(RoundedRectangle(cornerRadius: 12)
                        .fill(MeterTheme.waveColor.opacity(0.9)))
            }
            .buttonStyle(.plain)
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
        .background(RoundedRectangle(cornerRadius: 14).fill(MeterTheme.cardBackground))
        .tint(MeterTheme.waveColor)
    }

    // MARK: - 监听中

    private var running: some View {
        VStack(spacing: 22) {
            HStack(spacing: 8) {
                Circle()
                    .fill(Color(red: 1.0, green: 0.27, blue: 0.24))
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
                    .foregroundColor(.white.opacity(0.5))
            }

            VStack(spacing: 4) {
                Text("\(vm.eventCount)")
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                    .foregroundColor(MeterTheme.waveColor)
                    .monospacedDigit()
                Text("已抓拍异常事件")
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.5))
            }

            if let note = vm.lastEventNote {
                Text("最近:\(note)")
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.6))
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 10).fill(MeterTheme.cardBackground))
            }

            Spacer()
            Button {
                vm.stop()
            } label: {
                Text("停止监听")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity, minHeight: 48)
                    .background(RoundedRectangle(cornerRadius: 12)
                        .fill(Color(red: 1.0, green: 0.35, blue: 0.3).opacity(0.85)))
            }
            .buttonStyle(.plain)
        }
        .padding(20)
    }
}

// MARK: - 会话列表

struct MonitorSessionListView: View {
    @ObservedObject var store: MonitorSessionStore
    @Environment(\.dismiss) private var dismiss
    @State private var selected: MonitorSession?

    var body: some View {
        NavigationView {
            Group {
                if store.sessions.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "list.bullet")
                            .font(.system(size: 36))
                            .foregroundColor(.white.opacity(0.3))
                        Text("还没有监听记录")
                            .font(.system(size: 14))
                            .foregroundColor(MeterTheme.secondaryText)
                    }
                } else {
                    ScrollView {
                        LazyVStack(spacing: 12) {
                            ForEach(store.sessions) { session in
                                Button {
                                    selected = session
                                } label: {
                                    sessionRow(session)
                                }
                                .buttonStyle(.plain)
                                .contextMenu {
                                    if let index = store.sessions.firstIndex(where: { $0.id == session.id }) {
                                        Button(role: .destructive) {
                                            store.delete(at: IndexSet(integer: index))
                                        } label: {
                                            Label("删除", systemImage: "trash")
                                        }
                                    }
                                }
                            }
                        }
                        .padding(.horizontal, 20).padding(.vertical, 12)
                    }
                }
            }
            .background(MeterTheme.backgroundGradient.ignoresSafeArea())
            .navigationTitle("监听记录")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("完成") { dismiss() }
                        .foregroundColor(MeterTheme.waveColor)
                }
            }
        }
        .navigationViewStyle(.stack)
        .sheet(item: $selected) { session in
            MonitorSessionDetailView(session: session, store: store)
        }
    }

    private func sessionRow(_ session: MonitorSession) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(Self.df.string(from: session.startTime))
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.white)
                Spacer()
                if session.endTime == nil {
                    Text("进行中").font(.system(size: 12))
                        .foregroundColor(MeterTheme.waveColor)
                } else if session.abnormalEnd {
                    Text("异常结束").font(.system(size: 12))
                        .foregroundColor(.orange)
                }
            }
            HStack {
                Text("LAeq \(String(format: "%.1f", session.overallLaeq)) dB · \(session.events.count) 次事件")
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.55))
                Spacer()
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(MeterTheme.cardBackground)
                .overlay(RoundedRectangle(cornerRadius: 14)
                    .stroke(MeterTheme.cardBorder, lineWidth: 1))
        )
    }

    private static let df: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm"
        return f
    }()
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
                        stat(String(format: "%.1f", session.overallLaeq), "总 LAeq")
                        stat(String(format: "%.0f", session.maxSPL), "峰值")
                        stat("\(session.events.count)", "事件")
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
                        .foregroundColor(.white.opacity(0.5))
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
                    .fill(MeterTheme.cardBackground)
                    .overlay(RoundedRectangle(cornerRadius: 12)
                        .stroke(MeterTheme.cardBorder, lineWidth: 1))
            )
        }
        .buttonStyle(.plain)
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
        .background(RoundedRectangle(cornerRadius: 12).fill(MeterTheme.cardBackground))
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
