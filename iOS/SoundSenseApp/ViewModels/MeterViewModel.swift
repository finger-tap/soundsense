//
//  MeterViewModel.swift
//  SoundSense iOS
//
//  iOS 主视图模型:持有 AudioMeterEngine,维护声波条历史,持久化校准值。
//

import SwiftUI
import SoundSenseCore

@MainActor
final class MeterViewModel: ObservableObject {

    /// 引擎
    @Published private(set) var engine: AudioMeterEngine
    /// 声波条历史(最近 N 个 SPL 值)
    @Published private(set) var history: [Float] = []
    /// 当前噪音等级(由最新 SPL 推导)
    @Published private(set) var noiseLevel: NoiseLevel?

    /// 历史数组最大长度
    private let historyCapacity = 80

    /// 校准偏移量,持久化到 UserDefaults
    @AppStorage("calibrationOffset") private var storedOffset: Double = 0

    var calibrationOffset: Float {
        get { Float(storedOffset) }
        set {
            storedOffset = Double(newValue)
            engine.calibrationOffset = newValue
        }
    }

    init() {
        // 先读持久化值,再据此建引擎
        let offset = Float(UserDefaults.standard.object(forKey: "calibrationOffset") as? Double ?? 0)
        let e = AudioMeterEngine(calibrationOffset: offset,
                                  throttleInterval: 1.0 / 15.0,  // ~15fps,流畅且省电
                                  fftSize: 4096)
        self.engine = e
    }

    // MARK: - 控制

    func start() async {
        await engine.start()
    }

    func stop() {
        engine.stop()
        history.removeAll(keepingCapacity: true)
        noiseLevel = nil
    }

    // MARK: - 在视图层用 .onChange 监听 engine.latestResult 时调用

    /// 消费一帧结果:更新历史与等级
    func consume(_ result: MeterResult) {
        let spl = result.splA
        history.append(spl)
        if history.count > historyCapacity {
            history.removeFirst(history.count - historyCapacity)
        }
        noiseLevel = NoiseLevel.level(for: spl)
    }

    /// 当前显示的 SPL(平滑后),用于大数字
    var currentSPL: Float {
        engine.latestResult?.splA ?? -.greatestFiniteMagnitude
    }
}
