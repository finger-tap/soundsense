//
//  SourceTestListView.swift
//  SoundSense iOS
//
//  三点测试记录列表 + 详情(结论/三点位/录音回放/HTML 分享)。
//

import SwiftUI
import UIKit

struct SourceTestListView: View {
    @ObservedObject var store: SourceTestStore
    let deviceName: String
    @Environment(\.dismiss) private var dismiss
    @State private var selected: SourceTestResult?
    @State private var sharingHTML: SourceTestResult?

    var body: some View {
        NavigationView {
            Group {
                if store.results.isEmpty {
                    empty
                } else {
                    list
                }
            }
            .background(MeterTheme.backgroundGradient.ignoresSafeArea())
            .navigationTitle("测试记录")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    if !store.results.isEmpty {
                        Button(role: .destructive) {
                            store.removeAll()
                        } label: {
                            Text("清空").font(.system(size: 14))
                        }
                    }
                }
            }
        }
        .navigationViewStyle(.stack)
        .sheet(item: $selected) { result in
            SourceTestDetailView(result: result, store: store, deviceName: deviceName)
        }
        .sheet(item: $sharingHTML) { result in
            SourceTestHTMLShareSheet(result: result, deviceName: deviceName,
                                     audioURL: result.audioID.map { store.audioFileURL(forID: $0) })
        }
    }

    private var empty: some View {
        VStack(spacing: 10) {
            Image(systemName: "location")
                .font(.system(size: 40))
                .foregroundColor(.white.opacity(0.3))
            Text("还没有测试记录")
                .font(.system(size: 15))
                .foregroundColor(MeterTheme.secondaryText)
            Text("完成一次声源倾向测试后,结果会保存在这里")
                .font(.system(size: 12))
                .foregroundColor(MeterTheme.secondaryText)
        }
    }

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                ForEach(store.results) { result in
                    Button {
                        selected = result
                    } label: {
                        row(result)
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button {
                            sharingHTML = result
                        } label: {
                            Label("分享完整报告", systemImage: "doc.richtext")
                        }
                        if let index = store.results.firstIndex(where: { $0.id == result.id }) {
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

    private func row(_ result: SourceTestResult) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(Self.df.string(from: result.startTime))
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.white)
                Spacer()
                Text(SourceTestHTMLBuilder.verdictText(result.verdict))
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(MeterTheme.waveColor)
            }
            HStack {
                Text("置信度 \(SourceTestHTMLBuilder.confidenceText(result.confidence)) · \(SourceTestHTMLBuilder.typeText(result.noiseType))")
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.55))
                Spacer()
                if result.audioID == nil {
                    Text("无录音").font(.system(size: 11))
                        .foregroundColor(MeterTheme.secondaryText)
                } else {
                    Image(systemName: "waveform")
                        .font(.system(size: 11))
                        .foregroundColor(MeterTheme.secondaryText)
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

    private static let df: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm"
        return f
    }()
}

/// 测试详情:结论卡 + 录音回放 + HTML 分享
struct SourceTestDetailView: View {
    let result: SourceTestResult
    let store: SourceTestStore
    let deviceName: String
    @Environment(\.dismiss) private var dismiss
    @StateObject private var player = RecordingPlayer()
    @State private var sharingHTML = false

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 14) {
                    SourceTestResultCard(result: result)
                    if let id = result.audioID {
                        RecordingPlayerBar(player: player)
                            .onAppear { player.load(url: store.audioFileURL(forID: id)) }
                    }
                    Button {
                        sharingHTML = true
                    } label: {
                        Label("分享完整报告", systemImage: "doc.richtext")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity, minHeight: 42)
                            .background(RoundedRectangle(cornerRadius: 10)
                                .fill(MeterTheme.waveColor.opacity(0.85)))
                    }
                    .buttonStyle(.plain)
                }
                .padding(16)
            }
            .background(MeterTheme.backgroundGradient.ignoresSafeArea())
            .navigationTitle("测试详情")
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
            SourceTestHTMLShareSheet(result: result, deviceName: deviceName,
                                     audioURL: result.audioID.map { store.audioFileURL(forID: $0) })
        }
    }
}

/// HTML 分享(临时文件 + ActivityViewController)
struct SourceTestHTMLShareSheet: UIViewControllerRepresentable {
    let result: SourceTestResult
    let deviceName: String
    let audioURL: URL?

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let audioBase64 = audioURL.flatMap { try? Data(contentsOf: $0) }?.base64EncodedString()
        let html = SourceTestHTMLBuilder.build(result: result, deviceName: deviceName,
                                               audioBase64: audioBase64)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(SourceTestHTMLBuilder.filename(for: result))
        if let data = html.data(using: .utf8) {
            try? data.write(to: url, options: [.atomic])
        }
        return UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }

    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}
