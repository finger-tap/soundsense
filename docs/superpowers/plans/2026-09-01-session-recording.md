# 检测同步录音 + 历史回放 + HTML 报告导出 实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 检测时同步录音（AAC m4a），历史详情可看完整简报并播放录音，导出自包含 HTML 报告，清理历史时录音文件零残留。

**Architecture:** 复用 `AudioMeterEngine` 的唯一 inputNode tap，通过线程安全 `sampleSink` 把 PCM 分块喂给新的 `SessionAudioRecorder`（FIR 低通 + 2:1 降采样 → AVAudioFile AAC）；录音文件与历史记录经 `MeasurementStats.audioID` 关联，`MeasurementHistoryStore` 统一管理文件生命周期（删除/清空/淘汰/孤儿清扫）；HTML 导出用 `ReportHTMLBuilder` 把报告 PNG 与录音 base64 内嵌进单文件。

**Tech Stack:** Swift 5 / SwiftUI / AVFoundation（AVAudioEngine tap、AVAudioFile、AVAudioPlayer、AVAudioConverter 不用——自实现 FIR 降采样）/ CoreGraphics（复用 ReportRenderer）。

**Spec:** `docs/superpowers/specs/2026-09-01-session-recording-design.md`

## Global Constraints

- 平台部署目标：iOS 15 / macOS 12 / watchOS 8（`project.pbxproj` 现值，不得改动）。
- 新增 Shared 文件只注册进 **SoundSense（iOS）与 SoundSenseMac（macOS）** 两个 target，**不进 SoundSenseWatch**。
- 录音常开，**不做设置开关**（用户拍板）；watchOS 完全不录音。
- 录音格式：AAC / 24 kHz / 单声道 / 约 48 kbps `.m4a`；单场上限 60 分钟自动停写；不足 3 秒的会话丢弃。
- 录音目录：`Application Support/SoundSense/Recordings/<audioID>.m4a`，与 `measurement_history.json` 同级。
- 历史上限 50 条；淘汰/删除/清空必须连带删录音文件；启动时清扫孤儿文件。
- 不引入第三方依赖；工程无 app 层测试 target，纯逻辑用 `scripts/logic_tests.sh`（swiftc 编译 + 断言）做 TDD，UI/接线用 `xcodebuild` + 手动清单验证。
- 每个任务一个中文 conventional 提交（风格对齐 `git log`：`feat:`/`fix:`/`docs:` 等）。
- 方案名：`SessionAudioRecorder`、`RecordingPlayer`、`ReportHTMLBuilder`，ID 号段：文件引用 `A2BB0000000000000000000C/0D/0E`，iOS 构建文件 `A1BB0000000000000000000C/0D/0E`，macOS 构建文件 `AABB0000000000000000000B/0C/0D`。

---

### Task 1: 数据模型 audioID 字段 + 历史存储接管录音文件生命周期

**Files:**
- Modify: `Shared/MeasurementRecorder.swift`（`MeasurementStats` 增字段）
- Modify: `Shared/MeasurementHistoryStore.swift`（整文件重写文件管理职责）
- Create: `Tests/logic/main.swift`（swiftc 断言测试）
- Create: `scripts/logic_tests.sh`

**Interfaces:**
- Consumes: 现有 `MeasurementStats`、`MeasurementHistoryStore` API。
- Produces（后续任务依赖的精确签名）:
  - `MeasurementStats.audioID: String?`（`public var`，init 末尾默认参数 `audioID: String? = nil`）
  - `MeasurementHistoryStore.recordingsDirectory: URL`（实例只读属性）
  - `MeasurementHistoryStore.audioFileURL(forID: String) -> URL`
  - `MeasurementHistoryStore.maxRecords: Int`（`public static let` = 50）
  - `delete(at:)`/`removeAll()`/`add(_:)`/`init(fileURL:)` 签名不变（watch/iOS/macOS 调用方零改动）

- [ ] **Step 1: 建测试骨架并写失败测试**

`scripts/logic_tests.sh`（可执行）：

```bash
#!/bin/bash
# 纯逻辑测试:swiftc 直接编译 Shared 源文件 + 断言 main,不依赖 Xcode 测试 target。
set -e
cd "$(dirname "$0")/.."
mkdir -p .build/logic
swiftc -O \
  -framework Foundation -framework Combine \
  Shared/MeasurementRecorder.swift \
  Shared/MeasurementHistoryStore.swift \
  Tests/logic/main.swift \
  -o .build/logic/logic_tests
.build/logic/logic_tests
echo "ALL LOGIC TESTS PASSED"
```

`Tests/logic/main.swift`：

```swift
//
//  main.swift
//  纯逻辑断言测试(与 Xcode 工程无关,swiftc 直跑)
//
import Foundation

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
    try? Data("fake").write(to: url)
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
    expect(FileManager.default.fileExists(atPath: ref.path), "被引用的录音保留")
    expect(!FileManager.default.fileExists(atPath: orphan.path), "孤儿录音被清扫")
}

if failures > 0 { print("\(failures) FAILURES"); exit(1) }
```

- [ ] **Step 2: 跑测试确认失败**

```bash
chmod +x scripts/logic_tests.sh && ./scripts/logic_tests.sh
```
预期：编译错误 `extra argument 'audioID' in call`（字段还不存在），或 `recordingsDirectory` 不存在。

- [ ] **Step 3: 实现**

`Shared/MeasurementRecorder.swift` — `MeasurementStats` 改动（只列 diff 语义，两处）：

```swift
public struct MeasurementStats: Codable, Equatable, Identifiable {
    public var id: TimeInterval { startTime.timeIntervalSince1970 }
    public let startTime: Date
    public let endTime: Date
    public let duration: TimeInterval
    public let avgSPL: Float
    public let laeqSPL: Float
    public let peakSPL: Float
    public let minSPL: Float
    public let overLimitTotal: TimeInterval
    public let samples: [ReportSample]
    /// 关联录音文件名主干(Recordings/<audioID>.m4a);旧记录/无录音为 nil
    public var audioID: String?

    public init(startTime: Date, endTime: Date, duration: TimeInterval,
                avgSPL: Float, laeqSPL: Float, peakSPL: Float, minSPL: Float,
                overLimitTotal: TimeInterval, samples: [ReportSample],
                audioID: String? = nil) {
        // ...原赋值不变...
        self.audioID = audioID
    }
}
```
（`var audioID` 供 ViewModel 在 stop 时回填；默认参数保证 watch 与现有调用零改动。）

`Shared/MeasurementHistoryStore.swift` — 删掉 `records.remove(atOffsets:)`（SwiftUI 扩展，会让 swiftc 直编失败），接管录音文件生命周期，完整新实现：

```swift
//
//  MeasurementHistoryStore.swift
//  SoundSense
//
//  测量历史持久化:JSON 记录 + 关联录音文件生命周期管理。
//  录音存 Application Support/SoundSense/Recordings/<audioID>.m4a。
//  删除/清空/淘汰/启动清扫四条路径都不留孤儿文件。
//

import Foundation

public final class MeasurementHistoryStore: ObservableObject {

    public static let shared = MeasurementHistoryStore()

    /// 最多保留的历史条数
    public static let maxRecords = 50

    @Published public private(set) var records: [MeasurementStats] = []

    private let fileURL: URL
    /// 录音目录(与 JSON 同级);注入自定义 fileURL 的测试 likewise 隔离
    public let recordingsDirectory: URL

    public init(fileURL: URL? = nil) {
        if let url = fileURL {
            self.fileURL = url
        } else {
            let dir = FileManager.default.urls(for: .applicationSupportDirectory,
                                               in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory
            let appDir = dir.appendingPathComponent("SoundSense", isDirectory: true)
            try? FileManager.default.createDirectory(at: appDir, withIntermediateDirectories: true)
            self.fileURL = appDir.appendingPathComponent("measurement_history.json")
        }
        recordingsDirectory = self.fileURL.deletingLastPathComponent()
            .appendingPathComponent("Recordings", isDirectory: true)
        try? FileManager.default.createDirectory(at: recordingsDirectory,
                                                 withIntermediateDirectories: true)
        load()
    }

    // MARK: - 录音文件路径

    /// audioID → 录音文件路径(不检查存在性)
    public func audioFileURL(forID id: String) -> URL {
        recordingsDirectory.appendingPathComponent("\(id).m4a")
    }

    // MARK: - 增删

    public func add(_ stats: MeasurementStats) {
        records.insert(stats, at: 0)
        if records.count > Self.maxRecords {
            let evicted = records[Self.maxRecords...]
            let ids = evicted.compactMap { $0.audioID }
            records.removeSubrange(Self.maxRecords...)
            deleteAudioFiles(ids: ids)
        }
        save()
    }

    public func delete(at offsets: IndexSet) {
        let removable = offsets.filter { $0 >= 0 && $0 < records.count }
        guard !removable.isEmpty else { return }
        let ids = removable.map { records[$0].audioID }
        for index in removable.sorted(by: >) {
            records.remove(at: index)
        }
        deleteAudioFiles(ids: ids.compactMap { $0 })
        save()
    }

    public func removeAll() {
        records.removeAll()
        deleteAllAudioFiles()
        save()
    }

    // MARK: - 录音文件清理

    /// 删除指定 id 的录音文件(尽力删,失败不阻断)
    private func deleteAudioFiles(ids: [String]) {
        for id in ids {
            try? FileManager.default.removeItem(at: audioFileURL(forID: id))
        }
    }

    /// 清空目录内全部 m4a
    private func deleteAllAudioFiles() {
        sweepOrphans(keeping: [])
    }

    /// 孤儿清扫:目录里凡不被 keeping 引用的 m4a 一律删除(覆盖崩溃残留)
    private func sweepOrphans(keeping: Set<String>) {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: recordingsDirectory, includingPropertiesForKeys: nil) else { return }
        for url in contents where url.pathExtension.lowercased() == "m4a" {
            if !keeping.contains(url.deletingPathExtension().lastPathComponent) {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    // MARK: - 持久化

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        if let decoded = try? JSONDecoder().decode([MeasurementStats].self, from: data) {
            records = decoded
        }
        sweepOrphans(keeping: Set(records.compactMap { $0.audioID }))
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(records) else { return }
        try? data.write(to: fileURL, options: [.atomic])
    }
}
```

- [ ] **Step 4: 跑测试确认通过**

```bash
./scripts/logic_tests.sh
```
预期：`ALL LOGIC TESTS PASSED`（6 组断言全绿）。

- [ ] **Step 5: 提交**

```bash
git add Shared/MeasurementRecorder.swift Shared/MeasurementHistoryStore.swift Tests/logic/main.swift scripts/logic_tests.sh
git commit -m "feat: 历史记录关联录音文件生命周期(增删/清空/淘汰/孤儿清扫)"
```

---

### Task 2: SessionAudioRecorder 录音器

**Files:**
- Create: `Shared/SessionAudioRecorder.swift`
- Modify: `Tests/logic/main.swift`、`scripts/logic_tests.sh`

**Interfaces:**
- Consumes: 无（独立组件）。
- Produces:
  - `SessionAudioRecorder`：`startSession(directory: URL, inputSampleRate: Float) -> String?`（@discardableResult，返回 audioID）、`append(_ samples: [Float])`、`finishSession(keep: Bool) -> URL?`（@discardableResult）、`isActive: Bool`（getter，队列同步读）；可注入 `maxDuration: TimeInterval`（默认 3600）、`minKeepDuration: TimeInterval`（默认 3）、`targetSampleRate: Float = 24000`。
  - 文件内 `FIRDecimator`（internal struct，测试可直接用）。

- [ ] **Step 1: 写失败测试（追加到 main.swift 末尾 `if failures` 之前）**

`scripts/logic_tests.sh` 文件列表追加 `Shared/SessionAudioRecorder.swift \`（在 MeasurementHistoryStore 之后）。

```swift
// ---- 7. FIR 降采样:任意分块下输出数量正确、正弦幅度保持 ----
do {
    var dec = FIRDecimator(taps: SessionAudioRecorder.makeTaps(count: 33, cutoffRatio: 0.225),
                           factor: 2)
    let rate: Float = 48000, freq: Float = 1000
    var out: [Float] = []
    var totalIn = 0
    for chunkSize in [7, 13, 1024, 4096, 3] {   // 刁钻分块验证跨块衔接
        let chunk = (0..<chunkSize).map { Float($0 + totalIn)
            .map { sin(2 * .pi * freq * $0 / rate) } }
        out.append(contentsOf: dec.process(chunk))
        totalIn += chunkSize
    }
    expect(abs(out.count - totalIn / 2) <= 1, "降采样输出数 ≈ 输入/2 (得 \(out.count)/\(totalIn))")
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
    expect(try! FileManager.default.contentsOfDirectory(atPath: dir.path).isEmpty, "丢弃后目录为空")

    _ = rec.startSession(directory: dir, inputSampleRate: 48000)
    rec.append(Array(repeating: 0.3, count: 48000 * 5))
    expect(rec.finishSession(keep: false) == nil, "keep=false 丢弃")
    expect(try! FileManager.default.contentsOfDirectory(atPath: dir.path).isEmpty, "丢弃后目录为空")
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
```

注意：这些测试段需要 `import AVFoundation`（main.swift 顶部与 Foundation 并列）。测试 8/10 为同步语义：`finishSession` 是 `queue.sync`，先排空 `append` 的异步块。

- [ ] **Step 2: 跑测试确认失败**

```bash
./scripts/logic_tests.sh
```
预期：编译错误 `cannot find 'FIRDecimator'` / `'SessionAudioRecorder'`。

- [ ] **Step 3: 实现 `Shared/SessionAudioRecorder.swift`**

```swift
//
//  SessionAudioRecorder.swift
//  SoundSense
//
//  检测同步录音器:把 AudioMeterEngine tap 送来的 PCM 分块写成 AAC m4a。
//  仅 iOS / macOS 编译(watchOS 不录音)。
//
//  管线:输入(设备速率 Float32 单声道)→ FIR 低通 → 整数倍降采样(48k→24k)
//        → AVAudioFile(.m4a / AAC / 48kbps)。全程私有串行队列,写失败自动停用,
//        测量主流程不受影响。到 maxDuration 停写保文件;不足 minKeepDuration 丢弃。
//

#if os(iOS) || os(macOS)

import Foundation
import AVFoundation

/// FIR 低通 + 整数倍抽取(跨块连续,输出点为输入绝对位置 factor-1, 2·factor-1, …)
struct FIRDecimator {
    let taps: [Float]
    let factor: Int
    private var stream: [Float] = []   // 从 nextEnd-(n-1) 起的输入样本
    private var basePos = 0            // stream[0] 的绝对样本位置
    private var nextEnd: Int           // 下一个输出窗口末端的绝对位置

    init(taps: [Float], factor: Int) {
        self.taps = taps
        self.factor = max(1, factor)
        nextEnd = taps.count - 1
    }

    mutating func process(_ input: [Float]) -> [Float] {
        guard !input.isEmpty else { return [] }
        stream.append(contentsOf: input)
        let n = taps.count
        var out: [Float] = []
        out.reserveCapacity(input.count / factor + 1)
        while nextEnd < basePos + stream.count {
            let e = nextEnd - basePos
            var acc: Float = 0
            for j in 0..<n {
                let idx = e - j
                if idx >= 0 { acc += stream[idx] * taps[n - 1 - j] }
            }
            out.append(acc)
            nextEnd += factor
        }
        let keepFrom = max(0, nextEnd - (n - 1) - basePos)
        if keepFrom > 0 {
            stream.removeFirst(keepFrom)
            basePos += keepFrom
        }
        return out
    }
}

public final class SessionAudioRecorder: @unchecked Sendable {

    /// 单场录音时长上限(秒),到点停写保文件,测量继续
    public var maxDuration: TimeInterval = 3600
    /// 低于此时长(秒)的会话在结束时丢弃
    public var minKeepDuration: TimeInterval = 3
    /// 目标采样率(Hz)
    public let targetSampleRate: Float = 24000

    private let queue = DispatchQueue(label: "com.dinghao.soundsense.sessionRecorder")
    private var file: AVAudioFile?
    private var fileURL: URL?
    private var decimator: FIRDecimator?
    private var writtenFrames = 0
    private var stopped = true   // 未开始 / 已结束 / 已失败 / 已到上限

    /// 开始一次会话。返回 audioID(文件名主干);失败返回 nil(录音停用)。
    @discardableResult
    public func startSession(directory: URL, inputSampleRate: Float) -> String? {
        queue.sync {
            _ = finishLocked(keep: false)   // 异常残留先清
            guard inputSampleRate > 0 else { return nil }
            try? FileManager.default.createDirectory(at: directory,
                                                     withIntermediateDirectories: true)
            let id = UUID().uuidString
            let url = directory.appendingPathComponent("\(id).m4a")
            let base: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: Double(targetSampleRate),
                AVNumberOfChannelsKey: 1,
            ]
            let withBitrate = base + [AVEncoderBitRateKey: 48000]
            let withQuality = base + [AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue]
            if let f = try? AVAudioFile(forWriting: url, settings: withBitrate) {
                file = f
            } else if let f = try? AVAudioFile(forWriting: url, settings: withQuality) {
                file = f
            } else {
                return nil
            }
            fileURL = url
            let factor = Int(inputSampleRate / targetSampleRate)
            if Float(factor) * targetSampleRate == inputSampleRate && factor > 1 {
                decimator = FIRDecimator(taps: Self.makeTaps(count: 33,
                                                             cutoffRatio: 0.45 / Float(factor)),
                                         factor: factor)
            } else {
                decimator = nil   // 速率不整除:原速率直写(AAC 编码器自适配)
            }
            writtenFrames = 0
            stopped = false
            return id
        }
    }

    /// 追加样本(音频线程直调,内部转队列;全零/空块忽略)
    public func append(_ samples: [Float]) {
        guard !samples.isEmpty, !stopped else { return }
        queue.async { [weak self] in
            guard let self = self else { return }
            self.writeLocked(samples)
        }
    }

    /// 结束会话:keep 且时长达标返回文件 URL,否则删文件返回 nil。
    @discardableResult
    public func finishSession(keep: Bool) -> URL? {
        queue.sync { finishLocked(keep: keep) }
    }

    /// 是否有进行中的会话(UI 的"录音中"红点用)
    public var isActive: Bool {
        queue.sync { !stopped }
    }

    // MARK: - 队列内实现

    private func writeLocked(_ samples: [Float]) {
        guard !stopped, let file = file else { return }
        let out = decimator?.process(samples) ?? samples
        guard !out.isEmpty,
              let buffer = Self.pcmBuffer(samples: out, format: file.processingFormat) else { return }
        do {
            try file.write(from: buffer)
            writtenFrames += out.count
            if durationLocked >= maxDuration { stopped = true }
        } catch {
            stopped = true   // 磁盘满等:停用录音,不影响测量
        }
    }

    private func finishLocked(keep: Bool) -> URL? {
        defer {
            file = nil
            fileURL = nil
            decimator = nil
            stopped = true
        }
        guard let url = fileURL else { return nil }
        if !keep || durationLocked < minKeepDuration {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        return url
    }

    private var durationLocked: TimeInterval {
        TimeInterval(writtenFrames) / TimeInterval(targetSampleRate)
    }

    /// Hamming 窗 sinc 低通系数(cutoffRatio = fc / 输入速率,归一化增益 1)
    static func makeTaps(count: Int, cutoffRatio: Float) -> [Float] {
        let m = count - 1
        var taps = (0..<count).map { i -> Float in
            let k = Float(i) - Float(m) / 2
            let sinc = abs(k) < 1e-6
                ? 2 * Float.pi * cutoffRatio
                : sin(2 * Float.pi * cutoffRatio * k) / k
            let window = 0.54 - 0.46 * cos(2 * Float.pi * Float(i) / Float(m))
            return sinc * window
        }
        let sum = taps.reduce(0, +)
        if sum != 0 { for i in taps.indices { taps[i] /= sum } }
        return taps
    }

    private static func pcmBuffer(samples: [Float], format: AVAudioFormat) -> AVAudioPCMBuffer? {
        guard samples.count <= Int(AVAudioFrameCount.max),
              let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                            frameCapacity: AVAudioFrameCount(samples.count))
        else { return nil }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        if let dst = buffer.floatChannelData?[0] {
            samples.withUnsafeBufferPointer { src in
                dst.update(from: src.baseAddress!, count: samples.count)
            }
        }
        return buffer
    }
}

#endif
```

注：`append` 里读 `stopped` 在队列外 —— 该 Bool 只会 false→true 单向翻转，音频线程读到旧值 false 只会多排一个空转块，`writeLocked` 会再校验，无竞态风险。

- [ ] **Step 4: 跑测试确认通过**

```bash
./scripts/logic_tests.sh
```
预期：全部通过（含新增 4 组）。若 AAC 码率 48k 在本机被拒，代码已内建 quality 回退，不应失败；若仍失败，检查 `AVAudioFile` 错误并调整 fallback 设置。

- [ ] **Step 5: 提交**

```bash
git add Shared/SessionAudioRecorder.swift Tests/logic/main.swift scripts/logic_tests.sh
git commit -m "feat: 检测同步录音器(FIR 降采样 + AAC m4a,上限截断/短会话丢弃)"
```

---

### Task 3: RecordingPlayer 播放组件

**Files:**
- Create: `Shared/RecordingPlayer.swift`
- Modify: `scripts/logic_tests.sh`（编译清单加入，跑编译性验证）

**Interfaces:**
- Consumes: 无。
- Produces: `@MainActor public final class RecordingPlayer: NSObject, ObservableObject`，成员：`@Published isPlaying/progress/duration/isAvailable`（均 `private(set)`）、`load(url: URL)`、`togglePlayPause()`、`stop()`、`static func formatTime(_ t: TimeInterval) -> String`（`m:ss`）。UI 条件：`record.audioID != nil` 时显示播放条；`!isAvailable` 时显示"录音不可用"。

- [ ] **Step 1: 实现（纯组件无断言可写，编译通过即本任务测试；行为靠 Task 9 手动清单）**

`scripts/logic_tests.sh` 编译清单加 `Shared/RecordingPlayer.swift \`。

```swift
//
//  RecordingPlayer.swift
//  SoundSense
//
//  录音回放:AVAudioPlayer 的 ObservableObject 封装,历史详情页共用(iOS/macOS)。
//  文件缺失/损坏 → isAvailable=false,UI 降级为"录音不可用"。
//

#if os(iOS) || os(macOS)

import AVFoundation
import Combine

@MainActor
public final class RecordingPlayer: NSObject, ObservableObject {

    @Published public private(set) var isPlaying = false
    /// 0...1
    @Published public private(set) var progress: Double = 0
    @Published public private(set) var duration: TimeInterval = 0
    @Published public private(set) var isAvailable = false

    private var player: AVAudioPlayer?
    private var timer: Timer?

    public func load(url: URL) {
        stop()
        if let p = try? AVAudioPlayer(contentsOf: url) {
            player = p
            duration = p.duration
            isAvailable = p.duration > 0
        } else {
            player = nil
            duration = 0
            isAvailable = false
        }
    }

    public func togglePlayPause() {
        guard let p = player, isAvailable else { return }
        if p.isPlaying {
            p.pause()
            isPlaying = false
        } else {
            #if os(iOS)
            // 测量会话已停用;回放前切到 playback,避免听筒小声
            try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
            try? AVAudioSession.sharedInstance().setActive(true)
            #endif
            p.play()
            isPlaying = true
            startTimer()
        }
    }

    public func stop() {
        player?.stop()
        player?.currentTime = 0
        isPlaying = false
        progress = 0
        timer?.invalidate()
        timer = nil
    }

    private func startTimer() {
        timer?.invalidate()
        let t = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func tick() {
        guard let p = player, duration > 0 else { return }
        if p.isPlaying {
            progress = min(1, p.currentTime / duration)
        } else {   // 自然播完
            isPlaying = false
            progress = 0
            timer?.invalidate()
            timer = nil
        }
    }

    /// m:ss
    public static func formatTime(_ t: TimeInterval) -> String {
        let s = max(0, Int(t))
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

#endif
```

- [ ] **Step 2: 编译验证**

```bash
./scripts/logic_tests.sh
```
预期：编译通过、原断言全绿（RecordingPlayer 无运行时断言）。

- [ ] **Step 3: 提交**

```bash
git add Shared/RecordingPlayer.swift scripts/logic_tests.sh
git commit -m "feat: 录音回放组件 RecordingPlayer(播放/进度/优雅降级)"
```

---

### Task 4: ReportHTMLBuilder 单文件报告

**Files:**
- Create: `Shared/ReportHTMLBuilder.swift`
- Modify: `Tests/logic/main.swift`、`scripts/logic_tests.sh`

**Interfaces:**
- Consumes: `MeasurementStats`。
- Produces:
  - `ReportHTMLBuilder.build(stats: MeasurementStats, deviceName: String, calibrationOffset: Float, pngBase64: String, audioBase64: String?) -> String`（纯函数，Foundation only）
  - `ReportHTMLBuilder.filename(for stats: MeasurementStats) -> String`（`闻声报告_yyyy-MM-dd_HHmm.html`）

- [ ] **Step 1: 写失败测试（追加到 main.swift）**

`scripts/logic_tests.sh` 编译清单加 `Shared/ReportHTMLBuilder.swift \`。

```swift
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
```

- [ ] **Step 2: 跑测试确认失败**

```bash
./scripts/logic_tests.sh
```
预期：编译错误 `cannot find 'ReportHTMLBuilder'`。

- [ ] **Step 3: 实现 `Shared/ReportHTMLBuilder.swift`**

```swift
//
//  ReportHTMLBuilder.swift
//  SoundSense
//
//  HTML 单文件报告组装:报告 PNG + 录音 base64 内嵌,浏览器打开即可回放。
//  纯字符串模板(仅 Foundation),平台侧负责生成 PNG/读取录音后传 base64 进来。
//

#if os(iOS) || os(macOS)

import Foundation

public enum ReportHTMLBuilder {

    public static func build(stats: MeasurementStats,
                             deviceName: String,
                             calibrationOffset: Float,
                             pngBase64: String,
                             audioBase64: String?) -> String {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let range = "\(df.string(from: stats.startTime)) — \(df.string(from: stats.endTime))"
        let dur = RecordingPlayer.formatTime(stats.duration)

        let audioBlock: String
        if let audio = audioBase64 {
            audioBlock = """
            <section class="card">
              <h2>现场录音</h2>
              <audio controls preload="metadata" src="data:audio/mp4;base64,\(audio)"></audio>
            </section>
            """
        } else {
            audioBlock = ""
        }

        let row = { (_ v: String, _ label: String) in
            "<div class=\"stat\"><b>\(v)</b><span>\(label)</span></div>"
        }

        return """
        <!DOCTYPE html>
        <html lang="zh-CN">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>闻声 SoundSense 噪音测量报告</title>
        <style>
          :root { color-scheme: dark; }
          body { margin: 0; background: #0b1014; color: #fff;
                 font-family: -apple-system, "PingFang SC", "Helvetica Neue", sans-serif; }
          .wrap { max-width: 720px; margin: 0 auto; padding: 32px 20px 48px; }
          .brand { color: #3dd9bf; font-size: 13px; letter-spacing: 3px; font-weight: 700; }
          h1 { font-size: 26px; margin: 6px 0 4px; }
          .meta { color: rgba(255,255,255,.55); font-size: 13px; margin-bottom: 20px; }
          img.report { width: 100%; border-radius: 14px; display: block;
                       box-shadow: 0 8px 30px rgba(0,0,0,.45); }
          .card { background: rgba(255,255,255,.04); border: 1px solid rgba(255,255,255,.08);
                  border-radius: 14px; padding: 16px 18px; margin-top: 16px; }
          .card h2 { font-size: 14px; color: rgba(255,255,255,.6); margin: 0 0 10px; }
          .stats { display: flex; flex-wrap: wrap; gap: 8px; }
          .stat { flex: 1 1 100px; text-align: center; padding: 10px 4px;
                  background: rgba(255,255,255,.03); border-radius: 10px; }
          .stat b { font-size: 19px; display: block; color: #3dd9bf; }
          .stat span { font-size: 11px; color: rgba(255,255,255,.45); }
          audio { width: 100%; }
          footer { margin-top: 22px; color: rgba(255,255,255,.35); font-size: 12px;
                   border-top: 1px solid rgba(255,255,255,.08); padding-top: 12px;
                   line-height: 1.8; }
        </style>
        </head>
        <body>
        <div class="wrap">
          <div class="brand">SOUNDSENSE</div>
          <h1>噪音测量报告</h1>
          <div class="meta">\(range) · 时长 \(dur) · \(stats.samples.count) 个采样点</div>
          <img class="report" alt="测量报告" src="data:image/png;base64,\(pngBase64)">
          <section class="card">
            <h2>关键指标</h2>
            <div class="stats">
              \(row(String(format: "%.1f dB", stats.laeqSPL), "LAeq 等效声级"))
              \(row(String(format: "%.1f dB", stats.peakSPL), "峰值"))
              \(row(String(format: "%.1f dB", stats.avgSPL), "平均"))
              \(row(String(format: "%.1f dB", stats.minSPL), "最低"))
              \(row(String(format: "%.0f 秒", stats.overLimitTotal), "超 85dB 时长"))
            </div>
          </section>
          \(audioBlock)
          <footer>
            设备:\(escape(deviceName)) · 校准偏移:\(String(format: "%+.1f", calibrationOffset)) dB<br>
            IEC 61672-1 A 计权 · 4096 点 FFT · vDSP · 由闻声 SoundSense 生成
          </footer>
        </div>
        </body>
        </html>
        """
    }

    /// 默认文件名:闻声报告_2026-09-01_1430.html
    public static func filename(for stats: MeasurementStats) -> String {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd_HHmm"
        return "闻声报告_\(df.string(from: stats.startTime)).html"
    }

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}

#endif
```

注：模板引用 `RecordingPlayer.formatTime`（Task 3 产物，同编译清单）。

- [ ] **Step 4: 跑测试确认通过**

```bash
./scripts/logic_tests.sh
```
预期：全部通过。

- [ ] **Step 5: 提交**

```bash
git add Shared/ReportHTMLBuilder.swift Tests/logic/main.swift scripts/logic_tests.sh
git commit -m "feat: HTML 单文件报告组装器(图+录音 base64 内嵌)"
```

---

### Task 5: AudioMeterEngine 样本挂点

**Files:**
- Modify: `Shared/AudioMeterEngine.swift`

**Interfaces:**
- Consumes: 无（纯增量）。
- Produces:
  - `engine.setSampleSink(_ sink: (@Sendable ([Float]) -> Void)?)`（MainActor 公开方法）
  - `engine.activeSampleRate: Float`（`public private(set)`，tap 安装时更新，默认 48000）

- [ ] **Step 1: 实现（改动 4 处；本文件依赖 SoundSenseCore 模块与 SwiftUI，不入 logic harness，由 Task 6 的 xcodebuild 验证）**

1. 属性区（`private var tapInstalled = false` 之后）：

```swift
    /// 活跃输入采样率(tap 安装时确定;录音器据此设计降采样)
    public private(set) var activeSampleRate: Float = 48000
    /// 样本挂点:录音器等外部消费者由此收到与测量同源的 PCM 分块
    private let sinkBox = SampleSinkBox()
```

2. `stop()` 里 `worker?.reset()` 之前加一行（防极端时序下 sink 残留）：

```swift
        sinkBox.set(nil)
```

3. 公开方法（`// MARK: - 内部实现` 之前）：

```swift
    /// 设置/清除样本挂点(线程安全;tap 在音频线程每帧调用)
    public func setSampleSink(_ sink: (@Sendable ([Float]) -> Void)?) {
        sinkBox.set(sink)
    }
```

4. `installTapIfNeeded()` 里：`worker?.updateSampleRate(sampleRate)` 之后加 `activeSampleRate = sampleRate`；tap 闭包 `let samples = Array(...)` 之后、`self.worker?.enqueue(samples)` 之前加：

```swift
            self.sinkBox.deliver(samples)
```

5. 文件末尾（class 外）：

```swift
// MARK: - 线程安全的样本挂点盒子(音频线程读,主线程写)

private final class SampleSinkBox: @unchecked Sendable {
    private let lock = NSLock()
    private var sink: (@Sendable ([Float]) -> Void)?

    func set(_ s: (@Sendable ([Float]) -> Void)?) {
        lock.lock(); sink = s; lock.unlock()
    }

    func deliver(_ samples: [Float]) {
        lock.lock(); let s = sink; lock.unlock()
        s?(samples)
    }
}
```

- [ ] **Step 2: 语法冒烟检查（`-parse` 不做类型检查、不解析 import；完整编译在 Task 6）**

```bash
xcrun swiftc -parse Shared/AudioMeterEngine.swift 2>&1 | head -5
```
预期：无输出（无语法错误）。

- [ ] **Step 3: 提交**

```bash
git add Shared/AudioMeterEngine.swift
git commit -m "feat: 引擎暴露线程安全样本挂点与活跃采样率"
```

---

### Task 6: 注册新文件到 Xcode 工程（iOS + macOS，不含 watch）

**Files:**
- Modify: `SoundSense.xcodeproj/project.pbxproj`

**Interfaces:**
- Consumes: Task 2/3/4 产物文件。
- Produces: 三个新 Shared 文件参与 iOS/macOS target 编译。

- [ ] **Step 1: 编辑 pbxproj（5 处，先 Read 再 Edit，锚点用注释行文本而非行号）**

① PBXBuildFile 段（`A1BB0000000000000000000B` 条目之后）：

```
		A1BB0000000000000000000C /* SessionAudioRecorder.swift in Sources */ = {isa = PBXBuildFile; fileRef = A2BB0000000000000000000C /* SessionAudioRecorder.swift */; };
		A1BB0000000000000000000D /* RecordingPlayer.swift in Sources */ = {isa = PBXBuildFile; fileRef = A2BB0000000000000000000D /* RecordingPlayer.swift */; };
		A1BB0000000000000000000E /* ReportHTMLBuilder.swift in Sources */ = {isa = PBXBuildFile; fileRef = A2BB0000000000000000000E /* ReportHTMLBuilder.swift */; };
		AABB0000000000000000000B /* SessionAudioRecorder.swift in Sources */ = {isa = PBXBuildFile; fileRef = A2BB0000000000000000000C /* SessionAudioRecorder.swift */; };
		AABB0000000000000000000C /* RecordingPlayer.swift in Sources */ = {isa = PBXBuildFile; fileRef = A2BB0000000000000000000D /* RecordingPlayer.swift */; };
		AABB0000000000000000000D /* ReportHTMLBuilder.swift in Sources */ = {isa = PBXBuildFile; fileRef = A2BB0000000000000000000E /* ReportHTMLBuilder.swift */; };
```

② PBXFileReference 段（`A2BB0000000000000000000B` 条目之后）：

```
		A2BB0000000000000000000C /* SessionAudioRecorder.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = SessionAudioRecorder.swift; sourceTree = "<group>"; };
		A2BB0000000000000000000D /* RecordingPlayer.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = RecordingPlayer.swift; sourceTree = "<group>"; };
		A2BB0000000000000000000E /* ReportHTMLBuilder.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = ReportHTMLBuilder.swift; sourceTree = "<group>"; };
```

③ Shared group children（`A2BB0000000000000000000B /* NoiseAlertNotifier.swift */` 行之后）：

```
				A2BB0000000000000000000C /* SessionAudioRecorder.swift */,
				A2BB0000000000000000000D /* RecordingPlayer.swift */,
				A2BB0000000000000000000E /* ReportHTMLBuilder.swift */,
```

④ iOS target Sources phase（`A1BB00000000000000000009 /* NoiseAlertNotifier.swift in Sources */` 行之后，该 phase 以 `A1BB` 前缀为特征）：

```
				A1BB0000000000000000000C /* SessionAudioRecorder.swift in Sources */,
				A1BB0000000000000000000D /* RecordingPlayer.swift in Sources */,
				A1BB0000000000000000000E /* ReportHTMLBuilder.swift in Sources */,
```

⑤ macOS target Sources phase（`AABB0000000000000000000A /* … in Sources */` 最后一行之后，该 phase 以 `AABB` 前缀为特征）：

```
				AABB0000000000000000000B /* SessionAudioRecorder.swift in Sources */,
				AABB0000000000000000000C /* RecordingPlayer.swift in Sources */,
				AABB0000000000000000000D /* ReportHTMLBuilder.swift in Sources */,
```

- [ ] **Step 2: 三 target 编译验证**

```bash
xcodebuild -project SoundSense.xcodeproj -scheme SoundSenseMac -configuration Debug build 2>&1 | tail -3
xcodebuild -project SoundSense.xcodeproj -scheme SoundSense -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build 2>&1 | tail -3
xcodebuild -project SoundSense.xcodeproj -scheme SoundSenseWatch -destination 'generic/platform=watchOS Simulator' CODE_SIGNING_ALLOWED=NO build 2>&1 | tail -3
```
预期：三个 `BUILD SUCCEEDED`（watch 端不编译新文件，验证无交叉污染）。

- [ ] **Step 3: 提交**

```bash
git add SoundSense.xcodeproj/project.pbxproj
git commit -m "chore: 新共享文件注册进 iOS/macOS target(录音/播放/HTML)"
```

---

### Task 7: iOS 接线（ViewModel + 历史详情页 + HTML 分享）

**Files:**
- Modify: `iOS/SoundSenseApp/ViewModels/MeterViewModel.swift`
- Modify: `iOS/SoundSenseApp/Views/HistoryView.swift`（详情页 + 播放条 + HTML 分享）
- Modify: `Shared/LiveStatsBar.swift`（"录音中"红点，macOS 同步受益）
- Modify: `iOS/SoundSenseApp/Views/MainMeterView.swift:100`（传入红点状态）

**Interfaces:**
- Consumes: `SessionAudioRecorder`（Task 2）、`engine.setSampleSink/activeSampleRate`（Task 5）、`RecordingPlayer`（Task 3）、`ReportHTMLBuilder`（Task 4）、`MeasurementHistoryStore.recordingsDirectory/audioFileURL(forID:)`（Task 1）。
- Produces: `HistoryDetailSheet`、`RecordingPlayerBar`、`HTMLShareSheet`（均 iOS target 内部）。

- [ ] **Step 1: MeterViewModel 接线**

属性区 `private let recorder: MeasurementRecorder` 之后加：

```swift
    /// 检测同步录音器(与测量同源样本写 AAC m4a)
    private let sessionRecorder = SessionAudioRecorder()
```

`currentSPL` 计算属性旁加（consume 的 15fps 刷新会带动 UI 更新红点）：

```swift
    /// 是否正在同步录音(测量中恒 true,除非录音器启动失败)
    var isRecording: Bool { sessionRecorder.isActive }
```

`start()` 中 `recorder.start()` 之后加：

```swift
        sessionRecorder.startSession(directory: historyStore.recordingsDirectory,
                                      inputSampleRate: engine.activeSampleRate)
        engine.setSampleSink { [weak sessionRecorder] samples in
            sessionRecorder?.append(samples)
        }
```

`stop()` 整体替换为：

```swift
    func stop() {
        engine.stop()
        engine.setSampleSink(nil)
        stopLiveTimer()
        if var stats = recorder.stop() {
            if let audioURL = sessionRecorder.finishSession(keep: true) {
                stats.audioID = audioURL.deletingPathExtension().lastPathComponent
            }
            lastStats = stats
            historyStore.add(stats)
            if healthEnabled {
                Task { await HealthWriter.save(stats: stats) }
            }
        } else {
            sessionRecorder.finishSession(keep: false)
        }
        liveStats = nil
        exposureWarning = false
        history.removeAll(keepingCapacity: true)
        noiseLevel = nil
    }
```

（顺序要点：`engine.stop()` 先摘 tap，`finishSession` 是 `queue.sync` 会排空残余 append 后再定稿。）

- [ ] **Step 2: HistoryView 改造**

状态区加 `@State private var selectedRecord: MeasurementStats?`；列表行 `onExport` 回调改为 `selectedRecord = record`；sheet 区追加：

```swift
        .sheet(item: $selectedRecord) { record in
            HistoryDetailSheet(record: record, store: store,
                               deviceName: deviceName,
                               calibrationOffset: calibrationOffset)
        }
```

contextMenu 首项前插入：

```swift
                        Button {
                            selectedRecord = record
                        } label: {
                            Label("查看详情与录音", systemImage: "waveform")
                        }
```

文件末尾追加三个新视图：

```swift
/// 历史详情:完整简报(报告图)+ 录音回放 + 双格式导出
struct HistoryDetailSheet: View {
    let record: MeasurementStats
    let store: MeasurementHistoryStore
    let deviceName: String
    let calibrationOffset: Float
    @Environment(\.dismiss) private var dismiss
    @StateObject private var player = RecordingPlayer()
    @State private var sharingPNG = false
    @State private var sharingHTML = false

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 14) {
                    Image(uiImage: ReportRenderer.render(stats: record,
                                                         deviceName: deviceName,
                                                         calibrationOffset: calibrationOffset))
                        .resizable().scaledToFit()
                        .cornerRadius(12)
                    if record.audioID != nil {
                        RecordingPlayerBar(player: player)
                    }
                    HStack(spacing: 12) {
                        Button {
                            sharingPNG = true
                        } label: {
                            Label("分享图片", systemImage: "photo")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(.white)
                                .frame(maxWidth: .infinity, minHeight: 38)
                                .background(RoundedRectangle(cornerRadius: 10)
                                    .fill(.white.opacity(0.08)))
                        }
                        .buttonStyle(.plain)
                        Button {
                            sharingHTML = true
                        } label: {
                            Label("分享完整报告", systemImage: "doc.richtext")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundColor(.white)
                                .frame(maxWidth: .infinity, minHeight: 38)
                                .background(RoundedRectangle(cornerRadius: 10)
                                    .fill(MeterTheme.waveColor.opacity(0.85)))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(16)
            }
            .background(MeterTheme.backgroundGradient.ignoresSafeArea())
            .navigationTitle("测量简报")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("完成") { dismiss() }
                        .foregroundColor(MeterTheme.waveColor)
                }
            }
            .onAppear {
                if let id = record.audioID {
                    player.load(url: store.audioFileURL(forID: id))
                }
            }
        }
        .navigationViewStyle(.stack)
        .sheet(isPresented: $sharingPNG) {
            ReportShareSheet(stats: record, deviceName: deviceName,
                             calibrationOffset: calibrationOffset)
        }
        .sheet(isPresented: $sharingHTML) {
            HTMLShareSheet(stats: record, deviceName: deviceName,
                           calibrationOffset: calibrationOffset,
                           audioURL: record.audioID.map { store.audioFileURL(forID: $0) })
        }
    }
}

/// 录音回放条(iOS 风格)
struct RecordingPlayerBar: View {
    @ObservedObject var player: RecordingPlayer

    var body: some View {
        HStack(spacing: 12) {
            Button {
                player.togglePlayPause()
            } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(player.isAvailable ? MeterTheme.waveColor : .white.opacity(0.3))
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(MeterTheme.waveColor.opacity(0.14)))
            }
            .buttonStyle(.plain)
            .disabled(!player.isAvailable)
            VStack(alignment: .leading, spacing: 3) {
                Text("现场录音").font(.system(size: 12)).foregroundColor(.white.opacity(0.7))
                if player.isAvailable {
                    Text("\(RecordingPlayer.formatTime(player.progress * player.duration)) / \(RecordingPlayer.formatTime(player.duration))")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(MeterTheme.secondaryText)
                } else {
                    Text("录音不可用").font(.system(size: 10))
                        .foregroundColor(MeterTheme.secondaryText)
                }
            }
            Spacer()
            ProgressView(value: player.progress)
                .progressViewStyle(.linear)
                .tint(MeterTheme.waveColor)
                .frame(width: 90)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(MeterTheme.cardBackground))
    }
}

/// HTML 完整报告分享(临时文件 + ActivityViewController)
struct HTMLShareSheet: UIViewControllerRepresentable {
    let stats: MeasurementStats
    let deviceName: String
    let calibrationOffset: Float
    let audioURL: URL?

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let image = ReportRenderer.render(stats: stats, deviceName: deviceName,
                                          calibrationOffset: calibrationOffset)
        let pngBase64 = (image.pngData() ?? Data()).base64EncodedString()
        let audioBase64 = (try? Data(contentsOf: audioURL))?.base64EncodedString()
        let html = ReportHTMLBuilder.build(stats: stats, deviceName: deviceName,
                                           calibrationOffset: calibrationOffset,
                                           pngBase64: pngBase64, audioBase64: audioBase64)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(ReportHTMLBuilder.filename(for: stats))
        try? html.data(using: .utf8)?.write(to: url, options: [.atomic])
        return UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }

    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}
```

- [ ] **Step 3: "录音中"红点（LiveStatsBar + 主界面传参）**

`Shared/LiveStatsBar.swift`：`stats` 属性后加 `public var isRecording: Bool = false`，`init` 加默认参数 `isRecording: Bool = false`；`body` 的 HStack 里"时长"一项的 label 改为条件文字——`statItem(value: formatDuration(stats.duration), label: "时长")` 替换为：

```swift
            statItem(value: formatDuration(stats.duration), label: isRecording ? "时长 · 录音中" : "时长")
```

时长数值右上角叠红点：`statItem` 的 `value` 文字改为 `HStack(alignment: .top, spacing: 4) { Text(value)...; if isRecording { Circle().fill(Color.red).frame(width: 6, height: 6) } }`——具体做法（保持字号/字体不变，仅在 `isRecording` 时于数值右侧加 6pt 红点）：

```swift
    private func statItem(value: String, label: String) -> some View {
        VStack(spacing: 3) {
            HStack(alignment: .top, spacing: 4) {
                Text(value)
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                    .foregroundColor(.white)
                    .monospacedDigit()
                if isRecording {
                    Circle().fill(Color(red: 1.0, green: 0.27, blue: 0.24))
                        .frame(width: 6, height: 6)
                        .padding(.top, 3)
                }
            }
            Text(label)
                .font(.system(size: 10))
                .foregroundColor(.white.opacity(0.45))
        }
        .frame(maxWidth: .infinity)
    }
```

`iOS/SoundSenseApp/Views/MainMeterView.swift:100` 调用处改为：

```swift
                            LiveStatsBar(stats: live, isRecording: vm.isRecording)
```

（`vm` 按该文件实际变量名对齐；macOS 调用在 Task 8 改。）

- [ ] **Step 4: 编译验证**

```bash
xcodebuild -project SoundSense.xcodeproj -scheme SoundSense -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build 2>&1 | tail -3
```
预期：`BUILD SUCCEEDED`。

- [ ] **Step 5: 提交**

```bash
git add iOS/SoundSenseApp/ViewModels/MeterViewModel.swift iOS/SoundSenseApp/Views/HistoryView.swift Shared/LiveStatsBar.swift iOS/SoundSenseApp/Views/MainMeterView.swift
git commit -m "feat: iOS 检测同步录音 + 历史详情(简报/回放/HTML 分享)"
```

---

### Task 8: macOS 接线（ViewModel + 详情面板 + HTML 保存）

**Files:**
- Modify: `macOS/SoundSenseMacApp/MeterViewModel.swift`
- Modify: `macOS/SoundSenseMacApp/Views/HistoryOverlayView.swift`
- Modify: `macOS/SoundSenseMacApp/Views/ReportExporter.swift`
- Modify: `macOS/SoundSenseMacApp/Views/MacMainMeterView.swift:44`（红点传参）

**Interfaces:**
- Consumes: 同 Task 7 的共享组件。
- Produces: `ReportExporter.exportHTML(stats:deviceName:calibrationOffset:audioURL:)`、`ReportExporter.pngData(from:)`、`MacRecordingPlayerBar`。

- [ ] **Step 1: MeterViewModel 接线（与 iOS 同构，无 health 分支）**

属性区加 `private let sessionRecorder = SessionAudioRecorder()`（注释同 iOS）与计算属性（同 iOS）：

```swift
    /// 是否正在同步录音(测量中恒 true,除非录音器启动失败)
    var isRecording: Bool { sessionRecorder.isActive }
```

`start()` 中 `recorder.start()` 之后加与 iOS 相同的 `startSession` + `setSampleSink` 段；`stop()` 替换为：

```swift
    func stop() {
        engine.stop()
        engine.setSampleSink(nil)
        stopLiveTimer()
        if var stats = recorder.stop() {
            if let audioURL = sessionRecorder.finishSession(keep: true) {
                stats.audioID = audioURL.deletingPathExtension().lastPathComponent
            }
            lastStats = stats
            historyStore.add(stats)
        } else {
            sessionRecorder.finishSession(keep: false)
        }
        liveStats = nil
        exposureWarning = false
        history.removeAll(keepingCapacity: true)
        noiseLevel = nil
    }
```

- [ ] **Step 2: ReportExporter 抽 PNG 助手 + HTML 导出**

文件头加 `import UniformTypeIdentifiers`。`export(...)` 中 tiff→png 段抽出为：

```swift
    /// NSImage → PNG 数据
    static func pngData(from image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }
```

（`export` 改调 `pngData(from:)`。）追加：

```swift
    /// 导出 HTML 单文件报告(报告图 + 录音内嵌)
    static func exportHTML(stats: MeasurementStats,
                           deviceName: String,
                           calibrationOffset: Float,
                           audioURL: URL?) {
        let image = ReportRenderer.render(stats: stats, deviceName: deviceName,
                                          calibrationOffset: calibrationOffset)
        let pngBase64 = (pngData(from: image) ?? Data()).base64EncodedString()
        let audioBase64 = (try? Data(contentsOf: audioURL))?.base64EncodedString()
        let html = ReportHTMLBuilder.build(stats: stats, deviceName: deviceName,
                                           calibrationOffset: calibrationOffset,
                                           pngBase64: pngBase64, audioBase64: audioBase64)
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.html]
        panel.nameFieldStringValue = ReportHTMLBuilder.filename(for: stats)
        panel.title = "导出完整报告"
        if panel.runModal() == .OK, let url = panel.url {
            do {
                try html.data(using: .utf8)?.write(to: url)
            } catch {
                let alert = NSAlert()
                alert.messageText = "导出失败"
                alert.informativeText = error.localizedDescription
                alert.runModal()
            }
        }
    }
```

- [ ] **Step 3: HistoryOverlayView 升级详情面板**

`.sheet(item: $sharingStats)` 调用处传入 `store: store`；`MacReportPreviewSheet` 整体替换为：

```swift
/// 历史详情:报告图预览 + 录音回放 + 导出
struct MacReportPreviewSheet: View {
    let stats: MeasurementStats
    let store: MeasurementHistoryStore
    let deviceName: String
    let calibrationOffset: Float
    @Environment(\.dismiss) private var dismiss
    @StateObject private var player = RecordingPlayer()

    private static let df: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm"
        return f
    }()

    var body: some View {
        VStack(spacing: 14) {
            Text("测量简报")
                .font(.system(size: 14, weight: .bold)).foregroundColor(.white)
            Text("\(Self.df.string(from: stats.startTime)) · 时长 \(RecordingPlayer.formatTime(stats.duration))")
                .font(.system(size: 11)).foregroundColor(.white.opacity(0.5))

            ScrollView(showsIndicators: false) {
                Image(nsImage: ReportRenderer.render(stats: stats, deviceName: deviceName,
                                                     calibrationOffset: calibrationOffset))
                    .resizable().scaledToFit()
                    .cornerRadius(8)
                    .padding(.horizontal, 4)
            }
            .frame(height: 330)

            if stats.audioID != nil {
                MacRecordingPlayerBar(player: player)
            }

            HStack(spacing: 10) {
                Button {
                    dismiss()
                } label: {
                    Text("取消")
                        .font(.system(size: 12, weight: .medium)).foregroundColor(.white.opacity(0.7))
                        .frame(width: 74, height: 30)
                        .background(RoundedRectangle(cornerRadius: 8).fill(.white.opacity(0.08)))
                }
                .buttonStyle(.plain)
                Button {
                    ReportExporter.export(stats: stats, deviceName: deviceName,
                                           calibrationOffset: calibrationOffset)
                } label: {
                    Text("导出 PNG")
                        .font(.system(size: 12, weight: .medium)).foregroundColor(.white)
                        .frame(width: 92, height: 30)
                        .background(RoundedRectangle(cornerRadius: 8).fill(.white.opacity(0.12)))
                }
                .buttonStyle(.plain)
                Button {
                    ReportExporter.exportHTML(stats: stats, deviceName: deviceName,
                                              calibrationOffset: calibrationOffset,
                                              audioURL: stats.audioID.map { store.audioFileURL(forID: $0) })
                    dismiss()
                } label: {
                    Text("导出完整报告")
                        .font(.system(size: 12, weight: .semibold)).foregroundColor(.white)
                        .frame(width: 110, height: 30)
                        .background(RoundedRectangle(cornerRadius: 8)
                            .fill(Color(red: 0.24, green: 0.83, blue: 0.69).opacity(0.85)))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(20)
        .frame(width: 400)
        .background(RoundedRectangle(cornerRadius: 16).fill(MeterTheme.panel))
        .onAppear {
            if let id = stats.audioID {
                player.load(url: store.audioFileURL(forID: id))
            }
        }
    }
}

/// 录音回放条(macOS 风格)
struct MacRecordingPlayerBar: View {
    @ObservedObject var player: RecordingPlayer

    var body: some View {
        HStack(spacing: 10) {
            Button {
                player.togglePlayPause()
            } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(player.isAvailable ? Color(red: 0.24, green: 0.83, blue: 0.69) : .white.opacity(0.3))
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(Color(red: 0.24, green: 0.83, blue: 0.69).opacity(0.14)))
            }
            .buttonStyle(.plain)
            .disabled(!player.isAvailable)
            VStack(alignment: .leading, spacing: 2) {
                Text("现场录音").font(.system(size: 11)).foregroundColor(.white.opacity(0.7))
                if player.isAvailable {
                    Text("\(RecordingPlayer.formatTime(player.progress * player.duration)) / \(RecordingPlayer.formatTime(player.duration))")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundColor(.white.opacity(0.4))
                } else {
                    Text("录音不可用").font(.system(size: 9)).foregroundColor(.white.opacity(0.4))
                }
            }
            Spacer()
            ProgressView(value: player.progress)
                .progressViewStyle(.linear)
                .frame(width: 80)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(.white.opacity(0.05)))
    }
}
```

- [ ] **Step 4: 红点传参与编译验证**

`macOS/SoundSenseMacApp/Views/MacMainMeterView.swift:44` 调用处改为：

```swift
                            LiveStatsBar(stats: live, isRecording: vm.isRecording)
```

（`vm` 按该文件实际变量名对齐。）

```bash
xcodebuild -project SoundSense.xcodeproj -scheme SoundSenseMac -configuration Debug build 2>&1 | tail -3
```
预期：`BUILD SUCCEEDED`。

- [ ] **Step 5: 提交**

```bash
git add macOS/SoundSenseMacApp/MeterViewModel.swift macOS/SoundSenseMacApp/Views/HistoryOverlayView.swift macOS/SoundSenseMacApp/Views/ReportExporter.swift macOS/SoundSenseMacApp/Views/MacMainMeterView.swift
git commit -m "feat: macOS 检测同步录音 + 历史详情面板(简报/回放/HTML 导出)"
```

---

### Task 9: 全量验证 + 手动清单

**Files:**
- 无新改动（验证任务；发现问题则回对应 Task 修复后重跑）

- [ ] **Step 1: 逻辑测试 + Core 回归 + 三端编译**

```bash
./scripts/logic_tests.sh
cd Core && swift test 2>&1 | tail -3 && cd ..
xcodebuild -project SoundSense.xcodeproj -scheme SoundSenseMac -configuration Debug build 2>&1 | tail -2
xcodebuild -project SoundSense.xcodeproj -scheme SoundSense -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build 2>&1 | tail -2
xcodebuild -project SoundSense.xcodeproj -scheme SoundSenseWatch -destination 'generic/platform=watchOS Simulator' CODE_SIGNING_ALLOWED=NO build 2>&1 | tail -2
```
预期：逻辑测试全过、Core 测试全过、三 `BUILD SUCCEEDED`。

- [ ] **Step 2: 真机/模拟器手动清单（macOS App 实测,iOS 模拟器至少验证录音+回放）**

1. 开始检测 → 说几句话 → 停止：`~/Library/Application Support/SoundSense/Recordings/` 出现新 `.m4a`，历史出现记录。
2. 历史点该记录 → 详情显示报告图 + 播放条 → 播放/暂停/进度正常，能听到刚才说的话。
3. 详情 → 导出完整报告 → 浏览器打开 HTML：图片显示、`<audio>` 能播、底部统计正确。
4. 详情 → 导出 PNG：与原版一致。
5. 短测（开始后 1-2 秒停止）：不生成记录，Recordings 无新文件。
6. 左滑/右键删除单条记录：对应 m4a 消失。
7. 清空历史：Recordings 目录空。
8. 手动往 Recordings 塞一个假 `junk.m4a` → 重启 App：被清扫。
9. 旧版本升级场景：把一条无 `audioID` 的旧记录 JSON 放进 `measurement_history.json` → App 正常显示，详情无播放条。
10. watch App 构建产物运行不受影响（不录音、不出现相关 UI）。

- [ ] **Step 3: 更新 README 路线图与文档，收尾提交**

`README.md` 功能特性列表追加一行：

```markdown
- **检测同步录音** -- 测量同时记录现场音频(AAC),历史可回放,报告可导出为含录音的 HTML 单文件
```

```bash
git add README.md
git commit -m "docs: README 补充同步录音与 HTML 报告功能"
```
