//
//  MonitorViewModel.swift
//  SoundSense iOS
//
//  长时间监听:背景基线自学习,超过阈值(基线+N dB 或夜间绝对阈值)的异常事件
//  自动截取"pre-roll+事件+post-roll"片段并标注类型与位置推测。
//  iOS 后台音频模式支持锁屏运行;建议插电。
//

import SwiftUI
import Combine
import SoundSenseCore

@MainActor
final class MonitorViewModel: ObservableObject {

    enum Phase: Equatable { case idle, running }

    /// 单会话最多保存的片段数(到顶停存,测量继续)
    static let maxEventsPerSession = 100

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var currentLaeq: Float = -.greatestFiniteMagnitude
    @Published private(set) var baseline: Float = -.greatestFiniteMagnitude
    @Published private(set) var eventCount = 0
    /// 最近一条事件提示(时间线页外的小横幅用)
    @Published private(set) var lastEventNote: String?

    let store = MonitorSessionStore.shared
    let engine: AudioMeterEngine

    /// 触发阈值:背景 + N dB
    @AppStorage("monitorThresholdOver") var thresholdOver: Double = 10
    /// 夜间绝对阈值开关与数值(dB)
    @AppStorage("monitorAbsoluteEnabled") var absoluteEnabled: Bool = false
    @AppStorage("monitorAbsoluteDB") var absoluteDB: Double = 45

    private var eventEngine = NoiseEventEngine()
    private let clipRecorder = EventClipRecorder()
    private var builder = PositionStatsBuilder()
    private var session: MonitorSession?
    private var sessionStart = Date()
    private var cancellables = Set<AnyCancellable>()

    init() {
        engine = AudioMeterEngine(calibrationOffset: Self.currentCalibrationOffset(),
                                  throttleInterval: 0.1, fftSize: 4096)
        engine.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &cancellables)
    }

    /// 与主测量一致的校准偏移
    private static func currentCalibrationOffset() -> Float {
        Float(UserDefaults.standard.object(forKey: "calibrationOffset") as? Double ?? 93)
    }

    var deviceName: String { UIDevice.current.name }

    // MARK: - 开始 / 停止

    func start() async {
        await engine.start()
        guard engine.state == .running else { return }

        eventEngine = NoiseEventEngine()
        eventEngine.thresholdOverBackground = Float(thresholdOver)
        if absoluteEnabled { eventEngine.absoluteThreshold = Float(absoluteDB) }
        eventEngine.onEventStart = { [clipRecorder] in
            clipRecorder.beginClip()
        }
        builder = PositionStatsBuilder()
        sessionStart = Date()

        let id = UUID()
        let newSession = MonitorSession(id: id, startTime: sessionStart,
                                        overallLaeq: 0, minSPL: 0, maxSPL: 0,
                                        thresholdOverBackground: Float(thresholdOver))
        session = newSession
        store.add(newSession)

        clipRecorder.configure(directory: store.clipsDirectory(sessionID: id),
                               inputSampleRate: engine.activeSampleRate)
        engine.setSampleSink { [weak clipRecorder] samples in
            clipRecorder?.append(samples)
        }
        eventCount = 0
        lastEventNote = nil
        phase = .running
    }

    func stop() {
        guard phase == .running else { return }
        engine.setSampleSink(nil)
        engine.stop()
        clipRecorder.flush()
        guard var s = session else {
            phase = .idle
            return
        }
        s.endTime = Date()
        s.overallLaeq = builder.currentLaeq()
        s.minSPL = builder.minSPL.isFinite ? builder.minSPL : 0
        s.maxSPL = builder.maxSPL.isFinite ? builder.maxSPL : 0
        store.update(s)
        session = nil
        phase = .idle
    }

    // MARK: - 引擎消费(主视图转发)

    func consume(_ result: MeterResult) {
        guard phase == .running else { return }
        let spl = result.splA
        guard spl.isFinite else { return }
        builder.observe(spl: spl)
        let low = lowFrequencyRatio(spectrum: result.spectrum,
                                    frequencies: result.frequencies)
        let t = Date().timeIntervalSince(sessionStart)
        let finished = eventEngine.feed(t: t, spl: spl, lowRatio: low)
        currentLaeq = builder.currentLaeq()
        baseline = eventEngine.currentBaseline() ?? -.greatestFiniteMagnitude
        if let event = finished {
            record(event: event)
        }
    }

    private func record(event: NoiseEvent) {
        guard var s = session, s.events.count < Self.maxEventsPerSession else { return }
        let isImpact = (event.avgLowRatio ?? 0) >= 0.5
        // 单事件类型:低频冲击 → impact;足够长的连续段 → continuous;否则未知
        let type: NoiseType
        if isImpact { type = .impact }
        else if event.duration >= 8 { type = .continuous }
        else { type = .unknown }
        let guess = SourceTendencyAnalyzer.guessPosition(lowRatio: event.avgLowRatio ?? 0,
                                                         isImpact: isImpact,
                                                         calibration: SourceTestStore.shared.latest)
        let monitorEvent = MonitorEvent(time: Date().addingTimeInterval(-event.duration),
                                        peakSPL: event.peakSPL, duration: event.duration,
                                        avgLowRatio: event.avgLowRatio ?? 0,
                                        type: type, guess: guess,
                                        clipFile: clipRecorder.lastClipURL?.lastPathComponent)
        s.events.append(monitorEvent)
        eventCount = s.events.count
        store.update(s)
        session = s
        lastEventNote = "\(SourceTendencyAnalyzer.typeText(type)) · \(guess)"
        clipRecorder.endClip()
    }
}
