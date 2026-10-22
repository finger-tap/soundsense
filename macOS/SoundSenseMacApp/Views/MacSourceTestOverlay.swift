//
//  MacSourceTestOverlay.swift
//  SoundSenseMac
//
//  macOS 声源方向倾向工具：四点走位测试、结果卡、录音与 HTML 报告。
//

import SwiftUI
import SoundSenseCore

struct MacSourceTestOverlay: View {
    @StateObject private var vm: MacSourceTestViewModel
    @Binding var isPresented: Bool
    @Environment(\.openURL) private var openURL

    init(calibrationOffset: Float,
         inputDeviceUID: String?,
         weighting: Weighting,
         timeWeighting: TimeWeighting,
         isPresented: Binding<Bool>) {
        _isPresented = isPresented
        _vm = StateObject(wrappedValue: MacSourceTestViewModel(
            calibrationOffset: calibrationOffset,
            inputDeviceUID: inputDeviceUID,
            weighting: weighting,
            timeWeighting: timeWeighting))
    }

    var body: some View {
        ZStack {
            MeterTheme.overlayScrim
                .ignoresSafeArea()
                .onTapGesture {
                    if case .running = vm.phase { return }
                    close()
                }

            VStack(spacing: 0) {
                header
                Divider().overlay(MeterTheme.hairline)
                content
            }
            .frame(width: 720, height: 540)
            .background(
                RoundedRectangle(cornerRadius: 20)
                    .fill(MeterTheme.panelGradient)
                    .overlay(RoundedRectangle(cornerRadius: 20)
                        .stroke(MeterTheme.hairline, lineWidth: 1))
            )
            .shadow(color: .black.opacity(0.55), radius: 36, y: 14)
        }
        .onAppear {
            _ = vm.engine.refreshInputAvailability()
        }
        .onDisappear {
            vm.abandon()
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(MeterTheme.waveColor.opacity(0.13))
                    .frame(width: 34, height: 34)
                Image(systemName: "dot.radiowaves.left.and.right")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(MeterTheme.waveColor)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("声源方向倾向")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundColor(MeterTheme.primaryText)
                Text("四点位增益与漂移校验 · 结果仅供方向性参考")
                    .font(.system(size: 10.5))
                    .foregroundColor(MeterTheme.tertiaryText)
            }
            Spacer()
            phasePill
            Button(action: close) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(MeterTheme.secondaryText)
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(MeterTheme.surfaceStrongFill))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("关闭声源方向倾向")
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 16)
    }

    @ViewBuilder
    private var phasePill: some View {
        switch vm.phase {
        case .idle:
            toolPill("准备", color: MeterTheme.secondaryText)
        case .running(let index):
            toolPill("第 \(index + 1)/\(MacSourceTestViewModel.positions.count) 点位",
                     color: MeterTheme.waveColor)
        case .finished:
            toolPill("已完成", color: MeterTheme.waveColor)
        case .failed:
            toolPill("启动失败", color: MeterTheme.riskColor)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch vm.phase {
        case .idle:
            instruction
        case .running(let index):
            running(index)
        case .finished:
            result
        case .failed(let message):
            failed(message)
        }
    }

    // MARK: - 引导

    private var instruction: some View {
        HStack(alignment: .top, spacing: 22) {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text("4 × 30")
                        .font(.system(size: 44, weight: .heavy, design: .rounded))
                        .foregroundColor(MeterTheme.primaryText)
                        .monospacedDigit()
                    Text("秒")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(MeterTheme.waveColor)
                }
                Text("请在待判断噪音发生时完成四个点位。系统比较靠墙与靠顶的声级增益，并用回到中央的复测检查环境是否稳定。")
                    .font(.system(size: 12.5))
                    .foregroundColor(MeterTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)

                VStack(spacing: 10) {
                    ForEach(Array(MacSourceTestViewModel.positions.enumerated()), id: \.offset) { index, item in
                        HStack(alignment: .top, spacing: 11) {
                            Text("\(index + 1)")
                                .font(.system(size: 10, weight: .bold, design: .monospaced))
                                .foregroundColor(MeterTheme.waveColor)
                                .frame(width: 24, height: 24)
                                .background(Circle().fill(MeterTheme.waveColor.opacity(0.13)))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.name)
                                    .font(.system(size: 12.5, weight: .semibold))
                                    .foregroundColor(MeterTheme.primaryText)
                                Text(item.hint)
                                    .font(.system(size: 10.5))
                                    .foregroundColor(MeterTheme.tertiaryText)
                            }
                            Spacer()
                            Text("30s")
                                .font(.system(size: 10, weight: .medium, design: .monospaced))
                                .foregroundColor(MeterTheme.secondaryText)
                        }
                        .padding(11)
                        .background(RoundedRectangle(cornerRadius: 10)
                            .fill(MeterTheme.surfaceFill))
                    }
                }

                Label("单麦克风无法给出真实三维定位；结论是方向倾向推测，不是取证级结论。",
                      systemImage: "info.circle")
                    .font(.system(size: 10.5))
                    .foregroundColor(MeterTheme.tertiaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .leading, spacing: 14) {
                Text("测试准备")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(MeterTheme.primaryText)
                readinessRow(icon: "mic.fill",
                             title: "输入设备",
                             value: vm.engine.hasAudioInput ? "已就绪" : "未检测到麦克风",
                             warning: !vm.engine.hasAudioInput)
                readinessRow(icon: "waveform.path.ecg",
                             title: "测试录音",
                             value: "自动保存现场录音",
                             warning: false)
                readinessRow(icon: "clock",
                             title: "预计用时",
                             value: "约 2 分钟",
                             warning: false)

                Spacer(minLength: 8)

                Button {
                    Task { await vm.begin() }
                } label: {
                    HStack(spacing: 8) {
                        if vm.engine.state == .starting {
                            ProgressView().controlSize(.small).tint(.white)
                        } else {
                            Image(systemName: "location.north.line.fill")
                        }
                        Text(vm.engine.state == .starting ? "正在启动..." : "开始方向测试")
                            .font(.system(size: 13, weight: .semibold))
                    }
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .background(RoundedRectangle(cornerRadius: 11)
                        .fill(MeterTheme.primaryActionGradient))
                }
                .buttonStyle(.plain)
                .disabled(vm.engine.state == .starting || !vm.engine.hasAudioInput)
                .opacity(vm.engine.hasAudioInput ? 1 : 0.55)

                Text("测试开始后请保持环境安静，仅保留待判断的噪音源。")
                    .font(.system(size: 9.5))
                    .foregroundColor(MeterTheme.tertiaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(18)
            .frame(width: 244)
            .background(
                RoundedRectangle(cornerRadius: 15)
                    .fill(MeterTheme.surfaceFill)
                    .overlay(RoundedRectangle(cornerRadius: 15)
                        .stroke(MeterTheme.hairline, lineWidth: 1))
            )
        }
        .padding(24)
    }

    private func readinessRow(icon: String, title: String, value: String,
                              warning: Bool) -> some View {
        HStack(spacing: 9) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(warning ? MeterTheme.brass : MeterTheme.waveColor)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 10))
                    .foregroundColor(MeterTheme.tertiaryText)
                Text(value)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(warning ? MeterTheme.brass : MeterTheme.primaryText)
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: - 运行中

    private func running(_ index: Int) -> some View {
        let position = MacSourceTestViewModel.positions[index]
        return VStack(spacing: 16) {
            VStack(spacing: 5) {
                Text(position.name)
                    .font(.system(size: 25, weight: .bold))
                    .foregroundColor(MeterTheme.primaryText)
                Text(position.hint)
                    .font(.system(size: 12))
                    .foregroundColor(MeterTheme.secondaryText)
            }

            HStack(spacing: 36) {
                ZStack {
                    Circle()
                        .stroke(MeterTheme.hairline, lineWidth: 11)
                    Circle()
                        .trim(from: 0, to: vm.progress)
                        .stroke(MeterTheme.waveColor,
                                style: StrokeStyle(lineWidth: 11, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    VStack(spacing: 1) {
                        Text("\(vm.secondsLeft)")
                            .font(.system(size: 56, weight: .heavy, design: .rounded))
                            .foregroundColor(MeterTheme.primaryText)
                            .monospacedDigit()
                        Text("秒")
                            .font(.system(size: 10))
                            .foregroundColor(MeterTheme.tertiaryText)
                    }
                }
                .frame(width: 168, height: 168)

                VStack(alignment: .leading, spacing: 8) {
                    Text("本点位等效声级")
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .tracking(1.1)
                        .foregroundColor(MeterTheme.tertiaryText)
                    Text(laeqText)
                        .font(.system(size: 42, weight: .heavy, design: .rounded))
                        .foregroundColor(MeterTheme.waveColor)
                        .monospacedDigit()
                    Text("保持设备位置稳定，避免衣物摩擦和手持噪声")
                        .font(.system(size: 10.5))
                        .foregroundColor(MeterTheme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)

                    HStack(spacing: 8) {
                        ForEach(0..<MacSourceTestViewModel.positions.count, id: \.self) { step in
                            Capsule()
                                .fill(step <= index ? MeterTheme.waveColor
                                                   : MeterTheme.surfaceStrongFill)
                                .frame(width: step == index ? 42 : 24, height: 4)
                        }
                    }
                    .padding(.top, 4)
                }
                .frame(width: 250, alignment: .leading)
            }

            HStack(spacing: 12) {
                Button {
                    vm.redoCurrentPosition()
                } label: {
                    Label("重测本点位", systemImage: "arrow.counterclockwise")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundColor(MeterTheme.secondaryText)
                        .frame(width: 130, height: 36)
                        .background(RoundedRectangle(cornerRadius: 9)
                            .fill(MeterTheme.controlFill))
                }
                .buttonStyle(.plain)

                Button {
                    vm.abandon()
                    close()
                } label: {
                    Text("取消测试")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundColor(MeterTheme.riskColor)
                        .frame(width: 100, height: 36)
                        .background(RoundedRectangle(cornerRadius: 9)
                            .fill(MeterTheme.riskColor.opacity(0.08)))
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    private var laeqText: String {
        vm.currentLaeq.isFinite ? String(format: "%.1f dB", vm.currentLaeq) : "-- dB"
    }

    // MARK: - 结果

    private var result: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 14) {
                if let result = vm.latestResult {
                    MacSourceTestResultCard(result: result)

                    HStack(spacing: 10) {
                        Button {
                            ReportExporter.exportSourceHTML(
                                result: result,
                                deviceName: Host.current().localizedName ?? "Mac",
                                audioURL: result.audioID.map {
                                    vm.store.audioFileURL(forID: $0)
                                })
                        } label: {
                            Label("导出完整报告", systemImage: "doc.richtext")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundColor(.white)
                                .frame(maxWidth: .infinity, minHeight: 40)
                                .background(RoundedRectangle(cornerRadius: 10)
                                    .fill(MeterTheme.primaryActionGradient))
                        }
                        .buttonStyle(.plain)

                        Button(action: close) {
                            Text("完成")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(MeterTheme.secondaryText)
                                .frame(width: 110, height: 40)
                                .background(RoundedRectangle(cornerRadius: 10)
                                    .fill(MeterTheme.controlFill))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(24)
        }
    }

    private func failed(_ message: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "mic.slash.fill")
                .font(.system(size: 38))
                .foregroundColor(MeterTheme.riskColor)
            Text(message)
                .font(.system(size: 13))
                .foregroundColor(MeterTheme.primaryText)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            Button {
                openMicrophoneSettings()
            } label: {
                Text("打开麦克风设置")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 18)
                    .frame(height: 38)
                    .background(Capsule().fill(MeterTheme.primaryActionGradient))
            }
            .buttonStyle(.plain)
            Button("返回") {
                vm.abandon()
            }
            .buttonStyle(.plain)
            .foregroundColor(MeterTheme.secondaryText)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    private func toolPill(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
            .foregroundColor(color)
            .padding(.horizontal, 9)
            .frame(height: 22)
            .background(Capsule().fill(color.opacity(0.10)))
    }

    private func close() {
        vm.abandon()
        isPresented = false
    }

    private func openMicrophoneSettings() {
        guard let url = URL(string:
                "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") else {
            return
        }
        openURL(url)
    }
}

// MARK: - 结果卡 / 历史详情

struct MacSourceTestResultCard: View {
    let result: SourceTestResult

    var body: some View {
        VStack(spacing: 16) {
            HStack(alignment: .top, spacing: 18) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(result.rejectedByDrift
                         ? "环境变化过大"
                         : SourceTendencyAnalyzer.verdictText(result.verdict))
                        .font(.system(size: 34, weight: .heavy))
                        .foregroundColor(MeterTheme.waveColor)
                    Text(detailText)
                        .font(.system(size: 11))
                        .foregroundColor(MeterTheme.secondaryText)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 4) {
                    Text(Self.dateFormatter.string(from: result.startTime))
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundColor(MeterTheme.tertiaryText)
                    Text("总时长 \(RecordingPlayer.formatTime(result.duration))")
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundColor(MeterTheme.tertiaryText)
                }
            }

            VStack(spacing: 11) {
                let minLaeq = result.positions.map { $0.laeq }.filter { $0.isFinite }.min() ?? 0
                let maxLaeq = max(result.positions.map { $0.laeq }.max() ?? 1, 1)
                ForEach(Array(result.positions.enumerated()), id: \.offset) { _, position in
                    HStack(spacing: 10) {
                        Text(position.name)
                            .font(.system(size: 11.5))
                            .foregroundColor(MeterTheme.secondaryText)
                            .frame(width: 88, alignment: .leading)
                        GeometryReader { geometry in
                            ZStack(alignment: .leading) {
                                Capsule().fill(MeterTheme.controlFill)
                                Capsule()
                                    .fill(LinearGradient(
                                        colors: [MeterTheme.waveColor.opacity(0.65),
                                                 MeterTheme.waveColor],
                                        startPoint: .leading,
                                        endPoint: .trailing))
                                    .frame(width: geometry.size.width
                                        * max(0.04, CGFloat(
                                            (position.laeq - minLaeq)
                                            / max(1, maxLaeq - minLaeq))))
                            }
                        }
                        .frame(height: 11)
                        Text(String(format: "%.1f dB · %d 事件",
                                    position.laeq, position.eventCount))
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundColor(MeterTheme.secondaryText)
                            .frame(width: 120, alignment: .trailing)
                    }
                }
            }
            .padding(15)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(MeterTheme.surfaceFill)
                    .overlay(RoundedRectangle(cornerRadius: 12)
                        .stroke(MeterTheme.hairline, lineWidth: 1))
            )

            HStack(spacing: 6) {
                Image(systemName: "info.circle")
                Text("靠共用墙显著更响通常提示隔壁；靠天花板显著更响通常提示楼上。有效增益最低 3 dB，且中央复测漂移不得超过 2 dB。")
            }
            .font(.system(size: 10))
            .foregroundColor(MeterTheme.tertiaryText)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(MeterTheme.panelGradient)
                .overlay(RoundedRectangle(cornerRadius: 16)
                    .stroke(MeterTheme.hairline, lineWidth: 1))
        )
    }

    private var detailText: String {
        if result.rejectedByDrift {
            let drift = result.centerDrift.map { String(format: "%.1f dB", $0) } ?? "超过 2 dB"
            return "中央复测漂移 \(drift) · 环境变化过大，建议重新测试"
        }
        let drift = result.centerDrift.map {
            String(format: " · 中央漂移 %.1f dB", $0)
        } ?? ""
        return "置信度 \(SourceTendencyAnalyzer.confidenceText(result.confidence)) · \(SourceTendencyAnalyzer.typeText(result.noiseType))\(drift) · 方向倾向仅供参考"
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter
    }()
}

struct MacSourceTestDetailSheet: View {
    let result: SourceTestResult
    let store: SourceTestStore
    @Environment(\.dismiss) private var dismiss
    @StateObject private var player = RecordingPlayer()

    var body: some View {
        VStack(spacing: 14) {
            HStack {
                Text("声源方向倾向详情")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundColor(MeterTheme.primaryText)
                Spacer()
                Button("完成") { dismiss() }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(MeterTheme.waveColor)
            }

            ScrollView(showsIndicators: false) {
                VStack(spacing: 14) {
                    MacSourceTestResultCard(result: result)
                    if result.audioID != nil {
                        MacRecordingPlayerBar(player: player)
                    }
                }
            }

            Button {
                ReportExporter.exportSourceHTML(
                    result: result,
                    deviceName: Host.current().localizedName ?? "Mac",
                    audioURL: result.audioID.map { store.audioFileURL(forID: $0) })
            } label: {
                Label("导出完整报告", systemImage: "doc.richtext")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity, minHeight: 40)
                    .background(RoundedRectangle(cornerRadius: 10)
                        .fill(MeterTheme.primaryActionGradient))
            }
            .buttonStyle(.plain)
        }
        .padding(20)
        .frame(width: 660, height: 560)
        .background(MeterTheme.backgroundGradient)
        .onAppear {
            if let id = result.audioID {
                player.load(url: store.audioFileURL(forID: id))
            }
        }
        .onDisappear { player.stop() }
    }
}
