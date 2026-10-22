//
//  HistoryOverlayView.swift
//  SoundSenseMac
//
//  测量历史浮层(与设置浮层同风格):回看历史统计,可重新导出报告、删除。
//

import SwiftUI
import UniformTypeIdentifiers

struct HistoryOverlay: View {
    @ObservedObject var store: MeasurementHistoryStore
    @ObservedObject private var sourceStore = SourceTestStore.shared
    @ObservedObject private var monitorStore = MonitorSessionStore.shared
    let deviceName: String
    let calibrationOffset: Float
    @Binding var isPresented: Bool
    @State private var tab = 0
    @State private var sharingStats: MeasurementStats?
    @State private var selectedSource: SourceTestResult?
    @State private var selectedSession: MonitorSession?
    @State private var showingClearConfirmation = false

    init(store: MeasurementHistoryStore,
         deviceName: String,
         calibrationOffset: Float,
         isPresented: Binding<Bool>) {
        self.store = store
        self.deviceName = deviceName
        self.calibrationOffset = calibrationOffset
        _isPresented = isPresented
    }

    var body: some View {
        ZStack {
            MeterTheme.overlayScrim
                .ignoresSafeArea()
                .onTapGesture { isPresented = false }

            VStack(spacing: 0) {
                header
                typePicker
                content
            }
            .frame(width: 620, height: 600)
            .background(
                RoundedRectangle(cornerRadius: 18)
                    .fill(MeterTheme.panelGradient)
                    .overlay(RoundedRectangle(cornerRadius: 18)
                        .stroke(MeterTheme.hairline, lineWidth: 1))
            )
            .shadow(color: .black.opacity(0.5), radius: 30, y: 10)
        }
        .sheet(item: $sharingStats) { stats in
            MacReportPreviewSheet(stats: stats,
                                  store: store,
                                  deviceName: deviceName,
                                  calibrationOffset: calibrationOffset)
        }
        .sheet(item: $selectedSource) { result in
            MacSourceTestDetailSheet(result: result, store: sourceStore)
        }
        .sheet(item: $selectedSession) { session in
            MacMonitorSessionDetailSheet(session: session, store: monitorStore)
        }
        .confirmationDialog(clearConfirmationTitle,
                            isPresented: $showingClearConfirmation,
                            titleVisibility: .visible) {
            Button(clearActionTitle, role: .destructive) {
                clearCurrentTab()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("相关录音也会一并删除，此操作无法撤销。")
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("记录").font(.system(size: 16, weight: .bold))
                    .foregroundColor(MeterTheme.primaryText)
                Text("测量、声源方向倾向与长时间监听")
                    .font(.system(size: 10))
                    .foregroundColor(MeterTheme.tertiaryText)
            }
            Spacer()
            if tab == 0, !store.records.isEmpty {
                Button {
                    exportCSV(text: MeasurementCSV.csv(forAll: store.records),
                              filename: "闻声数据_全部记录.csv")
                } label: {
                    Text("CSV").font(.system(size: 12))
                        .foregroundColor(MeterTheme.waveColor)
                }
                .buttonStyle(.plain)
            }
            if hasCurrentRecords {
                Button {
                    showingClearConfirmation = true
                } label: {
                    Text("清空").font(.system(size: 12))
                        .foregroundColor(MeterTheme.riskColor)
                }
                .buttonStyle(.plain)
            }
            Button {
                isPresented = false
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(MeterTheme.tertiaryText)
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(MeterTheme.surfaceStrongFill))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("关闭")
        }
        .padding(.horizontal, 20).padding(.top, 18).padding(.bottom, 14)
    }

    private var typePicker: some View {
        Picker("记录类型", selection: $tab) {
            Text("测量").tag(0)
            Text("方向倾向").tag(1)
            Text("噪音监听").tag(2)
        }
        .pickerStyle(.segmented)
        .padding(.horizontal, 20)
        .padding(.bottom, 12)
    }

    @ViewBuilder
    private var content: some View {
        switch tab {
        case 0:
            measurementContent
        case 1:
            sourceContent
        default:
            monitorContent
        }
    }

    @ViewBuilder
    private var measurementContent: some View {
        if store.records.isEmpty {
            emptyRecord(icon: "clock.arrow.circlepath",
                        title: "还没有测量记录",
                        subtitle: "完成一次测量后，报告会自动保存在这里")
        } else {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 10) {
                    ForEach(Array(store.records.enumerated()), id: \.offset) { index, record in
                        MacHistoryRow(record: record) {
                            sharingStats = record
                        } onDelete: {
                            store.delete(at: IndexSet(integer: index))
                        } onExportCSV: {
                            exportCSV(text: MeasurementCSV.csv(for: record),
                                      filename: MeasurementCSV.filename(for: record))
                        }
                    }
                }
                .padding(.horizontal, 20).padding(.bottom, 20)
            }
        }
    }

    @ViewBuilder
    private var sourceContent: some View {
        if sourceStore.results.isEmpty {
            emptyRecord(icon: "dot.radiowaves.left.and.right",
                        title: "还没有方向倾向记录",
                        subtitle: "完成一次四点位测试后，结论和录音会保存在这里")
        } else {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 10) {
                    ForEach(Array(sourceStore.results.enumerated()), id: \.offset) { index, result in
                        HStack(spacing: 8) {
                            Button {
                                selectedSource = result
                            } label: {
                                sourceRow(result)
                            }
                            .buttonStyle(.plain)
                            Button {
                                sourceStore.delete(at: IndexSet(integer: index))
                            } label: {
                                Image(systemName: "trash")
                                    .font(.system(size: 11))
                                    .foregroundColor(MeterTheme.tertiaryText)
                                    .frame(width: 30, height: 30)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(.horizontal, 20).padding(.bottom, 20)
            }
        }
    }

    @ViewBuilder
    private var monitorContent: some View {
        if monitorStore.sessions.isEmpty {
            emptyRecord(icon: "moon.zzz",
                        title: "还没有监听记录",
                        subtitle: "开启一次长时间监听后，事件时间线会保存在这里")
        } else {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 10) {
                    ForEach(Array(monitorStore.sessions.enumerated()), id: \.offset) { index, session in
                        HStack(spacing: 8) {
                            Button {
                                selectedSession = session
                            } label: {
                                monitorRow(session)
                            }
                            .buttonStyle(.plain)
                            Button {
                                monitorStore.delete(at: IndexSet(integer: index))
                            } label: {
                                Image(systemName: "trash")
                                    .font(.system(size: 11))
                                    .foregroundColor(MeterTheme.tertiaryText)
                                    .frame(width: 30, height: 30)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(.horizontal, 20).padding(.bottom, 20)
            }
        }
    }

    private func sourceRow(_ result: SourceTestResult) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(Self.rowDate.string(from: result.startTime))
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundColor(MeterTheme.primaryText)
                Spacer()
                Text(result.rejectedByDrift
                     ? "环境变化过大"
                     : SourceTendencyAnalyzer.verdictText(result.verdict))
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(MeterTheme.waveColor)
            }
            HStack(spacing: 5) {
                if result.rejectedByDrift {
                    Text("中央复测漂移 \(result.centerDrift.map { String(format: "%.1f dB", $0) } ?? "超过 2 dB")")
                } else {
                    Text("置信度 \(SourceTendencyAnalyzer.confidenceText(result.confidence))")
                    Text("·")
                    Text(SourceTendencyAnalyzer.typeText(result.noiseType))
                }
                Spacer()
                if result.audioID != nil {
                    Image(systemName: "waveform")
                        .font(.system(size: 10))
                        .foregroundColor(MeterTheme.secondaryText)
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(MeterTheme.tertiaryText)
            }
            .font(.system(size: 10.5))
            .foregroundColor(MeterTheme.secondaryText)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 11)
                .fill(MeterTheme.surfaceFill)
                .overlay(RoundedRectangle(cornerRadius: 11)
                    .stroke(MeterTheme.hairline, lineWidth: 1))
        )
    }

    private func monitorRow(_ session: MonitorSession) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(Self.rowDate.string(from: session.startTime))
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundColor(MeterTheme.primaryText)
                Spacer()
                if session.endTime == nil {
                    Text("进行中")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundColor(MeterTheme.waveColor)
                } else if session.abnormalEnd {
                    Text("异常结束")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundColor(MeterTheme.brass)
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(MeterTheme.tertiaryText)
            }
            HStack {
                Text("\(session.leqMetricLabel) \(String(format: "%.1f", session.overallLaeq)) dB")
                Text("·")
                Text("\(session.totalEventCount) 个异常事件")
                Spacer()
                Text("阈值 +\(Int(session.thresholdOverBackground)) dB")
            }
            .font(.system(size: 10.5))
            .foregroundColor(MeterTheme.secondaryText)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 11)
                .fill(MeterTheme.surfaceFill)
                .overlay(RoundedRectangle(cornerRadius: 11)
                    .stroke(MeterTheme.hairline, lineWidth: 1))
        )
    }

    private func emptyRecord(icon: String, title: String, subtitle: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 34))
                .foregroundColor(MeterTheme.tertiaryText)
            Text(title)
                .font(.system(size: 14))
                .foregroundColor(MeterTheme.secondaryText)
            Text(subtitle)
                .font(.system(size: 11))
                .foregroundColor(MeterTheme.tertiaryText)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var hasCurrentRecords: Bool {
        switch tab {
        case 0: return !store.records.isEmpty
        case 1: return !sourceStore.results.isEmpty
        default: return !monitorStore.sessions.isEmpty
        }
    }

    private var clearConfirmationTitle: String {
        switch tab {
        case 0: return "清空全部测量记录？"
        case 1: return "清空全部声源方向倾向记录？"
        default: return "清空全部监听记录？"
        }
    }

    private var clearActionTitle: String {
        switch tab {
        case 0: return "清空测量记录"
        case 1: return "清空声源方向倾向记录"
        default: return "清空监听记录"
        }
    }

    private func clearCurrentTab() {
        switch tab {
        case 0: store.removeAll()
        case 1: sourceStore.removeAll()
        default: monitorStore.removeAll()
        }
    }

    private static let rowDate: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter
    }()

    /// 用 NSSavePanel 保存 CSV
    private func exportCSV(text: String, filename: String) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = filename
        if panel.runModal() == .OK, let url = panel.url {
            try? text.data(using: .utf8)?.write(to: url)
        }
    }
}

/// 单条历史记录
private struct MacHistoryRow: View {
    let record: MeasurementStats
    let onExport: () -> Void
    let onDelete: () -> Void
    let onExportCSV: () -> Void

    private static let df: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(Self.df.string(from: record.startTime))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(MeterTheme.primaryText)
                Spacer()
                Button(action: onDelete) {
                    Image(systemName: "trash")
                        .font(.system(size: 11))
                        .foregroundColor(MeterTheme.tertiaryText)
                }
                .buttonStyle(.plain)
                Button(action: onExportCSV) {
                    Image(systemName: "tablecells")
                        .font(.system(size: 11))
                        .foregroundColor(MeterTheme.secondaryText)
                }
                .buttonStyle(.plain)
                Button(action: onExport) {
                    HStack(spacing: 4) {
                        Image(systemName: "square.and.arrow.up").font(.system(size: 11, weight: .semibold))
                        Text("导出").font(.system(size: 12, weight: .medium))
                    }
                    .foregroundColor(MeterTheme.waveColor)
                }
                .buttonStyle(.plain)
            }

            HStack(spacing: 0) {
                stat(record.laeqSPL, label: "\(record.leqMetricLabel) dB",
                     color: MeterTheme.waveColor)
                stat(record.avgSPL, label: "平均 dB", color: MeterTheme.primaryText)
                stat(record.peakSPL, label: "\(record.peakMetricLabel) dB",
                     color: MeterTheme.brass)
                stat(Float(record.duration), label: "时长(秒)",
                     color: MeterTheme.secondaryText, format: "%.0f")
            }

            if let lpeak = record.lpeakSPL {
                Text(lpeak.isFinite
                     ? String(format: "%@ %.1f dB · 采样峰值，无 F/S 时间计权",
                              record.lpeakMetricLabel, lpeak)
                     : "\(record.lpeakMetricLabel) --")
                    .font(.system(size: 10.5))
                    .foregroundColor(MeterTheme.secondaryText)
            }

            if record.overLimitTotal >= 1 {
                Label {
                    Text(String(format: "有 %.0f 秒超过 %.0f dB",
                                record.overLimitTotal,
                                record.resolvedExposureLimit))
                        .font(.system(size: 10.5))
                        .foregroundColor(MeterTheme.riskColor)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 9.5))
                        .foregroundColor(MeterTheme.riskColor)
                }
            }

            if !record.isCompleteCapture {
                Label("本次存在丢帧，统计仅覆盖已处理数据",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 10.5))
                    .foregroundColor(MeterTheme.brass)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(MeterTheme.surfaceFill)
                .overlay(RoundedRectangle(cornerRadius: 12)
                    .stroke(MeterTheme.hairline, lineWidth: 1))
        )
    }

    private func stat(_ value: Float, label: String, color: Color,
                      format: String = "%.1f") -> some View {
        VStack(spacing: 2) {
            Text(String(format: format, value))
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .foregroundColor(color)
                .monospacedDigit()
            Text(label)
                .font(.system(size: 9.5))
                .foregroundColor(MeterTheme.tertiaryText)
        }
        .frame(maxWidth: .infinity)
    }
}

/// 历史详情:报告图预览 + 录音回放 + 导出
struct MacReportPreviewSheet: View {
    let stats: MeasurementStats
    let store: MeasurementHistoryStore
    let deviceName: String
    let calibrationOffset: Float
    @Environment(\.dismiss) private var dismiss
    @StateObject private var player = RecordingPlayer()

    private static let df: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm"
        return f
    }()

    var body: some View {
        VStack(spacing: 14) {
            Text("测量简报")
                .font(.system(size: 14, weight: .bold))
                .foregroundColor(MeterTheme.primaryText)
            Text("\(Self.df.string(from: stats.startTime)) · 时长 \(RecordingPlayer.formatTime(stats.duration))")
                .font(.system(size: 11)).foregroundColor(MeterTheme.secondaryText)

            ScrollView(showsIndicators: false) {
                Image(nsImage: ReportRenderer.render(stats: stats, deviceName: deviceName,
                                                     calibrationOffset: calibrationOffset))
                    .resizable().scaledToFit()
                    .cornerRadius(8)
                    .padding(.horizontal, 4)
            }
            .frame(height: 330)

            if stats.audioID != nil {
                MacRecordingPlayerBar(player: player)
            }

            HStack(spacing: 10) {
                Button {
                    dismiss()
                } label: {
                    Text("取消")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(MeterTheme.secondaryText)
                        .frame(width: 74, height: 30)
                        .background(RoundedRectangle(cornerRadius: 8)
                            .fill(MeterTheme.surfaceStrongFill))
                }
                .buttonStyle(.plain)
                Button {
                    ReportExporter.export(stats: stats, deviceName: deviceName,
                                           calibrationOffset: calibrationOffset)
                } label: {
                    Text("导出 PNG")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(MeterTheme.primaryText)
                        .frame(width: 92, height: 30)
                        .background(RoundedRectangle(cornerRadius: 8)
                            .fill(MeterTheme.controlFill))
                }
                .buttonStyle(.plain)
                Button {
                    ReportExporter.exportHTML(stats: stats, deviceName: deviceName,
                                              calibrationOffset: calibrationOffset,
                                              audioURL: stats.audioID.map { store.audioFileURL(forID: $0) })
                    dismiss()
                } label: {
                    Text("导出完整报告")
                        .font(.system(size: 12, weight: .semibold)).foregroundColor(.white)
                        .frame(width: 110, height: 30)
                        .background(RoundedRectangle(cornerRadius: 8)
                            .fill(MeterTheme.primaryActionGradient))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(20)
        .frame(width: 400)
        .background(RoundedRectangle(cornerRadius: 16).fill(MeterTheme.panelGradient))
        .onAppear {
            if let id = stats.audioID {
                player.load(url: store.audioFileURL(forID: id))
            }
        }
        // 详情页关闭即停:AVAudioPlayer 独立于视图存活,不停会一直响
        .onDisappear { player.stop() }
    }
}

/// 录音回放条(macOS 风格)
struct MacRecordingPlayerBar: View {
    @ObservedObject var player: RecordingPlayer

    var body: some View {
        HStack(spacing: 10) {
            Button {
                player.togglePlayPause()
            } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(player.isAvailable ? MeterTheme.waveColor : MeterTheme.tertiaryText)
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(MeterTheme.waveColor.opacity(0.14)))
            }
            .buttonStyle(.plain)
            .disabled(!player.isAvailable)
            VStack(alignment: .leading, spacing: 2) {
                Text("现场录音").font(.system(size: 11))
                    .foregroundColor(MeterTheme.secondaryText)
                if player.isAvailable {
                    Text("\(RecordingPlayer.formatTime(player.progress * player.duration)) / \(RecordingPlayer.formatTime(player.duration))")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundColor(MeterTheme.tertiaryText)
                } else {
                    Text("录音不可用").font(.system(size: 9)).foregroundColor(MeterTheme.tertiaryText)
                }
            }
            Spacer()
            ProgressView(value: player.progress)
                .progressViewStyle(.linear)
                .frame(width: 80)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10)
            .fill(MeterTheme.surfaceFill))
    }
}
