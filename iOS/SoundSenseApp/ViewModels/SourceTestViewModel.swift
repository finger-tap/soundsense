//
//  SourceTestViewModel.swift
//  SoundSense iOS
//
//  三点声源倾向测试:引导用户在 房间中央/靠共用墙/靠天花板 各测 30 秒,
//  每点位独立聚合统计(事件/低频占比/稳态),测完判定并入库,全程同步录音。
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
    private var positionStart = Date()
    private var testStart = Date()
    private var timer: Timer?
    private var cancellables = Set<AnyCancellable>()

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
        testStart = Date()
        snapshots = []
        startPosition(0)
    }

    func abandon() {
        engine.setSampleSink(nil)
        engine.stop()
        stopTimer()
        _ = sessionRecorder.finishSession(keep: false)
        phase = .idle
    }

    /// 重测当前点位(清空该点位的统计重新累积)
    func redoCurrentPosition() {
        guard case .running(let index) = phase else { return }
        startPosition(index)
    }

    private func startPosition(_ index: Int) {
        eventEngine = NoiseEventEngine()
        builder = PositionStatsBuilder()
        positionStart = Date()
        secondsLeft = Int(Self.secondsPerPosition)
        phase = .running(positionIndex: index)
        startTimer()
    }

    private func finish() {
        engine.setSampleSink(nil)
        engine.stop()
        stopTimer()

        // 最后点位的快照在 tick 里已入列;不足三个(异常路径)则以当前 builder 兜底
        var stats = snapshots
        if stats.count < Self.positions.count {
            stats.append(builder.snapshot(name: Self.positions[Self.positions.count - 1].name,
                                          engine: eventEngine))
        }
        let duration = Date().timeIntervalSince(testStart)
        let audioURL = sessionRecorder.finishSession(keep: true)
        let outcome = SourceTendencyAnalyzer.analyze(positions: stats, duration: duration)
        var result = SourceTestResult(startTime: testStart, duration: duration,
                                      positions: stats, verdict: outcome.verdict,
                                      confidence: outcome.confidence,
                                      noiseType: outcome.noiseType)
        if let url = audioURL {
            result.audioID = url.deletingPathExtension().lastPathComponent
        }
        store.add(result)
        latestResult = result
        phase = .finished
    }

    // MARK: - 引擎消费(主视图转发)

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
        let elapsed = Date().timeIntervalSince(positionStart)
        secondsLeft = max(0, Int(ceil(Self.secondsPerPosition - elapsed)))
        if elapsed >= Self.secondsPerPosition {
            let snap = builder.snapshot(name: Self.positions[index].name,
                                        engine: eventEngine)
            snapshots.append(snap)
            if index + 1 < Self.positions.count {
                startPosition(index + 1)
            } else {
                finish()
            }
        }
    }
}
