//
//  WatchMeterViewModel.swift
//  SoundSenseWatch
//
//  watchOS 视图模型:复用 AudioMeterEngine,节流更激进以省电。
//  校准偏移持久化,实时统计(LAeq / 峰值 / 时长)与 iOS/macOS 同源。
//  watchOS 只在前台测量 —— 见 WatchMeterView 的 scenePhase 处理。
//

import SwiftUI
import Combine
import SoundSenseCore

@MainActor
final class WatchMeterViewModel: ObservableObject {

    /// 引擎:创建后不变。变化通过 cancellables 转发。
    let engine: AudioMeterEngine
    @Published private(set) var history: [Float] = []
    @Published private(set) var noiseLevel: NoiseLevel?
    /// 实时统计(时长 / LAeq / 峰值)
    @Published private(set) var liveStats: LiveMeasurementStats?
    @Published private(set) var captureIncomplete = false

    /// 表盘声波条历史长度短一些(适配小屏)
    private let historyCapacity = 36
    private var cancellables = Set<AnyCancellable>()
    /// 测量记录器(与 iOS/macOS 同一套实时统计逻辑)
    private let recorder = MeasurementRecorder()

    /// 校准偏移量,持久化(默认 +115 dB,手表内建麦克风保守估计)
    @AppStorage("calibrationOffset") private var storedOffset: Double = Double(CalibrationDefaults.watchBuiltIn)

    var calibrationOffset: Float {
        get { Float(storedOffset) }
        set {
            storedOffset = Double(newValue)
            engine.calibrationOffset = newValue
        }
    }

    init() {
        // 迁移旧默认 +93 → +115(未手动校准过的安装),详见 CalibrationDefaults
        let offset = CalibrationDefaults.resolved(platformDefault: CalibrationDefaults.watchBuiltIn)
        storedOffset = Double(offset)
        let e = AudioMeterEngine(calibrationOffset: offset,
                                  throttleInterval: 0.2,   // 5fps,省电
                                  fftSize: 4096)
        self.engine = e
        // ★ 转发 engine 的 objectWillChange,否则 UI 观察不到结果
        e.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)
    }

    func start() async {
        guard engine.refreshInputAvailability() else {
            engine.stop()
            return
        }
        await engine.start()
        guard engine.state == .running else { return }
        recorder.weighting = engine.weighting == .c ? "C" : "A"
        recorder.timeWeighting = engine.timeWeighting == .slow ? "S" : "F"
        recorder.start()
        captureIncomplete = false
    }

    func stop() async {
        await engine.freezeForFinalization()
        _ = recorder.stop(sessionPeak: engine.sessionPeakSPL,
                          sessionLpeak: engine.sessionLpeakSPL,
                          sessionLeq: engine.sessionLeqSPL,
                          sessionLeqDuration: engine.sessionLeqDuration,
                          captureStart: engine.captureTimeRange?.lowerBound,
                          captureEnd: engine.captureTimeRange?.upperBound,
                          completeCapture: engine.sessionDroppedSampleCount == 0)
        engine.finishFinalization()
        liveStats = nil
        captureIncomplete = false
        history.removeAll(keepingCapacity: true)
        noiseLevel = nil
    }

    func consume(_ result: MeterResult) {
        let spl = result.splA
        history.append(spl)
        if history.count > historyCapacity {
            history.removeFirst(history.count - historyCapacity)
        }
        noiseLevel = NoiseLevel.level(for: spl)
        recorder.record(spl: spl,
                        sessionPeak: engine.sessionPeakSPL,
                        sessionLpeak: engine.sessionLpeakSPL,
                        sessionLeq: engine.sessionLeqSPL,
                        sessionLeqDuration: engine.sessionLeqDuration)
        recorder.updateCaptureCompleteness(
            droppedSampleCount: result.totalDroppedSampleCount)
        captureIncomplete = !result.measurementCoverageComplete
        liveStats = recorder.liveStats()
    }

    var currentSPL: Float {
        engine.latestResult?.splA ?? -.greatestFiniteMagnitude
    }
}
