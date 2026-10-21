//
//  WatchSourceTestView.swift
//  SoundSenseWatch
//
//  手表版声源方向倾向测试:平胸/靠墙/举高/回平胸各 30 秒,
//  完成后经 WCSession 把结果同步到 iPhone 存储(手表不存历史、不录音)。
//

import SwiftUI
import WatchConnectivity
import Combine
import SoundSenseCore

// MARK: - ViewModel

@MainActor
final class WatchSourceTestViewModel: ObservableObject {

    static let positionNames = ["房间中央", "靠近共用墙", "举高靠天花板", "回到房间中央"]

    enum Phase: Equatable {
        case idle
        case running(positionIndex: Int)
        case done
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var currentLaeq: Float = -.greatestFiniteMagnitude
    @Published private(set) var secondsLeft = 30
    @Published private(set) var result: SourceTestResult?
    @Published private(set) var syncNote: String?

    let engine: AudioMeterEngine

    private var eventEngine = NoiseEventEngine()
    private var builder = PositionStatsBuilder()
    private var snapshots: [PositionStats] = []
    private var testStart = Date()
    private var positionAudioElapsed: TimeInterval = 0
    private var testAudioElapsed: TimeInterval = 0
    private var didFinish = false
    private var isFinishing = false
    private var timer: Timer?
    private var cancellables = Set<AnyCancellable>()
    private var isConsumingAnalysis = false
    private var analysisPending: [AnalysisFrame] = []
    private var analysisGeneration: UInt64 = 0
    private static let maxPendingAnalysisResults = 128

    private struct AnalysisFrame { let result: MeterResult }

    init() {
        let offset = CalibrationDefaults.resolved(platformDefault: CalibrationDefaults.watchBuiltIn)
        engine = AudioMeterEngine(calibrationOffset: offset,
                                  throttleInterval: 0.2, fftSize: 4096)
        engine.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &cancellables)
    }

    func begin() async {
        await engine.start()
        guard engine.state == .running else { return }
        analysisPending.removeAll(keepingCapacity: false)
        isConsumingAnalysis = false
        installAnalysisSink()
        testStart = Date()
        testAudioElapsed = 0
        positionAudioElapsed = 0
        didFinish = false
        isFinishing = false
        snapshots = []
        start(0)
    }

    func stop() {
        engine.setSampleSink(nil)
        engine.setAnalysisSink(nil)
        analysisGeneration &+= 1
        engine.stop()
        timer?.invalidate()
        timer = nil
        analysisPending.removeAll(keepingCapacity: false)
        isConsumingAnalysis = false
        isFinishing = false
        if phase != .done { phase = .idle }
    }

    func consume(_ result: MeterResult) {
        guard case .running = phase else { return }
        currentLaeq = builder.currentLaeq()
    }

    private func installAnalysisSink() {
        analysisGeneration &+= 1
        let generation = analysisGeneration
        engine.setAnalysisSink { [weak self] results in
            self?.consumeAnalysis(results, generation: generation)
        }
    }

    private nonisolated func consumeAnalysis(_ results: [MeterResult],
                                             generation: UInt64) {
        guard results.contains(where: { $0.splA.isFinite }) else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard self.analysisGeneration == generation else { return }
            self.analysisPending.append(contentsOf: results.map(AnalysisFrame.init))
            if self.analysisPending.count > Self.maxPendingAnalysisResults {
                let overflow = self.analysisPending.count - Self.maxPendingAnalysisResults
                self.analysisPending.removeFirst(overflow)
            }
            self.drainAnalysisIfNeeded()
        }
    }

    private func drainAnalysisIfNeeded() {
        guard !isConsumingAnalysis, !analysisPending.isEmpty else { return }
        isConsumingAnalysis = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            var processed = 0
            while case .running = self.phase,
                  !self.analysisPending.isEmpty,
                  processed < 64 {
                if self.isFinishing {
                    self.analysisPending.removeAll(keepingCapacity: true)
                    break
                }
                let next = self.analysisPending.removeFirst()
                self.consumeFullRate(next.result)
                processed += 1
            }
            self.isConsumingAnalysis = false
            if !self.analysisPending.isEmpty,
               case .running = self.phase {
                self.drainAnalysisIfNeeded()
            } else {
                self.analysisPending.removeAll(keepingCapacity: true)
            }
        }
    }

    private func consumeFullRate(_ result: MeterResult) {
        guard case .running = phase, !isFinishing else { return }
        let spl = result.splA
        guard spl.isFinite else { return }
        guard result.integratedSampleCount > 0 else { return }
        let fullDuration = result.coveredDuration
        guard fullDuration.isFinite, fullDuration > 0 else { return }
        let low = lowFrequencyRatio(spectrum: result.spectrum,
                                    frequencies: result.frequencies)

        var remaining = fullDuration
        while remaining > 0, !isFinishing, case .running = phase {
            let split = SourceTestTimeline.split(
                elapsed: positionAudioElapsed,
                duration: remaining,
                positionDuration: 30)
            if split.current > 0 {
                observeCurrentPosition(spl: result.splInstant,
                                       duration: split.current,
                                       lowRatio: low)
                remaining = split.overflow
            }
            if positionAudioElapsed >= 30 - 0.000_001 {
                finishCurrentPosition()
            } else {
                break
            }
        }
    }

    private func observeCurrentPosition(spl: Float,
                                        duration: TimeInterval,
                                        lowRatio: Float?) {
        let t = positionAudioElapsed + duration
        positionAudioElapsed = t
        testAudioElapsed += duration
        builder.observe(spl: spl, duration: duration, at: t)
        eventEngine.feed(t: t, duration: duration, spl: spl, lowRatio: lowRatio)
        currentLaeq = builder.currentLaeq()
        secondsLeft = max(0, Int(ceil(30 - t)))
    }

    private func waitForAnalysisDrain() async {
        for _ in 0..<500 {
            if !isConsumingAnalysis && analysisPending.isEmpty { return }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
    }

    func start(_ index: Int) {
        eventEngine = NoiseEventEngine()
        eventEngine.beginSession()
        builder = PositionStatsBuilder()
        currentLaeq = -.greatestFiniteMagnitude
        positionAudioElapsed = 0
        secondsLeft = 30
        isFinishing = false
        engine.resetDisplayDetectorForNewPosition()
        phase = .running(positionIndex: index)
        timer?.invalidate()
        let t = Timer(timeInterval: 0.25, repeats: true) { _ in
            Task { @MainActor [weak self] in self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func tick() {
        guard case .running(let index) = phase else { return }
        secondsLeft = max(0, Int(ceil(30 - positionAudioElapsed)))
        guard positionAudioElapsed >= 30 else { return }
        finishCurrentPosition()
    }

    private func finishCurrentPosition() {
        guard case .running(let index) = phase else { return }
        builder.finish(at: min(positionAudioElapsed, 30))
        snapshots.append(builder.snapshot(
            name: Self.positionNames[index], engine: eventEngine))
        if index + 1 < Self.positionNames.count {
            start(index + 1)
        } else {
            isFinishing = true
            Task { @MainActor [weak self] in
                await self?.finish()
            }
        }
    }

    private func finish() async {
        guard !didFinish else { return }
        didFinish = true
        timer?.invalidate()
        timer = nil
        engine.setSampleSink(nil)
        await engine.freezeForFinalization()
        await waitForAnalysisDrain()
        engine.setAnalysisSink(nil)
        let duration = max(testAudioElapsed, positionAudioElapsed)
        let outcome = SourceTendencyAnalyzer.analyze(positions: snapshots, duration: duration)
        let result = SourceTestResult(startTime: testStart, duration: duration,
                                      positions: snapshots, verdict: outcome.verdict,
                                      confidence: outcome.confidence,
                                      noiseType: outcome.noiseType,
                                      centerDrift: outcome.centerDrift,
                                      rejectedByDrift: outcome.rejectedByDrift,
                                      audioID: nil)   // 手表测试不录音
        engine.finishFinalization()
        self.result = result
        phase = .done
        send(result)
    }

    /// 结果发到 iPhone(不重试;失败提示仅本次展示)
    private func send(_ result: SourceTestResult) {
        guard WCSession.isSupported() else {
            syncNote = "无法同步:iPhone 不可达,结果仅本次展示"
            return
        }
        let session = WCSession.default
        guard session.activationState == .activated, session.isReachable else {
            syncNote = "iPhone 未连接,结果仅本次展示"
            return
        }
        guard let data = try? JSONEncoder().encode([result]) else { return }
        session.sendMessageData(data, replyHandler: nil) { _ in
            Task { @MainActor in self.syncNote = "同步失败,结果仅本次展示" }
        }
        syncNote = "已发送到 iPhone"
    }

}

// MARK: - View

struct WatchSourceTestView: View {
    @StateObject private var vm = WatchSourceTestViewModel()
    @Environment(\.dismiss) private var dismiss

    private let positionNames = WatchSourceTestViewModel.positionNames

    var body: some View {
        NavigationView {
            Group {
                switch vm.phase {
                case .idle:
                    intro
                case .running(let index):
                    running(index)
                case .done:
                    done
                }
            }
            .navigationTitle("声源方向倾向")
        }
        .onDisappear { vm.stop() }
    }

    private var intro: some View {
        ScrollView {
            VStack(spacing: 8) {
                Text("在邻居噪音进行时,按提示在 4 个位置各测 30 秒")
                    .font(.system(size: 13))
                    .foregroundColor(.white.opacity(0.7))
                Button {
                    Task { await vm.begin() }
                } label: {
                    Text("开始")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(.black)
                }
            }
        }
    }

    private func running(_ index: Int) -> some View {
        VStack(spacing: 6) {
            Text("\(index + 1)/\(positionNames.count) · \(positionNames[index])")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.white)
            Text("\(vm.secondsLeft)")
                .font(.system(size: 44, weight: .heavy, design: .rounded))
                .foregroundColor(.white)
                .monospacedDigit()
            Text(vm.currentLaeq.isFinite
                 ? String(format: "LAeq %.1f dB", vm.currentLaeq)
                 : "LAeq --")
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(MeterTheme.waveColor)
        }
    }

    private var done: some View {
        ScrollView {
            VStack(spacing: 8) {
                if let result = vm.result {
                    Text(result.rejectedByDrift
                         ? "环境变化过大"
                         : SourceTendencyAnalyzer.verdictText(result.verdict))
                        .font(.system(size: 20, weight: .heavy))
                        .foregroundColor(MeterTheme.waveColor)
                    Text(detailText(result))
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.5))
                }
                if let note = vm.syncNote {
                    Text(note)
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.45))
                }
                Button {
                    vm.stop()
                    dismiss()
                } label: {
                    Text("完成")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.black)
                }
            }
        }
    }

    private func detailText(_ result: SourceTestResult) -> String {
        if result.rejectedByDrift {
            let drift = result.centerDrift.map { String(format: "%.1f dB", $0) } ?? "超过 2 dB"
            return "中央漂移 \(drift) · 环境不稳定，建议重测"
        }
        let drift = result.centerDrift.map {
            String(format: " · 漂移 %.1f dB", $0)
        } ?? ""
        return "置信度 \(SourceTendencyAnalyzer.confidenceText(result.confidence))\(drift) · 方向倾向仅供参考"
    }
}
