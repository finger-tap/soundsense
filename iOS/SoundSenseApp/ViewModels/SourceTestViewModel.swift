//
//  SourceTestViewModel.swift
//  SoundSense iOS
//
//  声源方向倾向测试:房间中央 → 靠共用墙 → 靠天花板 → 回中央复测,
//  每点位 30 秒;中央前后漂移超过 2 dB 时拒绝方向结论并提示复测,
//  但仍保存本次录音与数据,避免把时间变化误判成位置差异。
//

import SwiftUI
import Combine
import SoundSenseCore
import UIKit

@MainActor
final class SourceTestViewModel: ObservableObject {

    enum Phase: Equatable {
        case idle
        case running(positionIndex: Int)
        case finished
        case failed(String)
    }

    static let positions: [(name: String, hint: String)] = [
        ("房间中央", "手持手机站到房间中央,保持不动"),
        ("靠近共用墙", "走到与隔壁相邻的墙边,距墙半米内"),
        ("举高靠天花板", "把手机举高,尽量靠近天花板"),
        ("回到房间中央", "回到第一次的位置和高度,复测环境是否稳定"),
    ]
    static let secondsPerPosition: TimeInterval = 30

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var currentLaeq: Float = -.greatestFiniteMagnitude
    @Published private(set) var secondsLeft: Int = 30
    /// 测完的最近一次结果(展示用;已入库)
    @Published private(set) var latestResult: SourceTestResult?

    let store = SourceTestStore.shared
    /// 引擎(视图通过 onChange(engine.latestResult) 转发 consume)
    let engine: AudioMeterEngine
    private let sessionRecorder = SessionAudioRecorder()
    private var eventEngine = NoiseEventEngine()
    private var builder = PositionStatsBuilder()
    /// 已完成点位的快照(切换点位时落盘)
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
    private static let maxPendingAnalysisResults = 256

    private struct AnalysisFrame { let result: MeterResult }

    init(calibrationOffset: Float) {
        self.engine = AudioMeterEngine(calibrationOffset: calibrationOffset,
                                       throttleInterval: 0.1,   // 事件检测要细粒度
                                       fftSize: 4096)
        engine.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &cancellables)
    }

    var deviceName: String { UIDevice.current.name }

    // MARK: - 流程控制

    func begin() async {
        await engine.start()
        guard engine.state == .running else {
            phase = .failed("麦克风启动失败,请检查权限")
            return
        }
        sessionRecorder.startSession(directory: store.recordingsDirectory,
                                     inputSampleRate: engine.activeSampleRate)
        engine.setSampleSink { [weak sessionRecorder] samples in
            sessionRecorder?.append(samples)
        }
        analysisPending.removeAll(keepingCapacity: false)
        isConsumingAnalysis = false
        installAnalysisSink()
        testStart = Date()
        testAudioElapsed = 0
        positionAudioElapsed = 0
        didFinish = false
        isFinishing = false
        snapshots = []
        startPosition(0)
    }

    func abandon() {
        guard case .running = phase else { return }
        engine.setSampleSink(nil)
        engine.setAnalysisSink(nil)
        analysisGeneration &+= 1
        engine.stop()
        stopTimer()
        analysisPending.removeAll(keepingCapacity: false)
        isConsumingAnalysis = false
        isFinishing = false
        _ = sessionRecorder.finishSession(keep: false)
        phase = .idle
    }

    /// 重测当前点位(清空该点位的统计重新累积)
    func redoCurrentPosition() {
        guard case .running(let index) = phase else { return }
        analysisPending.removeAll(keepingCapacity: true)
        installAnalysisSink()
        startPosition(index)
    }

    private func startPosition(_ index: Int) {
        eventEngine = NoiseEventEngine()
        eventEngine.beginSession()
        builder = PositionStatsBuilder()
        currentLaeq = -.greatestFiniteMagnitude
        positionAudioElapsed = 0
        secondsLeft = Int(Self.secondsPerPosition)
        isFinishing = false
        // 下一帧重新建立 F/S 显示检波器，避免上一点位的指数拖尾。
        engine.resetDisplayDetectorForNewPosition()
        phase = .running(positionIndex: index)
        startTimer()
    }

    private func finishSession() async {
        guard !didFinish else { return }
        didFinish = true
        engine.setSampleSink(nil)
        stopTimer()

        // 先排空最后一批已采集样本，再生成点位统计和结论；
        // 否则结束前最后约一个 hop 的能量会漏出测试。
        await engine.freezeForFinalization()
        await waitForAnalysisDrain()
        engine.setAnalysisSink(nil)

        // 最后点位的快照在 tick 里已入列;不足四个(异常路径)则以当前 builder 兜底
        var stats = Array(snapshots.prefix(Self.positions.count - 1))
        let finalName = Self.positions[min(stats.count, Self.positions.count - 1)].name
        let final = builder.finishAndSnapshot(
            name: finalName,
            engine: eventEngine,
            endTime: positionAudioElapsed)
        if stats.count < Self.positions.count { stats.append(final) }
        let duration = max(testAudioElapsed, positionAudioElapsed)
        let audioURL = sessionRecorder.finishSession(keep: true)
        let outcome = SourceTendencyAnalyzer.analyze(positions: stats, duration: duration)
        var result = SourceTestResult(startTime: testStart, duration: duration,
                                      positions: stats, verdict: outcome.verdict,
                                      confidence: outcome.confidence,
                                      noiseType: outcome.noiseType,
                                      centerDrift: outcome.centerDrift,
                                      rejectedByDrift: outcome.rejectedByDrift)
        if let url = audioURL {
            result.audioID = url.deletingPathExtension().lastPathComponent
        }
        engine.finishFinalization()
        store.add(result)
        latestResult = result
        phase = .finished
    }

    // MARK: - 引擎消费(主视图转发)

    func consume(_ result: MeterResult) {
        guard case .running = phase else { return }
        currentLaeq = builder.currentLaeq()
    }

    /// 每个 hop 都进入点位统计，确保 30 秒边界和事件检测不受 UI 节流影响。
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
                  processed < 128 {
                if self.isFinishing {
                    // 最后一个点位已到 30 秒；收尾期间只排空队列，不再积分
                    // 边界之后的额外音频。
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
                positionDuration: Self.secondsPerPosition)
            if split.current > 0 {
                observeCurrentPosition(spl: result.splInstant,
                                       duration: split.current,
                                       lowRatio: low)
                remaining = split.overflow
            }
            if positionAudioElapsed >= Self.secondsPerPosition - 0.000_001 {
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
        // 点位 LAeq 必须使用当前 hop 的未平滑计权能量，不能用 F/S 显示值。
        builder.observe(spl: spl, duration: duration, at: t)
        eventEngine.feed(t: t, duration: duration, spl: spl, lowRatio: lowRatio)
        currentLaeq = builder.currentLaeq()
        secondsLeft = max(0, Int(ceil(Self.secondsPerPosition - t)))
    }

    /// freezeForFinalization() 只保证引擎侧已交付；ViewModel 的 MainActor
    /// 消费任务还可能排队，必须等它完全落账后再生成报告。
    private func waitForAnalysisDrain() async {
        for _ in 0..<500 {
            if !isConsumingAnalysis && analysisPending.isEmpty { return }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
    }

    // MARK: - 定时器

    private func startTimer() {
        stopTimer()
        let t = Timer(timeInterval: 0.25, repeats: true) { _ in
            Task { @MainActor [weak self] in
                self?.tick()
            }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        guard case .running(let index) = phase else { return }
        secondsLeft = max(0, Int(ceil(Self.secondsPerPosition - positionAudioElapsed)))
        // 音频回调短暂停顿时不提前切换点位。真正边界由音频时钟推进；
        // 定时器只负责在已经到达边界后兜底触发一次。
        if positionAudioElapsed >= Self.secondsPerPosition {
            finishCurrentPosition()
        }
    }

    private func finishCurrentPosition() {
        guard case .running(let index) = phase else { return }
        builder.finish(at: min(positionAudioElapsed, Self.secondsPerPosition))
        let snap = builder.snapshot(name: Self.positions[index].name,
                                    engine: eventEngine)
        snapshots.append(snap)
        if index + 1 < Self.positions.count {
            startPosition(index + 1)
        } else {
            isFinishing = true
            Task { @MainActor [weak self] in
                await self?.finishSession()
            }
        }
    }

}
