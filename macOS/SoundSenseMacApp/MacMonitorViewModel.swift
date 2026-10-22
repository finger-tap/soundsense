//
//  MacMonitorViewModel.swift
//  SoundSenseMac
//
//  macOS 长时间噪音监听。超过背景基线阈值的异常声会自动保存片段，
//  并在会话时间线中记录类型和位置推测。
//

import Foundation
import Combine
import SoundSenseCore

@MainActor
final class MacMonitorViewModel: ObservableObject {

    enum Phase: Equatable {
        case idle
        case running
    }

    static let maxEventsPerSession = 100

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var currentLaeq: Float = -.greatestFiniteMagnitude
    @Published private(set) var baseline: Float = -.greatestFiniteMagnitude
    @Published private(set) var eventCount = 0
    @Published private(set) var lastEventNote: String?
    @Published private(set) var startError: String?
    @Published private(set) var audioRecoveryNote: String?
    @Published private(set) var liveSession: MonitorSession?

    /// 触发阈值：背景 + N dB。
    @Published var thresholdOver: Double {
        didSet {
            UserDefaults.standard.set(thresholdOver, forKey: "monitorThresholdOver")
        }
    }
    /// 夜间绝对阈值：开启后取「背景阈值」和「绝对阈值」中较低者，
    /// 避免夜间模式反而因为 max() 变得不敏感。
    @Published var absoluteEnabled: Bool {
        didSet {
            UserDefaults.standard.set(absoluteEnabled, forKey: "monitorAbsoluteEnabled")
        }
    }
    @Published var absoluteDB: Double {
        didSet {
            UserDefaults.standard.set(absoluteDB, forKey: "monitorAbsoluteDB")
        }
    }

    let store = MonitorSessionStore.shared
    let engine: AudioMeterEngine

    private var eventEngine = NoiseEventEngine()
    private let clipRecorder = EventClipRecorder()
    private var builder = PositionStatsBuilder()
    private var session: MonitorSession?
    private var sessionStart = Date()
    private var audioElapsed: TimeInterval = 0
    private var cancellables = Set<AnyCancellable>()
    private var isStarting = false
    /// 启动期间用户已请求停止；start() 完成或失败后必须立即回滚。
    private var shouldAbortStart = false
    private var isConsumingAnalysis = false
    private var analysisQueueOverflowed = false
    private var analysisPending: [AnalysisFrame] = []
    private static let maxPendingAnalysisResults = 256
    private let analysisInbox = AnalysisDeliveryInbox(
        maxResults: MacMonitorViewModel.maxPendingAnalysisResults)

    private struct AnalysisFrame { let result: MeterResult }

    init(calibrationOffset: Float,
         inputDeviceUID: String?,
         weighting: Weighting,
         timeWeighting: TimeWeighting) {
        engine = AudioMeterEngine(calibrationOffset: calibrationOffset,
                                  throttleInterval: 0.25,
                                  fftSize: 4096,
                                  weighting: weighting,
                                  timeWeighting: timeWeighting,
                                  inputDeviceUID: inputDeviceUID,
                                  spectrumEnabled: false,
                                  lowBandAnalysisInterval: 0.5)
        thresholdOver = UserDefaults.standard.object(forKey: "monitorThresholdOver") as? Double ?? 10
        absoluteEnabled = UserDefaults.standard.bool(forKey: "monitorAbsoluteEnabled")
        absoluteDB = UserDefaults.standard.object(forKey: "monitorAbsoluteDB") as? Double ?? 45

        engine.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &cancellables)
    }

    // MARK: - 开始 / 停止

    func start() async {
        guard phase == .idle, !isStarting else { return }
        isStarting = true
        shouldAbortStart = false
        defer { isStarting = false }
        startError = nil
        audioRecoveryNote = nil
        clipRecorder.finish()

        eventEngine = NoiseEventEngine()
        eventEngine.beginSession()
        eventEngine.thresholdOverBackground = Float(thresholdOver)
        if absoluteEnabled { eventEngine.absoluteThreshold = Float(absoluteDB) }
        eventEngine.onEventStart = { [clipRecorder] in
            clipRecorder.beginClip()
        }
        builder = PositionStatsBuilder()
        sessionStart = Date()
        audioElapsed = 0

        let id = UUID()
        let newSession = MonitorSession(id: id,
                                        startTime: sessionStart,
                                        overallLaeq: 0,
                                        minSPL: 0,
                                        maxSPL: 0,
                                        weighting: engine.weighting == .c ? "C" : "A",
                                        timeWeighting: engine.timeWeighting == .slow ? "S" : "F",
                                        thresholdOverBackground: Float(thresholdOver),
                                        absoluteThreshold: absoluteEnabled ? Float(absoluteDB) : nil)
        analysisPending.removeAll(keepingCapacity: false)
        isConsumingAnalysis = false
        analysisQueueOverflowed = false
        analysisInbox.reset()
        let inbox = analysisInbox
        let inboxGeneration = inbox.currentGeneration
        // 先准备分析消费者，再启动硬件；启动窗口内产生的结果先缓存，
        // 成功运行后立即按音频时钟消费。
        engine.setAnalysisSink { [weak self, inbox, inboxGeneration] results in
            self?.consumeAnalysis(results,
                                  inbox: inbox,
                                  generation: inboxGeneration)
        }
        await engine.start()
        guard !shouldAbortStart else {
            engine.setSampleSink(nil)
            engine.setAnalysisSink(nil)
            engine.stop()
            clipRecorder.finish()
            clipRecorder.flush()
            analysisPending.removeAll(keepingCapacity: false)
            analysisInbox.reset()
            phase = .idle
            return
        }
        guard engine.state == .running else {
            engine.setSampleSink(nil)
            engine.setAnalysisSink(nil)
            clipRecorder.finish()
            analysisPending.removeAll(keepingCapacity: false)
            analysisInbox.reset()
            phase = .idle
            switch engine.state {
            case .denied:
                startError = "麦克风权限被拒绝。请到系统设置 → 隐私与安全性 → 麦克风允许闻声。"
            case .failed(let message):
                startError = "无法启动监听：\(message)"
            default:
                startError = "监听未能启动，请检查输入设备后重试。"
            }
            return
        }

        clipRecorder.configure(directory: store.clipsDirectory(sessionID: id),
                               inputSampleRate: engine.activeSampleRate)
        engine.setSampleSink { [weak clipRecorder] samples in
            clipRecorder?.append(samples)
        }
        session = newSession
        liveSession = newSession
        store.add(newSession)
        eventCount = 0
        lastEventNote = nil
        phase = .running
        drainAnalysisIfNeeded()
        publishLiveStats()
    }

    func stop() async {
        guard phase == .running || isStarting else { return }
        if isStarting {
            shouldAbortStart = true
            return
        }
        // 先冻结硬件并排空音频 worker，再收口事件和统计。
        engine.setSampleSink(nil)
        await engine.freezeForFinalization()
        await waitForAnalysisDrain()
        let endTime = engine.captureTimeRange?.upperBound ?? Date()
        let finalTime = max(audioElapsed, engine.sessionLeqDuration, 0)
        let analysisDrainTimedOut =
            engine.sessionLeqDuration > audioElapsed + 0.05
        if analysisDrainTimedOut {
            audioRecoveryNote = "停止时分析队列未完全落账，报告已使用引擎最终统计。"
        }
        builder.finish(at: finalTime)
        let openEvent = eventEngine.snapshotOpenEvent()
        if clipRecorder.isClipOpen || openEvent != nil {
            record(event: openEvent
                   ?? NoiseEvent(startTime: finalTime, endTime: finalTime,
                                 peakSPL: currentLaeq.isFinite ? currentLaeq : 0,
                                 avgLowRatio: nil, attackRate: 0))
        }
        clipRecorder.finish()
        clipRecorder.flush()

        if var current = session {
            current.endTime = endTime
            let finalLeq = engine.sessionLeqSPL.isFinite
                ? engine.sessionLeqSPL : builder.currentLaeq()
            let finalPeak = engine.sessionPeakSPL.isFinite
                ? engine.sessionPeakSPL : builder.maxSPL
            current.overallLaeq = finalLeq
            current.minSPL = builder.minSPL.isFinite ? builder.minSPL : 0
            current.maxSPL = finalPeak.isFinite ? finalPeak : 0
            current.captureIncomplete =
                engine.sessionDroppedSampleCount > 0
                    || engine.audioDiscontinuityCount > 0
                    || analysisQueueOverflowed
                    || analysisDrainTimedOut
                    || clipRecorder.droppedAppendCount > 0
            current.droppedClipBlockCount = clipRecorder.droppedAppendCount
            store.update(current)
            store.flush()
            liveSession = current
            currentLaeq = finalLeq
        }
        engine.finishFinalization()
        analysisInbox.reset()
        session = nil
        analysisQueueOverflowed = false
        phase = .idle
    }

    // MARK: - 引擎消费

    func consume(_ result: MeterResult) {
        guard phase == .running else { return }
        let spl = result.splA
        guard spl.isFinite else { return }
        let t = Date().timeIntervalSince(sessionStart)
        builder.observe(spl: spl, at: t)
        let low = lowFrequencyRatio(spectrum: result.spectrum,
                                    frequencies: result.frequencies)
        let finished = eventEngine.feed(t: t, spl: spl, lowRatio: low)
        publishLiveStats()
        if let event = finished {
            record(event: event)
        }
        if clipRecorder.isFinalizedForCompletedEvent,
           let clip = clipRecorder.lastClipURL?.lastPathComponent,
           var current = session,
           let index = current.events.indices.last,
           current.events[index].clipFile == nil {
            current.events[index].clipFile = clip
            session = current
            liveSession = current
            store.update(current)
            clipRecorder.markLastClipConsumed()
        }
    }

    private func record(event: NoiseEvent) {
        _ = clipRecorder.endClip()
        guard var current = session else { return }
        let classification = SourceTendencyAnalyzer.classifyMonitorEvent(
            lowRatio: event.avgLowRatio,
            duration: event.duration,
            attackRate: event.attackRate,
            calibration: SourceTestStore.shared.latest)
        let eventAudioTime = max(0, event.endTime - event.duration)
        let eventDate = engine.wallClockDate(forAudioTime: eventAudioTime,
                                             duration: event.duration)
        let clipCount = current.events.reduce(0) {
            $0 + ($1.clipFile == nil ? 0 : 1)
        }
        let monitorEvent = MonitorEvent(time: eventDate,
                                        peakSPL: event.peakSPL,
                                        duration: event.duration,
                                        avgLowRatio: event.avgLowRatio ?? 0,
                                        type: classification.type,
                                        guess: classification.guess,
                                        clipFile: clipCount < Self.maxEventsPerSession
                                            ? clipRecorder.lastClipURL?.lastPathComponent
                                            : nil)
        current.appendEvent(monitorEvent)
        if let avgLow = eventEngine.recentAverageLowRatio {
            current.recentAvgLowRatio = avgLow
        }
        eventCount = current.totalEventCount
        current.overallLaeq = engine.sessionLeqSPL.isFinite
            ? engine.sessionLeqSPL : builder.currentLaeq()
        current.minSPL = builder.minSPL.isFinite ? builder.minSPL : 0
        current.maxSPL = engine.sessionPeakSPL.isFinite
            ? engine.sessionPeakSPL
            : (builder.maxSPL.isFinite ? builder.maxSPL : 0)
        current.captureIncomplete = current.captureIncomplete
            || engine.sessionDroppedSampleCount > 0
            || engine.audioDiscontinuityCount > 0
            || analysisQueueOverflowed
            || clipRecorder.droppedAppendCount > 0
        current.droppedClipBlockCount = clipRecorder.droppedAppendCount
        store.update(current)
        session = current
        liveSession = current
        lastEventNote = "\(SourceTendencyAnalyzer.typeText(classification.type)) · \(classification.guess)"
        let clipsAtLimit = current.events.reduce(0) {
            $0 + ($1.clipFile == nil ? 0 : 1)
        } >= Self.maxEventsPerSession
        if clipsAtLimit {
            // 仅停止新增片段，事件检测和声级统计继续运行。
            engine.setSampleSink(nil)
            clipRecorder.disableCapture()
            lastEventNote = "已达到 \(Self.maxEventsPerSession) 条片段上限，后续继续记录事件但不保存新片段"
        }
    }

    /// 每约 0.25 秒一批投递，避免事件检测被 10 Hz 的 UI 节流漏掉。
    private nonisolated func consumeAnalysis(_ results: [MeterResult],
                                             inbox: AnalysisDeliveryInbox,
                                             generation: UInt64) {
        guard results.contains(where: { $0.splA.isFinite }) else { return }
        inbox.enqueue(results, generation: generation) { [weak self] in
            guard let self else {
                inbox.abandonDrain()
                return
            }
            Task { @MainActor in
                self.drainAnalysisInbox(inbox: inbox, generation: generation)
            }
        }
    }

    private func drainAnalysisInbox(inbox: AnalysisDeliveryInbox,
                                    generation: UInt64) {
        guard phase == .running || isStarting else {
            if inbox.abandonDrainAndCheckPending() {
                inbox.enqueue([], generation: generation) { [weak self] in
                    guard let self else {
                        inbox.abandonDrain()
                        return
                    }
                    Task { @MainActor in
                        self.drainAnalysisInbox(inbox: inbox,
                                                generation: generation)
                    }
                }
            }
            return
        }
        guard let payload = inbox.takeAll(generation: generation) else {
            return
        }
        if payload.overflowed {
            analysisQueueOverflowed = true
        }
        analysisPending.append(contentsOf: payload.results.map(AnalysisFrame.init))
        if analysisPending.count > Self.maxPendingAnalysisResults {
            let overflow = analysisPending.count - Self.maxPendingAnalysisResults
            analysisPending.removeFirst(overflow)
            analysisQueueOverflowed = true
        }
        if phase == .running {
            drainAnalysisIfNeeded()
        }
    }

    private func drainAnalysisIfNeeded() {
        guard !isConsumingAnalysis, !analysisPending.isEmpty else { return }
        isConsumingAnalysis = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            var processed = 0
            while self.phase == .running,
                  !self.analysisPending.isEmpty,
                  processed < 128 {
                let next = self.analysisPending.removeFirst()
                self.consumeFullRate(next.result)
                processed += 1
            }
            self.publishLiveStats()
            self.isConsumingAnalysis = false
            if !self.analysisPending.isEmpty, self.phase == .running {
                self.drainAnalysisIfNeeded()
            } else {
                self.analysisPending.removeAll(keepingCapacity: true)
            }
        }
    }

    private func waitForAnalysisDrain() async {
        let deadline = Date().addingTimeInterval(2)
        while (isConsumingAnalysis
               || !analysisPending.isEmpty
               || analysisInbox.hasPendingWork)
                && Date() < deadline {
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
    }

    private func consumeFullRate(_ result: MeterResult) {
        let spl = result.splA
        guard spl.isFinite else { return }
        guard result.integratedSampleCount > 0 else { return }
        let duration = result.coveredDuration
        let t = audioElapsed + duration
        audioElapsed = t
        // 事件检测使用未平滑 hop 能量；显示层仍保留 F/S 峰值。
        let eventSPL = result.splInstant
        builder.observe(spl: eventSPL, duration: duration, at: t)
        let low = lowFrequencyRatio(spectrum: result.spectrum,
                                    frequencies: result.frequencies)
        let finished = eventEngine.feed(t: t, duration: duration,
                                        spl: eventSPL, lowRatio: low)
        if let event = finished {
            record(event: event)
        }
        if clipRecorder.isFinalizedForCompletedEvent,
           let clip = clipRecorder.lastClipURL?.lastPathComponent,
           var current = session,
           let index = current.events.indices.last,
           current.events[index].clipFile == nil {
            current.events[index].clipFile = clip
            session = current
            liveSession = current
            store.update(current)
            clipRecorder.markLastClipConsumed()
        }
    }

    /// UI 读数按分析批次刷新，不跟随每个 42.7 ms hop。
    private func publishLiveStats() {
        let newLaeq = engine.sessionLeqSPL.isFinite
            ? engine.sessionLeqSPL : builder.currentLaeq()
        if currentLaeq != newLaeq {
            currentLaeq = newLaeq
        }
        let newBaseline = eventEngine.currentBaseline() ?? -.greatestFiniteMagnitude
        if baseline != newBaseline {
            baseline = newBaseline
        }
        let note = engine.audioRecoveryNote
        if audioRecoveryNote != note {
            audioRecoveryNote = note
        }
    }
}
