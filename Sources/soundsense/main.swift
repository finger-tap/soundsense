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
// SoundSenseCore.swift 的代码在同一编译单元内，无需 import

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
    let silence = [Float](repeating: 0, count: n)
    if let r = meter.process(Array(silence[fftSize..<(fftSize+fftSize)])) {
        print("✅ 静音信号: \(r)")
        if r.dbfsFlat < -180 {
            print("   （预期: 接近 -∞，因为 RMS=0）")
            passed += 1
        } else {
            print("❌ 静音 dBFS 偏高，可能有问题")
            failed += 1
        }
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
    print("  ✅ = 偏差 < 0.5 dB，符合 IEC 61672 容差")
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

    static func create() -> LiveMeter? {
        LiveMeter()
    }

    private let engine = AVAudioEngine()
    private let meter: DBMeter
    private let sampleRate: Double
    private var isRunning = false

    private init?() {
        // macOS 不需要 AVAudioSession（那是 iOS 专属）。
        // AVAudioEngine 在 macOS 上直接用即可。

        let inputNode = engine.inputNode

        // 先启动一次 engine 来获取真实的麦克风格式
        // （engine 未启动时 inputNode 的 format 可能是占位值）
        do {
            try engine.start()
        } catch {
            logToFile("❌ 无法启动音频引擎（可能没有麦克风权限）: \(error)")
            logToFile("   请到 系统设置 -> 隐私与安全 -> 麦克风 授权给终端")
            return nil
        }

        let format = inputNode.outputFormat(forBus: 0)
        self.sampleRate = format.sampleRate

        logToFile("  采样率: \(Int(format.sampleRate)) Hz")
        logToFile("  声道数: \(format.channelCount)")
        logToFile("  格式: \(format)")

        // 先停掉 engine，稍后在 start() 里装 tap 后再启动
        engine.stop()

        self.meter = DBMeter(config: MeterConfig(
            sampleRate: Float(format.sampleRate),
            fftSize: 4096,
            calibrationOffset: 0
        ))
    }

    func start() {
        let inputNode = engine.inputNode
        let format = inputNode.outputFormat(forBus: 0)

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
            try engine.start()
            isRunning = true
            logToFile("  🎙 麦克风已启动，开始测量...")
            logToFile("  日志文件: \(logFilePath())")
            logToFile("  对着麦克风说话或拍手，观察数值变化")

            // 保持运行
            RunLoop.main.run()
        } catch {
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
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }
}
