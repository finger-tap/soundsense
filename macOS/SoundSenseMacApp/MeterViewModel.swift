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

    /// 大屏历史数组容量大一些
    private let historyCapacity = 120
    /// 订阅 engine 的变化,转发给本 ViewModel,让 UI 能刷新
    private var cancellables = Set<AnyCancellable>()
    /// 测量记录器(每秒采样 1 点,停止时生成报告数据)
    private let recorder = MeasurementRecorder()

    @AppStorage("calibrationOffset") private var storedOffset: Double = 93

    var calibrationOffset: Float {
        get { Float(storedOffset) }
        set {
            storedOffset = Double(newValue)
            engine.calibrationOffset = newValue
        }
    }

    init() {
        // 默认偏移量 +93 dB(典型 Mac 麦克风),开箱即显示 SPL 而非裸 dBFS。
        let offset = Float(UserDefaults.standard.object(forKey: "calibrationOffset") as? Double ?? 93)
        let e = AudioMeterEngine(calibrationOffset: offset,
                                  throttleInterval: 1.0 / 30.0,  // 30fps,桌面端更流畅
                                  fftSize: 4096)
        self.engine = e
        e.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)
    }

    func start() async {
        await engine.start()
        recorder.start()
    }

    func stop() {
        engine.stop()
        lastStats = recorder.stop()
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
    }

    var currentSPL: Float {
        engine.latestResult?.splA ?? -.greatestFiniteMagnitude
    }

    /// 设备名(用于报告页脚)
    var deviceName: String {
        ProcessInfo.processInfo.hostName
    }
}
