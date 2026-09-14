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
                     overLimitTotal: 0,
                     samples: [ReportSample(relativeTime: 1, spl: 55),
                               ReportSample(relativeTime: 2, spl: 56)],
                     audioID: audioID)
}

func fakeAudioFile(in dir: URL, id: String) -> URL {
    let url = dir.appendingPathComponent("\(id).m4a")
    try? Data("fake".utf8).write(to: url)
    return url
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
}

// ---- 2. audioID 随 JSON 往返 ----
do {
    let (store, json, _) = makeStore()
    store.add(makeStats(audioID: "abc"))
    let reloaded = MeasurementHistoryStore(fileURL: json)
    expect(reloaded.records.first?.audioID == "abc", "audioID 持久化往返")
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
    var dec = FIRDecimator(taps: SessionAudioRecorder.makeTaps(count: 33, cutoffRatio: 0.225),
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

// ---- 9. 短会话丢弃 / keep=false 丢弃 ----
do {
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

// ---- 10. 时长上限自动停写 ----
do {
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
    expect(html.contains(String(format: "%.1f", stats.laeqSPL)), "包含 LAeq 数值")
    let noAudio = ReportHTMLBuilder.build(stats: stats, deviceName: "d",
                                          calibrationOffset: 0, pngBase64: "P",
                                          audioBase64: nil)
    expect(!noAudio.contains("<audio") && !noAudio.contains("AUDIODATA"),
           "无录音时不渲染音频块")
    expect(ReportHTMLBuilder.filename(for: stats).hasSuffix(".html")
        && ReportHTMLBuilder.filename(for: stats).contains("闻声报告_"), "文件名格式")
}

// ---- 12. lowFrequencyRatio 频谱低频占比 ----
do {
    let ratio = lowFrequencyRatio(spectrum: [1, 1, 2], frequencies: [100, 500, 1000])
    // 功率: 100Hz=1, 500Hz=1, 1kHz=4 → 低频(≤200Hz)占比 = 1/6
    expect(abs(ratio! - 1.0/6.0) < 1e-6, "lowFrequencyRatio 功率占比 (得 \(ratio!))")
    expect(lowFrequencyRatio(spectrum: [], frequencies: []) == nil, "空频谱返回 nil")
}

// ---- 13. 事件引擎:背景+三次脉冲 → 3 个事件 ----
do {
    let e = NoiseEventEngine()
    e.beginSession()
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
    if let ev = e.events.first {
        expect(abs(ev.endTime - 63.5) < 0.3, "合并事件终点 ≈63.5 (得 \(ev.endTime))")
    }
    run(0.5, 55); run(5.5, 35)               // 脉冲3 @66.5(间隔 3s ≤ 5s)→ 仍合并
    expect(e.events.count == 1, "间隔 3s 仍合并 (得 \(e.events.count))")
    run(0.5, 55); run(8.0, 35)               // 脉冲4 @72.5(间隔 72.5−67.0 = 5.5s > 5s)→ 独立
    expect(e.events.count == 2, "间隔 >5s 不合并 (得 \(e.events.count))")
}

// ---- 15. 事件引擎:短脉冲(低于最小时长)忽略 ----
do {
    let e = NoiseEventEngine()
    e.beginSession()
    var t = 0.0
    for _ in 0..<600 { e.feed(t: t, spl: 35, lowRatio: nil); t += 0.1 }
    for _ in 0..<1 { e.feed(t: t, spl: 55, lowRatio: nil); t += 0.1 }   // 0.1s < 0.2s
    for _ in 0..<60 { e.feed(t: t, spl: 35, lowRatio: nil); t += 0.1 }
    expect(e.events.isEmpty, "0.1s 瞬态被忽略 (得 \(e.events.count))")
}

// ---- 16. 判定器:方向倾向 ----
do {
    func pos(_ name: String, _ laeq: Float, events: Int = 0,
             low: Float = 0.3, steady: Float = 0.5) -> PositionStats {
        PositionStats(name: name, laeq: laeq, minSPL: laeq - 5, maxSPL: laeq + 10,
                      eventCount: events, avgLowRatio: low, steadyRatio: steady)
    }
    let center = { pos("中央", 40) }
    // 靠墙显著更响(+5dB) → 邻居,高置信
    let r1 = SourceTendencyAnalyzer.analyze(
        positions: [center(), pos("靠墙", 45), pos("靠顶", 41)], duration: 90)
    expect(r1.verdict == .neighbor, "墙增益主导 → 邻居")
    expect(r1.confidence == .high, "增益 5dB → 高置信 (得 \(r1.confidence.rawValue))")
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
    // 增益 3dB → 中置信
    let r5 = SourceTendencyAnalyzer.analyze(
        positions: [center(), pos("靠墙", 43), pos("靠顶", 40.5)], duration: 90)
    expect(r5.confidence == .medium, "增益 3dB → 中置信 (得 \(r5.confidence.rawValue))")
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
    let unknown = SourceTendencyAnalyzer.analyze(
        positions: [pos(1, low: 0.2, steady: 0.3),
                    pos(1, low: 0.2, steady: 0.3),
                    pos(1, low: 0.2, steady: 0.3)], duration: 180)
    expect(unknown.noiseType == .unknown, "特征不足 → unknown (得 \(unknown.noiseType.rawValue))")
}

// ---- 18. 位置推测 ----
do {
    expect(SourceTendencyAnalyzer.guessPosition(lowRatio: 0.8, isImpact: true, calibration: nil)
           == "楼上(推测)", "低频冲击 → 楼上(推测)")
    expect(SourceTendencyAnalyzer.guessPosition(lowRatio: 0.2, isImpact: true, calibration: nil)
           == "不确定", "中频冲击 → 不确定")
    expect(SourceTendencyAnalyzer.guessPosition(lowRatio: 0.2, isImpact: false, calibration: nil)
           == "隔壁(推测)", "连续声 → 隔壁(推测)")
    let cal = SourceTestResult(id: UUID(), startTime: Date(), duration: 90,
                               positions: [], verdict: .neighbor,
                               confidence: .medium, noiseType: .continuous, audioID: nil)
    expect(SourceTendencyAnalyzer.guessPosition(lowRatio: 0.2, isImpact: false, calibration: cal)
           == "隔壁(推测·标定一致)", "连续声+标定邻居 → 标定一致")
}

if failures > 0 { print("\(failures) FAILURES"); exit(1) }
