//
//  MacSourceTestViewModel.swift
//  SoundSenseMac
//
//  macOS 声源方向倾向测试。流程与 iOS 一致，但使用 macOS 当前选中的
//  输入设备和校准值，测试过程与结果都落在本机。
//

import Foundation
import Combine
import SoundSenseCore

@MainActor
final class MacSourceTestViewModel: ObservableObject {

    enum Phase: Equatable {
        case idle
        case running(positionIndex: Int)
        case finished
        case failed(String)
    }

    static let positions: [(name: String, hint: String)] = [
        ("房间中央", "站在房间中央，保持不动，让麦克风朝向噪音来源"),
        ("靠近共用墙", "走到与隔壁相邻的墙边，距离墙面约半米"),
        ("举高靠天花板", "把 Mac 或麦克风举高，尽量靠近天花板"),
        ("回到房间中央", "回到第一次的位置和高度，复测环境是否稳定"),
    ]
    static let secondsPerPosition: TimeInterval = 30

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var currentLaeq: Float = -.greatestFiniteMagnitude
    @Published private(set) var secondsLeft = Int(secondsPerPosition)
    @Published private(set) var latestResult: SourceTestResult?

    let engine: AudioMeterEngine
    let store = SourceTestStore.shared

    private let sessionRecorder = SessionAudioRecorder()
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
    private static let maxPendingAnalysisResults = 256

    private struct AnalysisFrame { let result: MeterResult }

    init(calibrationOffset: Float,
         inputDeviceUID: String?,
         weighting: Weighting,
         timeWeighting: TimeWeighting) {
        engine = AudioMeterEngine(calibrationOffset: calibrationOffset,
                                  throttleInterval: 0.1,
                                  fftSize: 4096,
                                  weighting: weighting,
                                  timeWeighting: timeWeighting,
                                  inputDeviceUID: inputDeviceUID)
        engine.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &cancellables)
    }

    var progress: CGFloat {
        let elapsed = Self.secondsPerPosition - Double(secondsLeft)
        return CGFloat(max(0, min(1, elapsed / Self.secondsPerPosition)))
    }

    var errorText: String? {
        if case .failed(let message) = phase { return message }
        return nil
    }

    // MARK: - 流程

    func begin() async {
        await engine.start()
        guard engine.state == .running else {
            phase = .failed(startFailureMessage)
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
        latestResult = nil
        startPosition(0)
    }

    func abandon() {
        guard phase != .idle else { return }
        if case .finished = phase { return }
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

    func redoCurrentPosition() {
        guard case .running(let index) = phase else { return }
        analysisPending.removeAll(keepingCapacity: true)
        installAnalysisSink()
        startPosition(index)
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
                  processed < 128 {
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
        builder.observe(spl: spl, duration: duration, at: t)
        eventEngine.feed(t: t, duration: duration, spl: spl, lowRatio: lowRatio)
        currentLaeq = builder.currentLaeq()
        secondsLeft = max(0, Int(ceil(Self.secondsPerPosition - t)))
    }

    private func waitForAnalysisDrain() async {
        for _ in 0..<500 {
            if !isConsumingAnalysis && analysisPending.isEmpty { return }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
    }

    // MARK: - 点位

    private func startPosition(_ index: Int) {
        eventEngine = NoiseEventEngine()
        eventEngine.beginSession()
        builder = PositionStatsBuilder()
        currentLaeq = -.greatestFiniteMagnitude
        positionAudioElapsed = 0
        secondsLeft = Int(Self.secondsPerPosition)
        isFinishing = false
        engine.resetDisplayDetectorForNewPosition()
        phase = .running(positionIndex: index)
        startTimer()
    }

    private func finishSession() async {
        guard !didFinish else { return }
        didFinish = true
        engine.setSampleSink(nil)
        stopTimer()
        await engine.freezeForFinalization()
        await waitForAnalysisDrain()
        engine.setAnalysisSink(nil)

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
        var result = SourceTestResult(startTime: testStart,
                                      duration: duration,
                                      positions: stats,
                                      verdict: outcome.verdict,
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

    private var startFailureMessage: String {
        switch engine.state {
        case .denied:
            return "麦克风权限被拒绝。请到系统设置 → 隐私与安全性 → 麦克风允许闻声。"
        case .failed(let message):
            return "无法启动麦克风：\(message)"
        default:
            return "麦克风未能启动，请检查输入设备后重试。"
        }
    }

    // MARK: - 定时器

    private func startTimer() {
        stopTimer()
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.tick()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        guard case .running(let index) = phase else { return }
        secondsLeft = max(0, Int(ceil(Self.secondsPerPosition - positionAudioElapsed)))
        guard positionAudioElapsed >= Self.secondsPerPosition else { return }
        finishCurrentPosition()
    }

    private func finishCurrentPosition() {
        guard case .running(let index) = phase else { return }
        builder.finish(at: min(positionAudioElapsed, Self.secondsPerPosition))
        let snapshot = builder.snapshot(name: Self.positions[index].name,
                                        engine: eventEngine)
        snapshots.append(snapshot)
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
