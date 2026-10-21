//
// 长时间监听音频链路基准。
// 用法: ./scripts/audio_benchmark.sh [秒数]
//
// 使用固定 10 秒循环 PCM 模拟长时间输入，测 DBMeter 的 DSP 路径，以及监听
// 页使用的低频特征 + 事件状态机 + 统计聚合。不启动麦克风、不画 UI、不写录音
// 文件；结果用于比较路径成本和检查长时内存趋势，不能替代真机 Instruments。
//

import Foundation

@main
enum AudioBenchmarkMain {
    static func main() {
        run()
    }
}

let seconds = max(30, Int(CommandLine.arguments.dropFirst().first ?? "28_800") ?? 28_800)
let sampleRate: Float = 48_000
let fftSize = 4096
let hop = fftSize / 2
let loopSeconds = 10
let loopFrames = loopSeconds * Int(sampleRate)

// 固定种子，保证每次基准输入一致。
var seed: UInt64 = 0x9E3779B97F4A7C15
func nextNoise() -> Float {
    seed = seed &* 6364136223846793005 &+ 1442695040888963407
    let unit = Float((seed >> 40) & 0xFFFFFF) / Float(0xFFFFFF)
    return (unit * 2 - 1) * 0.035
}

let source = (0..<loopFrames).map { index -> Float in
    let t = Float(index) / sampleRate
    let hum = 0.018 * sin(2 * Float.pi * 50 * t)
        + 0.009 * sin(2 * Float.pi * 120 * t)
    let voiceBand = 0.006 * sin(2 * Float.pi * 1_000 * t)
    return hum + voiceBand + nextNoise()
}

struct RunResult {
    let label: String
    let wall: TimeInterval
    let cpu: TimeInterval
    let baselineRSS: Int
    let peakRSS: Int
    let growthRSS: Int
}

func residentBytes() -> Int {
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(
        MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
    let kr = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO),
                      $0, &count)
        }
    }
    return kr == KERN_SUCCESS ? Int(info.resident_size) : 0
}

func processCPUTime() -> TimeInterval {
    var usage = rusage()
    guard getrusage(RUSAGE_SELF, &usage) == 0 else { return 0 }
    let user = TimeInterval(usage.ru_utime.tv_sec)
        + TimeInterval(usage.ru_utime.tv_usec) / 1_000_000
    let system = TimeInterval(usage.ru_stime.tv_sec)
        + TimeInterval(usage.ru_stime.tv_usec) / 1_000_000
    return user + system
}

func measure(_ label: String,
             audioSeconds: Int,
             spectrumEnabled: Bool,
             lowBandInterval: TimeInterval) -> RunResult {
    let sampleCount = ((audioSeconds * Int(sampleRate) - fftSize) / hop + 1) * hop
    let iterations = sampleCount / hop
    let meter = DBMeter(config: MeterConfig(
        sampleRate: sampleRate,
        fftSize: fftSize,
        calibrationOffset: 120,
        spectrumEnabled: spectrumEnabled,
        lowBandAnalysisInterval: lowBandInterval))
    // 先跑几秒暖机，把 FFT/计权滤波器初始化放入基线，避免把启动分配
    // 冒充成长期内存泄漏。
    for index in 0..<(Int(sampleRate * 5) / hop) {
        let offset = index * hop
        let frame = Array(source[offset..<(offset + fftSize)])
        _ = meter.process(frame, hopSamples: hop)
    }
    let baselineRSS = residentBytes()
    var peakRSS = baselineRSS
    var offset = 0
    let wallStart = Date()
    let cpuStart = processCPUTime()
    for _ in 0..<iterations {
        if offset + fftSize > source.count {
            offset = 0
        }
        source.withUnsafeBufferPointer { buffer in
            let frame = Array(UnsafeBufferPointer(
                start: buffer.baseAddress!.advanced(by: offset),
                count: fftSize))
            _ = meter.process(frame, hopSamples: hop)
        }
        offset += hop
        if peakRSS == 0 || (offset / hop).isMultiple(of: 2_000) {
            peakRSS = max(peakRSS, residentBytes())
        }
    }
    let wall = Date().timeIntervalSince(wallStart)
    let cpu = processCPUTime() - cpuStart
    peakRSS = max(peakRSS, residentBytes())
    return RunResult(label: label, wall: wall, cpu: cpu,
                     baselineRSS: baselineRSS, peakRSS: peakRSS,
                     growthRSS: max(0, peakRSS - baselineRSS))
}

/// 监听页完整纯逻辑路径：低频 FFT、低频功率占比、L90 事件状态机和
/// PositionStatsBuilder。片段编码/写盘和 UI 绘制仍不在这个基准里。
func measureMonitorPipeline(label: String, audioSeconds: Int) -> RunResult {
    let sampleCount = ((audioSeconds * Int(sampleRate) - fftSize) / hop + 1) * hop
    let iterations = sampleCount / hop
    let meter = DBMeter(config: MeterConfig(
        sampleRate: sampleRate,
        fftSize: fftSize,
        calibrationOffset: 120,
        spectrumEnabled: false,
        lowBandAnalysisInterval: 0.5))
    let eventEngine = NoiseEventEngine()
    eventEngine.beginSession()
    eventEngine.thresholdOverBackground = 10
    var builder = PositionStatsBuilder()
    var audioTime: TimeInterval = 0
    var offset = 0

    func processFrame() {
        if offset + fftSize > source.count { offset = 0 }
        let frame = Array(source[offset..<(offset + fftSize)])
        if let result = meter.process(frame, hopSamples: hop) {
            let duration = result.coveredDuration
            audioTime += duration
            builder.observe(spl: result.splInstant, duration: duration, at: audioTime)
            let low = lowFrequencyRatio(spectrum: result.spectrum,
                                        frequencies: result.frequencies)
            _ = eventEngine.feed(t: audioTime, duration: duration,
                                 spl: result.splInstant, lowRatio: low)
        }
        offset += hop
    }

    // 先建立 5 秒滤波/基线状态，再预热事件分类。正式积分另起会话，
    // 这样采样器不会把已累积的 5 秒样本算进 8 小时内存趋势。
    for _ in 0..<(Int(sampleRate * 5) / hop) {
        processFrame()
    }
    eventEngine.beginSession()
    builder = PositionStatsBuilder()
    audioTime = 0
    let baselineRSS = residentBytes()
    var peakRSS = baselineRSS
    let wallStart = Date()
    let cpuStart = processCPUTime()
    for _ in 0..<iterations {
        processFrame()
        if (offset / hop).isMultiple(of: 2_000) {
            peakRSS = max(peakRSS, residentBytes())
        }
    }
    let wall = Date().timeIntervalSince(wallStart)
    let cpu = processCPUTime() - cpuStart
    peakRSS = max(peakRSS, residentBytes())
    return RunResult(label: label, wall: wall, cpu: cpu,
                     baselineRSS: baselineRSS, peakRSS: peakRSS,
                     growthRSS: max(0, peakRSS - baselineRSS))
}

/// 高频事件状态机基准：每 6 秒一个脉冲，持续触发/结束事件与合并窗口，
/// 覆盖事件明细封顶、背景窗口滚动和统计聚合，不包含 AAC 编码与磁盘写入。
func measureHighRateEventPipeline(label: String, audioSeconds: Int) -> RunResult {
    let sampleCount = ((audioSeconds * Int(sampleRate) - fftSize) / hop + 1) * hop
    let iterations = sampleCount / hop
    let meter = DBMeter(config: MeterConfig(
        sampleRate: sampleRate,
        fftSize: fftSize,
        calibrationOffset: 120,
        spectrumEnabled: false,
        lowBandAnalysisInterval: 0.5))
    let eventEngine = NoiseEventEngine()
    eventEngine.beginSession()
    eventEngine.thresholdOverBackground = 10
    eventEngine.retainedEventLimit = 1_000
    // 每个脉冲持续 0.5 秒；缩小合并窗口，确保 6 秒间隔的脉冲会生成
    // 独立事件，从而真正覆盖明细封顶与长期事件状态机。
    eventEngine.minEventDuration = 0.2
    eventEngine.mergeWindow = 0.5
    var builder = PositionStatsBuilder()
    var audioTime: TimeInterval = 0
    var offset = 0

    func processFrame() {
        if offset + fftSize > source.count { offset = 0 }
        let base = Array(source[offset..<(offset + fftSize)])
        // 每 6 秒叠加 0.5 秒的 +30 dB 脉冲，并留出 3 秒滞回/结束确认；
        // 基线 L90 不会把占空比不足 10% 的脉冲当成背景。
        let phase = audioTime.truncatingRemainder(dividingBy: 6.0)
        let gain: Float = phase < 0.5 ? 31.622_776 : 1
        let frame = base.map { $0 * gain }
        if let result = meter.process(frame, hopSamples: hop) {
            let duration = result.coveredDuration
            audioTime += duration
            builder.observe(spl: result.splInstant, duration: duration, at: audioTime)
            let low = lowFrequencyRatio(spectrum: result.spectrum,
                                        frequencies: result.frequencies)
            _ = eventEngine.feed(t: audioTime, duration: duration,
                                 spl: result.splInstant, lowRatio: low)
        }
        offset += hop
    }

    for _ in 0..<(Int(sampleRate * 5) / hop) {
        processFrame()
    }
    eventEngine.beginSession()
    builder = PositionStatsBuilder()
    audioTime = 0
    let baselineRSS = residentBytes()
    var peakRSS = baselineRSS
    let wallStart = Date()
    let cpuStart = processCPUTime()
    for _ in 0..<iterations {
        processFrame()
        if (offset / hop).isMultiple(of: 2_000) {
            peakRSS = max(peakRSS, residentBytes())
        }
    }
    let wall = Date().timeIntervalSince(wallStart)
    let cpu = processCPUTime() - cpuStart
    peakRSS = max(peakRSS, residentBytes())
    print("  高频事件: \(eventEngine.totalEventCount) 个，明细 \(eventEngine.events.count) 条")
    return RunResult(label: label, wall: wall, cpu: cpu,
                     baselineRSS: baselineRSS, peakRSS: peakRSS,
                     growthRSS: max(0, peakRSS - baselineRSS))
}

/// 监听页即使没有事件，也会持续维护 2 秒 pre-roll：48k→24k FIR
/// 降采样并滚动环形缓冲。这里只测该常驻 PCM 路径，不含后台队列、
/// AAC 编码、片段写盘和 UI。
func measurePrerollPipeline(label: String, audioSeconds: Int) -> RunResult {
    let sampleCount = ((audioSeconds * Int(sampleRate) - fftSize) / hop + 1) * hop
    let iterations = sampleCount / hop
    let outputRate = 24_000
    let ringCapacity = outputRate * 2
    var decimator = FIRDecimator(
        taps: AACWriteSupport.makeTaps(count: 33, cutoffRatio: 0.225),
        factor: 2)
    var ring: [Float] = []
    var offset = 0

    func processFrame() {
        if offset + hop > source.count { offset = 0 }
        let chunk = Array(source[offset..<(offset + hop)])
        let out = decimator.process(chunk)
        ring.append(contentsOf: out)
        if ring.count > ringCapacity {
            ring.removeFirst(ring.count - ringCapacity)
        }
        offset += hop
    }

    for _ in 0..<(Int(sampleRate * 5) / hop) {
        processFrame()
    }
    decimator = FIRDecimator(
        taps: AACWriteSupport.makeTaps(count: 33, cutoffRatio: 0.225),
        factor: 2)
    ring.removeAll(keepingCapacity: true)
    let baselineRSS = residentBytes()
    var peakRSS = baselineRSS
    let wallStart = Date()
    let cpuStart = processCPUTime()
    for _ in 0..<iterations {
        processFrame()
        if (offset / hop).isMultiple(of: 2_000) {
            peakRSS = max(peakRSS, residentBytes())
        }
    }
    let wall = Date().timeIntervalSince(wallStart)
    let cpu = processCPUTime() - cpuStart
    peakRSS = max(peakRSS, residentBytes())
    return RunResult(label: label, wall: wall, cpu: cpu,
                     baselineRSS: baselineRSS, peakRSS: peakRSS,
                     growthRSS: max(0, peakRSS - baselineRSS))
}

func median(_ values: [Double]) -> Double {
    guard !values.isEmpty else { return 0 }
    let sorted = values.sorted()
    let mid = sorted.count / 2
    return sorted.count.isMultiple(of: 2)
        ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid]
}

func fmt(_ value: Double, _ digits: Int = 2) -> String {
    String(format: "%.\(digits)f", value)
}

func report(_ result: RunResult) {
    let audioSeconds = Double(seconds)
    let realtime = audioSeconds / max(result.wall, 0.000_001)
    let cpuLoad = result.cpu / audioSeconds * 100
    print("\(result.label):")
    print("  音频时长       \(fmt(audioSeconds)) s")
    print("  基线内存       \(fmt(Double(result.baselineRSS) / 1024 / 1024)) MiB")
    print("  峰值内存       \(fmt(Double(result.peakRSS) / 1024 / 1024)) MiB")
    print("  内存增长       \(fmt(Double(result.growthRSS) / 1024 / 1024)) MiB")
    print("  处理耗时       \(fmt(result.wall)) s")
    print("  CPU 时间       \(fmt(result.cpu)) s")
    print("  单核 CPU 占用  \(fmt(cpuLoad, 4))%")
    print("  实时倍率       \(fmt(realtime))x")
    print("  音频秒/处理秒 \(fmt(realtime))")
}

func run() {
    print("音频基准: \(seconds)s (\(fmt(Double(seconds) / 3600, 1)) h) / \(Int(sampleRate)) Hz / FFT \(fftSize) / hop \(hop)")
    print("输入: \(loopSeconds)s 固定循环；内存采样用于检查长时增长趋势。")
    print("说明:覆盖 DSP + 监听事件/统计纯逻辑；不包含麦克风采集、UI、录音写盘、系统调度与无线电。\n")
    print("输入包含稳态底噪与每 6 秒一次的异常事件；事件抓拍/编码/写盘成本仍需真机测试。\n")

    // 预热一次，避免首次分配/FFT setup 污染第一组结果。
    _ = measure("预热", audioSeconds: 30,
                spectrumEnabled: false, lowBandInterval: 1.0)

    // 交错重复，降低 CPU 频率/后台任务对单次结果的偏差。
    var fullRuns: [RunResult] = []
    var lowRuns: [RunResult] = []
    var offRuns: [RunResult] = []
    var monitorRuns: [RunResult] = []
    var eventRuns: [RunResult] = []
    var prerollRuns: [RunResult] = []
    for runIndex in 0..<3 {
        print("  第 \(runIndex + 1)/3 轮...")
        fullRuns.append(measure("全频谱", audioSeconds: seconds, spectrumEnabled: true,
                                lowBandInterval: 0.5))
        lowRuns.append(measure("仅低频", audioSeconds: seconds, spectrumEnabled: false,
                               lowBandInterval: 1.0))
        offRuns.append(measure("关闭频谱", audioSeconds: seconds, spectrumEnabled: false,
                               lowBandInterval: 86_400))
        monitorRuns.append(measureMonitorPipeline(
            label: "监听完整逻辑", audioSeconds: seconds))
        eventRuns.append(measureHighRateEventPipeline(
            label: "事件状态机", audioSeconds: seconds))
        prerollRuns.append(measurePrerollPipeline(
            label: "事件预录 PCM 路径", audioSeconds: seconds))
    }
    func aggregate(_ label: String, _ runs: [RunResult]) -> RunResult {
        let walls = runs.map(\.wall)
        let cpu = median(runs.map(\.cpu))
        return RunResult(label: label, wall: median(walls), cpu: cpu,
                         baselineRSS: median(runs.map { Double($0.baselineRSS) }).intValue,
                         peakRSS: runs.map(\.peakRSS).max() ?? 0,
                         growthRSS: runs.map(\.growthRSS).max() ?? 0)
    }
    let full = aggregate("全频谱（每 hop FFT）", fullRuns)
    let low = aggregate("仅低频（1 秒刷新）", lowRuns)
    let off = aggregate("关闭频谱（仅首次 FFT）", offRuns)
    let monitor = aggregate("监听完整逻辑（低频 + 事件状态机）", monitorRuns)
    let highRateEvents = aggregate("事件状态机（每 6 秒 1 次）", eventRuns)
    let preroll = aggregate("事件预录（2 秒 PCM 前摇）", prerollRuns)

    report(full)
    print()
    report(low)
    print()
    report(off)
    print()
    report(monitor)
    print()
    report(highRateEvents)
    print()
    report(preroll)
    print()

    let lowRatio = full.wall > 0 ? (1 - low.wall / full.wall) * 100 : 0
    let offRatio = full.wall > 0 ? (1 - off.wall / full.wall) * 100 : 0
    print("相对全频谱的离线处理耗时降低:")
    print("  仅低频: \(fmt(lowRatio, 1))%")
    print("  关闭频谱: \(fmt(offRatio, 1))%")
    let monitorOverhead = full.wall > 0
        ? (monitor.wall / full.wall - 1) * 100 : 0
    print("监听完整逻辑相对全频谱: \(fmt(monitorOverhead, 1))%")
    print("\n注意:此结果是单机 DSP 微基准，不等于 iPhone/Apple Watch 的实际电池续航。")
}

private extension Double {
    var intValue: Int { Int(self.rounded()) }
}
