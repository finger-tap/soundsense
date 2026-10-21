//
//  main.swift
//  soundsense
//
//  闻声 SoundSense -- 命令行验证工具，三种模式：
//    soundsense test    -- 用已知分贝的合成信号验证算法准确性
//    soundsense sweep   -- 扫频，观察 A 计权曲线
//    soundsense live    -- 实时麦克风测量（需要麦克风权限）
//

import Foundation
#if canImport(CoreAudio)
import CoreAudio
#endif
// SwiftPM 模块化编译需要显式 import SoundSenseCore;
// scripts/build.sh 走 swiftc 单文件编译(把算法源码直接并入编译单元),
// 此时模块不存在,用 canImport 守卫跳过,两种方式都能编译。
#if canImport(SoundSenseCore)
import SoundSenseCore
#endif

// MARK: - 命令行解析

let args = Array(CommandLine.arguments.dropFirst())
// 默认 live 模式（.app bundle 启动时不带参数，应直接进入实时测量）
let mode = args.first ?? "live"

func printUsage() {
    print("""
    闻声 SoundSense -- 环境噪音分贝计

    用法:
      soundsense test     用合成信号验证算法
      soundsense sweep    扫频观察 A 计权曲线
      soundsense live     实时麦克风测量

    示例:
      soundsense test
      soundsense sweep
      soundsense live
    """)
}

switch mode {
case "test":  runTests()
case "sweep": runSweep()
case "live":  runLive()
case "-h", "--help": printUsage()
default:
    print("未知模式: \(mode)\n")
    printUsage()
    exit(1)
}

// MARK: - 模式 1：算法验证测试

func runTests() {
    print("═══════════════════════════════════════════════════════════")
    print("  分贝计算法验证 -- 用数学上已知分贝的合成信号检验")
    print("═══════════════════════════════════════════════════════════\n")

    let sampleRate: Float = 48000
    let fftSize = 4096
    let meter = DBMeter(config: MeterConfig(sampleRate: sampleRate,
                                             fftSize: fftSize,
                                             calibrationOffset: 0))
    let n = fftSize * 4  // 取 4 个 FFT 帧的数据，更稳定
    var passed = 0
    var failed = 0

    func test(name: String,
              signal: [Float],
              expectedDBFS: Float,
              tolerance: Float = 2.0) {
        // 取信号中间一段，避免边缘效应
        let startIdx = fftSize
        let frame = Array(signal[startIdx..<(startIdx + fftSize)])
        guard let result = meter.process(frame) else {
            print("❌ \(name): 处理失败")
            failed += 1
            return
        }

        // 用未计权的 dBFS(flat) 验证，因为它对应全频段 RMS
        let diff = result.dbfsFlat - expectedDBFS
        let ok = abs(diff) < tolerance
        let mark = ok ? "✅" : "❌"

        print("\(mark) \(name)")
        print("     预期 dBFS(flat) = \(String(format: "%6.2f", expectedDBFS))")
        print("     实际 dBFS(flat) = \(String(format: "%6.2f", result.dbfsFlat))  差值 \(String(format: "%+.2f", diff)) dB")
        print("     \(result)")
        print()

        if ok { passed += 1 } else { failed += 1 }
    }

    // 1. 不同振幅的 1 kHz 正弦波
    //    纯正弦波 RMS = amplitude / sqrt(2)
    //    dBFS = 20·log10(amplitude / sqrt(2))
    print("── 测试组 1：1 kHz 正弦波，不同振幅 ──────────────────────")
    let amplitudes: [(Float, String)] = [
        (1.0,    "满幅 0 dBFS"),
        (0.5,    "-6.02 dBFS"),
        (0.1,    "-20 dBFS"),
        (0.01,   "-40 dBFS"),
        (0.001,  "-60 dBFS"),
    ]
    for (amp, label) in amplitudes {
        let expected = 20 * log10(amp / Float(2.0.squareRoot()))
        let signal = SignalGenerator.sineWave(frequency: 1000,
                                               amplitude: amp,
                                               sampleRate: sampleRate,
                                               count: n)
        test(name: "1 kHz @ \(label)", signal: signal, expectedDBFS: expected)
    }

    // 2. 不同频率的正弦波，观察 A 计权效应
    //    关键：使用 bin 对齐频率（= k · binWidth），消除 FFT 频谱泄漏，
    //    才能精确验证 A 计权修正量是否正确。
    print("── 测试组 2：bin 对齐正弦波，验证 A 计权精度 ──────────")
    let binWidth = sampleRate / Float(fftSize)
    print("     bin 宽度 = \(String(format: "%.2f", binWidth)) Hz")
    print("     使用 bin 中心频率，消除泄漏，精确验证 A 计权\n")
    let targetBins: [Int] = [9, 43, 85, 171, 341, 683]  // ≈ 100,500,1k,2k,4k,8k Hz
    let amp: Float = 0.5

    print("  bin   频率        A计权理论   dBFS(flat)   dBFS(A)    差值    偏差    判定")
    print("  ────  ──────────  ─────────  ──────────   ────────   ────    ────    ────")
    for k in targetBins {
        let f = Float(k) * binWidth  // bin 对齐频率
        let signal = SignalGenerator.sineWave(frequency: f,
                                               amplitude: amp,
                                               sampleRate: sampleRate,
                                               count: n)
        let startIdx = fftSize
        let frame = Array(signal[startIdx..<(startIdx + fftSize)])
        guard let r = meter.process(frame) else { continue }

        let aTheory = AWeighting.gain(at: f)
        let diff = r.dbfsAWeighted - r.dbfsFlat
        let deviation = diff - aTheory  // 偏差应接近 0
        let ok = abs(deviation) < 0.5
        if ok { passed += 1 } else { failed += 1 }
        print("  \(String(format: "%4d", k))   " +
              "\(String(format: "%8.2f Hz", f))   " +
              "\(String(format: "%+6.2f dB", aTheory))   " +
              "\(String(format: "%8.2f", r.dbfsFlat))   " +
              "\(String(format: "%8.2f", r.dbfsAWeighted))   " +
              "\(String(format: "%+6.2f", diff))   " +
              "\(String(format: "%+6.2f", deviation))   " +
              "\(ok ? "✅" : "❌")")
    }
    print()

    // 3. 粉红噪声与白噪声
    //    白噪声均匀分布 [-a, a]，RMS = a/√3，dBFS = 20·log10(a/√3)
    //    粉红噪声振幅分布不均匀，无法简单算预期值，只验证合理范围
    print("── 测试组 3：噪声信号 ──────────────────────────────────")
    let whiteExpected = 20 * log10(0.5 / Float(3.0.squareRoot()))  // ≈ -10.8 dBFS
    let white = SignalGenerator.whiteNoise(amplitude: 0.5, count: n)
    test(name: "白噪声 (amplitude=0.5, RMS=a/√3)",
         signal: white, expectedDBFS: whiteExpected, tolerance: 1.5)

    // 粉红噪声：只验证 dBFS(A) < dBFS(flat)
    // （因为粉红噪声低频能量多，A 计权会衰减，所以 dBFS(A) 应更低）
    let pink = SignalGenerator.pinkNoise(amplitude: 0.5, count: n)
    let startIdx = fftSize
    let pinkFrame = Array(pink[startIdx..<(startIdx + fftSize)])
    if let pr = meter.process(pinkFrame) {
        let pinkOk = pr.dbfsAWeighted < pr.dbfsFlat
        print("\(pinkOk ? "✅" : "❌") 粉红噪声 (amplitude=0.5)")
        print("     dBFS(flat) = \(String(format: "%6.2f", pr.dbfsFlat))")
        print("     dBFS(A)    = \(String(format: "%6.2f", pr.dbfsAWeighted))")
        print("     验证: A计权后应更低（粉红噪声低频能量多）: " +
              "\(pinkOk ? "通过" : "失败")")
        print()
        if pinkOk { passed += 1 } else { failed += 1 }
    }

    // 4. 极端情况
    print("── 测试组 4：边界情况 ──────────────────────────────────")
    let silenceMeter = DBMeter(config: MeterConfig(sampleRate: sampleRate,
                                                    fftSize: fftSize,
                                                    calibrationOffset: 0))
    let silence = [Float](repeating: 0, count: fftSize)
    if let r = silenceMeter.process(silence) {
        let silenceOK = r.dbfsFlat.isFinite && r.dbfsFlat <= -199.9
            && r.dbfsAWeighted <= -199.9
            && r.splA <= -199.9
            && r.splInstant <= -199.9
            && r.leqSPL == -Float.infinity
            && silenceMeter.leqDuration > 0
        print("\(silenceOK ? "✅" : "❌") 静音信号: \(r)")
        print("   （预期: dBFS 有限下限、计权/瞬时/Leq 均为 -∞，不再落入约 0 dB 的无效读数）")
        silenceOK ? (passed += 1) : (failed += 1)
    }
    print()

    // 5. 绝对声压级链路:SPL = dBFS(RMS) + offset
    //    数字 MEMS 麦克风惯例:94 dB SPL@1kHz ≈ -29 dBFS(RMS)。
    //    用 bin 对齐正弦(996.09 Hz,1 kHz 附近 A/C 修正量均 ≈0 dB,泄漏为零),
    //    校准偏移取 +123,则 1 kHz 附近 -29 dBFS 的音应显示 94 dB。
    print("── 测试组 5：绝对声压级链路(SPL = dBFS + offset) ────────")
    do {
        let amp = Float(2.0.squareRoot()) * pow(10, -29.0 / 20)   // RMS = -29 dBFS
        let f1k = Float(85) * binWidth                              // 996.09 Hz,bin 对齐
        for (w, name) in [(Weighting.a, "A 计权"), (Weighting.c, "C 计权")] {
            let m = DBMeter(config: MeterConfig(sampleRate: sampleRate, fftSize: fftSize,
                                                calibrationOffset: 123, weighting: w))
            let sig = SignalGenerator.sineWave(frequency: f1k, amplitude: amp,
                                               sampleRate: sampleRate, count: fftSize * 24)
            // 50% 重叠推进喂 16 帧,让时间计权检波器收敛(残余 < 0.1 dB)
            var last: MeterResult?
            var start = 0
            for _ in 0..<16 {
                last = m.process(Array(sig[start..<(start + fftSize)]), hopSamples: fftSize / 2)
                start += fftSize / 2
            }
            if let r = last {
                let err = r.splA - 94
                let ok = abs(err) < 0.5
                print("\(ok ? "✅" : "❌") \(name): -29 dBFS @ \(Int(f1k)) Hz + offset 123 → " +
                      "SPL = \(String(format: "%.2f", r.splA)) dB (期望 94.00, 偏差 \(String(format: "%+.2f", err)))" +
                      "  瞬时 \(String(format: "%.2f", r.splInstant))")
                ok ? (passed += 1) : (failed += 1)
            } else {
                print("❌ \(name): 处理失败"); failed += 1
            }
        }
    }
    print()

    // 6. 时间计权 F/S:能量域一阶指数平均,阶跃响应 1-(1-α)^k,α=1-exp(-Δt/τ)
    print("── 测试组 6：时间计权 F/S 阶跃响应 ─────────────────────")
    do {
        let f1k = Float(85) * binWidth
        let amp: Float = 0.5
        let sig = SignalGenerator.sineWave(frequency: f1k, amplitude: amp,
                                           sampleRate: sampleRate, count: fftSize * 32)
        let quiet = [Float](repeating: 0, count: fftSize * 8)
        let steady = 20 * log10(amp / Float(2.0.squareRoot()))   // 稳态 dBFS ≈ -9.03
        let dt = Float(fftSize / 2) / sampleRate                  // 42.7 ms

        for (tw, name) in [(TimeWeighting.fast, "Fast τ=125ms"), (TimeWeighting.slow, "Slow τ=1s")] {
            let m = DBMeter(config: MeterConfig(sampleRate: sampleRate, fftSize: fftSize,
                                                calibrationOffset: 0, timeWeighting: tw))
            // 先喂静音(置零检波器),再阶跃到稳态正弦
            var start = 0
            for _ in 0..<4 {
                _ = m.process(Array(quiet[start..<(start + fftSize)]), hopSamples: fftSize / 2)
                start += fftSize / 2
            }
            var results: [MeterResult] = []
            start = 0
            for _ in 0..<12 {
                if let r = m.process(Array(sig[start..<(start + fftSize)]), hopSamples: fftSize / 2) {
                    results.append(r)
                }
                start += fftSize / 2
            }
            let alpha = Float(-expm1(-Double(dt) / tw.tau))
            var allOK = true
            for k in [1, 3, 6, 9] {
                let expected = steady + 10 * log10(1 - pow(1 - alpha, Float(k)))
                let got = results[k - 1].splA
                let dev = got - expected
                let ok = abs(dev) < 0.4
                allOK = allOK && ok
                print("  \(name) 第\(k)帧: \(String(format: "%7.2f", got)) dB " +
                      "(期望 \(String(format: "%7.2f", expected)), 偏差 \(String(format: "%+.2f", dev))) \(ok ? "✅" : "❌")")
            }
            allOK ? (passed += 1) : (failed += 1)
        }
    }
    print()

    // 7. Leq 能量积分:20 帧 -40 dBFS + 20 帧 -20 dBFS → -22.97 dBFS
    print("── 测试组 7：Leq 能量域平均 ────────────────────────────")
    do {
        let m = DBMeter(config: MeterConfig(sampleRate: sampleRate, fftSize: fftSize))
        let f1k = Float(85) * binWidth
        func feed(_ levelDBFS: Float, frames: Int) {
            let ms = pow(10, levelDBFS / 10)
            let amp = (2 * ms).squareRoot()          // 正弦 RMS² = amp²/2
            let sig = SignalGenerator.sineWave(frequency: f1k, amplitude: amp,
                                               sampleRate: sampleRate, count: fftSize * (frames + 2))
            var start = 0
            for _ in 0..<frames {
                _ = m.process(Array(sig[start..<(start + fftSize)]), hopSamples: fftSize / 2)
                start += fftSize / 2
            }
        }
        feed(-40, frames: 20)
        feed(-20, frames: 20)
        let leq = m.currentLeq()
        let expected = Float(10 * log10((20 * pow(10, -40.0 / 10) + 20 * pow(10, -20.0 / 10)) / 40))
        let ok = abs(leq - expected) < 0.3
        print("\(ok ? "✅" : "❌") Leq(-40×20帧 + -20×20帧) = \(String(format: "%.2f", leq)) dBFS " +
              "(期望 \(String(format: "%.2f", expected)))")
        print("     Leq 覆盖时长 = \(String(format: "%.2f", m.leqDuration)) s (期望 ≈ 1.71)")
        let durationOK = abs(m.leqDuration - 40 * Double(fftSize / 2) / 48000.0) < 0.01
        (ok && durationOK) ? (passed += 1) : (failed += 1)

        // 运行中校准只改变 dBFS→SPL 偏移,不得把已累计 Leq 清零。
        let beforeCalibration = m.currentLeq()
        let beforeDuration = m.leqDuration
        m.setCalibrationOffset(10)
        let calibrationOK = abs(m.currentLeq() - (beforeCalibration + 10)) < 0.01
            && abs(m.leqDuration - beforeDuration) < 1e-9
        print("\(calibrationOK ? "✅" : "❌") 运行中校准 +10 dB 保留整场 Leq " +
              "(得 \(String(format: "%.2f", m.currentLeq())), " +
              "时长 \(String(format: "%.2f", m.leqDuration)) s)")
        calibrationOK ? (passed += 1) : (failed += 1)

        // F/S 与 Leq 无关:切换时间计权不得清空 Leq。
        m.setTimeWeighting(.slow)
        let weightingOK = abs(m.currentLeq() - (beforeCalibration + 10)) < 0.01
            && abs(m.leqDuration - beforeDuration) < 1e-9
        print("\(weightingOK ? "✅" : "❌") 切换 F/S 保留 Leq " +
              "(得 \(String(format: "%.2f", m.currentLeq())) dBFS)")
        weightingOK ? (passed += 1) : (failed += 1)
    }
    print()

    // 8. 宽带噪声计权修正量 vs 解析值(按 bin 中心积分)
    print("── 测试组 8：宽带噪声计权修正量 ────────────────────────")
    do {
        func meanCorrection(_ samples: [Float], frames: Int, weighting: Weighting) -> Float {
            let m = DBMeter(config: MeterConfig(sampleRate: sampleRate, fftSize: fftSize,
                                                weighting: weighting))
            var acc: Float = 0
            var cnt = 0
            var start = 0
            for _ in 0..<frames {
                if let r = m.process(Array(samples[start..<(start + fftSize)]), hopSamples: fftSize / 2) {
                    acc += r.dbfsAWeighted - r.dbfsFlat
                    cnt += 1
                }
                start += fftSize / 2
            }
            return cnt > 0 ? acc / Float(cnt) : 0
        }
        // 白噪声:平坦 PSD → 修正量 = 10log10(mean(W²(bin 中心)))
        let white = SignalGenerator.whiteNoise(amplitude: 0.5, count: fftSize * 32)
        let whiteCorr = meanCorrection(white, frames: 24, weighting: .a)
        let binFreqs = (0..<fftSize / 2).map { Float($0) * binWidth }
        let analyticWhite = 10 * log10(binFreqs.map { pow(10, AWeighting.gain(at: $0) / 10) }
            .reduce(0, +) / Float(fftSize / 2))
        let okW = abs(whiteCorr - analyticWhite) < 0.4
        print("\(okW ? "✅" : "❌") 白噪声 A 修正量 = \(String(format: "%+.2f", whiteCorr)) dB " +
              "(解析 \(String(format: "%+.2f", analyticWhite)))")
        okW ? (passed += 1) : (failed += 1)

        // 粉红噪声(1/f):解析按 Σ W²(f)/f 归一。信号发生器是 1/f 近似,
        // 不是严格 PSD,给 1.5 dB 工程容差。
        let pink = SignalGenerator.pinkNoise(amplitude: 0.5, count: fftSize * 32)
        let pinkCorr = meanCorrection(pink, frames: 24, weighting: .a)
        let analyticPink = 10 * log10(
            binFreqs.dropFirst().map { pow(10, AWeighting.gain(at: $0) / 10) / $0 }.reduce(0, +)
            / binFreqs.dropFirst().map { 1 / $0 }.reduce(0, +))
        let okP = abs(pinkCorr - analyticPink) < 1.5
        print("\(okP ? "✅" : "❌") 粉红噪声 A 修正量 = \(String(format: "%+.2f", pinkCorr)) dB " +
              "(解析 \(String(format: "%+.2f", analyticPink)))")
        okP ? (passed += 1) : (failed += 1)
    }
    print()

    // 9. 频谱显示聚合:低频空段插值 + 多 bin 功率平均
    //    48k/4096 下 32 段对数轴,第 2 段(24.6~30.4 Hz)与第 4 段
    //    (37.4~46.1 Hz)没有 bin 落入;空段必须插值而不是恒贴底。
    print("── 测试组 9：频谱显示聚合(空段插值/功率平均) ───────────")
    do {
        let fs: Float = 48000
        let freqs = (0..<fftSize / 2).map { Float($0) * fs / Float(fftSize) }

        // 场景 1:平坦谱 → 32 段全部有值且 ≈0.5(插值保持平坦)
        let flat = [Float](repeating: 0.5, count: freqs.count)
        let flatBands = SpectrumBands.aggregate(spectrum: flat, frequencies: freqs,
                                                bandCount: 32, minFrequency: 20, maxFrequency: 16000)
        let flatOK = flatBands.count == 32 && flatBands.allSatisfy { band in
            let avg = band.reduce(0, +) / Float(max(1, band.count))
            return !band.isEmpty && abs(avg - 0.5) < 0.01
        }
        print("\(flatOK ? "✅" : "❌") 平坦谱 → 32 段全部有值且 ≈0.5")
        flatOK ? (passed += 1) : (failed += 1)

        // 场景 2:第 2、4 段应取相邻 bin 的插值,落在两侧 bin 幅度之间
        var spec = [Float](repeating: 1e-7, count: freqs.count)
        spec[2] = 0.5     // 23.4 Hz
        spec[3] = 1.0     // 35.2 Hz
        spec[4] = 0.25    // 46.9 Hz
        let bands = SpectrumBands.aggregate(spectrum: spec, frequencies: freqs,
                                            bandCount: 32, minFrequency: 20, maxFrequency: 16000)
        func bandAvg(_ i: Int) -> Float { bands[i].reduce(0, +) / Float(max(1, bands[i].count)) }
        let noneEmpty = bands.allSatisfy { !$0.isEmpty }
        let band1OK = bandAvg(1) > 0.5 && bandAvg(1) < 1.0     // 中心≈27.3 Hz,介于 bin2/bin3
        let band3OK = bandAvg(3) > 0.25 && bandAvg(3) < 1.0    // 中心≈41.5 Hz,介于 bin3/bin4
        let ok = noneEmpty && band1OK && band3OK
        print("\(ok ? "✅" : "❌") 全部段非空=\(noneEmpty), " +
              "段2=\(String(format: "%.3f", bandAvg(1))) (期望 0.5~1.0), " +
              "段4=\(String(format: "%.3f", bandAvg(3))) (期望 0.25~1.0)")
        ok ? (passed += 1) : (failed += 1)

        // 构造一个窄桶,仅包含 110/120 Hz 两根非零 bin;同桶另有一个零 bin。
        let freqs2: [Float] = [100, 110, 120, 130, 140, 150]
        let spec2: [Float] = [0, 1, 0.5, 0, 0, 0]
        let levels = SpectrumBands.bandLevelsDB(spectrum: spec2, frequencies: freqs2,
                                                bandCount: 1, minFrequency: 100,
                                                maxFrequency: 139)
        // 区间 [100,139) 纳入 100/110/120/130 四个 bin。
        let expectedPowerDB = Float(10 * log10((1.0 + 0.25) / 4.0))
        let amplitudeAvgDB = Float(20 * log10((1.0 + 0.5) / 4.0))
        let powerOK = levels.count == 1
            && abs(levels[0] - expectedPowerDB) < 0.01
            && levels[0] > amplitudeAvgDB
        print("\(powerOK ? "✅" : "❌") 多 bin 采用功率平均: " +
              "\(String(format: "%+.2f", levels.first ?? 0)) dB " +
              "(功率平均 \(String(format: "%+.2f", expectedPowerDB)), " +
              "幅度平均 \(String(format: "%+.2f", amplitudeAvgDB)))")
        powerOK ? (passed += 1) : (failed += 1)
    }
    print()

    // 10. 时域 A/C 滤波器频响:直接验证数字 IIR 与 IEC 解析曲线
    print("── 测试组 10：时域 A/C IIR 滤波器频响 ─────────────────")
    do {
        let keyFrequencies: [Float] = [
            20, 31.5, 63, 125, 250, 500, 1000,
            2000, 4000, 8000, 10000, 12500, 16000
        ]
        for fs in [Float(44100), 48000, 96000] {
            for weighting in [Weighting.a, Weighting.c] {
                let filter = WeightingFilter(weighting: weighting, sampleRate: fs)
                var worst: Float = 0
                var worstFrequency: Float = 0
                for frequency in keyFrequencies where frequency < fs * 0.49 {
                    let reference = weighting == .a
                        ? AWeighting.gain(at: frequency)
                        : CWeighting.gain(at: frequency)
                    let error = filter.gain(at: frequency) - reference
                    if abs(error) > abs(worst) {
                        worst = error
                        worstFrequency = frequency
                    }
                }
                let ok = abs(worst) < 0.5
                print("\(ok ? "✅" : "❌") " +
                      "\(Int(fs)) Hz · \(weighting.rawValue.uppercased()) 计权 " +
                      "最大偏差 \(String(format: "%+.3f", worst)) dB " +
                      "@ \(String(format: "%.1f", worstFrequency)) Hz")
                ok ? (passed += 1) : (failed += 1)
            }
        }
    }
    print()

    // 11. 滤波器状态连续性:同一段信号,分块喂入与整段喂入的均方值应一致
    print("── 测试组 11：计权滤波器的分块连续性 ─────────────────")
    do {
        let fs: Float = 48000
        let f1k = Float(85) * binWidth
        let signal = SignalGenerator.sineWave(frequency: f1k, amplitude: 0.5,
                                               sampleRate: fs, count: fftSize * 8)

        var wholeFilter = WeightingFilter(weighting: .a, sampleRate: fs)
        let whole = wholeFilter.meanSquare(of: signal, filterRange: 0..<signal.count)

        var chunkedFilter = WeightingFilter(weighting: .a, sampleRate: fs)
        var energy = 0.0
        var count = 0
        let chunkSize = 333
        var offset = 0
        while offset < signal.count {
            let end = min(offset + chunkSize, signal.count)
            let chunk = Array(signal[offset..<end])
            let ms = chunkedFilter.meanSquare(of: chunk, filterRange: 0..<chunk.count)
            energy += ms * Double(chunk.count)
            count += chunk.count
            offset = end
        }
        let chunked = energy / Double(count)
        let diffDB = 10 * log10(max(chunked, 1e-20) / max(whole, 1e-20))
        let ok = abs(diffDB) < 0.01
        print("\(ok ? "✅" : "❌") 状态跨块连续:整段与 333 点分块差 " +
              "\(String(format: "%+.4f", diffDB)) dB")
        ok ? (passed += 1) : (failed += 1)
    }
    print()

    // 12. 停止收尾:不足一个 FFT 窗口的尾部也要计入 Leq 时长与能量
    print("── 测试组 12：测量尾部样本计入 Leq ───────────────────")
    do {
        let fs: Float = 48000
        let f1k = Float(85) * binWidth
        let signal = SignalGenerator.sineWave(frequency: f1k, amplitude: 0.5,
                                               sampleRate: fs, count: fftSize * 3)
        let m = DBMeter(config: MeterConfig(sampleRate: fs, fftSize: fftSize))
        _ = m.process(Array(signal[0..<fftSize]), hopSamples: fftSize / 2)
        let beforeLeq = m.currentLeq()
        let beforeDuration = m.leqDuration
        let tail = Array(signal[fftSize..<(fftSize + 1000)])
        let tailResult = m.processTail(tail)
        let expectedTailDuration = TimeInterval(tail.count) / TimeInterval(fs)
        let tailOK = tailResult != nil
            && abs(m.leqDuration - beforeDuration - expectedTailDuration) < 0.001
            && abs(m.currentLeq() - beforeLeq) < 0.05
        print("\(tailOK ? "✅" : "❌") 尾样本 \(tail.count) 点: " +
              "Leq 时长 \(String(format: "%.4f", m.leqDuration)) s, " +
              "Leq 变化 \(String(format: "%+.3f", m.currentLeq() - beforeLeq)) dB")
        tailOK ? (passed += 1) : (failed += 1)

        // 新样本已在上一次 process() 中完整覆盖时，不能把同一段再次喂给
        // 滤波器。否则尾段会重复计入 Leq，且滤波器状态会人为前移。
        let m2 = DBMeter(config: MeterConfig(sampleRate: fs, fftSize: fftSize))
        let before = m2.leqDuration
        _ = m2.process(Array(signal[0..<fftSize]), hopSamples: fftSize / 2)
        let afterProcess = m2.leqDuration
        let duplicateTail = Array(signal[(fftSize / 2)..<fftSize])
        _ = m2.processTail(duplicateTail, skipSamples: duplicateTail.count)
        let duplicateOK = abs(m2.leqDuration - afterProcess) < 1e-6
            && afterProcess > before
        print("\(duplicateOK ? "✅" : "❌") 已统计窗口不重复计入尾段 " +
              "(处理 \(String(format: "%.4f", afterProcess)) s → " +
              "收尾 \(String(format: "%.4f", m2.leqDuration)) s)")
        duplicateOK ? (passed += 1) : (failed += 1)

        // 重叠窗口后若还带新样本，只统计新增部分，不能把已测 hop 再算一次。
        let m3 = DBMeter(config: MeterConfig(sampleRate: fs, fftSize: fftSize))
        _ = m3.process(Array(signal[0..<fftSize]), hopSamples: fftSize / 2)
        let beforeFresh = m3.leqDuration
        let freshTail = Array(signal[(fftSize / 2)..<(fftSize + 1000)])
        _ = m3.processTail(freshTail, skipSamples: fftSize / 2)
        let freshOK = abs(m3.leqDuration - beforeFresh - 1000 / Double(fs)) < 1e-6
        print("\(freshOK ? "✅" : "❌") 尾段只新增 1000 点 " +
              "(新增 \(String(format: "%.4f", m3.leqDuration - beforeFresh)) s)")
        freshOK ? (passed += 1) : (failed += 1)
    }
    print()

    // 13. 新一场测量:滤波器/检波器/Leq 都必须从干净状态开始
    print("── 测试组 13：跨测量状态复位 ─────────────────────────")
    do {
        let fs: Float = 48000
        let f1k = Float(85) * binWidth
        let loud = SignalGenerator.sineWave(frequency: f1k, amplitude: 0.8,
                                             sampleRate: fs, count: fftSize * 8)
        let m = DBMeter(config: MeterConfig(sampleRate: fs, fftSize: fftSize))
        var offset = 0
        for _ in 0..<8 {
            _ = m.process(Array(loud[offset..<(offset + fftSize)]),
                          hopSamples: fftSize / 2)
            offset += fftSize / 2
        }
        let oldDuration = m.leqDuration
        m.resetSmoothing()

        let silence = [Float](repeating: 0, count: fftSize)
        let result = m.process(silence, hopSamples: fftSize / 2)
        let hopDuration = TimeInterval(fftSize / 2) / TimeInterval(fs)
        let ok = result != nil
            && result!.dbfsAWeighted <= -199.9
            && result!.splA <= -199.9
            && abs(m.leqDuration - hopDuration) < 1e-5
            && oldDuration > 0
        print("\(ok ? "✅" : "❌") resetSmoothing 后首帧不再带上一场状态 " +
              "(旧时长 \(String(format: "%.2f", oldDuration)) s → " +
              "新时长 \(String(format: "%.3f", m.leqDuration)) s)")
        ok ? (passed += 1) : (failed += 1)
    }
    print()

    // 总结
    print("═══════════════════════════════════════════════════════════")
    print("  结果: \(passed) 通过, \(failed) 失败")
    if failed == 0 {
        print("  ✅ 核心算法验证通过！可以进入 live 模式测试真实麦克风。")
    } else {
        print("  ⚠️  有测试未通过，需要检查算法实现。")
    }
    print("═══════════════════════════════════════════════════════════")
}

// MARK: - 模式 2：A 计权扫频

func runSweep() {
    print("═══════════════════════════════════════════════════════════")
    print("  A 计权曲线扫描 (IEC 61672)")
    print("═══════════════════════════════════════════════════════════\n")
    print("  频率         A计权增益(dB)   参考标准值(dB)")
    print("  ──────────   ─────────────   ──────────────")

    // IEC 61672-1 表 A.1 的参考值（部分关键点）
    let reference: [Float: Float] = [
        10: -70.4, 20: -50.5, 50: -30.2, 100: -19.1,
        200: -10.9, 500: -3.2, 1000: 0.0, 2000: 1.2,
        5000: 0.5, 8000: -1.1, 10000: -2.5, 20000: -9.3,
    ]

    let freqs: [Float] = [10, 20, 50, 100, 200, 500, 1000, 2000, 5000, 8000, 10000, 20000]
    for f in freqs {
        let calc = AWeighting.gain(at: f)
        let ref = reference[f] ?? 0
        let mark = abs(calc - ref) < 0.5 ? "✅" : "⚠️"
        print("  \(String(format: "%8.0f Hz", f))   " +
              "\(String(format: "%+12.2f", calc))   " +
              "\(String(format: "%+12.2f", ref))  \(mark)")
    }
    print()

    // A 计权完整 IEC 关键频点(含低频与高频滚降)。sweep 不只是显示,
    // 全部点超差时以非零状态退出,才能用于 CI/发布前回归。
    let aPoints: [Float: Float] = [
        20: -50.5, 31.5: -39.4, 63: -26.2, 125: -16.1,
        250: -8.6, 500: -3.2, 1000: 0, 2000: 1.2, 4000: 1.0,
        8000: -1.1, 12500: -4.3, 16000: -6.6,
    ]
    var aFailures = 0
    for f in aPoints.keys.sorted() {
        let ref = aPoints[f]!
        if abs(AWeighting.gain(at: f) - ref) >= 0.5 { aFailures += 1 }
    }

    // C 计权曲线(IEC 61672-1 表 A.2 关键点)
    // 回归背景:C 曾错把 A 的 107.7/737.9 中频因子抄进分母,
    // 导致 20Hz 放大 +17dB、10kHz 衰减 -42dB,宽带读数严重失真。
    let cReference: [Float: Float] = [
        20: -6.2, 31.5: -3.0, 63: -0.8, 125: -0.2, 500: 0.0,
        1000: 0.0, 2000: -0.2, 4000: -0.8, 8000: -3.0,
        10000: -4.4, 20000: -11.2,
    ]
    print("  C 计权曲线扫描 (IEC 61672-1 表 A.2)\n")
    print("  频率         C计权增益(dB)   参考标准值(dB)")
    print("  ──────────   ─────────────   ──────────────")
    let cFreqs: [Float] = [20, 31.5, 63, 125, 500, 1000, 2000, 4000, 8000, 10000, 20000]
    var cFailures = 0
    for f in cFreqs {
        let calc = CWeighting.gain(at: f)
        let ref = cReference[f] ?? 0
        let mark = abs(calc - ref) < 0.5 ? "✅" : "❌"
        if mark == "❌" { cFailures += 1 }
        print("  \(String(format: "%8.1f Hz", f))   " +
              "\(String(format: "%+12.2f", calc))   " +
              "\(String(format: "%+12.2f", ref))  \(mark)")
    }
    print()
    if aFailures > 0 || cFailures > 0 {
        print("  ❌ A 计权超差 \(aFailures) 点，C 计权超差 \(cFailures) 点")
        exit(1)
    }
    print("  ✅ A/C 计权全部偏差 < 0.5 dB，符合 IEC 61672 容差")
}

// MARK: - 模式 3：实时麦克风

func runLive() {
    print("═══════════════════════════════════════════════════════════")
    print("  闻声 SoundSense -- 实时环境噪音测量（按 Ctrl+C 退出）")
    print("═══════════════════════════════════════════════════════════\n")

    // 实时模式需要 AVAudioEngine，这里用动态加载避免纯算法测试时依赖
    guard let liveMeter = LiveMeter.create() else {
        print("❌ 无法初始化音频引擎。请检查麦克风权限。")
        print("   系统设置 -> 隐私与安全 -> 麦克风")
        return
    }
    liveMeter.start()
}

/// 获取日志文件路径（.app bundle 启动时 stdout 不可见，改写文件）
func logFilePath() -> String {
    let home = NSHomeDirectory()
    return home + "/soundsense.log"
}

/// 写日志到文件（同时输出到 stdout）
func logToFile(_ message: String) {
    print(message)
    let path = logFilePath()
    let timestamp = DateFormatter.localizedString(from: Date(),
                                                   dateStyle: .none,
                                                   timeStyle: .medium)
    let line = "[\(timestamp)] \(message)\n"
    if let handle = FileHandle(forWritingAtPath: path) {
        handle.seekToEndOfFile()
        if let data = line.data(using: .utf8) {
            handle.write(data)
        }
        handle.closeFile()
    } else {
        try? line.write(toFile: path, atomically: true, encoding: .utf8)
    }
}

// MARK: - LiveMeter（实时采集）

import AVFoundation

final class LiveMeter {

    static let noInputDeviceMessage = "未检测到可用的麦克风。请连接麦克风，或在系统设置中检查输入设备。"

    static func create() -> LiveMeter? {
        LiveMeter()
    }

    private let engine = AVAudioEngine()
    private let meter: DBMeter
    private let sampleRate: Double
    private var isRunning = false
    private var tapInstalled = false

    private init?() {
        // macOS 不需要 AVAudioSession（那是 iOS 专属）。
        // 必须在触达 AVAudioEngine.inputNode 之前先查 CoreAudio 真实设备:
        // 无麦克风时 inputNode/installTap 可能直接抛 Objective-C 异常,Swift 接不住。
        #if canImport(CoreAudio)
        guard MacInputDeviceProbe.hasInputDevice() else {
            logToFile("❌ \(Self.noInputDeviceMessage)")
            return nil
        }
        #endif

        let inputNode = engine.inputNode
        // 优先读输入 format;部分机器在 engine 未启动时 outputFormat 为占位值。
        let inputFormat = inputNode.inputFormat(forBus: 0)
        let format = (inputFormat.sampleRate > 0 && inputFormat.channelCount > 0)
                     ? inputFormat : inputNode.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            logToFile("❌ \(Self.noInputDeviceMessage)")
            return nil
        }
        self.sampleRate = format.sampleRate

        logToFile("  采样率: \(Int(format.sampleRate)) Hz")
        logToFile("  声道数: \(format.channelCount)")
        logToFile("  格式: \(format)")

        self.meter = DBMeter(config: MeterConfig(
            sampleRate: Float(format.sampleRate),
            fftSize: 4096,
            calibrationOffset: 0
        ))
    }

    func start() {
        #if canImport(CoreAudio)
        guard MacInputDeviceProbe.hasInputDevice() else {
            logToFile("❌ \(Self.noInputDeviceMessage)")
            return
        }
        #endif
        let inputNode = engine.inputNode
        let inputFormat = inputNode.inputFormat(forBus: 0)
        let format = (inputFormat.sampleRate > 0 && inputFormat.channelCount > 0)
                     ? inputFormat : inputNode.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            logToFile("❌ \(Self.noInputDeviceMessage)")
            return
        }

        // 诊断：打印 tap 格式信息
        logToFile("  Tap 格式: \(Int(format.sampleRate)) Hz, \(format.channelCount) ch")

        var frameCount = 0

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            guard let self = self else { return }
            guard let channelData = buffer.floatChannelData?[0] else { return }
            let frameLength = Int(buffer.frameLength)
            frameCount += 1

            // 诊断：前几帧 + 每 50 帧打印原始样本统计
            if frameCount <= 5 || (frameCount % 50 == 0) {
                var maxVal: Float = 0
                var rmsVal: Float = 0
                for i in 0..<min(frameLength, 256) {
                    let v = abs(channelData[i])
                    if v > maxVal { maxVal = v }
                    rmsVal += channelData[i] * channelData[i]
                }
                rmsVal = sqrt(rmsVal / Float(min(frameLength, 256)))
                logToFile(String(format: "  [帧 %d] frameLength=%d, maxAbs=%.6f, rms=%.6f",
                                 frameCount, frameLength, maxVal, rmsVal))
            }

            let samples = Array(UnsafeBufferPointer(start: channelData, count: frameLength))

            guard let result = self.meter.process(samples) else { return }

            // 在主线程更新显示
            DispatchQueue.main.async {
                self.display(result)
            }
        }

        do {
            tapInstalled = true
            try engine.start()
            isRunning = true
            logToFile("  🎙 麦克风已启动，开始测量...")
            logToFile("  日志文件: \(logFilePath())")
            logToFile("  对着麦克风说话或拍手，观察数值变化")

            // 保持运行
            RunLoop.main.run()
        } catch {
            if tapInstalled {
                inputNode.removeTap(onBus: 0)
                tapInstalled = false
            }
            logToFile("❌ 音频引擎启动失败: \(error)")
        }
    }

    private var lastDisplayTime: Date = .distantPast

    private func display(_ result: MeterResult) {
        let spl = result.splA

        // 简易分贝条
        let barWidth = 50
        let normalized = max(0, min(1, (spl + 80) / 100))  // -80~+20 映射到 0~1
        let filled = Int(normalized * Float(barWidth))
        let bar = String(repeating: "█", count: filled) +
                  String(repeating: "░", count: barWidth - filled)

        // 颜色提示
        let level: String
        if spl > -5 { level = "🔴 非常吵" }
        else if spl > -20 { level = "🟡 较吵" }
        else if spl > -40 { level = "🟢 正常" }
        else { level = "🔵 安静" }

        // 终端显示（回车刷新）
        let output = String(format: "\r  %@ | SPL(A)=%6.1f dBFS(A)  %@  \u{1B}[K",
                            bar, spl, level)
        print(output, terminator: "")
        fflush(stdout)

        // 每秒写一次日志（.app 模式下终端不可见，用文件替代）
        let now = Date()
        if now.timeIntervalSince(lastDisplayTime) >= 1.0 {
            lastDisplayTime = now
            logToFile(String(format: "  %@ | SPL(A)=%6.1f dBFS(A)  %@",
                             bar, spl, level))
        }
    }

    deinit {
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
        }
        engine.stop()
    }
}

#if canImport(CoreAudio)
/// CoreAudio 设备预检。只查询系统默认输入设备及其输入通道,
/// 不依赖 AVAudioEngine 的占位 format。
private enum MacInputDeviceProbe {
    static func hasInputDevice() -> Bool {
        guard let deviceID = defaultInputDeviceID() else { return false }
        return inputChannelCount(of: deviceID) > 0
    }

    private static func defaultInputDeviceID() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address, 0, nil, &size, &deviceID
        )
        guard status == noErr, deviceID != kAudioObjectUnknown else { return nil }
        return deviceID
    }

    private static func inputChannelCount(of deviceID: AudioDeviceID) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size) == noErr,
              size >= UInt32(MemoryLayout<AudioBufferList>.size) else { return 0 }

        let raw = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size),
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, raw) == noErr else {
            return 0
        }
        let bufferList = raw.bindMemory(to: AudioBufferList.self, capacity: 1)
        return UnsafeMutableAudioBufferListPointer(bufferList)
            .reduce(0) { $0 + Int($1.mNumberChannels) }
    }
}
#endif
