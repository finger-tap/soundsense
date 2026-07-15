//
//  MeterViewModel.swift
//  SoundSense iOS
//
//  iOS 主视图模型:持有 AudioMeterEngine,维护声波条历史,持久化校准值 + 测量记录。
//

import SwiftUI
import Combine
import SoundSenseCore
#if os(iOS)
import UIKit
#endif

@MainActor
final class MeterViewModel: ObservableObject {

    /// 引擎:创建后不变。它的 @Published 变化通过 cancellables 转发。
    let engine: AudioMeterEngine
    @Published private(set) var history: [Float] = []
    @Published private(set) var noiseLevel: NoiseLevel?
    /// 最近一次测量的统计(停止检测后填充,用于导出报告)
    @Published private(set) var lastStats: MeasurementStats?

    /// 历史数组最大长度
    private let historyCapacity = 80
    /// 订阅 engine 变化转发给本 VM
    private var cancellables = Set<AnyCancellable>()
    /// 测量记录器(每秒采样 1 点,停止时生成报告数据)
    private let recorder = MeasurementRecorder()

    /// 校准偏移量,持久化到 UserDefaults(默认 +93 dB,典型 iOS 麦克风)
    @AppStorage("calibrationOffset") private var storedOffset: Double = 93

    var calibrationOffset: Float {
        get { Float(storedOffset) }
        set {
            storedOffset = Double(newValue)
            engine.calibrationOffset = newValue
        }
    }

    init() {
        let offset = Float(UserDefaults.standard.object(forKey: "calibrationOffset") as? Double ?? 93)
        let e = AudioMeterEngine(calibrationOffset: offset,
                                  throttleInterval: 1.0 / 15.0,  // ~15fps,流畅且省电
                                  fftSize: 4096)
        self.engine = e
        // ★ 转发 engine 的 objectWillChange,否则 UI 观察不到 latestResult/state
        e.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)
    }

    // MARK: - 控制

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
        #if os(iOS)
        return UIDevice.current.name
        #else
        return ProcessInfo.processInfo.hostName
        #endif
    }
}
