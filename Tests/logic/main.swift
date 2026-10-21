//
//  main.swift
//  纯逻辑断言测试(与 Xcode 工程无关,swiftc 直跑)
//
import Foundation
import AVFoundation

var failures = 0
func expect(_ cond: Bool, _ name: String) {
    if cond { print("  ✓ \(name)") }
    else { failures += 1; print("  ✗ FAIL: \(name)") }
}

func makeStore() -> (MeasurementHistoryStore, URL, URL) {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("ss-test-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let json = dir.appendingPathComponent("history.json")
    let store = MeasurementHistoryStore(fileURL: json)
    return (store, json, store.recordingsDirectory)
}

func makeStats(audioID: String? = nil, startAgo: TimeInterval = 60) -> MeasurementStats {
    MeasurementStats(startTime: Date().addingTimeInterval(-startAgo), endTime: Date(),
                     duration: startAgo, avgSPL: 55, laeqSPL: 56, peakSPL: 70, minSPL: 40,
                     overLimitTotal: 12, exposureLimit: 80,
                     samples: [ReportSample(relativeTime: 1, spl: 55),
                               ReportSample(relativeTime: 2, spl: 56)],
                     audioID: audioID)
}

func fakeAudioFile(in dir: URL, id: String) -> URL {
    let url = dir.appendingPathComponent("\(id).m4a")
    try? Data("fake".utf8).write(to: url)
    return url
}

// ---- 0. MeasurementRecorder 全帧统计:短峰值不因 1 Hz 趋势采样丢失 ----
do {
    let rec = MeasurementRecorder()
    rec.start()
    // 趋势每秒只保留第一个点。模拟连续低价帧中插入一个只出现在非采样秒的尖峰。
    rec.record(spl: 40, sessionPeak: 40, sessionLeq: 40, sessionLeqDuration: 1)
    rec.record(spl: 40, sessionPeak: 40, sessionLeq: 40, sessionLeqDuration: 2)
    rec.record(spl: 95, sessionPeak: 95, sessionLeq: 46, sessionLeqDuration: 3)
    rec.record(spl: 40, sessionPeak: 95, sessionLeq: 46, sessionLeqDuration: 4)
    let live = rec.liveStats()
    expect(live?.peak == 95, "实时峰值使用引擎全帧峰值 (得 \(live?.peak ?? -999))")
    expect(abs((live?.laeq ?? 0) - 46) < 0.001,
           "实时 Leq 优先使用引擎全帧积分 (得 \(live?.laeq ?? -999))")

    // 再喂一个趋势点以跨过 stop() 的至少 2 点门槛
    Thread.sleep(forTimeInterval: 1.05)
    rec.record(spl: 40, sessionPeak: 95, sessionLeq: 46, sessionLeqDuration: 5)
    let stats = rec.stop()
    expect(stats?.peakSPL == 95, "最终报告峰值不丢失短尖峰 (得 \(stats?.peakSPL ?? -999))")
    expect(abs((stats?.laeqSPL ?? 0) - 46) < 0.001,
           "最终报告 LAeq 使用全帧积分 (得 \(stats?.laeqSPL ?? -999))")
    expect(stats.map { $0.duration >= 1.0 && $0.duration < 2.0 } == true,
           "报告时长从第一帧起算,不含启动等待 (得 \(stats?.duration ?? -999))")
}

// ---- 0b. PositionStatsBuilder 按时间积分,而不是帧数平均 ----
do {
    var b = PositionStatsBuilder()
    // 0~1s 为 40dB,1~4s 为 50dB。帧数平均会得到 45dB,
    // 正确的时间积分为 10log10((1·10^4 + 3·10^5)/4) ≈ 48.34dB。
    b.observe(spl: 40, at: 0)
    b.observe(spl: 40, at: 1)
    b.observe(spl: 50, at: 4)
    let expected = Float(10 * log10((1 * pow(10.0, 4.0) + 3 * pow(10.0, 5.0)) / 4))
    expect(abs(b.currentLaeq() - expected) < 0.01,
           "PositionStatsBuilder 按时间积分 LAeq (得 \(b.currentLaeq()), 期望 \(expected))")
    b.finish(at: 5)
    let finishedExpected = Float(10 * log10(
        (1 * pow(10.0, 4.0) + 4 * pow(10.0, 5.0)) / 5))
    expect(abs(b.currentLaeq() - finishedExpected) < 0.01,
           "PositionStatsBuilder 收尾尾段计入 (得 \(b.currentLaeq()), 期望 \(finishedExpected))")
}

// ---- 0b1. 超过 2 万帧后稳态占比分母仍等于真实帧数 ----
do {
    var b = PositionStatsBuilder()
    let engine = NoiseEventEngine()
    engine.beginSession()
    let totalFrames = 50_000
    for index in 0..<totalFrames {
        let spl: Float = index < totalFrames / 2 ? 40 : 80
        b.observe(spl: spl, duration: 0.05, at: Double(index) * 0.05)
    }
    let snapshot = b.snapshot(name: "长期", engine: engine)
    // 后 2.5 万帧距最终 Leq 超过 3 dB，前 2.5 万帧也不接近最终值；
    // 该用例主要验证比例不会因 2 万样本上限被放大。
    expect(snapshot.steadyRatio >= 0 && snapshot.steadyRatio <= 1,
           "长期稳态占比在 0...1 (得 \(snapshot.steadyRatio))")
    expect(b.frameCount == totalFrames,
           "长期帧计数完整 (得 \(b.frameCount))")

    var stable = PositionStatsBuilder()
    for index in 0..<totalFrames {
        stable.observe(spl: 40, duration: 0.05, at: Double(index) * 0.05)
    }
    let stableSnapshot = stable.snapshot(name: "稳定", engine: engine)
    expect(abs(stableSnapshot.steadyRatio - 1) < 0.0001,
           "长期稳定声占比不因抽样上限缩小 (得 \(stableSnapshot.steadyRatio))")
}

// ---- 0b1a. 跨点位边界的 hop 按音频时长拆分 ----
do {
    let crossing = SourceTestTimeline.split(
        elapsed: 29.98, duration: 0.085_333, positionDuration: 30)
    expect(abs(crossing.current - 0.02) < 0.000_001,
           "跨点位 hop 前段归上一点位 (得 \(crossing.current))")
    expect(abs(crossing.overflow - 0.065_333) < 0.000_001,
           "跨点位 hop 后段归下一点位 (得 \(crossing.overflow))")
    expect(abs(crossing.current + crossing.overflow - 0.085_333) < 0.000_001,
           "跨点位拆分不丢时长也不重复")

    let atBoundary = SourceTestTimeline.split(
        elapsed: 30, duration: 0.042_667, positionDuration: 30)
    expect(atBoundary.current == 0
           && abs(atBoundary.overflow - 0.042_667) < 0.000_001,
           "边界后的 next hop 全部归下一点位")
}

// ---- 0b2. 主线程长间隔不得从 Leq 分母中丢失 ----
do {
    let rec = MeasurementRecorder()
    rec.start()
    rec.record(spl: 40, sessionPeak: 40, sessionLeq: nil, sessionLeqDuration: 0)
    Thread.sleep(forTimeInterval: 2.2)
    rec.record(spl: 40, sessionPeak: 40, sessionLeq: nil, sessionLeqDuration: 0)
    let live = rec.liveStats()
    expect(live.map { $0.duration >= 2.1 } == true,
           "长间隔仍计入测量时长 (得 \(live?.duration ?? -1))")
    expect(live.map { abs($0.laeq - 40) < 0.01 } == true,
           "卡顿间隔用上一帧读数补满,Leq 不偏高也不偏低 (得 \(live?.laeq ?? -999))")
}

// ---- 0c. L10/L50/L90 分位数方向 ----
do {
    let samples = (0..<100).map {
        ReportSample(relativeTime: TimeInterval($0), spl: Float($0))
    }
    guard let s = AcousticStatistics.from(samples: samples) else {
        fatalError("AcousticStatistics 应能从有限样本计算")
    }
    expect(abs(s.l10 - 90) < 0.001, "L10 = 超过它的时间占 10% (得 \(s.l10))")
    expect(abs(s.l50 - 50) < 0.001, "L50 = 中位数 (得 \(s.l50))")
    expect(abs(s.l90 - 10) < 0.001, "L90 = 超过它的时间占 90% (得 \(s.l90))")
    expect(abs(s.peak - 99) < 0.001, "统计峰值 = 最大 SPL (得 \(s.peak))")
}

// ---- 0d. 统计样本乱序时按时间重新积分,并保留全部有限有效点 ----
do {
    let samples = [
        ReportSample(relativeTime: 3, spl: 50),
        ReportSample(relativeTime: 0, spl: 40),
        ReportSample(relativeTime: 1, spl: 40),
        ReportSample(relativeTime: 2, spl: 50),
    ]
    guard let s = AcousticStatistics.from(samples: samples) else {
        fatalError("乱序样本应可计算")
    }
    // 排序后:40@0、40@1、50@2、50@3,各点按相邻间隔计 1s。
    let expected = Float(10 * log10((2 * pow(10.0, 4.0) + 2 * pow(10.0, 5.0)) / 4))
    expect(abs(s.laeq - expected) < 0.01,
           "乱序趋势样本按时间重排后积分 (得 \(s.laeq), 期望 \(expected))")
    expect(abs(s.l10 - 50) < 0.001 && abs(s.l90 - 40) < 0.001,
           "乱序样本分位数正确")
}

// ---- 0e. DBMeter：频谱开关只影响 FFT，不改变 SPL/Leq ----
do {
    let sampleRate: Float = 48000
    let tone = SignalGenerator.sineWave(frequency: 1000, amplitude: 0.1,
                                        sampleRate: sampleRate, count: 48_000 * 3)
    let full = DBMeter(config: MeterConfig(
        sampleRate: sampleRate, fftSize: 4096,
        spectrumEnabled: true, lowBandAnalysisInterval: 0.5))
    let lean = DBMeter(config: MeterConfig(
        sampleRate: sampleRate, fftSize: 4096,
        spectrumEnabled: false, lowBandAnalysisInterval: 0.5))
    var fullResult: MeterResult?
    var leanResult: MeterResult?
    var offset = 0
    while offset + 4096 <= tone.count {
        let frame = Array(tone[offset..<(offset + 4096)])
        fullResult = full.process(frame)
        leanResult = lean.process(frame)
        offset += 2048
    }
    expect(fullResult != nil && leanResult != nil,
           "频谱开关两组均产生测量结果")
    if let a = fullResult, let b = leanResult {
        expect(abs(a.splA - b.splA) < 0.001,
               "频谱开关不改变 SPL (差 \(abs(a.splA - b.splA)))")
        expect(abs(a.leqSPL - b.leqSPL) < 0.001,
               "频谱开关不改变 Leq (差 \(abs(a.leqSPL - b.leqSPL)))")
        expect(abs(a.leqDuration - b.leqDuration) < 0.001,
               "频谱开关不改变积分时长")
        expect(a.frequencies == b.frequencies
               && a.frequencies.last.map { abs($0 - 24_000) < 0.01 } == true,
               "频谱开关不改变频率轴；48k 输入 Nyquist bin 正确")
    }

    // 关闭全频谱后，低频分析仍按约 0.5s 音频时钟刷新。
    var spectrumUpdates = 0
    let cadence = DBMeter(config: MeterConfig(
        sampleRate: sampleRate, fftSize: 4096,
        spectrumEnabled: false, lowBandAnalysisInterval: 0.5))
    var t = 0
    while t + 4096 <= 48_000 * 3 {
        let frame = Array(tone[t..<(t + 4096)])
        if let r = cadence.process(frame), !r.spectrum.isEmpty {
            spectrumUpdates += 1
        }
        t += 2048
    }
    expect(spectrumUpdates >= 4 && spectrumUpdates <= 8,
           "关闭全频谱后低频仍约每 0.5s 刷新 (得 \(spectrumUpdates) 次/3s)")
}

// ---- 0f. 频谱归一化、尾帧新鲜度与 96k 高频计权 ----
do {
    let sampleRate: Float = 48_000
    let bin = sampleRate / 4096
    let tone = SignalGenerator.sineWave(frequency: 85 * bin, amplitude: 0.5,
                                        sampleRate: sampleRate, count: 8192)
    let meter = DBMeter(config: MeterConfig(sampleRate: sampleRate, fftSize: 4096))
    if let result = meter.process(tone, hopSamples: 2048),
       let peak = result.spectrum.max() {
        expect(abs(peak - 0.5) < 0.02,
               "频谱幅度归一化：满幅 0.5 正弦峰值 bin ≈0.5 (得 \(peak))")
        expect(result.frequencies.last.map { abs($0 - 24_000) < 0.01 } == true,
               "频谱频率轴保留到 Nyquist")
    } else {
        expect(false, "频谱归一化前置：应产生结果")
    }
    let tail = meter.processTail([Float](repeating: 0.1, count: 777))
    expect(tail?.spectrum.isEmpty == true,
           "尾帧不返回上一窗的旧频谱")

    let fs96: Float = 96_000
    let a96 = WeightingFilter(weighting: .a, sampleRate: fs96)
    let c96 = WeightingFilter(weighting: .c, sampleRate: fs96)
    let probe: [Float] = [24_000, 31_500, 40_000, 43_200]
    let maxA = probe.map { abs(a96.gain(at: $0) - AWeighting.gain(at: $0)) }.max() ?? 999
    let maxC = probe.map { abs(c96.gain(at: $0) - CWeighting.gain(at: $0)) }.max() ?? 999
    expect(maxA < 0.5 && maxC < 0.5,
           "96k 的 20–43.2kHz A/C 计权误差 <0.5dB (A \(maxA), C \(maxC))")
}

// ---- 1. 旧 JSON(无 audioID)可解码,audioID 为 nil ----
do {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("ss-old-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let json = dir.appendingPathComponent("history.json")
    let old = """
    [{"startTime":700000000,"endTime":700000060,"duration":60,"avgSPL":55,"laeqSPL":56,\
    "peakSPL":70,"minSPL":40,"overLimitTotal":0,\
    "samples":[{"relativeTime":1,"spl":55},{"relativeTime":2,"spl":56}]}]
    """
    try old.data(using: .utf8)?.write(to: json)
    let store = MeasurementHistoryStore(fileURL: json)
    expect(store.records.count == 1, "旧 JSON 解出 1 条记录")
    expect(store.records.first?.audioID == nil, "旧记录 audioID == nil")
    expect(store.records.first?.resolvedExposureLimit == 85,
           "旧记录缺少 exposureLimit 时按 85 dB 兼容")
}

// ---- 2. audioID 随 JSON 往返 ----
do {
    let (store, json, _) = makeStore()
    store.add(makeStats(audioID: "abc"))
    let reloaded = MeasurementHistoryStore(fileURL: json)
    expect(reloaded.records.first?.audioID == "abc", "audioID 持久化往返")
    expect(reloaded.records.first?.exposureLimit == 80,
           "exposureLimit 持久化往返")
    expect(reloaded.records.first?.resolvedWeighting == "A"
        && reloaded.records.first?.resolvedTimeWeighting == "F",
           "旧记录计权口径按 A/F 兼容")
}

// ---- 2b. 完全静音记录可写入 JSON,并在读取后恢复 -inf 语义 ----
do {
    let (store, json, _) = makeStore()
    let silent = MeasurementStats(
        startTime: Date(), endTime: Date(), duration: 1,
        avgSPL: -Float.infinity, laeqSPL: -Float.infinity,
        peakSPL: -Float.infinity,
        l10: -Float.infinity, l50: -Float.infinity, l90: -Float.infinity,
        minSPL: -Float.infinity, overLimitTotal: 0,
        exposureLimit: 85, weighting: "C", timeWeighting: "S",
        samples: [ReportSample(relativeTime: 0, spl: -Float.infinity)]
    )
    store.add(silent)
    expect(FileManager.default.fileExists(atPath: json.path),
           "静音记录成功写入历史文件")
    expect(!((try? String(contentsOf: json, encoding: .utf8)) ?? "")
        .lowercased().contains("inf"),
           "静音历史 JSON 不包含 -inf")
    let reloaded = MeasurementHistoryStore(fileURL: json)
    let record = reloaded.records.first
    expect(record?.laeqSPL == -Float.infinity
        && record?.peakSPL == -Float.infinity
        && record?.samples.first?.spl == -Float.infinity,
           "静音值读取后恢复 -inf 语义")
    expect(record?.leqMetricLabel == "LCeq"
        && record?.peakMetricLabel == "LCSmax"
        && record?.resolvedExposureLimit == 85,
           "计权口径与暴露阈值随记录往返")
}

// ---- 3. 删除单条 → 录音文件删除 ----
do {
    let (store, _, recDir) = makeStore()
    let f = fakeAudioFile(in: recDir, id: "rec-1")
    store.add(makeStats(audioID: "rec-1"))
    store.delete(at: IndexSet(integer: 0))
    expect(!FileManager.default.fileExists(atPath: f.path), "delete(at:) 删除录音文件")
    expect(store.records.isEmpty, "delete(at:) 删除记录")
}

// ---- 4. 清空 → 录音文件全删 ----
do {
    let (store, _, recDir) = makeStore()
    let f1 = fakeAudioFile(in: recDir, id: "a"), f2 = fakeAudioFile(in: recDir, id: "b")
    store.add(makeStats(audioID: "a"))
    store.add(makeStats(audioID: "b"))
    store.removeAll()
    expect(!FileManager.default.fileExists(atPath: f1.path)
        && !FileManager.default.fileExists(atPath: f2.path), "removeAll() 删除全部录音文件")
}

// ---- 5. 超上限淘汰 → 被淘汰记录的录音文件删除 ----
do {
    let (store, _, recDir) = makeStore()
    var kept: URL?
    for i in 0..<(MeasurementHistoryStore.maxRecords + 1) {
        let id = "rec-\(i)"
        let f = fakeAudioFile(in: recDir, id: id)
        if i == 1 { kept = f }  // 第 2 新的记录在淘汰后应保留
        store.add(makeStats(audioID: id))
    }
    expect(store.records.count == MeasurementHistoryStore.maxRecords, "记录数封顶 50")
    expect(!FileManager.default.fileExists(atPath: recDir.appendingPathComponent("rec-0.m4a").path),
           "最旧记录(最先加入)的录音文件被淘汰删除")
    expect(kept.map { FileManager.default.fileExists(atPath: $0.path) } == true, "未被淘汰的录音文件保留")
}

// ---- 6. 启动孤儿清扫 ----
do {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("ss-orphan-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let json = dir.appendingPathComponent("history.json")
    let store1 = MeasurementHistoryStore(fileURL: json)
    let ref = fakeAudioFile(in: store1.recordingsDirectory, id: "keep-me")
    let orphan = fakeAudioFile(in: store1.recordingsDirectory, id: "crash-leftover")
    store1.add(makeStats(audioID: "keep-me"))
    let store2 = MeasurementHistoryStore(fileURL: json)  // 重新 load → 清扫
    _ = store2
    expect(FileManager.default.fileExists(atPath: ref.path), "被引用的录音保留")
    expect(!FileManager.default.fileExists(atPath: orphan.path), "孤儿录音被清扫")
}

// ---- 7. FIR 降采样:任意分块下输出数量正确、正弦幅度保持 ----
do {
    var dec = FIRDecimator(taps: AACWriteSupport.makeTaps(count: 33, cutoffRatio: 0.225),
                           factor: 2)
    let rate: Float = 48000, freq: Float = 1000
    var out: [Float] = []
    var totalIn = 0
    for chunkSize in [7, 13, 1024, 4096, 3] {   // 刁钻分块验证跨块衔接
        let chunk = (0..<chunkSize).map { sin(2 * Float.pi * freq * Float($0 + totalIn) / rate) }
        out.append(contentsOf: dec.process(chunk))
        totalIn += chunkSize
    }
    // FIR 有 n-1 个输入样本的启动瞬态:期望输出数 = (输入-(n-1))/factor
    let tapCount = 33
    let expectedOut = (totalIn - (tapCount - 1) + 1) / 2
    expect(abs(out.count - expectedOut) <= 1,
           "降采样输出数 ≈ (输入-瞬态)/2 (得 \(out.count)/期望 \(expectedOut))")
    let rmsIn: Float = 0.707                       // 单位幅度正弦的 RMS
    let rmsOut = sqrt(out.map { $0 * $0 }.reduce(0, +) / Float(out.count))
    expect(abs(rmsOut - rmsIn) / rmsIn < 0.2, "1kHz 正弦幅度保持(得 \(rmsOut))")
}

// ---- 8. 完整录音会话:写盘可读、时长正确 ----
do {
    let probeURL = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("ss-audio-probe-\(UUID().uuidString).m4a")
    let canWriteAAC = AACWriteSupport.openFile(forWriting: probeURL,
                                               targetSampleRate: 24000) != nil
    try? FileManager.default.removeItem(at: probeURL)
    if !canWriteAAC {
        print("  - 跳过:当前环境无法创建 AAC 文件(沙箱/编码器不可用)")
    } else {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("ss-rec-\(UUID().uuidString)", isDirectory: true)
    let rec = SessionAudioRecorder()
    let id = rec.startSession(directory: dir, inputSampleRate: 48000)
    expect(id != nil, "会话创建返回 audioID")
    let rate: Float = 48000
    var written = 0
    while written < Int(3.0 * rate) {              // 3 秒 1kHz 正弦,按 tap 尺寸分块
        let chunk = (0..<4096).map { sin(2 * Float.pi * 1000 * Float(written + $0) / rate) }
        rec.append(chunk)
        written += 4096
    }
    let url = rec.finishSession(keep: true)
    expect(url != nil, "达标会话返回文件 URL")
    if let url = url {
        let audio = try? AVAudioFile(forReading: url)
        let dur = audio.map { TimeInterval($0.length) / $0.fileFormat.sampleRate } ?? 0
        expect(abs(dur - 3.0) < 0.5, "写盘时长 ≈ 3s (得 \(dur))")
        expect(url.deletingPathExtension().lastPathComponent == id, "文件名主干 == audioID")
    }
    }
}

// ---- 9. 短会话丢弃 / keep=false 丢弃 ----
do {
    let probeURL = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("ss-audio-probe-\(UUID().uuidString).m4a")
    let canWriteAAC = AACWriteSupport.openFile(forWriting: probeURL,
                                               targetSampleRate: 24000) != nil
    try? FileManager.default.removeItem(at: probeURL)
    if !canWriteAAC {
        print("  - 跳过:当前环境无法创建 AAC 文件(沙箱/编码器不可用)")
    } else {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("ss-rec2-\(UUID().uuidString)", isDirectory: true)
    let rec = SessionAudioRecorder()
    _ = rec.startSession(directory: dir, inputSampleRate: 48000)
    rec.append(Array(repeating: 0.3, count: 48000))    // 1 秒 < minKeepDuration
    let url = rec.finishSession(keep: true)
    expect(url == nil, "< 3s 会话被丢弃")
    expect((try? FileManager.default.contentsOfDirectory(atPath: dir.path))?.isEmpty == true,
           "丢弃后目录为空")

    _ = rec.startSession(directory: dir, inputSampleRate: 48000)
    rec.append(Array(repeating: 0.3, count: 48000 * 5))
    expect(rec.finishSession(keep: false) == nil, "keep=false 丢弃")
    expect((try? FileManager.default.contentsOfDirectory(atPath: dir.path))?.isEmpty == true,
           "丢弃后目录为空")
    }
}

// ---- 10. 时长上限自动停写 ----
do {
    let probeURL = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("ss-audio-probe-\(UUID().uuidString).m4a")
    let canWriteAAC = AACWriteSupport.openFile(forWriting: probeURL,
                                               targetSampleRate: 24000) != nil
    try? FileManager.default.removeItem(at: probeURL)
    if !canWriteAAC {
        print("  - 跳过:当前环境无法创建 AAC 文件(沙箱/编码器不可用)")
    } else {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("ss-rec3-\(UUID().uuidString)", isDirectory: true)
    let rec = SessionAudioRecorder()
    rec.maxDuration = 1.0
    rec.minKeepDuration = 0.5   // 避免默认 3s 门槛把截断文件当短会话删掉
    _ = rec.startSession(directory: dir, inputSampleRate: 48000)
    for _ in 0..<20 { rec.append(Array(repeating: 0.3, count: 48000)) }  // 名义 20s
    let url = rec.finishSession(keep: true)
    if let url = url {
        let audio = try? AVAudioFile(forReading: url)
        let dur = audio.map { TimeInterval($0.length) / $0.fileFormat.sampleRate } ?? 0
        expect(dur < 2.0, "到上限停写(得 \(dur)s)")
    } else {
        expect(false, "上限截断的文件应保留")
    }
    }
}

// ---- 11. HTML 报告组装 ----
do {
    let stats = makeStats(audioID: "x")
    let html = ReportHTMLBuilder.build(stats: stats, deviceName: "Mac&Book<Pro>",
                                       calibrationOffset: 93, pngBase64: "PNGDATA==",
                                       audioBase64: "AUDIODATA==")
    expect(html.contains("data:image/png;base64,PNGDATA=="), "内嵌报告图")
    expect(html.contains("data:audio/mp4;base64,AUDIODATA=="), "内嵌录音")
    expect(html.contains("<audio"), "存在 audio 控件")
    expect(html.contains("Mac&amp;Book&lt;Pro&gt;"), "设备名 HTML 转义")
    expect(html.contains(String(format: "%.1f", stats.laeqSPL)), "包含等效声级数值")
    expect(html.contains("LAeq 等效声级") && html.contains("峰值 LAFmax"),
           "A/F 口径正确标注 LAeq 与 LAFmax")
    expect(html.contains("超 80 dB 时长"), "报告超限时长使用记录中的实际阈值")
    let noAudio = ReportHTMLBuilder.build(stats: stats, deviceName: "d",
                                          calibrationOffset: 0, pngBase64: "P",
                                          audioBase64: nil)
    expect(!noAudio.contains("<audio") && !noAudio.contains("AUDIODATA"),
           "无录音时不渲染音频块")
    expect(ReportHTMLBuilder.filename(for: stats).hasSuffix(".html")
        && ReportHTMLBuilder.filename(for: stats).contains("闻声报告_"), "文件名格式")
    let csv = MeasurementCSV.csv(for: stats)
    expect(csv.contains("# 暴露阈值(dB),80")
        && csv.contains("# 超过该阈值时长(秒),12"),
           "CSV 导出实际暴露阈值与超限时长")

    let cStats = MeasurementStats(startTime: Date(), endTime: Date(), duration: 10,
                                  avgSPL: 50, laeqSPL: 52, peakSPL: 61,
                                  minSPL: 40, overLimitTotal: 0,
                                  exposureLimit: 85,
                                  weighting: "C", timeWeighting: "S",
                                  samples: [ReportSample(relativeTime: 0, spl: 50)])
    expect(cStats.leqMetricLabel == "LCeq"
        && cStats.peakMetricLabel == "LCSmax",
           "C/S 记录使用 LCeq 与 LCSmax 名称")
    let cHTML = ReportHTMLBuilder.build(stats: cStats, deviceName: "d",
                                        calibrationOffset: 0, pngBase64: "P",
                                        audioBase64: nil)
    expect(cHTML.contains("LCeq 等效声级")
        && cHTML.contains("峰值 LCSmax")
        && !cHTML.contains("LAeq"),
           "C 计权报告不误标成 LAeq")

    let silent = MeasurementStats(startTime: Date(), endTime: Date(), duration: 1,
                                  avgSPL: -Float.infinity,
                                  laeqSPL: -Float.infinity,
                                  peakSPL: -Float.infinity,
                                  l10: -Float.infinity, l50: -Float.infinity,
                                  l90: -Float.infinity,
                                  minSPL: -Float.infinity,
                                  overLimitTotal: 0,
                                  exposureLimit: 85,
                                  samples: [ReportSample(relativeTime: 0,
                                                         spl: -Float.infinity)])
    let silentHTML = ReportHTMLBuilder.build(stats: silent, deviceName: "d",
                                             calibrationOffset: 0, pngBase64: "P",
                                             audioBase64: nil)
    expect(!silentHTML.lowercased().contains("inf")
        && !silentHTML.lowercased().contains("nan")
        && silentHTML.contains("<b>--</b>"),
           "HTML 报告不输出 -inf/nan")
    let silentCSV = MeasurementCSV.csv(for: silent)
    expect(!silentCSV.lowercased().contains("inf")
        && !silentCSV.lowercased().contains("nan"),
           "CSV 不输出 -inf/nan")
}

// ---- 12. lowFrequencyRatio 频谱低频占比 ----
do {
    let ratio = lowFrequencyRatio(spectrum: [1, 1, 2], frequencies: [100, 500, 1000])
    // 功率: 100Hz=1, 500Hz=1, 1kHz=4 → 低频(≤200Hz)占比 = 1/6
    expect(abs(ratio! - 1.0/6.0) < 1e-6, "lowFrequencyRatio 功率占比 (得 \(ratio!))")
    let dcRatio = lowFrequencyRatio(spectrum: [100, 1, 1, 1, 2],
                                    frequencies: [0, 5, 10, 100, 500])
    expect(abs(dcRatio! - 0.2) < 1e-6,
           "低频占比排除 DC/20Hz 以下 (得 \(dcRatio!))")
    expect(lowFrequencyRatio(spectrum: [1, 1], frequencies: [0, 10]) == nil,
           "只有 DC/次声时低频占比为 nil")
    expect(lowFrequencyRatio(spectrum: [], frequencies: []) == nil, "空频谱返回 nil")
}

// ---- 13. 事件引擎:背景+三次脉冲 → 3 个事件 ----
do {
    let e = NoiseEventEngine()
    e.beginSession()
    var starts = 0
    e.onEventStart = { starts += 1 }
    var t = 0.0
    func run(_ seconds: Double, _ spl: Float, _ low: Float? = nil) {
        let steps = Int(seconds / 0.1)
        for _ in 0..<steps { e.feed(t: t, spl: spl, lowRatio: low); t += 0.1 }
    }
    run(60, 35)                                  // 背景 0→60
    run(0.5, 55, 0.8); run(5.5, 35)              // 脉冲1 @60.0
    run(0.5, 55, 0.8); run(5.5, 35)              // 脉冲2 @66.0(间隔 5.5s > 合并窗)
    run(0.5, 55, 0.8); run(4.0, 35)              // 脉冲3 @72.0
    expect(e.events.count == 3, "三次脉冲检出 3 个事件 (得 \(e.events.count))")
    expect(starts == 3,
           "只有达到最小时长的事件才启动片段录制 (得 \(starts))")
    if let ev = e.events.first {
        expect(abs(ev.startTime - 60.0) < 0.3, "事件起点 ≈60s (得 \(ev.startTime))")
        expect(abs(ev.peakSPL - 55) < 0.01, "事件峰值 55 (得 \(ev.peakSPL))")
        expect(abs(ev.avgLowRatio! - 0.8) < 0.01, "事件低频占比 0.8 (得 \(ev.avgLowRatio!))")
        expect(ev.attackRate >= 0, "起振陡度非负 (得 \(ev.attackRate))")
    }
    // 聚合:35dB 背景 + 少量 55dB 脉冲 → LAeq ≈ 39.7
    expect(abs(e.currentLaeq() - 39.7) < 1.0, "LAeq ≈39.7 (得 \(e.currentLaeq()))")
    expect(e.steadyCount > 0, "稳态帧计数 > 0")
    expect(e.frameCount == 765, "帧计数正确 (得 \(e.frameCount))")
}

// ---- 13b. 事件引擎：音频时钟与 wall clock 无关，基线缓存按时间更新 ----
do {
    let e = NoiseEventEngine()
    e.beginSession()
    e.baselineUpdateInterval = 0.5
    e.maxLowRatioAge = 0.2
    var t = 0.0
    while t < 12 {
        t += 0.05
        e.feed(t: t, duration: 0.05, spl: 40, lowRatio: 0.2)
    }
    expect(e.currentBaseline() != nil && abs(e.currentBaseline()! - 40) < 0.01,
           "音频时钟推进后基线可用")
    // 用真实音频时长积分：即使 t 看起来很大，也不会把时钟跳变误当成 45 秒静音。
    let beforeDuration = e.observedDuration
    _ = e.feed(t: 5000, duration: 0.05, spl: 40, lowRatio: 0.2)
    expect(abs(e.observedDuration - (beforeDuration + 0.05)) < 0.001,
           "事件积分只使用 coveredDuration (得 \(e.observedDuration - beforeDuration))")

    // 旧低频特征过期后不能继续污染后续事件分类。
    let stale = NoiseEventEngine()
    stale.beginSession()
    stale.maxLowRatioAge = 0.2
    var st = 0.0
    while st < 60 { st += 0.1; stale.feed(t: st, duration: 0.1, spl: 35, lowRatio: 0.9) }
    st += 2.0
    stale.feed(t: st, duration: 0.1, spl: 55, lowRatio: nil)
    let open = stale.snapshotOpenEvent()
    expect(open?.avgLowRatio == nil,
           "过期低频特征不参与新事件分类")
}

// ---- 14. 事件引擎:mergeWindow 内合并、窗外独立 ----
do {
    let e = NoiseEventEngine()
    e.beginSession()
    var t = 0.0
    func run(_ seconds: Double, _ spl: Float) {
        for _ in 0..<Int(seconds / 0.1) { e.feed(t: t, spl: spl, lowRatio: nil); t += 0.1 }
    }
    run(60, 35)                              // 背景 0→60
    run(0.5, 55); run(2.5, 35)               // 脉冲1 @60.0,结束 60.5
    run(0.5, 55); run(3.0, 35)               // 脉冲2 @63.0(间隔 2.5s ≤ 5s)→ 合并
    expect(e.events.count == 1, "间隔 2.5s 的双脉冲合并为 1 (得 \(e.events.count))")
    expect(e.totalEventCount == 1,
           "合并后的双脉冲仍只累计 1 个事件 (得 \(e.totalEventCount))")
    if let ev = e.events.first {
        expect(abs(ev.endTime - 63.5) < 0.3, "合并事件终点 ≈63.5 (得 \(ev.endTime))")
    }
    run(0.5, 55); run(5.5, 35)               // 脉冲3 @66.5(间隔 3s ≤ 5s)→ 仍合并
    expect(e.events.count == 1, "间隔 3s 仍合并 (得 \(e.events.count))")
    expect(e.totalEventCount == 1,
           "连续合并不会重复增加累计事件数 (得 \(e.totalEventCount))")
    run(0.5, 55); run(8.0, 35)               // 脉冲4 @72.5(间隔 72.5−67.0 = 5.5s > 5s)→ 独立
    expect(e.events.count == 2, "间隔 >5s 不合并 (得 \(e.events.count))")
    expect(e.totalEventCount == 2,
           "合并窗口外的新事件才增加累计数 (得 \(e.totalEventCount))")
}

// ---- 15. 事件引擎:短脉冲(低于最小时长)忽略 ----
do {
    let e = NoiseEventEngine()
    e.beginSession()
    var starts = 0
    e.onEventStart = { starts += 1 }
    var t = 0.0
    for _ in 0..<600 { e.feed(t: t, spl: 35, lowRatio: nil); t += 0.1 }
    for _ in 0..<1 { e.feed(t: t, spl: 55, lowRatio: nil); t += 0.1 }   // 0.1s < 0.2s
    for _ in 0..<60 { e.feed(t: t, spl: 35, lowRatio: nil); t += 0.1 }
    expect(e.events.isEmpty, "0.1s 瞬态被忽略 (得 \(e.events.count))")
    expect(starts == 0, "被忽略的短瞬态不启动片段录制 (得 \(starts))")
    expect(e.snapshotOpenEvent() == nil, "停止时也不伪造短瞬态事件")
}

// ---- 15b. 夜间绝对阈值应更敏感,不能被 max() 抬高 ----
do {
    let e = NoiseEventEngine()
    e.beginSession()
    e.absoluteThreshold = 45
    var t = 0.0
    func run(_ seconds: Double, _ spl: Float) {
        for _ in 0..<Int(seconds / 0.1) {
            e.feed(t: t, spl: spl, lowRatio: nil)
            t += 0.1
        }
    }
    run(60, 30)                 // 背景阈值=40；绝对阈值=45
    run(0.5, 42)                // 42 > 40，应触发
    run(4.0, 30)
    expect(e.events.count == 1,
           "夜间绝对阈值不会把较低背景阈值抬高 (得 \(e.events.count))")
}

// ---- 16. 判定器:方向倾向 ----
do {
    func pos(_ name: String, _ laeq: Float, events: Int = 0,
             low: Float = 0.3, steady: Float = 0.5) -> PositionStats {
        PositionStats(name: name, laeq: laeq, minSPL: laeq - 5, maxSPL: laeq + 10,
                      eventCount: events, avgLowRatio: low, steadyRatio: steady)
    }
    let center = { pos("中央", 40) }
    // 靠墙显著更响(+6.5dB) → 邻居,高置信
    let r1 = SourceTendencyAnalyzer.analyze(
        positions: [center(), pos("靠墙", 46.5), pos("靠顶", 41)], duration: 90)
    expect(r1.verdict == .neighbor, "墙增益主导 → 邻居")
    expect(r1.confidence == .high, "增益 6.5dB → 高置信 (得 \(r1.confidence.rawValue))")
    // 靠顶显著更响 → 楼上
    let r2 = SourceTendencyAnalyzer.analyze(
        positions: [center(), pos("靠墙", 41), pos("靠顶", 46)], duration: 90)
    expect(r2.verdict == .upstairs, "顶增益主导 → 楼上")
    // 平坦无梯度 → 无法判断/低置信
    let r3 = SourceTendencyAnalyzer.analyze(
        positions: [center(), pos("靠墙", 40.5), pos("靠顶", 40.5)], duration: 90)
    expect(r3.verdict == .inconclusive && r3.confidence == .low, "无梯度 → 无法判断/低置信")
    // 双侧同升,无主导 → 无法判断
    let r4 = SourceTendencyAnalyzer.analyze(
        positions: [center(), pos("靠墙", 42.5), pos("靠顶", 42.5)], duration: 90)
    expect(r4.verdict == .inconclusive, "双侧同升 → 无法判断")
    // 增益 4dB → 中置信
    let r5 = SourceTendencyAnalyzer.analyze(
        positions: [center(), pos("靠墙", 44), pos("靠顶", 40.5)], duration: 90)
    expect(r5.confidence == .medium, "增益 4dB → 中置信 (得 \(r5.confidence.rawValue))")

    // 四点测试:中央基准 40、墙 45、顶 41、中央复测 40.5 → 邻居
    let fourPoint = SourceTendencyAnalyzer.analyze(
        positions: [center(), pos("靠墙", 45), pos("靠顶", 41), pos("中央复测", 40.5)],
        duration: 120)
    expect(fourPoint.verdict == .neighbor
           && fourPoint.centerDrift == 0.5
           && !fourPoint.rejectedByDrift,
           "四点测试稳定 → 方向结论 (漂移 \(fourPoint.centerDrift ?? -1))")

    // 中央复测漂移 2.1 dB → 拒绝方向结论
    let drifted = SourceTendencyAnalyzer.analyze(
        positions: [center(), pos("靠墙", 45), pos("靠顶", 41), pos("中央复测", 42.1)],
        duration: 120)
    expect(drifted.verdict == .inconclusive
           && drifted.confidence == .low
           && drifted.rejectedByDrift,
           "中央漂移 >2dB → 拒绝方向结论")
}

// ---- 17. 判定器:噪音类型 ----
do {
    func pos(_ events: Int, low: Float, steady: Float) -> PositionStats {
        PositionStats(name: "x", laeq: 40, minSPL: 35, maxSPL: 55,
                      eventCount: events, avgLowRatio: low, steadyRatio: steady)
    }
    let impact = SourceTendencyAnalyzer.analyze(
        positions: [pos(60, low: 0.8, steady: 0.3),
                    pos(60, low: 0.8, steady: 0.3),
                    pos(60, low: 0.8, steady: 0.3)], duration: 90)
    expect(impact.noiseType == .impact, "事件密集 → impact (得 \(impact.noiseType.rawValue))")
    let sparseImpact = SourceTendencyAnalyzer.analyze(
        positions: [pos(1, low: 0.8, steady: 0.3),
                    pos(1, low: 0.8, steady: 0.3),
                    pos(1, low: 0.8, steady: 0.3)], duration: 90)
    expect(sparseImpact.noiseType == .impact, "2/min 且低频重 → impact (得 \(sparseImpact.noiseType.rawValue))")
    let continuous = SourceTendencyAnalyzer.analyze(
        positions: [pos(0, low: 0.2, steady: 0.8),
                    pos(0, low: 0.2, steady: 0.8),
                    pos(0, low: 0.2, steady: 0.8)], duration: 90)
    expect(continuous.noiseType == .continuous, "稳态连续 → continuous (得 \(continuous.noiseType.rawValue))")
    let mixed = SourceTendencyAnalyzer.analyze(
        positions: [pos(1, low: 0.2, steady: 0.7),
                    pos(1, low: 0.2, steady: 0.7),
                    pos(1, low: 0.2, steady: 0.7)], duration: 90)
    expect(mixed.noiseType == .mixed, "事件+稳态并存 → mixed (得 \(mixed.noiseType.rawValue))")
    let denseMixed = SourceTendencyAnalyzer.analyze(
        positions: [pos(3, low: 0.2, steady: 0.7),
                    pos(3, low: 0.2, steady: 0.7),
                    pos(3, low: 0.2, steady: 0.7)], duration: 90)
    expect(denseMixed.noiseType == .mixed,
           "密集事件+稳态底噪仍判 mixed，不能被 impact 吞掉 (得 \(denseMixed.noiseType.rawValue))")
    let unknown = SourceTendencyAnalyzer.analyze(
        positions: [pos(1, low: 0.2, steady: 0.3),
                    pos(1, low: 0.2, steady: 0.3),
                    pos(1, low: 0.2, steady: 0.3)], duration: 180)
    expect(unknown.noiseType == .unknown, "特征不足 → unknown (得 \(unknown.noiseType.rawValue))")
}

// ---- 18. 位置推测 ----
do {
    let cal = SourceTestResult(id: UUID(), startTime: Date(), duration: 90,
                               positions: [], verdict: .neighbor,
                               confidence: .medium, noiseType: .continuous, audioID: nil)
    expect(SourceTendencyAnalyzer.guessPosition(lowRatio: 0.8, isImpact: true, calibration: nil)
           == "位置未标定", "无标定的低频冲击不冒充楼上结论")
    expect(SourceTendencyAnalyzer.guessPosition(lowRatio: 0.2, isImpact: true, calibration: nil)
           == "位置未标定", "无标定冲击 → 位置未标定")
    expect(SourceTendencyAnalyzer.guessPosition(lowRatio: 0.2, isImpact: false, calibration: nil)
           == "不确定", "无标定连续声 → 不确定")
    expect(SourceTendencyAnalyzer.guessPosition(lowRatio: 0.2, isImpact: false, calibration: cal)
           == "隔壁(推测·标定一致)", "连续声+标定邻居 → 标定一致")
    let driftCal = SourceTestResult(id: UUID(), startTime: Date(), duration: 120,
                                    positions: [], verdict: .inconclusive,
                                    confidence: .low, noiseType: .unknown,
                                    centerDrift: 4.2, rejectedByDrift: true)
    expect(SourceTendencyAnalyzer.guessPosition(lowRatio: 0.2, isImpact: false,
                                                 calibration: driftCal)
           == "不确定", "漂移被拒的历史结果不能当作标定")

    let upstairsCal = SourceTestResult(
        id: UUID(), startTime: Date(), duration: 120,
        positions: [], verdict: .upstairs, confidence: .high,
        noiseType: .impact, audioID: nil)
    expect(SourceTendencyAnalyzer.guessPosition(
        lowRatio: 0.8, isImpact: true, calibration: upstairsCal)
           == "楼上(推测·标定一致)", "楼上标定 + 低频冲击 → 标定一致")
    expect(SourceTendencyAnalyzer.guessPosition(
        lowRatio: 0.2, isImpact: true, calibration: upstairsCal)
           == "不确定", "楼上标定但无低频证据 → 不确定")

    // 低频重只能说明能量分布，不能把长连续声误判成脚步/撞击。
    let longLow = SourceTendencyAnalyzer.classifyMonitorEvent(
        lowRatio: 0.9, duration: 12, attackRate: 2, calibration: nil)
    expect(longLow.type == .continuous,
           "低频重但持续 12s → 连续声，不判冲击 (得 \(longLow.type.rawValue))")
    let shortFast = SourceTendencyAnalyzer.classifyMonitorEvent(
        lowRatio: 0.1, duration: 0.8, attackRate: 30, calibration: nil)
    expect(shortFast.type == .impact,
           "短促快速起振 → 冲击，与低频占比无关 (得 \(shortFast.type.rawValue))")
    let mediumSlow = SourceTendencyAnalyzer.classifyMonitorEvent(
        lowRatio: 0.9, duration: 2.5, attackRate: 1, calibration: nil)
    expect(mediumSlow.type == .unknown,
           "中长缓起声即使低频重也不判冲击 (得 \(mediumSlow.type.rawValue))")
}

// ---- 19. 三点测试存储:生命周期 ----
do {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("ss-st-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let json = dir.appendingPathComponent("source_tests.json")
    let store = SourceTestStore(fileURL: json)
    func result(_ id: String) -> SourceTestResult {
        SourceTestResult(startTime: Date(), duration: 90,
                         positions: [PositionStats(name: "中央", laeq: 40, minSPL: 35, maxSPL: 50,
                                                   eventCount: 3, avgLowRatio: 0.7, steadyRatio: 0.4)],
                         verdict: .upstairs, confidence: .medium,
                         noiseType: .impact, audioID: id)
    }
    // 增 + audioID 往返
    store.add(result("t-1"))
    let reloaded = SourceTestStore(fileURL: json)
    expect(reloaded.results.first?.audioID == "t-1", "三点测试结果持久化往返")
    // 旧版三位置 JSON 缺少 centerDrift / rejectedByDrift 字段,必须仍可解码
    let legacyJSON = """
    [{"id":"\(UUID().uuidString)","startTime":0,"duration":90,
      "positions":[{"name":"中央","laeq":40,"minSPL":35,"maxSPL":50,
                    "eventCount":1,"avgLowRatio":0.2,"steadyRatio":0.5}],
      "verdict":"inconclusive","confidence":"low","noiseType":"unknown"}]
    """
    let legacyURL = dir.appendingPathComponent("source_tests_legacy.json")
    try? Data(legacyJSON.utf8).write(to: legacyURL)
    let legacyStore = SourceTestStore(fileURL: legacyURL)
    expect(legacyStore.results.count == 1
           && legacyStore.results[0].centerDrift == nil
           && !legacyStore.results[0].rejectedByDrift,
           "旧版三位置 JSON 兼容(无漂移字段)")
    // 删除连带文件
    let f: Void? = try? Data("x".utf8).write(to: store.audioFileURL(forID: "t-1"))
    expect(f != nil, "测试前置:文件已建")
    store.delete(at: IndexSet(integer: 0))
    expect(!FileManager.default.fileExists(atPath: store.audioFileURL(forID: "t-1").path),
           "删除结果连带录音文件")
    // 清空连带文件 + 孤儿清扫
    store.add(result("k")); store.add(result("orphan"))
    try? Data("x".utf8).write(to: store.audioFileURL(forID: "keep2"))
    store.removeAll()
    let left = (try? FileManager.default.contentsOfDirectory(
        atPath: store.recordingsDirectory.path)) ?? []
    expect(left.isEmpty, "清空后录音目录为空 (得 \(left))")
    // 超 20 条淘汰
    for i in 0..<(SourceTestStore.maxResults + 1) {
        store.add(result("e-\(i)"))
    }
    expect(store.results.count == SourceTestStore.maxResults, "结果封顶 20")
    expect(!FileManager.default.fileExists(atPath: store.audioFileURL(forID: "e-0").path),
           "最旧结果录音被淘汰删除")
}

// ---- 20. SessionAudioRecorder:非整数倍采样率不能标错文件头 ----
do {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("ss-session-441-\(UUID().uuidString)", isDirectory: true)
    let rec = SessionAudioRecorder()
    rec.minKeepDuration = 0
    if let id = rec.startSession(directory: dir, inputSampleRate: 44100) {
        rec.append(Array(repeating: 0.2, count: 44100))
        rec.finishSession(keep: true)
        let url = dir.appendingPathComponent("\(id).m4a")
        if let audio = try? AVAudioFile(forReading: url) {
            expect(abs(audio.fileFormat.sampleRate - 44100) < 1,
                   "44.1kHz 输入按 44.1kHz 写盘 (得 \(audio.fileFormat.sampleRate))")
            let duration = TimeInterval(audio.length) / audio.fileFormat.sampleRate
            expect(abs(duration - 1.0) < 0.15,
                   "44.1kHz 一秒样本时长 ≈1s (得 \(duration))")
        } else {
            expect(false, "44.1kHz 录音文件可读")
        }
    } else {
        print("  - 跳过:当前环境无法创建 AAC 文件(沙箱/编码器不可用)")
    }
}

// ---- 20b. 事件片段录音器 ----
do {
    let probeURL = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("ss-audio-probe-\(UUID().uuidString).m4a")
    let canWriteAAC = AACWriteSupport.openFile(forWriting: probeURL,
                                               targetSampleRate: 24000) != nil
    try? FileManager.default.removeItem(at: probeURL)
    if !canWriteAAC {
        print("  - 跳过:当前环境无法创建 AAC 文件(沙箱/编码器不可用)")
    } else {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("ss-clip-\(UUID().uuidString)", isDirectory: true)
    let rec = EventClipRecorder()
    rec.configure(directory: dir, inputSampleRate: 48000)
    let rate = 48000
    func feed(_ seconds: Double) {
        var n = 0
        while n < Int(seconds * Double(rate)) {
            rec.append(Array(repeating: 0.3, count: 4096))
            n += 4096
        }
    }
    // 未开始片段:只进环形缓冲,不落盘
    feed(2.5)
    expect(!rec.isClipOpen, "喂流但未开片段 → 不算打开")
    // 开片段(含 2s pre-roll)→ 0.5s 事件 → 收口后补 3s post-roll
    let url = rec.beginClip()
    expect(url != nil, "beginClip 返回片段文件 URL")
    expect(rec.isClipOpen, "片段打开中")
    feed(0.5)                                   // 事件本体
    expect(rec.endClip(), "endClip 成功(有打开的片段)")
    expect(!rec.isClipOpen, "endClip 后关闭")
    feed(3.0)                                   // post-roll 数据到位后异步定稿
    rec.flush()                                 // 等队列排空,文件定稿
    if let url = url {
        let audio = try? AVAudioFile(forReading: url)
        let dur = audio.map { TimeInterval($0.length) / $0.fileFormat.sampleRate } ?? 0
        expect(abs(dur - 5.5) < 0.4, "片段时长 ≈ pre+事件+post=5.5s (得 \(dur))")
    }
    // 无片段时 endClip → false
    expect(!rec.endClip(), "无片段 endClip 返回 false")
    // 第二个片段独立工作
    let url2 = rec.beginClip()
    feed(0.3)
    _ = rec.endClip()
    feed(3.0)
    rec.flush()
    expect(url2 != nil && FileManager.default.fileExists(atPath: url2!.path),
           "第二个片段正常落盘")

    // 非整数倍采样率按源采样率写,不能把 44.1k 标成 24k
    let rec441 = EventClipRecorder()
    rec441.configure(directory: dir, inputSampleRate: 44100)
    let url441 = rec441.beginClip()
    rec441.append(Array(repeating: 0.2, count: 44100))
    expect(rec441.endClip(), "44.1kHz 片段可收口")
    expect(rec441.lastClipURL != nil, "44.1kHz 片段 pre-roll/事件已有 URL")
    rec441.finish()
    rec441.flush()
    if let url441,
       let audio441 = try? AVAudioFile(forReading: url441) {
        expect(abs(audio441.fileFormat.sampleRate - 44100) < 1,
               "44.1kHz 片段文件头采样率正确 (得 \(audio441.fileFormat.sampleRate))")
    } else {
        expect(false, "44.1kHz 片段文件可读")
    }

    // 硬时限:1 秒上限,持续喂 4 秒,文件应在 ≈1 秒定稿
    let limitedDir = dir.appendingPathComponent("limited", isDirectory: true)
    let limited = EventClipRecorder()
    limited.maxClipDuration = 1
    limited.configure(directory: limitedDir, inputSampleRate: 48000)
    let limitedURL = limited.beginClip()
    var limitedN = 0
    while limitedN < Int(4.0 * Double(rate)) {
        limited.append(Array(repeating: 0.3, count: 4096))
        limitedN += 4096
    }
    limited.flush()
    expect(!limited.isClipOpen, "达到片段硬时限后自动定稿")
    if let limitedURL = limitedURL,
       let audio = try? AVAudioFile(forReading: limitedURL) {
        let duration = TimeInterval(audio.length) / audio.fileFormat.sampleRate
        expect(duration <= 1.2, "硬时限片段不超过设定时长 (得 \(duration))")
    }
    expect(limited.endClip(), "硬时限定稿后 endClip 仍可收口")
    limited.finish()
    limited.flush()

    // 达到事件上限后停用抓拍：不能继续保留环形缓冲或打开文件。
    let disabled = EventClipRecorder()
    disabled.configure(directory: dir, inputSampleRate: 48000)
    disabled.append(Array(repeating: 0.1, count: 4800))
    disabled.disableCapture()
    disabled.append(Array(repeating: 0.1, count: 4800))
    disabled.flush()
    expect(disabled.beginClip() == nil, "停用抓拍后不再创建片段")
    expect(!disabled.isClipOpen, "停用抓拍后没有悬挂文件")
    disabled.configure(directory: dir, inputSampleRate: 48000)
    expect(disabled.beginClip() != nil, "重新 configure 后可恢复抓拍")
    disabled.finish()
    disabled.flush()
    }
}

// ---- 21. 监听会话存储:生命周期 ----
do {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("ss-mon-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let json = dir.appendingPathComponent("monitor_sessions.json")
    let store = MonitorSessionStore(fileURL: json)

    func session(id: UUID = UUID(), clips: [String] = []) -> MonitorSession {
        let events = clips.enumerated().map { i, clip in
            MonitorEvent(id: UUID(), time: Date(), peakSPL: 55, duration: 1.2,
                         avgLowRatio: 0.8, type: .impact, guess: "楼上(推测)", clipFile: clip)
        }
        return MonitorSession(startTime: Date().addingTimeInterval(-3600),
                              endTime: Date(), overallLaeq: 42, minSPL: 33, maxSPL: 58,
                              thresholdOverBackground: 10, events: events)
    }
    // 增删 + 片段目录生命周期
    let s1 = session()
    store.add(s1)
    let clipURL = store.clipsDirectory(sessionID: s1.id).appendingPathComponent("e1.m4a")
    try? Data("x".utf8).write(to: clipURL)
    store.flushAndWait()
    let reloaded = MonitorSessionStore(fileURL: json)
    expect(reloaded.sessions.first?.id == s1.id, "监听会话持久化往返")
    let thresholdSession = MonitorSession(
        startTime: Date(), endTime: Date(), overallLaeq: 40,
        minSPL: 30, maxSPL: 50, weighting: "C", timeWeighting: "S",
        thresholdOverBackground: 10,
        absoluteThreshold: 45, captureIncomplete: true)
    store.add(thresholdSession)
    store.flushAndWait()
    let thresholdReloaded = MonitorSessionStore(fileURL: json)
    expect(thresholdReloaded.sessions.first { $0.id == thresholdSession.id }?
        .absoluteThreshold == 45,
           "监听绝对阈值随会话持久化")
    expect(thresholdReloaded.sessions.first { $0.id == thresholdSession.id }?
        .captureIncomplete == true,
           "监听完整性诊断随会话持久化")
    let reloadedMonitor = thresholdReloaded.sessions.first { $0.id == thresholdSession.id }
    expect(reloadedMonitor?.leqMetricLabel == "LCeq"
        && reloadedMonitor?.peakMetricLabel == "LCSmax",
           "监听会话计权口径随记录往返")
    // 事件更新采用合并写入；flush() 后必须能在新实例中立即读到。
    var coalesced = thresholdSession
    coalesced.events = [MonitorEvent(time: Date(), peakSPL: 52, duration: 1,
                                     avgLowRatio: 0.3, type: .continuous,
                                     guess: "隔壁(推测)")]
    store.update(coalesced)
    expect(store.sessions.first { $0.id == thresholdSession.id }?.events.count == 1,
           "监听事件在内存中立即更新")
    store.flushAndWait()
    let flushedStore = MonitorSessionStore(fileURL: json)
    expect(flushedStore.sessions.first { $0.id == thresholdSession.id }?.events.count == 1,
           "flush 后监听事件立即落盘")
    // 旧版 JSON 没有 absoluteThreshold / abnormalEnd 字段，必须仍可解码。
    // 使用独立目录，避免旧格式的孤儿清扫影响本组生命周期用例。
    let legacyDir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("ss-mon-legacy-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: legacyDir, withIntermediateDirectories: true)
    let legacyJSONURL = legacyDir.appendingPathComponent("monitor_sessions.json")
    let legacyJSON = """
    [{
      "id": "\(UUID().uuidString)",
      "startTime": 0,
      "overallLaeq": 42,
      "minSPL": 33,
      "maxSPL": 58,
      "thresholdOverBackground": 10,
      "events": []
    }]
    """
    try? Data(legacyJSON.utf8).write(to: legacyJSONURL)
    let legacyStore = MonitorSessionStore(fileURL: legacyJSONURL)
    expect(legacyStore.sessions.count == 1
        && legacyStore.sessions[0].absoluteThreshold == nil,
           "旧版监听 JSON 兼容(无 absoluteThreshold)")
    expect(FileManager.default.fileExists(atPath: clipURL.path), "前置:片段文件已建")
    let s1Index = store.sessions.firstIndex { $0.id == s1.id }
    expect(s1Index != nil, "测试前置:原会话仍在列表")
    if let s1Index { store.delete(at: IndexSet(integer: s1Index)) }
    expect(!FileManager.default.fileExists(atPath: clipURL.path), "删除会话连带删片段目录")
    // 孤儿子目录清扫
    let orphanDir = store.baseClipsDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try? FileManager.default.createDirectory(at: orphanDir, withIntermediateDirectories: true)
    try? Data("x".utf8).write(to: orphanDir.appendingPathComponent("junk.m4a"))
    _ = MonitorSessionStore(fileURL: json)   // 重新加载触发清扫
    expect(!FileManager.default.fileExists(atPath: orphanDir.path), "孤儿片段目录被清扫")
    // 清空
    store.add(session()); store.add(session())
    store.removeAll()
    expect(store.sessions.isEmpty, "清空后会话为空")
    expect(((try? FileManager.default.contentsOfDirectory(
        atPath: store.baseClipsDirectory.path)) ?? []).isEmpty, "清空后片段目录空")
    // 超 20 条淘汰
    for _ in 0..<(MonitorSessionStore.maxSessions + 1) { store.add(session()) }
    expect(store.sessions.count == MonitorSessionStore.maxSessions, "会话封顶 20")
}

// ---- 22. 监听会话:启动时收口异常中断 ----
do {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("ss-mon-interrupt-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let json = dir.appendingPathComponent("monitor_sessions.json")
    let store = MonitorSessionStore(fileURL: json)
    let running = MonitorSession(startTime: Date().addingTimeInterval(-60),
                                 overallLaeq: 41, minSPL: 30, maxSPL: 55,
                                 thresholdOverBackground: 10)
    let finished = MonitorSession(startTime: Date().addingTimeInterval(-120),
                                  endTime: Date().addingTimeInterval(-60),
                                  overallLaeq: 40, minSPL: 29, maxSPL: 52,
                                  thresholdOverBackground: 10)
    store.add(finished)
    store.add(running)
    store.finalizeInterruptedSessions()
    expect(store.sessions.first { $0.id == running.id }?.endTime != nil
        && store.sessions.first { $0.id == running.id }?.abnormalEnd == true,
           "启动收口将遗留监听标为异常结束")
    expect(store.sessions.first { $0.id == finished.id }?.abnormalEnd == false,
           "启动收口不修改已正常结束的监听")
}

// ---- 23. 监听达到片段上限后仍继续记录事件 ----
do {
    var session = MonitorSession(startTime: Date(), overallLaeq: 40,
                                 minSPL: 30, maxSPL: 70,
                                 thresholdOverBackground: 10)
    let maxEvents = 3
    for index in 0..<(maxEvents + 1) {
        let hasClip = session.events.count < maxEvents
        session.appendEvent(MonitorEvent(
            time: Date().addingTimeInterval(Double(index)),
            peakSPL: 60, duration: 0.5,
            avgLowRatio: 0.2, type: .impact,
            guess: "位置未标定",
            clipFile: hasClip ? "clip-\(index).m4a" : nil))
    }
    expect(session.events.count == maxEvents + 1,
           "达到片段上限后仍记录后续事件 (得 \(session.events.count))")
    expect(session.events.last?.clipFile == nil,
           "超过片段上限的新事件不再关联录音")
}

// ---- 24. 事件明细有界，累计数量与峰值不丢 ----
do {
    let e = NoiseEventEngine()
    e.beginSession()
    e.retainedEventLimit = 5
    var t = 0.0
    func run(_ seconds: Double, _ spl: Float, _ low: Float? = nil) {
        for _ in 0..<Int(seconds / 0.1) {
            e.feed(t: t, duration: 0.1, spl: spl, lowRatio: low)
            t += 0.1
        }
    }
    run(60, 35)
    for index in 0..<12 {
        run(0.4, 55 + Float(index), 0.4)
        run(6.0, 35)
    }
    expect(e.events.count == 5,
           "事件明细封顶 5 (得 \(e.events.count))")
    expect(e.totalEventCount == 12,
           "累计事件数不被明细上限截断 (得 \(e.totalEventCount))")
    expect(e.droppedEventCount == 7,
           "记录被淘汰的明细数 (得 \(e.droppedEventCount))")
    expect(abs(e.eventPeakSPL - 66) < 0.01,
           "事件峰值不随明细淘汰丢失 (得 \(e.eventPeakSPL))")

    var session = MonitorSession(startTime: Date(), overallLaeq: 40,
                                 minSPL: 30, maxSPL: 80,
                                 thresholdOverBackground: 10)
    for index in 0..<(MonitorSession.maxRetainedEvents + 10) {
        session.appendEvent(MonitorEvent(
            time: Date().addingTimeInterval(Double(index)),
            peakSPL: Float(50 + index % 20), duration: 0.5,
            avgLowRatio: 0.3, type: .impact,
            guess: "不确定", clipFile: nil))
    }
    expect(session.events.count == MonitorSession.maxRetainedEvents,
           "监听会话事件明细有界 (得 \(session.events.count))")
    expect(session.totalEventCount == MonitorSession.maxRetainedEvents + 10,
           "监听会话累计事件数完整 (得 \(session.totalEventCount))")
    expect(session.droppedEventCount == 10,
           "监听会话淘汰明细数正确 (得 \(session.droppedEventCount))")
}

if failures > 0 { print("\(failures) FAILURES"); exit(1) }
