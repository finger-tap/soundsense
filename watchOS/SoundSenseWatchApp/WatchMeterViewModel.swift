//
//  WatchMeterViewModel.swift
//  SoundSenseWatch
//
//  watchOS 视图模型:复用 AudioMeterEngine,节流更激进以省电。
//  watchOS 只在前台测量 —— 见 WatchMeterView 的 scenePhase 处理。
//

import SwiftUI
import SoundSenseCore

@MainActor
final class WatchMeterViewModel: ObservableObject {

    @Published private(set) var engine: AudioMeterEngine
    @Published private(set) var history: [Float] = []
    @Published private(set) var noiseLevel: NoiseLevel?

    /// 表盘声波条历史长度短一些(适配小屏)
    private let historyCapacity = 36

    init() {
        let e = AudioMeterEngine(calibrationOffset: 0,
                                  throttleInterval: 0.2,   // 5fps,省电
                                  fftSize: 4096)
        self.engine = e
    }

    func start() async {
        await engine.start()
    }

    func stop() {
        engine.stop()
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
    }

    var currentSPL: Float {
        engine.latestResult?.splA ?? -.greatestFiniteMagnitude
    }
}
