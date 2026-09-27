//
//  SourceTestFlowView.swift
//  SoundSense iOS
//
//  三点声源倾向测试流程:引导 → 三点位计时(实时 LAeq + 倒计时 + 重测) → 结果卡。
//

import SwiftUI

struct SourceTestFlowView: View {
    @StateObject private var vm: SourceTestViewModel
    @Environment(\.dismiss) private var dismiss

    init(calibrationOffset: Float) {
        _vm = StateObject(wrappedValue: SourceTestViewModel(calibrationOffset: calibrationOffset))
    }

    var body: some View {
        NavigationView {
            Group {
                switch vm.phase {
                case .idle:
                    instruction
                case .running(let index):
                    running(index)
                case .finished:
                    resultCard
                case .failed(let message):
                    failed(message)
                }
            }
            .background(MeterTheme.backgroundGradient.ignoresSafeArea())
            .navigationTitle("声源定位")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("关闭") {
                        vm.abandon()
                        dismiss()
                    }
                    .foregroundColor(MeterTheme.waveColor)
                }
            }
        }
        .navigationViewStyle(.stack)
        .onChange(of: vm.engine.latestResult) { result in
            if let result = result {
                vm.consume(result)
            }
        }
    }

    // MARK: - 引导页

    private var instruction: some View {
        VStack(spacing: 18) {
            Image(systemName: "location.north.line")
                .font(.system(size: 42))
                .foregroundColor(MeterTheme.waveColor)
            Text("声源倾向测试")
                .font(.system(size: 22, weight: .bold))
                .foregroundColor(.white)
            VStack(alignment: .leading, spacing: 12) {
                step("1", "请在邻居噪音正在进行时开始测试")
                step("2", "依次在 3 个位置各测 30 秒:房间中央、靠近共用墙、举高靠天花板")
                step("3", "测完自动给出「倾向楼上/隔壁」的推测与置信度")
                step("4", "全程同步录音,作为证据保存在测试记录里")
            }
            .padding(16)
            .background(RoundedRectangle(cornerRadius: 14).fill(MeterTheme.cardBackground))

            Button {
                Task { await vm.begin() }
            } label: {
                Text("开始测试")
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

    private func step(_ n: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(n)
                .font(.system(size: 12, weight: .bold))
                .foregroundColor(MeterTheme.waveColor)
                .frame(width: 20, height: 20)
                .background(Circle().fill(MeterTheme.waveColor.opacity(0.15)))
            Text(text)
                .font(.system(size: 13))
                .foregroundColor(.white.opacity(0.8))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - 测量中

    private func running(_ index: Int) -> some View {
        let position = SourceTestViewModel.positions[index]
        return VStack(spacing: 22) {
            Text("第 \(index + 1)/3 步 · \(position.name)")
                .font(.system(size: 18, weight: .bold))
                .foregroundColor(.white)
            Text(position.hint)
                .font(.system(size: 13))
                .foregroundColor(.white.opacity(0.6))
                .multilineTextAlignment(.center)

            ZStack {
                Circle()
                    .stroke(.white.opacity(0.08), lineWidth: 10)
                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(MeterTheme.waveColor, style: StrokeStyle(lineWidth: 10, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                VStack(spacing: 2) {
                    Text("\(vm.secondsLeft)")
                        .font(.system(size: 52, weight: .heavy, design: .rounded))
                        .foregroundColor(.white)
                        .monospacedDigit()
                    Text("秒")
                        .font(.system(size: 12))
                        .foregroundColor(.white.opacity(0.45))
                }
            }
            .frame(width: 180, height: 180)

            VStack(spacing: 4) {
                Text(laeqText)
                    .font(.system(size: 34, weight: .semibold, design: .rounded))
                    .foregroundColor(MeterTheme.waveColor)
                    .monospacedDigit()
                Text("本点位 LAeq")
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.45))
            }

            Button {
                vm.redoCurrentPosition()
            } label: {
                Label("重测本点位", systemImage: "arrow.counterclockwise")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.white.opacity(0.7))
            }
            .buttonStyle(.plain)
            Spacer()
        }
        .padding(20)
    }

    private var progress: CGFloat {
        CGFloat(SourceTestViewModel.secondsPerPosition - Double(vm.secondsLeft))
            / CGFloat(SourceTestViewModel.secondsPerPosition)
    }

    private var laeqText: String {
        vm.currentLaeq.isFinite ? String(format: "%.1f dB", vm.currentLaeq) : "--"
    }

    // MARK: - 结果

    private var resultCard: some View {
        ScrollView {
            VStack(spacing: 16) {
                if let result = vm.latestResult {
                    SourceTestResultCard(result: result)
                    Button {
                        dismiss()
                    } label: {
                        Text("完成")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity, minHeight: 46)
                            .background(RoundedRectangle(cornerRadius: 12)
                                .fill(MeterTheme.waveColor.opacity(0.9)))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(20)
        }
    }

    private func failed(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 36))
                .foregroundColor(.orange)
            Text(message)
                .font(.system(size: 14))
                .foregroundColor(.white.opacity(0.7))
        }
        .padding(30)
    }
}

/// 结果卡(流程结果页与历史详情共用)
struct SourceTestResultCard: View {
    let result: SourceTestResult

    var body: some View {
        VStack(spacing: 14) {
            VStack(spacing: 6) {
                Text(SourceTestHTMLBuilder.verdictText(result.verdict))
                    .font(.system(size: 30, weight: .heavy))
                    .foregroundColor(MeterTheme.waveColor)
                Text("置信度 \(SourceTestHTMLBuilder.confidenceText(result.confidence)) · \(SourceTestHTMLBuilder.typeText(result.noiseType)) · 推测仅供参考")
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.5))
            }

            VStack(spacing: 10) {
                let maxLaeq = max(result.positions.map { $0.laeq }.max() ?? 1, 1)
                ForEach(Array(result.positions.enumerated()), id: \.offset) { _, p in
                    HStack(spacing: 10) {
                        Text(p.name)
                            .font(.system(size: 12))
                            .foregroundColor(.white.opacity(0.7))
                            .frame(width: 84, alignment: .leading)
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(.white.opacity(0.06))
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(MeterTheme.waveColor)
                                    .frame(width: geo.size.width
                                        * max(0.04, CGFloat(p.laeq / maxLaeq)))
                            }
                        }
                        .frame(height: 12)
                        Text(String(format: "%.1f dB · %d 次", p.laeq, p.eventCount))
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(.white.opacity(0.5))
                            .frame(width: 110, alignment: .trailing)
                    }
                }
            }
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 12).fill(MeterTheme.cardBackground))
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(MeterTheme.cardBackground)
                .overlay(RoundedRectangle(cornerRadius: 16)
                    .stroke(MeterTheme.cardBorder, lineWidth: 1))
        )
    }
}
