//
//  HistoryView.swift
//  SoundSense iOS
//
//  测量历史列表:回看每次测量的统计,可重新导出报告,左滑删除。
//

import SwiftUI
import UIKit

/// CSV 文件分享(iOS ActivityViewController 包装)
struct CSVShareSheet: UIViewControllerRepresentable {
    let text: String
    let filename: String

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
        try? text.data(using: .utf8)?.write(to: url)
        return UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }

    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}

struct HistoryView: View {
    @ObservedObject var store: MeasurementHistoryStore
    let deviceName: String
    let calibrationOffset: Float
    @Environment(\.dismiss) private var dismiss
    @State private var sharingStats: MeasurementStats?
    @State private var sharingCSV: CSVItem?
    @State private var selectedRecord: MeasurementStats?

    var body: some View {
        NavigationView {
            Group {
                if store.records.isEmpty {
                    emptyState
                } else {
                    list
                }
            }
            .navigationTitle("测量历史")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("完成") { dismiss() }
                        .foregroundColor(MeterTheme.waveColor)
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    if !store.records.isEmpty {
                        HStack(spacing: 14) {
                            Button {
                                sharingCSV = CSVItem(
                                    text: MeasurementCSV.csv(forAll: store.records),
                                    filename: "闻声数据_全部记录.csv")
                            } label: {
                                Text("CSV").font(.system(size: 14))
                            }
                            Button(role: .destructive) {
                                store.removeAll()
                            } label: {
                                Text("清空").font(.system(size: 14))
                            }
                        }
                    }
                }
            }
        }
        .navigationViewStyle(.stack)
        .sheet(item: $sharingStats) { stats in
            ReportShareSheet(stats: stats,
                             deviceName: deviceName,
                             calibrationOffset: calibrationOffset)
        }
        .sheet(item: $selectedRecord) { record in
            HistoryDetailSheet(record: record, store: store,
                               deviceName: deviceName,
                               calibrationOffset: calibrationOffset)
        }
        .sheet(item: $sharingCSV) { item in
            CSVShareSheet(text: item.text, filename: item.filename)
        }
    }

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                ForEach(Array(store.records.enumerated()), id: \.offset) { index, record in
                    HistoryRow(record: record) {
                        selectedRecord = record
                    } .contextMenu {
                        Button {
                            selectedRecord = record
                        } label: {
                            Label("查看详情与录音", systemImage: "waveform")
                        }
                        Button {
                            sharingStats = record
                        } label: {
                            Label("导出报告 PNG", systemImage: "square.and.arrow.up")
                        }
                        Button {
                            sharingCSV = CSVItem(
                                text: MeasurementCSV.csv(for: record),
                                filename: MeasurementCSV.filename(for: record))
                        } label: {
                            Label("导出数据 CSV", systemImage: "tablecells")
                        }
                        Button(role: .destructive) {
                            store.delete(at: IndexSet(integer: index))
                        } label: {
                            Label("删除", systemImage: "trash")
                        }
                    }
                }
            }
            .padding(.horizontal, 20).padding(.vertical, 12)
        }
        .background(MeterTheme.backgroundGradient.ignoresSafeArea())
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 40))
                .foregroundColor(.white.opacity(0.3))
            Text("还没有测量记录")
                .font(.system(size: 15))
                .foregroundColor(MeterTheme.secondaryText)
            Text("完成一次测量后,报告会自动保存在这里")
                .font(.system(size: 12))
                .foregroundColor(MeterTheme.secondaryText)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(MeterTheme.backgroundGradient.ignoresSafeArea())
    }
}

/// CSV 分享内容包装(供 sheet(item:) 用)
struct CSVItem: Identifiable {
    let id = UUID()
    let text: String
    let filename: String
}

/// 单条历史记录卡片
struct HistoryRow: View {
    let record: MeasurementStats
    let onExport: () -> Void

    private static let dateFormatter: DateFormatter = {
        let df = DateFormatter()
        df.dateFormat = "MM-dd HH:mm"
        return df
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(Self.dateFormatter.string(from: record.startTime))
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.white)
                Spacer()
                Button(action: onExport) {
                    Image(systemName: "square.and.arrow.up")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(MeterTheme.waveColor)
                }
                .buttonStyle(.plain)
            }

            HStack(spacing: 0) {
                stat(value: record.laeqSPL, label: "LAeq", color: MeterTheme.waveColor)
                stat(value: record.avgSPL, label: "平均", color: .white.opacity(0.85))
                stat(value: record.peakSPL, label: "峰值", color: Color(red: 1.0, green: 0.6, blue: 0.2))
                stat(value: Float(Int(record.duration)), label: "秒", color: .white.opacity(0.6),
                     format: "%.0f")
            }

            if record.overLimitTotal >= 1 {
                Label {
                    Text(String(format: "有 %.0f 秒超过 85 dB", record.overLimitTotal))
                        .font(.system(size: 11))
                        .foregroundColor(Color(red: 1.0, green: 0.5, blue: 0.4))
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 10))
                        .foregroundColor(Color(red: 1.0, green: 0.5, blue: 0.4))
                }
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

    private func stat(value: Float, label: String, color: Color,
                      format: String = "%.1f") -> some View {
        VStack(spacing: 2) {
            Text(String(format: format, value))
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .foregroundColor(color)
                .monospacedDigit()
            Text(label)
                .font(.system(size: 10))
                .foregroundColor(MeterTheme.secondaryText)
        }
        .frame(maxWidth: .infinity)
    }
}

/// 历史详情:完整简报(报告图)+ 录音回放 + 双格式导出
struct HistoryDetailSheet: View {
    let record: MeasurementStats
    let store: MeasurementHistoryStore
    let deviceName: String
    let calibrationOffset: Float
    @Environment(\.dismiss) private var dismiss
    @StateObject private var player = RecordingPlayer()
    @State private var sharingPNG = false
    @State private var sharingHTML = false

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 14) {
                    Image(uiImage: ReportRenderer.render(stats: record,
                                                         deviceName: deviceName,
                                                         calibrationOffset: calibrationOffset))
                        .resizable().scaledToFit()
                        .cornerRadius(12)
                    if record.audioID != nil {
                        RecordingPlayerBar(player: player)
                    }
                    HStack(spacing: 12) {
                        Button {
                            sharingPNG = true
                        } label: {
                            Label("分享图片", systemImage: "photo")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(.white)
                                .frame(maxWidth: .infinity, minHeight: 38)
                                .background(RoundedRectangle(cornerRadius: 10)
                                    .fill(.white.opacity(0.08)))
                        }
                        .buttonStyle(.plain)
                        Button {
                            sharingHTML = true
                        } label: {
                            Label("分享完整报告", systemImage: "doc.richtext")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundColor(.white)
                                .frame(maxWidth: .infinity, minHeight: 38)
                                .background(RoundedRectangle(cornerRadius: 10)
                                    .fill(MeterTheme.waveColor.opacity(0.85)))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(16)
            }
            .background(MeterTheme.backgroundGradient.ignoresSafeArea())
            .navigationTitle("测量简报")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("完成") { dismiss() }
                        .foregroundColor(MeterTheme.waveColor)
                }
            }
            .onAppear {
                if let id = record.audioID {
                    player.load(url: store.audioFileURL(forID: id))
                }
            }
        }
        .navigationViewStyle(.stack)
        .sheet(isPresented: $sharingPNG) {
            ReportShareSheet(stats: record, deviceName: deviceName,
                             calibrationOffset: calibrationOffset)
        }
        .sheet(isPresented: $sharingHTML) {
            HTMLShareSheet(stats: record, deviceName: deviceName,
                           calibrationOffset: calibrationOffset,
                           audioURL: record.audioID.map { store.audioFileURL(forID: $0) })
        }
    }
}

/// 录音回放条(iOS 风格)
struct RecordingPlayerBar: View {
    @ObservedObject var player: RecordingPlayer

    var body: some View {
        HStack(spacing: 12) {
            Button {
                player.togglePlayPause()
            } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(player.isAvailable ? MeterTheme.waveColor : .white.opacity(0.3))
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(MeterTheme.waveColor.opacity(0.14)))
            }
            .buttonStyle(.plain)
            .disabled(!player.isAvailable)
            VStack(alignment: .leading, spacing: 3) {
                Text("现场录音").font(.system(size: 12)).foregroundColor(.white.opacity(0.7))
                if player.isAvailable {
                    Text("\(RecordingPlayer.formatTime(player.progress * player.duration)) / \(RecordingPlayer.formatTime(player.duration))")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(MeterTheme.secondaryText)
                } else {
                    Text("录音不可用").font(.system(size: 10))
                        .foregroundColor(MeterTheme.secondaryText)
                }
            }
            Spacer()
            ProgressView(value: player.progress)
                .progressViewStyle(.linear)
                .tint(MeterTheme.waveColor)
                .frame(width: 90)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(MeterTheme.cardBackground))
    }
}

/// HTML 完整报告分享(临时文件 + ActivityViewController)
struct HTMLShareSheet: UIViewControllerRepresentable {
    let stats: MeasurementStats
    let deviceName: String
    let calibrationOffset: Float
    let audioURL: URL?

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let image = ReportRenderer.render(stats: stats, deviceName: deviceName,
                                          calibrationOffset: calibrationOffset)
        let pngBase64 = (image.pngData() ?? Data()).base64EncodedString()
        let audioBase64 = audioURL.flatMap { try? Data(contentsOf: $0) }?.base64EncodedString()
        let html = ReportHTMLBuilder.build(stats: stats, deviceName: deviceName,
                                           calibrationOffset: calibrationOffset,
                                           pngBase64: pngBase64, audioBase64: audioBase64)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(ReportHTMLBuilder.filename(for: stats))
        if let data = html.data(using: .utf8) {
            try? data.write(to: url, options: [.atomic])
        }
        return UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }

    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}
