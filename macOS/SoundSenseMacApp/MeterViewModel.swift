//
//  MeterViewModel.swift
//  SoundSenseMac
//
//  macOS 主视图模型:复用共享 AudioMeterEngine。
//

import SwiftUI
import SoundSenseCore

@MainActor
final class MeterViewModel: ObservableObject {

    @Published private(set) var engine: AudioMeterEngine
    @Published private(set) var history: [Float] = []
    @Published private(set) var noiseLevel: NoiseLevel?

    /// 大屏历史数组容量大一些
    private let historyCapacity = 120

    @AppStorage("calibrationOffset") private var storedOffset: Double = 0

    var calibrationOffset: Float {
        get { Float(storedOffset) }
        set {
            storedOffset = Double(newValue)
            engine.calibrationOffset = newValue
        }
    }

    init() {
        let offset = Float(UserDefaults.standard.object(forKey: "calibrationOffset") as? Double ?? 0)
        let e = AudioMeterEngine(calibrationOffset: offset,
                                  throttleInterval: 1.0 / 30.0,  // 30fps,桌面端更流畅
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
