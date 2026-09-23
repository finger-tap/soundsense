# 设计：声源定位套件（事件引擎 + 三点测试 + 长时间监听）

日期：2026-09-14
状态：已确认（用户拍板：整体通过，顺序 事件引擎→A→B；A 拆 A1 手机 / A2 手表；手表 v1 不做录音片段）

## 目标

1. 共享事件引擎：背景基线 + 瞬态事件检测 + 噪音类型分类（纯逻辑，多端复用）。
2. A1 三点声源倾向测试（iOS）：房间中央/靠共用墙/靠天花板各 30s，输出"倾向楼上/隔壁/无法判断 + 置信度 + 噪音类型"，同步录音作证据。
3. A2 三点测试手表版（watchOS）：表上独立完成走位测试，结果经 WCSession 同步 iPhone 存储展示（无录音）。
4. B 长时间监听（iOS）：插电值守模式，异常噪音自动存短片段并按时间线标注类型与位置推测。

## 非目标

- 真实声源定位（单麦克风物理不可行；输出一律为"推测，仅供参考"）。
- Mac 端测试/监听 UI（走位与值守均为手机场景；Shared 分析逻辑保持平台无关以备将来）。
- 手表端录音片段传输（v1 砍掉）。

## 0. 共享事件引擎（`Shared/NoiseEventEngine.swift`，纯逻辑）

- 输入帧：`(相对时间, spl, lowRatio)`；lowRatio = <200Hz 功率占比，由调用方从 `MeterResult.spectrum` 计算（辅助函数随引擎提供）。
- 背景基线：60s 滑窗 L90 分位。
- 事件状态机：`spl > 基线+10dB`（或 > 可选绝对阈值）且持续 ≥0.2s 触发；回落低于阈值−3dB 持续 2s 结束；结束 5s 内的新触发合并进上一事件。
- 输出事件：起止时间、峰值 SPL、事件帧平均 lowRatio、起振陡度 dB/s。
- 类型分类（供 A/B 共用）：事件率 ≥6/min，或 ≥2/min 且事件 lowRatio ≥0.5 → `impact`；稳态帧占比 ≥0.6 且事件率 <2/min → `continuous`；两者兼有 → `mixed`；否则 `unknown`。

## 1. A1 三点测试（iOS）

- 流程：引导页 → 三点位各 30s（中央→靠墙→靠顶，自动倒计时，可重测）→ 结果卡片。
- 每点位统计 `PositionStats`：LAeq、最低/最高、事件数、事件平均 lowRatio、稳态占比。
- 判定（`SourceTendencyAnalyzer`，阈值常量可调）：墙增益=靠墙LAeq−中央LAeq，顶增益=靠顶LAeq−中央LAeq；增益 ≥2dB 且比另一侧高 ≥2dB → 对应倾向；置信度：差距 ≥5dB 高 / ≥3dB 中 / 其余低；都不足 2dB → 无法判断。
- 测试全程用 `SessionAudioRecorder` 录一个连续文件（≥90s 必然保留），audioID 入库。
- 存储：`SourceTestStore`（JSON，最多 20 条，`SourceTestResult` 模型），录音在 `Recordings/Tests/` 子目录；删除/清空/淘汰/孤儿清扫与测量历史同一套生命周期（目录隔离，互不干扰）。
- 最新一次测试结果作为"房间标定"供 B 的位置推测使用。
- 录音回放复用 `RecordingPlayer`/`RecordingPlayerBar`；HTML 导出复用 ReportHTMLBuilder 的样式模式。

## 2. A2 三点测试（watchOS）

- watch 端独立流程：三步引导（抬腕平胸→靠墙→举高），每步 30s，复用事件引擎与 Analyzer（纯逻辑文件注册进 watch target）。
- 完成后 `SourceTestResult`（audioID=nil，标注无录音）经 WCSession 发送；iPhone 端 delegate 接收入库并提示。
- watch 端不持久化历史（结果只在本端展示一次）。

## 3. B 长时间监听（iOS）

- 后台：Info.plist 加 `UIBackgroundModes: audio`，监听期间保持 audio session 活动实现锁屏运行；UI 明示"建议插电、系统可能回收"。
- 运行：独立监听页，引擎节流 0.1s 喂事件引擎；触发事件时 `EventClipRecorder`（iOS only）从环形缓冲取**前 2s + 事件 + 后 3s** 写独立 m4a（AAC 24k，与 SessionAudioRecorder 共享写盘辅助）。
- 上限：单会话 100 条片段/20 条会话，到顶停存并提示；只存片段不全程录。
- 位置推测：类型启发（impact+低频重→楼上；continuous 语音频段→隔壁；其余不确定）+ 若有房间标定则提升对应置信度；UI 列名就叫"推测"。
- 存储：`MonitorSessionStore`（会话+事件元数据），片段在 `Recordings/Monitor/<sessionID>/`；同一套清理生命周期。
- 详情：时间线列表（时刻/峰值/类型图标/推测），点击播放片段；会话 HTML 导出（时间线+统计+代表片段内嵌）。

## 错误处理

- 引擎/录音失败：静默降级为只测数据不录音，UI 提示一次。
- WCSession 不可用/未配对：watch 端提示"结果仅本次展示"。
- 后台被系统回收：会话标记"异常结束"，已存数据保留。

## 验证

- 逻辑测试（logic harness）：事件引擎（基线/触发/合并/分类）、Analyzer（四类判定）、两个 Store 的生命周期与孤儿清扫。
- 三平台 typecheck（`scripts/typecheck_targets.sh`），watch target 新增纯逻辑文件的注册验证。
- 手动清单：A1 三点走位全流程与报告；A2 手表测试→手机收结果；B 过夜监听（锁屏、事件抓取、回放、导出）；各清理路径无残留。

## 涉及文件

新增：`Shared/NoiseEventEngine.swift`（多端）、`Shared/SourceTendencyAnalyzer.swift`（多端）、
`Shared/SourceTestStore.swift`（iOS/macOS 编译）、`Shared/EventClipRecorder.swift`（iOS/macOS）、
`Shared/MonitorSessionStore.swift`（iOS/macOS）、`Shared/SourceTestHTMLBuilder.swift`、`Shared/MonitorHTMLBuilder.swift`、
iOS `SourceTest/`（VM+流程视图+列表）、iOS `Monitor/`（VM+监听页+时间线）、iOS WCSession 接收、
watchOS 测试流程视图 + 发送。
改动：iOS `MainMeterView`（两个入口）、`SoundSenseApp.swift`（WCSession 激活）、watch `WatchMeterView`（入口）、
iOS Info.plist（后台音频）、`SoundSense.xcodeproj/project.pbxproj`、`SessionAudioRecorder.swift`（抽出共享写盘辅助）。
