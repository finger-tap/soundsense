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

if failures > 0 { print("\(failures) FAILURES"); exit(1) }
