//
//  WatchSourceTestView.swift
//  SoundSenseWatch
//
//  手表版三点声源倾向测试:抬腕平胸/靠墙/举高各 30 秒,
//  完成后经 WCSession 把结果同步到 iPhone 存储(手表不存历史、不录音)。
//

import SwiftUI
import WatchConnectivity
import SoundSenseCore

// MARK: - ViewModel

@MainActor
final class WatchSourceTestViewModel: ObservableObject {

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
    private var positionStart = Date()
    private var testStart = Date()
    private var timer: Timer?

    init() {
        let offset = Float(UserDefaults.standard.object(forKey: "calibrationOffset") as? Double ?? 93)
        engine = AudioMeterEngine(calibrationOffset: offset,
                                  throttleInterval: 0.2, fftSize: 4096)
    }

    func begin() async {
        await engine.start()
        guard engine.state == .running else { return }
        testStart = Date()
        snapshots = []
        start(0)
    }

    func stop() {
        engine.setSampleSink(nil)
        engine.stop()
        timer?.invalidate()
        timer = nil
        if phase != .done { phase = .idle }
    }

    func consume(_ result: MeterResult) {
        guard case .running = phase else { return }
        let spl = result.splA
        guard spl.isFinite else { return }
        builder.observe(spl: spl)
        let low = lowFrequencyRatio(spectrum: result.spectrum,
                                    frequencies: result.frequencies)
        eventEngine.feed(t: Date().timeIntervalSince(positionStart), spl: spl, lowRatio: low)
        currentLaeq = builder.currentLaeq()
    }

    func start(_ index: Int) {
        eventEngine = NoiseEventEngine()
        builder = PositionStatsBuilder()
        positionStart = Date()
        secondsLeft = 30
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
        let elapsed = Date().timeIntervalSince(positionStart)
        secondsLeft = max(0, Int(ceil(30 - elapsed)))
        guard elapsed >= 30 else { return }
        snapshots.append(builder.snapshot(
            name: ["房间中央", "靠近共用墙", "举高靠天花板"][index], engine: eventEngine))
        if index + 1 < 3 {
            start(index + 1)
        } else {
            finish()
        }
    }

    private func finish() {
        timer?.invalidate()
        timer = nil
        engine.setSampleSink(nil)
        engine.stop()
        let duration = Date().timeIntervalSince(testStart)
        let outcome = SourceTendencyAnalyzer.analyze(positions: snapshots, duration: duration)
        let result = SourceTestResult(startTime: testStart, duration: duration,
                                      positions: snapshots, verdict: outcome.verdict,
                                      confidence: outcome.confidence,
                                      noiseType: outcome.noiseType,
                                      audioID: nil)   // 手表测试不录音
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

    private let positionNames = ["房间中央", "靠近共用墙", "举高靠天花板"]

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
            .navigationTitle("声源定位")
        }
        .onChange(of: vm.engine.latestResult) { result in
            if let result = result { vm.consume(result) }
        }
        .onDisappear { vm.stop() }
    }

    private var intro: some View {
        ScrollView {
            VStack(spacing: 8) {
                Text("在邻居噪音进行时,按提示在 3 个位置各测 30 秒")
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
            Text("\(index + 1)/3 · \(positionNames[index])")
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
                .foregroundColor(Color(red: 0.24, green: 0.83, blue: 0.69))
        }
    }

    private var done: some View {
        ScrollView {
            VStack(spacing: 8) {
                if let result = vm.result {
                    Text(SourceTendencyAnalyzer.verdictText(result.verdict))
                        .font(.system(size: 20, weight: .heavy))
                        .foregroundColor(Color(red: 0.24, green: 0.83, blue: 0.69))
                    Text("置信度 \(SourceTendencyAnalyzer.confidenceText(result.confidence)) · 推测仅供参考")
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
}
