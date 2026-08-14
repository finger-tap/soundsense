//
//  MeterViewModel.swift
//  SoundSenseMac
//
//  macOS 主视图模型:复用共享 AudioMeterEngine + 测量记录。
//

import SwiftUI
import Combine
import SoundSenseCore

@MainActor
final class MeterViewModel: ObservableObject {

    /// 引擎:创建后不变。它的 @Published 变化通过下面 cancellables 转发。
    let engine: AudioMeterEngine
    @Published private(set) var history: [Float] = []
    @Published private(set) var noiseLevel: NoiseLevel?
    /// 最近一次测量的统计(停止检测后填充,用于导出报告)
    @Published private(set) var lastStats: MeasurementStats?
    /// 测量进行中的实时统计(时长 / LAeq / 峰值),nil = 未在测量
    @Published private(set) var liveStats: LiveMeasurementStats?
    /// 噪声暴露警告:连续超过 85 dB 达到阈值后置 true,回落或重开后复位
    @Published private(set) var exposureWarning = false
    /// 测量历史(持久化)
    let historyStore = MeasurementHistoryStore.shared

    /// 大屏历史数组容量大一些
    private let historyCapacity = 120
    /// 订阅 engine 的变化,转发给本 ViewModel,让 UI 能刷新
    private var cancellables = Set<AnyCancellable>()
    /// 测量记录器(每秒采样 1 点,停止时生成报告数据)
    private let recorder: MeasurementRecorder
    /// 每秒刷新实时统计的定时器
    private var liveTimer: Timer?
    /// 每场测量只发一次暴露通知
    private var exposureNotified = false

    @AppStorage("calibrationOffset") private var storedOffset: Double = 93
    /// 频率计权(A/C),持久化
    @AppStorage("weighting") private var storedWeighting: String = "A"
    /// 暴露警告阈值(dB),持久化
    @AppStorage("warningThreshold") private var storedThreshold: Double = MeasurementRecorder.defaultExposureLimit

    var calibrationOffset: Float {
        get { Float(storedOffset) }
        set {
            storedOffset = Double(newValue)
            engine.calibrationOffset = newValue
        }
    }

    var weighting: Weighting {
        get { storedWeighting == "C" ? .c : .a }
        set {
            storedWeighting = newValue.rawValue.uppercased()
            engine.weighting = newValue
        }
    }

    var warningThreshold: Float {
        get { Float(storedThreshold) }
        set {
            storedThreshold = Double(newValue)
            recorder.exposureLimit = newValue
        }
    }

    init() {
        // 默认偏移量 +93 dB(典型 Mac 麦克风),开箱即显示 SPL 而非裸 dBFS。
        let offset = Float(UserDefaults.standard.object(forKey: "calibrationOffset") as? Double ?? 93)
        let weightingRaw = UserDefaults.standard.string(forKey: "weighting") ?? "A"
        let weighting: Weighting = weightingRaw == "C" ? .c : .a
        let threshold = Float(UserDefaults.standard.object(forKey: "warningThreshold") as? Double
                              ?? Double(MeasurementRecorder.defaultExposureLimit))
        let e = AudioMeterEngine(calibrationOffset: offset,
                                  throttleInterval: 1.0 / 30.0,  // 30fps,桌面端更流畅
                                  fftSize: 4096,
                                  weighting: weighting)
        self.engine = e
        self.recorder = MeasurementRecorder(exposureLimit: threshold)
        e.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)
    }

    func start() async {
        await engine.start()
        guard engine.state == .running else { return }
        recorder.start()
        exposureWarning = false
        exposureNotified = false
        startLiveTimer()
        NoiseAlertNotifier.requestAuthorization()
    }

    func stop() {
        engine.stop()
        stopLiveTimer()
        if let stats = recorder.stop() {
            lastStats = stats
            historyStore.add(stats)
        }
        liveStats = nil
        exposureWarning = false
        history.removeAll(keepingCapacity: true)
        noiseLevel = nil
    }

    /// 消费一帧结果:更新历史与等级,并记录到报告采样。
    func consume(_ result: MeterResult) {
        let spl = result.splA
        history.append(spl)
        if history.count > historyCapacity {
            history.removeFirst(history.count - historyCapacity)
        }
        noiseLevel = NoiseLevel.level(for: spl)
        recorder.record(spl: spl)
        liveStats = recorder.liveStats()

        // 暴露警告:连续超限达到阈值
        if let live = liveStats,
           live.overLimitContinuous >= MeasurementRecorder.warningAfter {
            exposureWarning = true
            if !exposureNotified {
                exposureNotified = true
                NoiseAlertNotifier.notifyExposure(
                    db: recorder.exposureLimit,
                    seconds: Int(live.overLimitContinuous))
            }
        }
    }

    var currentSPL: Float {
        engine.latestResult?.splA ?? -.greatestFiniteMagnitude
    }

    /// 设备名(用于报告页脚)
    var deviceName: String {
        ProcessInfo.processInfo.hostName
    }

    // MARK: - 实时统计定时器

    private func startLiveTimer() {
        liveTimer?.invalidate()
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self = self, self.engine.state == .running else { return }
                self.liveStats = self.recorder.liveStats()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        liveTimer = timer
    }

    private func stopLiveTimer() {
        liveTimer?.invalidate()
        liveTimer = nil
    }
}
