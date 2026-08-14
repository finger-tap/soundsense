//
//  WatchSettingsView.swift
//  SoundSenseWatch
//
//  watchOS 校准设置:偏移量滑块(数字表冠不可用,用滑块),
//  与 iOS/macOS 的设置语义一致。
//

import SwiftUI

struct WatchSettingsView: View {
    @ObservedObject var viewModel: WatchMeterViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("校准")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundColor(.white)

                Text("麦克风采集 dBFS,加偏移量换算成 SPL。默认 +93 适用多数手表。")
                    .font(.system(size: 11))
                    .foregroundColor(MeterTheme.secondaryText)

                Text(String(format: "%+.1f dB", viewModel.calibrationOffset))
                    .font(.system(size: 20, weight: .semibold, design: .monospaced))
                    .foregroundColor(MeterTheme.waveColor)
                    .frame(maxWidth: .infinity)

                Slider(value: Binding(
                    get: { Double(viewModel.calibrationOffset) },
                    set: { viewModel.calibrationOffset = Float($0) }
                ), in: 60...110, step: 0.5)
                .tint(MeterTheme.waveColor)

                HStack {
                    Text("60").font(.system(size: 9))
                    Spacer()
                    Text("85").font(.system(size: 9))
                    Spacer()
                    Text("110").font(.system(size: 9))
                }
                .foregroundColor(MeterTheme.secondaryText)

                Button {
                    viewModel.calibrationOffset = 93
                } label: {
                    Text("恢复默认 (+93)")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(RoundedRectangle(cornerRadius: 10)
                            .fill(.white.opacity(0.08)))
                }
                .buttonStyle(.plain)

                Button("完成") { dismiss() }
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(MeterTheme.waveColor)
                    .frame(maxWidth: .infinity)
            }
            .padding(.horizontal, 4)
        }
        .background(MeterTheme.backgroundGradient.ignoresSafeArea())
    }
}
