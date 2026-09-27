# 声源定位套件（事件引擎 + 三点测试 + 长时间监听）实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 共享事件引擎之上交付：A1 iOS 三点声源倾向测试（含录音证据）、A2 watchOS 走位测试（WCSession 同步）、B iOS 长时间监听（异常事件自动存片段 + 时间线 + 位置推测）。

**Architecture:** 事件引擎与判定器为纯逻辑 Shared 文件（多端注册）；测试/监听各自拥有 `AudioMeterEngine` 实例；片段录音在 SessionAudioRecorder 的写盘辅助上扩展；三个存储共用"删除/清空/淘汰/孤儿清扫"生命周期模式但目录互相隔离。

**Tech Stack:** Swift 5 / SwiftUI / AVFoundation / WCSession / CoreGraphics（HTML 复用 ReportHTMLBuilder 样式）。

**Spec:** `docs/superpowers/specs/2026-09-14-source-localization-suite-design.md`

## Global Constraints

- 部署目标不变：iOS 15 / macOS 12 / watchOS 8。不引第三方依赖。
- 纯逻辑文件（NoiseEventEngine / SourceTendencyAnalyzer）注册进 **iOS + macOS + watchOS 三 target**；存储/录音/HTML 文件只进 iOS（+macOS 可选）；watch 不注册任何录音/存储文件。
- 录音格式沿用 AAC 24kHz 单声道；目录：测试 `Recordings/Tests/`、监听 `Recordings/Monitor/<sessionID>/`。
- 一切位置输出文案带"推测/仅供参考"；无录音的结果标注"无录音"。
- 纯逻辑 TDD 走 `scripts/logic_tests.sh`（追加源文件与用例）；UI/接线用 `scripts/typecheck_targets.sh` + 手动清单。
- 每任务一个中文 conventional 提交；在 `feature/source-localization` 分支工作（已合回 main 后新建）。
- 新 pbxproj ID 号段：文件引用 `A2BB0000000000000000000F…14`，iOS 构建 `A1BB0000000000000000000F…14`，macOS 构建 `AABB0000000000000000000E…12`，watch 构建 `A1000000000000000000002F 段后接续`（实施时先用 grep 确认空闲）。

---

### Task 1: NoiseEventEngine 事件引擎

**Files:** Create `Shared/NoiseEventEngine.swift`（**不加平台 #if**，watch 也要用）；Modify `Tests/logic/main.swift`、`scripts/logic_tests.sh`

**Interfaces（后续任务依赖）:**
- `func lowFrequencyRatio(spectrum: [Float], frequencies: [Float], cutoff: Float = 200) -> Float?`
- `struct NoiseEvent: Codable, Equatable { startTime/endTime: TimeInterval; peakSPL: Float; avgLowRatio: Float; attackRate: Float }`
- `final class NoiseEventEngine { var thresholdOverBackground/hysteresis/minEventDuration/endHoldoff/mergeWindow/baselineWindow/frameInterval; var absoluteThreshold: Float?; func beginSession(); func feed(t: TimeInterval, spl: Float, lowRatio: Float?) -> NoiseEvent?（返回**刚结束**的事件，新建返回 nil）; var events: [NoiseEvent]; func beginClipHooks(onStart: @escaping () -> Void)（B 用来触发片段录制）`
- 聚合统计（A 的 PositionStats 用）：`var frameCount: Int; var energySum: Double; var minSPL/maxSPL: Float; var steadyCount: Int（|spl−当前运行LAeq|≤3dB 的帧数）; func currentLaeq() -> Float`

关键实现：基线=滑窗复制排序取 10% 分位；事件状态机 idle→active（>基线+10dB 或 >绝对阈值，持续≥minEventDuration）→ 结束滞回（<阈值−3dB 连续 2s）→ 结束 5s 内合并；attackRate=(peak−触发起点 SPL)/上升耗时。

- [ ] Step 1 写失败测试（合成场景：60s 背景 35dB + 3 次 55dB×0.5s 脉冲 → events.count==3、mergeWindow 内双脉冲并 1、lowRatio 平均正确、LAeq/稳态计数）
- [ ] Step 2 跑 `./scripts/logic_tests.sh` 确认编译失败
- [ ] Step 3 实现
- [ ] Step 4 测试全绿
- [ ] Step 5 提交 `feat: 噪音事件引擎(背景基线/瞬态检测/合并/类型特征)`

### Task 2: SourceTendencyAnalyzer 判定器

**Files:** Create `Shared/SourceTendencyAnalyzer.swift`（不加平台 #if）；Modify 测试与脚本

**Interfaces:**
- `struct PositionStats: Codable, Equatable { name: String; laeq/minSPL/maxSPL: Float; eventCount: Int; avgLowRatio: Float; steadyRatio: Float }`（positions 顺序固定 [中央,靠墙,靠顶]）
- `enum TendencyVerdict: String, Codable { upstairs, neighbor, inconclusive }`；`enum Confidence: String, Codable { low, medium, high }`；`enum NoiseType: String, Codable { impact, continuous, mixed, unknown }`
- `struct SourceTestResult: Codable, Equatable, Identifiable { id: UUID; startTime: Date; duration: TimeInterval; positions: [PositionStats]; verdict/confidence/noiseType; audioID: String? }`
- `enum SourceTendencyAnalyzer { static func analyze(positions: [PositionStats], duration: TimeInterval) -> (verdict, confidence, noiseType)（常量：minGain=2, dominanceGap=2, high≥5, medium≥3; 类型: 事件率≥6/min 或 ≥2/min且lowRatio≥0.5 → impact; steadyRatio≥0.6 且 <2/min → continuous; 两者并存 → mixed; else unknown）; static func guessPosition(lowRatio: Float, isImpact: Bool, calibration: SourceTestResult?) -> String（"楼上(推测)"/"隔壁(推测)"/"不确定"） }`
- `PositionStats` 由 VM 用 Task 1 的聚合统计填：`steadyRatio = steadyCount/frameCount`，`avgLowRatio` 取事件平均。

- [ ] Step 1 失败测试（墙增益主导→neighbor/high；顶增益→upstairs；平坦→inconclusive；事件密集低频→impact；稳态→continuous）
- [ ] Step 2 确认失败 → Step 3 实现 → Step 4 全绿 → Step 5 提交 `feat: 声源倾向判定器(三点位增益/置信度/噪音类型/位置推测)`

### Task 3: SourceTestStore 存储

**Files:** Create `Shared/SourceTestStore.swift`（`#if os(iOS) || os(macOS)`，watch 不注册）；Modify 测试与脚本

**Interfaces:** `final class SourceTestStore: ObservableObject { static let shared; @Published private(set) var results: [SourceTestResult]; init(fileURL: URL? = nil)（默认 SoundSense/source_tests.json，录音目录 = JSON 同级 Recordings/Tests/）; var recordingsDirectory: URL; func audioFileURL(forID:); func add(_)/delete(at:)/removeAll(); static let maxResults = 20 }` —— 生命周期与 MeasurementHistoryStore 完全同构（本机目录隔离，清扫只清自己目录）。

- [ ] Step 1 失败测试（增删/清空/淘汰连文件/孤儿清扫/audioID 往返，模式照抄现有 6 组）→ Step 2 失败 → Step 3 实现 → Step 4 绿 → Step 5 `feat: 三点测试存储与录音文件生命周期`

### Task 4: EventClipRecorder 片段录音器

**Files:** Modify `Shared/SessionAudioRecorder.swift`（把 `pcmBuffer`/`makeTaps` 提为 `internal enum AACWriteSupport`，两处复用）；Create `Shared/EventClipRecorder.swift`（`#if os(iOS) || os(macOS)`）；Modify 测试与脚本

**Interfaces:**
- `final class EventClipRecorder { func configure(directory: URL, inputSampleRate: Float); func append(_ samples: [Float])（持续喂,内部维护 preRollSeconds=2 环形缓冲）; func beginClip() -> Bool（事件触发,落盘 pre-roll 并开新文件）; func endClip() -> Bool（事件结束,写满 postRollSeconds=3 后异步定稿,返回是否成功开启过）; var isClipOpen: Bool; var preRollSeconds/postRollSeconds: TimeInterval }`
- 实现：串行队列；open 时把环形缓冲写完后接续写实时流；endClip 后计数 post 帧数到位即 finalize（无需定时器）。

- [ ] Step 1 失败测试（合成流：begin→验证文件含 pre-roll≈2s；endClip 后继续 append 3s→文件总时长≈pre+事件+post；未 begin 的 append 不落盘）→ Step 2 失败 → Step 3 实现（先重构 AACWriteSupport 并保持 SessionAudioRecorder 原测试全绿）→ Step 4 绿 → Step 5 `feat: 事件片段录音器(环形缓冲 pre-roll/post-roll)`

### Task 5: MonitorSessionStore 存储

**Files:** Create `Shared/MonitorSessionStore.swift`（`#if os(iOS) || os(macOS)`）；Modify 测试与脚本

**Interfaces:**
- `struct MonitorEvent: Codable, Equatable, Identifiable { id: UUID; time: Date; peakSPL: Float; duration: TimeInterval; avgLowRatio: Float; type: NoiseType; guess: String; clipFile: String? }`
- `struct MonitorSession: Codable, Equatable, Identifiable { id: UUID; startTime: Date; endTime: Date?; overallLaeq/minSPL/maxSPL: Float; thresholdOverBackground: Float; events: [MonitorEvent]; var abnormalEnd: Bool }`
- `final class MonitorSessionStore: ObservableObject { static let shared; @Published results…; init(fileURL:); var baseClipsDirectory（Recordings/Monitor/）; func clipsDirectory(sessionID:); func add(_)/update(_)/delete(at:)/removeAll(); static let maxSessions = 20 }` —— 删除会话连带删其子目录；清扫遍历子目录。

- [ ] Step 1 失败测试（会话/事件增删、删除会话删片段目录、孤儿子目录清扫、超 20 淘汰）→ … → Step 5 `feat: 监听会话存储(事件+片段目录生命周期)`

### Task 6: pbxproj 注册 + typecheck

**Files:** Modify `SoundSense.xcodeproj/project.pbxproj`

- [ ] Step 1 按 Global Constraints 注册：Engine+Analyzer → 三 target；Store×2/ClipRecorder/（HTML builders Task 7/9 产物回头补）→ iOS（+macOS）；先 grep 确认 ID 空闲
- [ ] Step 2 `./scripts/typecheck_targets.sh all` 三端过
- [ ] Step 3 提交 `chore: 注册事件引擎与判定器进三端 target`

### Task 7: A1 — iOS 三点测试流程

**Files:** Create `iOS/SoundSenseApp/SourceTest/SourceTestViewModel.swift`、`…/SourceTestFlowView.swift`、`…/SourceTestListView.swift`（列表+详情）、`Shared/SourceTestHTMLBuilder.swift`；Modify `iOS/SoundSenseApp/Views/MainMeterView.swift`（工具条加"声源定位"入口）、HistoryView 旁复用 `RecordingPlayerBar`；pbxproj 补注册

**VM 要点:** 自持 `AudioMeterEngine(calibrationOffset: 同主设置, throttleInterval: 0.1)`；进入流程若主测量在跑先调 `vm.stop()`；`start()` = engine.start + recorder.startSession(directory: SourceTestStore.shared.recordingsDirectory) + setSampleSink；consume 里 `lowFrequencyRatio(spectrum:frequencies:)` 喂 engine；每点位 30s Timer 切换，收集三份 `PositionStats`（feed 聚合重建——注意每个点位开始时 `beginSession()` 重置聚合）；结束 `finishSession(keep:true)` 回填 audioID → `Analyzer.analyze` → `store.add`；暴露 `latestResult` 供 B 读取标定。

**UI 要点:** FlowView 三态（引导/进行中[点位名+倒计时环+实时 LAeq+可重测]/结果卡[verdict 大字+confidence+type+三点位条形对比]）；ListView 用 `HistoryRow` 风格重排 + 详情（报告要素+播放条+分享 HTML）。HTML：`SourceTestHTMLBuilder.build(result:pngBase64:audioBase64:)`，CSS 从 ReportHTMLBuilder 抽 `static let themeCSS` 复用。

- [ ] Step 1 VM + 引擎/存储接线 → Step 2 三视图 + 入口 → Step 3 HTML builder → Step 4 typecheck iOS → Step 5 提交 `feat: iOS 三点声源倾向测试(走位流程/录音证据/结果报告)`

### Task 8: A2 — watch 走位测试 + WCSession

**Files:** Create `watchOS/SoundSenseWatchApp/Views/WatchSourceTestView.swift`（三步引导+结果卡，复用 Engine/Analyzer——注册进 watch target）、`iOS/SoundSenseApp/WatchSyncManager.swift`（iOS 端 WCSessionDelegate 收结果）；Modify watch `WatchMeterView`（入口按钮）、iOS `SoundSenseApp.swift`（激活 WCSession）、pbxproj（watch 新增 Engine/Analyzer/WatchTestView，iOS 新增 SyncManager）

**要点:** watch VM 同 Task 7 模式但无 recorder（audioID=nil）；结果 JSON 编码经 `WCSession.sendMessageData`（fallback `transferUserInfo`）；iOS 端解码 `SourceTestResult` → `store.add`，NotificationCenter 通知 UI 弹提示"手表测试结果已同步"。

- [ ] Step 1 watch 流程 VM+视图 → Step 2 WCSession 双端 → Step 3 typecheck（macos/ios/watchos）→ Step 4 提交 `feat: watchOS 走位测试与结果同步`

### Task 9: B — 长时间监听

**Files:** Create `iOS/SoundSenseApp/Monitor/MonitorViewModel.swift`、`…/MonitorView.swift`（主页面+进行中）、`…/MonitorSessionDetailView.swift`（时间线+回放）、`Shared/MonitorHTMLBuilder.swift`；Modify `iOS/SoundSenseApp/Info.plist`（`UIBackgroundModes: [audio]`）、`MainMeterView`（监听入口）、pbxproj

**VM 要点:** 自持 engine(throttle 0.1)；`NoiseEventEngine.beginClipHooks` 驱动 `EventClipRecorder`（configure 到 `Monitor/<sessionID>/`）；事件结束 → `MonitorEvent`（guess 用 `Analyzer.guessPosition(lowRatio:isImpact:calibration: SourceTestStore.shared.latest)`）→ 事件数组与 `MonitorSessionStore.update`；会话上限 100 片段；stop() 落 endTime；引擎失败/后台回收标 `abnormalEnd`；监听期间 LiveStatsBar 同款显示 + 事件计数。

**UI 要点:** 主页面（大开始/停止按钮、阈值设置[基线+10dB 默认/夜间绝对阈值可开]、建议插电提示）；详情页时间线列表（时刻/峰值/类型图标[ WF 字符：footstep→"figure.walk"、speech→"text.bubble"、mixed→"speaker.wave.2" ]/推测列），行点击 `RecordingPlayerBar` 播放对应片段；分享 HTML（时间线表格+LAeq 统计+最长 3 个片段内嵌）。

- [ ] Step 1 VM + 后台模式 → Step 2 监听页 + 时间线详情 + HTML → Step 3 typecheck → Step 4 提交 `feat: 长时间监听(事件片段/时间线/位置推测/HTML 导出)`

### Task 10: 全量验证 + 收尾

- [ ] Step 1 `./scripts/logic_tests.sh`（全部新用例）+ `./scripts/typecheck_targets.sh all` + Core `soundsense test` 14 通过
- [ ] Step 2 手动清单：A1 走位全流程（录音/结论/HTML）；A2 手表测→手机收；B 锁屏过夜监听（事件抓取/回放/推测列/导出）；删除会话/测试/清空后 Recordings 各目录无残留；旧功能（测量/历史/录音回放）回归不破
- [ ] Step 3 README 功能列表补两条 + 提交 `docs: README 补充声源定位套件`
- [ ] Step 4 收尾：finishing-a-development-branch
