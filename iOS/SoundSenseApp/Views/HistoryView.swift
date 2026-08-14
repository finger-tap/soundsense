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
        .sheet(item: $sharingCSV) { item in
            CSVShareSheet(text: item.text, filename: item.filename)
        }
    }

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                ForEach(Array(store.records.enumerated()), id: \.offset) { index, record in
                    HistoryRow(record: record) {
                        sharingStats = record
                    }
                    .contextMenu {
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
