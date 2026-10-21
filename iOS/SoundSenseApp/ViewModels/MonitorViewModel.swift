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
    /// 启动失败时给界面的可操作提示
    @Published private(set) var startError: String?
    /// 系统中断/路由切换后的恢复提示。监听继续时不抹掉已测数据。
    @Published private(set) var audioRecoveryNote: String?
    /// 显示系统要求用户手动恢复的场景。音频已中断时不能继续展示
    /// “监听中”，否则用户会误以为中断期间仍被记录。
    @Published private(set) var waitingForAudioRecovery = false

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
    /// 最近一个分析帧对应的音频时钟终点（秒）及样本位置。
    private var audioElapsed: TimeInterval = 0
    private var cancellables = Set<AnyCancellable>()
    private var isStarting = false
    /// 启动期间用户已请求停止；start() 完成或失败后必须立即回滚。
    private var shouldAbortStart = false
    /// 分析回调与 UI 消费都在主线程串行执行；音频线程只投递 hop 结果。
    /// 这样事件状态机不需要跨线程加锁，也不会因锁争用影响音频队列。
    private var isConsumingAnalysis = false
    /// 主队列积压超过上限时事件时间线可能缺帧；最终 SPL/Leq 仍由
    /// 引擎全帧统计兜底，但会话必须记录“不完整”。
    private var analysisQueueOverflowed = false
    /// stop() 要等已经投递到 MainActor 的分析任务全部执行完，不能只靠
    /// engine 的“已交付”屏障。后者只代表跨过了 sink，尚未保证本 VM 消费。
    /// 队列上限。正常处理速度远高于 23 hop/s；若主线程长时间卡住，
    /// 只保留最新结果，避免频谱数组无限占用内存。
    private static let maxPendingAnalysisResults = 256
    /// 分析结果先在非隔离收件箱合并，主线程只保留一个排空任务。
    private let analysisInbox = AnalysisDeliveryInbox(
        maxResults: MonitorViewModel.maxPendingAnalysisResults)

    init() {
        engine = AudioMeterEngine(calibrationOffset: Self.currentCalibrationOffset(),
                                  throttleInterval: 0.25, fftSize: 4096,
                                  spectrumEnabled: false,
                                  lowBandAnalysisInterval: 0.5)
        engine.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &cancellables)
    }

    /// 与主测量一致的校准偏移(含旧默认迁移)
    private static func currentCalibrationOffset() -> Float {
        CalibrationDefaults.resolved(platformDefault: CalibrationDefaults.iosBuiltIn)
    }

    var deviceName: String { UIDevice.current.name }

    // MARK: - 开始 / 停止

    func start() async {
        guard phase == .idle, !isStarting else { return }
        isStarting = true
        shouldAbortStart = false
        defer { isStarting = false }
        startError = nil
        audioRecoveryNote = nil
        waitingForAudioRecovery = false
        clipRecorder.finish()

        eventEngine = NoiseEventEngine()
        eventEngine.beginSession()
        eventEngine.thresholdOverBackground = Float(thresholdOver)
        eventEngine.absoluteThreshold =
            absoluteEnabled ? Float(absoluteDB) : nil
        eventEngine.onEventStart = { [clipRecorder] in
            // 分析在 meterQueue，片段写入在 EventClipRecorder 自己的串行队列；
            // 按队列顺序先投递当前 PCM，再开片段，pre-roll 才完整。
            clipRecorder.beginClip()
        }
        builder = PositionStatsBuilder()
        sessionStart = Date()
        audioElapsed = 0

        let id = UUID()
        let newSession = MonitorSession(
            id: id, startTime: sessionStart,
            overallLaeq: 0, minSPL: 0, maxSPL: 0,
            weighting: engine.weighting == .c ? "C" : "A",
            timeWeighting: engine.timeWeighting == .slow ? "S" : "F",
            thresholdOverBackground: Float(thresholdOver),
            absoluteThreshold: absoluteEnabled ? Float(absoluteDB) : nil)
        isConsumingAnalysis = false
        analysisQueueOverflowed = false
        analysisPending.removeAll(keepingCapacity: false)
        analysisInbox.reset()
        let inbox = analysisInbox
        let inboxGeneration = inbox.currentGeneration
        // 先装分析 sink 再启动硬件。启动阶段的首批 hop 暂存在内存队列，
        // 成功启动后再按音频时钟依次消费，避免开头事件和片段 pre-roll 丢失。
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
                startError = "麦克风权限被拒绝，请到系统设置中允许闻声访问麦克风。"
            case .failed(let message):
                startError = "无法启动监听：\(message)"
            default:
                startError = "监听未能启动，请稍后重试。"
            }
            return
        }

        configureClipCapture(directory: store.clipsDirectory(sessionID: id))
        engine.setSampleSink { [weak clipRecorder] samples in
            clipRecorder?.append(samples)
        }
        session = newSession
        store.add(newSession)
        eventCount = 0
        lastEventNote = nil
        phase = .running
        drainAnalysisIfNeeded()
        publishLiveStats()
    }

    private func configureClipCapture(directory: URL) {
        clipRecorder.configure(directory: directory,
                               inputSampleRate: engine.activeSampleRate)
    }

    func refreshAudioRecoveryState() {
        let note = engine.audioRecoveryNote
        if audioRecoveryNote != note {
            audioRecoveryNote = note
        }
        let waiting = engine.state != .running
            && phase == .running
            && audioRecoveryNote != nil
        if waitingForAudioRecovery != waiting {
            waitingForAudioRecovery = waiting
        }
    }

    private func refreshRecoveryNote() {
        refreshAudioRecoveryState()
    }

    func stop() async {
        // 页面可能在权限弹窗/硬件启动期间被关闭。此时也必须撤销启动，
        // 不能因为 phase 还是 idle 就直接返回，否则 await start() 完成后
        // 会继续采集并留下“隐形监听”。
        guard phase == .running || isStarting else { return }
        if isStarting {
            shouldAbortStart = true
            return
        }
        // 先冻结硬件并排空音频 worker，再收口事件；否则最后约一个 hop
        // 的事件/峰值会丢。分析 sink 由 freeze 在尾批交付后暂停。
        engine.setSampleSink(nil)
        await engine.freezeForFinalization()
        await waitForAnalysisTasksToDrain()
        let endTime = engine.captureTimeRange?.upperBound ?? Date()
        let finalTime = max(audioElapsed, engine.sessionLeqDuration, 0)
        let analysisDrainTimedOut =
            engine.sessionLeqDuration > audioElapsed + 0.05
        if analysisDrainTimedOut {
            // 正常路径不应进入：音频链路已完整处理，但 ViewModel 收尾队列
            // 仍未追上。明确提示，避免把不完整的 Leq 冒充为完整统计。
            audioRecoveryNote = "停止时分析队列未完全落账，报告已使用引擎最终统计。"
        }
        builder.finish(at: finalTime)
        var openEvent = eventEngine.snapshotOpenEvent()
        if var event = openEvent {
            event.endTime = min(event.endTime, finalTime)
            openEvent = event
        }
        if clipRecorder.isClipOpen || openEvent != nil {
            record(event: openEvent
                   ?? NoiseEvent(startTime: finalTime, endTime: finalTime,
                                 peakSPL: currentLaeq.isFinite ? currentLaeq : 0,
                                 avgLowRatio: nil, attackRate: 0))
        }
        clipRecorder.finish()
        clipRecorder.flush()
        guard var s = session else {
            phase = .idle
            return
        }
        s.endTime = endTime
        let finalLeq = engine.sessionLeqSPL.isFinite
            ? engine.sessionLeqSPL : builder.currentLaeq()
        let finalPeak = engine.sessionPeakSPL.isFinite
            ? engine.sessionPeakSPL : builder.maxSPL
        s.overallLaeq = finalLeq
        s.minSPL = builder.minSPL.isFinite ? builder.minSPL : 0
        s.maxSPL = finalPeak.isFinite ? finalPeak : 0
        s.captureIncomplete =
            engine.sessionDroppedSampleCount > 0
                || engine.audioDiscontinuityCount > 0
                || analysisQueueOverflowed
                || analysisDrainTimedOut
        store.update(s)
        store.flush()
        currentLaeq = finalLeq
        engine.finishFinalization()
        analysisInbox.reset()
        session = nil
        analysisQueueOverflowed = false
        waitingForAudioRecovery = false
        phase = .idle
    }

    // MARK: - 引擎消费(低频 UI 刷新)

    func consume(_ result: MeterResult) {
        guard phase == .running else { return }
        let spl = result.splA
        guard spl.isFinite else { return }
        publishLiveStats()
        if clipRecorder.isFinalizedForCompletedEvent,
           let clip = clipRecorder.lastClipURL?.lastPathComponent,
           var current = session,
           let index = current.events.indices.last,
           current.events[index].clipFile == nil {
            current.events[index].clipFile = clip
            session = current
            store.update(current)
            clipRecorder.markLastClipConsumed()
        }
    }

    private func record(event: NoiseEvent) {
        // 有些事件在片段硬时限之后才结束时,endClip 会安全地返回 false。
        _ = clipRecorder.endClip()
        guard var s = session else { return }
        let classification = SourceTendencyAnalyzer.classifyMonitorEvent(
            lowRatio: event.avgLowRatio,
            duration: event.duration,
            attackRate: event.attackRate,
            calibration: SourceTestStore.shared.latest)
        let eventAudioTime = max(0, event.endTime - event.duration)
        let eventDate = engine.wallClockDate(forAudioTime: eventAudioTime,
                                             duration: event.duration)
        let clipCount = s.events.reduce(0) {
            $0 + ($1.clipFile == nil ? 0 : 1)
        }
        let monitorEvent = MonitorEvent(time: eventDate,
                                        peakSPL: event.peakSPL, duration: event.duration,
                                        avgLowRatio: event.avgLowRatio ?? 0,
                                        type: classification.type,
                                        guess: classification.guess,
                                        clipFile: clipCount < Self.maxEventsPerSession
                                            ? clipRecorder.lastClipURL?.lastPathComponent
                                            : nil)
        s.appendEvent(monitorEvent)
        if let avgLow = eventEngine.recentAverageLowRatio {
            s.recentAvgLowRatio = avgLow
        }
        eventCount = s.totalEventCount
        s.overallLaeq = engine.sessionLeqSPL.isFinite
            ? engine.sessionLeqSPL : builder.currentLaeq()
        s.minSPL = builder.minSPL.isFinite ? builder.minSPL : 0
        s.maxSPL = engine.sessionPeakSPL.isFinite
            ? engine.sessionPeakSPL
            : (builder.maxSPL.isFinite ? builder.maxSPL : 0)
        s.captureIncomplete = s.captureIncomplete
            || engine.sessionDroppedSampleCount > 0
            || engine.audioDiscontinuityCount > 0
            || analysisQueueOverflowed
        store.update(s)
        session = s
        lastEventNote = "\(SourceTendencyAnalyzer.typeText(classification.type)) · \(classification.guess)"
        let clipsAtLimit = s.events.reduce(0) {
            $0 + ($1.clipFile == nil ? 0 : 1)
        } >= Self.maxEventsPerSession
        if clipsAtLimit {
            // 达到片段上限后仍继续检测并记录事件，只停止新增音频片段，
            // 避免长监听悄悄失去事件时间线。
            engine.setSampleSink(nil)
            clipRecorder.disableCapture()
            lastEventNote = "已达到 \(Self.maxEventsPerSession) 条片段上限，后续继续记录事件但不保存新片段"
        }
    }

    /// 每约 0.25 秒一批投递，确保极短事件和精确结束边界不被 UI 节流漏掉。
    /// 状态机本身仍在 MainActor 上串行消费，避免与 UI 数据竞争。
    private nonisolated func consumeAnalysis(_ results: [MeterResult],
                                             inbox: AnalysisDeliveryInbox,
                                             generation: UInt64) {
        guard results.contains(where: { $0.splA.isFinite }) else { return }
        // 只在没有排空任务时投递一次主线程闭包；主线程慢时后续结果
        // 进入有界收件箱，不会生成无限多个待执行闭包。
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

    private func waitForAnalysisTasksToDrain() async {
        let deadline = Date().addingTimeInterval(2)
        while (isConsumingAnalysis
               || !analysisPending.isEmpty
               || analysisInbox.hasPendingWork)
                && Date() < deadline {
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
    }

    private struct AnalysisFrame { let result: MeterResult }

    private var analysisPending: [AnalysisFrame] = []

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
            if self.phase == .running,
               self.engine.state != .running,
               self.audioRecoveryNote != nil {
                // 恢复失败不能让界面静默假装仍在监听。
                self.waitingForAudioRecovery = true
            }
            if !self.analysisPending.isEmpty, self.phase == .running {
                self.drainAnalysisIfNeeded()
            } else {
                self.analysisPending.removeAll(keepingCapacity: true)
            }
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
            store.update(current)
            clipRecorder.markLastClipConsumed()
        }
    }

    /// UI 读数按分析批次刷新，不跟随每个 42.7 ms hop。
    /// 事件检测仍逐帧运行，这里只合并显示状态，避免过夜监听产生无意义重绘。
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
        refreshRecoveryNote()
    }
}
