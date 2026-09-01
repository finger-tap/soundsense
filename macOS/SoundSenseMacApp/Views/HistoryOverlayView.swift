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
    let deviceName: String
    let calibrationOffset: Float
    @Binding var isPresented: Bool
    @State private var sharingStats: MeasurementStats?

    var body: some View {
        ZStack {
            Color.black.opacity(0.45)
                .ignoresSafeArea()
                .onTapGesture { isPresented = false }

            VStack(spacing: 0) {
                header
                content
            }
            .frame(width: 480, height: 560)
            .background(
                RoundedRectangle(cornerRadius: 18)
                    .fill(MeterTheme.panel)
                    .overlay(RoundedRectangle(cornerRadius: 18)
                        .stroke(.white.opacity(0.1), lineWidth: 1))
            )
            .shadow(color: .black.opacity(0.5), radius: 30, y: 10)
        }
        .sheet(item: $sharingStats) { stats in
            MacReportPreviewSheet(stats: stats,
                                  store: store,
                                  deviceName: deviceName,
                                  calibrationOffset: calibrationOffset)
        }
    }

    private var header: some View {
        HStack {
            Text("测量历史").font(.system(size: 16, weight: .bold)).foregroundColor(.white)
            Spacer()
            if !store.records.isEmpty {
                Button {
                    exportCSV(text: MeasurementCSV.csv(forAll: store.records),
                              filename: "闻声数据_全部记录.csv")
                } label: {
                    Text("CSV").font(.system(size: 12))
                        .foregroundColor(Color(red: 0.24, green: 0.83, blue: 0.69))
                }
                .buttonStyle(.plain)
                Button {
                    store.removeAll()
                } label: {
                    Text("清空").font(.system(size: 12))
                        .foregroundColor(Color(red: 1.0, green: 0.45, blue: 0.4))
                }
                .buttonStyle(.plain)
            }
            Button {
                isPresented = false
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white.opacity(0.5))
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(.white.opacity(0.1)))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 20).padding(.top, 18).padding(.bottom, 14)
    }

    @ViewBuilder
    private var content: some View {
        if store.records.isEmpty {
            VStack(spacing: 10) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 34))
                    .foregroundColor(.white.opacity(0.3))
                Text("还没有测量记录")
                    .font(.system(size: 14)).foregroundColor(.white.opacity(0.5))
                Text("完成一次测量后,报告会自动保存在这里")
                    .font(.system(size: 11)).foregroundColor(.white.opacity(0.35))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
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
                    .font(.system(size: 13, weight: .semibold)).foregroundColor(.white)
                Spacer()
                Button(action: onDelete) {
                    Image(systemName: "trash")
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.4))
                }
                .buttonStyle(.plain)
                Button(action: onExportCSV) {
                    Image(systemName: "tablecells")
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.5))
                }
                .buttonStyle(.plain)
                .help("导出 CSV")
                Button(action: onExport) {
                    HStack(spacing: 4) {
                        Image(systemName: "square.and.arrow.up").font(.system(size: 11, weight: .semibold))
                        Text("导出").font(.system(size: 12, weight: .medium))
                    }
                    .foregroundColor(Color(red: 0.24, green: 0.83, blue: 0.69))
                }
                .buttonStyle(.plain)
            }

            HStack(spacing: 0) {
                stat(record.laeqSPL, label: "LAeq dB", color: Color(red: 0.24, green: 0.83, blue: 0.69))
                stat(record.avgSPL, label: "平均 dB", color: .white.opacity(0.85))
                stat(record.peakSPL, label: "峰值 dB", color: Color(red: 1.0, green: 0.6, blue: 0.2))
                stat(Float(record.duration), label: "时长(秒)", color: .white.opacity(0.6), format: "%.0f")
            }

            if record.overLimitTotal >= 1 {
                Label {
                    Text(String(format: "有 %.0f 秒超过 85 dB", record.overLimitTotal))
                        .font(.system(size: 10.5))
                        .foregroundColor(Color(red: 1.0, green: 0.5, blue: 0.4))
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 9.5))
                        .foregroundColor(Color(red: 1.0, green: 0.5, blue: 0.4))
                }
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(.white.opacity(0.04))
                .overlay(RoundedRectangle(cornerRadius: 12)
                    .stroke(.white.opacity(0.07), lineWidth: 1))
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
                .foregroundColor(.white.opacity(0.4))
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
                .font(.system(size: 14, weight: .bold)).foregroundColor(.white)
            Text("\(Self.df.string(from: stats.startTime)) · 时长 \(RecordingPlayer.formatTime(stats.duration))")
                .font(.system(size: 11)).foregroundColor(.white.opacity(0.5))

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
                        .font(.system(size: 12, weight: .medium)).foregroundColor(.white.opacity(0.7))
                        .frame(width: 74, height: 30)
                        .background(RoundedRectangle(cornerRadius: 8).fill(.white.opacity(0.08)))
                }
                .buttonStyle(.plain)
                Button {
                    ReportExporter.export(stats: stats, deviceName: deviceName,
                                           calibrationOffset: calibrationOffset)
                } label: {
                    Text("导出 PNG")
                        .font(.system(size: 12, weight: .medium)).foregroundColor(.white)
                        .frame(width: 92, height: 30)
                        .background(RoundedRectangle(cornerRadius: 8).fill(.white.opacity(0.12)))
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
                            .fill(Color(red: 0.24, green: 0.83, blue: 0.69).opacity(0.85)))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(20)
        .frame(width: 400)
        .background(RoundedRectangle(cornerRadius: 16).fill(MeterTheme.panel))
        .onAppear {
            if let id = stats.audioID {
                player.load(url: store.audioFileURL(forID: id))
            }
        }
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
                    .foregroundColor(player.isAvailable ? Color(red: 0.24, green: 0.83, blue: 0.69) : .white.opacity(0.3))
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(Color(red: 0.24, green: 0.83, blue: 0.69).opacity(0.14)))
            }
            .buttonStyle(.plain)
            .disabled(!player.isAvailable)
            VStack(alignment: .leading, spacing: 2) {
                Text("现场录音").font(.system(size: 11)).foregroundColor(.white.opacity(0.7))
                if player.isAvailable {
                    Text("\(RecordingPlayer.formatTime(player.progress * player.duration)) / \(RecordingPlayer.formatTime(player.duration))")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundColor(.white.opacity(0.4))
                } else {
                    Text("录音不可用").font(.system(size: 9)).foregroundColor(.white.opacity(0.4))
                }
            }
            Spacer()
            ProgressView(value: player.progress)
                .progressViewStyle(.linear)
                .frame(width: 80)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(.white.opacity(0.05)))
    }
}
