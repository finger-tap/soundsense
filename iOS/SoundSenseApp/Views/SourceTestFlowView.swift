//
//  SourceTestFlowView.swift
//  SoundSense iOS
//
//  声源方向倾向测试流程:引导 → 四点位计时(实时 LAeq + 倒计时 + 重测) → 结果卡。
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
            ZStack {
                // 背景独立满铺:不能挂在 Group 上(Group 修饰符逐子视图生效,
                // 内容窄时两侧会露出系统底色)
                MeterTheme.backgroundGradient.ignoresSafeArea()
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
            .navigationTitle("声源方向倾向")
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
        .onDisappear {
            vm.abandon()
        }
    }

    // MARK: - 引导页

    private var instruction: some View {
        VStack(spacing: 18) {
            Image(systemName: "location.north.line")
                .font(.system(size: 42))
                .foregroundColor(MeterTheme.waveColor)
            Text("声源方向倾向测试")
                .font(.system(size: 22, weight: .bold))
                .foregroundColor(.white)
            VStack(alignment: .leading, spacing: 12) {
                step("1", "请在待判断的噪音正在进行时开始")
                step("2", "依次在 4 个位置各测 30 秒：中央 → 共用墙 → 靠天花板 → 回中央复测")
                step("3", "中央前后变化超过 2 dB 时判为环境不稳定，不给出方向结论")
                step("4", "全程同步录音；结果是方向倾向推测，不是三维定位或取证结论")
            }
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(MeterTheme.panelGradient)
                    .overlay(RoundedRectangle(cornerRadius: 14)
                        .stroke(MeterTheme.cardBorder, lineWidth: 1))
            )

            Button {
                Task { await vm.begin() }
            } label: {
                HStack(spacing: 8) {
                    if vm.engine.state == .starting {
                        ProgressView().tint(.white).scaleEffect(0.8)
                    } else {
                        Image(systemName: "dot.radiowaves.left.and.right")
                    }
                    Text(vm.engine.state == .starting ? "正在启动..." : "开始测试")
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
            Text("第 \(index + 1)/\(SourceTestViewModel.positions.count) 步 · \(position.name)")
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
                    .foregroundColor(MeterTheme.secondaryText)
                    .padding(.horizontal, 14)
                    .frame(minHeight: 40)
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
                                .fill(MeterTheme.primaryActionGradient))
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
                Text(result.rejectedByDrift
                     ? "环境变化过大"
                     : SourceTestHTMLBuilder.verdictText(result.verdict))
                    .font(.system(size: 30, weight: .heavy))
                    .foregroundColor(MeterTheme.waveColor)
                Text(detailText)
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.5))
            }

            VStack(spacing: 10) {
                let minLaeq = result.positions.map { $0.laeq }.filter { $0.isFinite }.min() ?? 0
                let maxLaeq = max(result.positions.map(\.laeq).max() ?? 1, 1)
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
                                        * max(0.04, CGFloat(
                                            (p.laeq - minLaeq) / max(1, maxLaeq - minLaeq))))
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
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(MeterTheme.panelGradient)
                    .overlay(RoundedRectangle(cornerRadius: 12)
                        .stroke(MeterTheme.cardBorder, lineWidth: 1))
            )
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(MeterTheme.panelGradient)
                .overlay(RoundedRectangle(cornerRadius: 16)
                    .stroke(MeterTheme.cardBorder, lineWidth: 1))
        )
    }

    private var detailText: String {
        if result.rejectedByDrift {
            let drift = result.centerDrift.map { String(format: "%.1f dB", $0) } ?? "超过 2 dB"
            return "中央复测漂移 \(drift) · 请保持声源稳定后重新测试"
        }
        let drift = result.centerDrift.map {
            String(format: " · 中央漂移 %.1f dB", $0)
        } ?? ""
        return "置信度 \(SourceTestHTMLBuilder.confidenceText(result.confidence)) · \(SourceTestHTMLBuilder.typeText(result.noiseType))\(drift) · 方向倾向仅供参考"
    }
}
