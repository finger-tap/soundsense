# 设计：检测同步录音 + 历史回放 + HTML 报告导出

日期：2026-09-01
状态：已确认（用户拍板：HTML 单文件导出；录音常开、不做设置开关）

## 目标

1. 开始检测时同步录音（iOS / macOS；watchOS 不参与）。
2. 历史里可查看监测期间的完整简报，并播放当次录音。
3. 导出支持 HTML 单文件报告（报告图 + 录音 + 统计全部内嵌），原 PNG 导出保留。
4. 清除历史时录音文件一并清理，任何路径都不留垃圾文件。

## 非目标

- watchOS 录音（无历史界面、存储受限、后台即挂起）。
- 录音设置开关（用户明确要求常开）。
- 后台长时间录音 / 录音转写。

## 架构

### 1. 录音管线（新增 `Shared/SessionAudioRecorder.swift`，仅 `os(iOS) || os(macOS)` 编译）

`AudioMeterEngine` 在 `inputNode` 上只有一个 tap（AVAudioEngine 每 bus 仅允许一个），
录音必须复用该 tap：引擎新增线程安全的 `sampleSink` 挂点，tap 回调里在喂
`MeterWorker` 的同时把 PCM 样本喂给 sink；watch 端 sink 恒为 nil，零开销。

```
inputNode tap ──┬──► MeterWorker（现状不变）
                └──► sampleSink ──► SessionAudioRecorder
                                        │ 自己的串行队列
                                        ▼
                        AVAudioConverter: 48k Float mono → 24k Float mono
                                        ▼
                        AVAudioFile (.m4a, AAC, ~48 kbps) → Recordings/<UUID>.m4a
```

- 格式：AAC / 24 kHz / 单声道（约 0.3 MB/分钟，回放环境噪音足够）。
- 写文件在录音器私有串行队列，与测量队列、主线程隔离。
- 时长上限 60 分钟：到上限自动停止写入（测量继续），文件保持有效。
- 不足 3 秒的会话（连 MeasurementStats 都不会生成的那种）停止时直接丢弃。

### 2. 数据模型与存储

- `MeasurementStats` 增加 `audioID: String?`（UUID 字符串）。Codable 可选字段，
  旧 JSON 解码为 nil，前后兼容。
- 录音目录：`Application Support/SoundSense/Recordings/<audioID>.m4a`，
  与 `measurement_history.json` 同级。
- `MeasurementHistoryStore` 承担录音文件生命周期，四处清理：
  1. `delete(at:)` 删除对应记录的文件；
  2. `removeAll()` 清空目录内容；
  3. `add()` 淘汰超过 50 条的旧记录时，删其文件；
  4. `load()` 启动时孤儿清扫：目录内凡不被任何记录引用的文件一律删除
     （覆盖崩溃残留、历史版本残留）。
- 文件删除失败不阻断 UI（尽力删，不影响记录本身操作）。

### 3. 历史简报 + 播放

- 简报直接复用 `ReportRenderer.render()` 的报告图（LAeq / 峰值 / 趋势图全在里面），
  不另造简报布局。
- 新增 `Shared/RecordingPlayer.swift`：AVAudioPlayer 的 ObservableObject 封装，
  播放/暂停/停止、进度、时长；录音不存在时优雅降级（不显示播放器）。
- iOS：历史条目点击 → 详情 sheet（报告图 + 播放条 + 导出 PNG / 导出 HTML 按钮），
  导出入口从"直接弹分享"改为先进详情。
- macOS：`MacReportPreviewSheet` 升级为详情面板：报告图预览 + 播放条 + 导出按钮。
- 旧记录（audioID 为 nil 或文件已丢）只显示简报与导出，无播放器。

### 4. HTML 单文件报告（新增 `Shared/ReportHTMLBuilder.swift`，仅 iOS/macOS）

- 自包含 HTML：内嵌 base64 PNG（简报图）+ base64 m4a（`<audio>` 控件）+ 统计数字表格，
  深色配色与 App 同款（石墨底 / 青绿主色）。
- 无录音的记录生成不含音频块的 HTML，其余照常。
- iOS：详情页"导出 HTML"→ 临时文件 + UIActivityViewController 分享。
- macOS：详情面板"导出 HTML"→ NSSavePanel（`.html`）保存；PNG 导出按钮并存。

### 5. ViewModel 接线（iOS / macOS 两个 MeterViewModel）

- `start()`：测量启动成功后 `recorder.startSession()` 并挂上引擎 sink。
- `stop()`：先停 sink 再停引擎；统计生成 → 录音文件定稿并随 stats 存 audioID；
  统计未生成 → 丢弃录音文件。
- 引擎启动失败（权限拒绝等）不产生任何录音文件。

## 错误处理

- 录音写入失败（磁盘满等）：停用录音、测量照常，简报/导出退化为无录音形态。
- 播放文件缺失：播放区显示"录音不可用"或不渲染播放器。
- 清理删除失败：静默容错，下次启动孤儿清扫兜底。

## 验证

- `xcodebuild` 三 target 编译通过（SoundSense / SoundSenseMac / SoundSenseWatch）。
- Core 包 `swift test` 回归（算法无改动，应全绿）。
- 手动清单：开始→停止→历史出现记录且 Recordings 有对应 m4a；详情可播放；
  导出 HTML 在浏览器可开、音频可播；短测（<3s）不留文件；删除单条/清空/
  超 50 条淘汰/重启后 Recordings 目录均无残留；旧版本历史记录正常显示。

## 涉及文件

新增：`Shared/SessionAudioRecorder.swift`、`Shared/RecordingPlayer.swift`、
`Shared/ReportHTMLBuilder.swift`（均注册进 iOS + macOS target，不进 watch）。
改动：`Shared/AudioMeterEngine.swift`（sampleSink 挂点）、
`Shared/MeasurementRecorder.swift`（audioID 字段）、
`Shared/MeasurementHistoryStore.swift`（文件生命周期）、
`iOS/.../MeterViewModel.swift`、`iOS/.../HistoryView.swift`、
`iOS/.../ReportShareSheet.swift`、
`macOS/.../MeterViewModel.swift`、`macOS/.../HistoryOverlayView.swift`、
`macOS/.../ReportExporter.swift`、`SoundSense.xcodeproj/project.pbxproj`。
