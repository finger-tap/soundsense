# 闻声 SoundSense

> 环境噪音分贝计 -- 基于 IEC 61672 A 计权标准的精确噪音测量工具

闻声（SoundSense）是一个用 Swift 编写的噪音分贝测量工具。核心链路使用
Accelerate/vDSP 做 FFT 频谱显示，并按 IEC 61672-1 的解析曲线设计时域
A/C 计权 IIR 滤波器；它不是经过型式批准的 IEC Class 1/2 声级计。

## ✨ 功能特性

- **A/C 时域计权** -- 按 IEC 61672-1 解析曲线设计 IIR，逐样本处理，1 kHz 归一化
- **FFT 频谱分析** -- 使用 Accelerate/vDSP 做 4096 点 FFT，仅用于频谱显示，不参与 SPL/Leq
- **F/S + Leq** -- 在计权后的能量域做 Fast/Slow 指数检波，按真实 hop 时长积分 Leq
- **实时测量** -- 通过 AVAudioEngine 采集麦克风数据，实时显示分贝值和声波条
- **检测同步录音** -- 测量同时记录现场音频(AAC 24kHz)，历史可回放，报告可导出为含录音的 HTML 单文件；清除历史时录音文件一并清理
- **声源方向倾向套件** -- 四点走位测试（中央基准 → 共用墙 → 天花板 → 中央复测）给出「倾向楼上/隔壁」推测与置信度；中央前后漂移 > 2 dB 时拒绝结论。支持 Apple Watch 端走位、结果同步；长时间监听在异常噪音超出背景基线时自动截取录音片段，按时间线标注噪音类型与位置推测（方向倾向仅供参考，不是三维定位）
- **算法自验证** -- 内置单元测试，用数学上已知分贝的合成信号验证算法准确性
- **低功耗监听** -- 长监听关闭完整频谱，仅按约 0.5 秒刷新低频特征；DSP 结果按 0.25 秒批量交付，UI 跟随批次刷新，L90 基线按 1 秒重算

## 📊 算法验证结果

| 验证项 | 结果 | 精度 |
|--------|------|------|
| dBFS 计算（5 个振幅档） | ✅ 全通过 | 误差 < 0.01 dB |
| A/C 时域 IIR 频响（44.1/48/96 kHz） | ✅ 全通过 | 与 IEC 解析曲线最大偏差 < 0.05 dB |
| A/C 计权曲线（多频点 vs IEC 61672） | ✅ 全通过 | 偏差 < 0.5 dB |
| 白噪声 / 粉红噪声 | ✅ 全通过 | -- |
| 静音处理 | ✅ 全通过 | 正确返回 -∞ |
| 实时麦克风采集 | ✅ 正常工作 | -- |

## 🏗 技术架构

### 数据流

```
麦克风
  │
  ▼
AVAudioEngine (.record, .measurement)    ← 关闭 AGC/高通，精度基础
  │
  ▼
PCM Float32 样本
  │
  ├───────────────────────────────┐
  ▼                               ▼
A/C 时域 IIR（状态跨帧连续）     加 Hann 窗 → vDSP FFT
  │                               │
  ▼                               ▼
计权均方值（能量域）             频谱显示（不参与声级）
  │
  ├── F/S 能量域一阶指数检波 → LAF/LAS
  └── 按 hop 时长积分 → LAeq/LCeq
  │
  ▼
SPL = 10·log₁₀(均方值) + 校准偏移量
```

### 核心设计

- **时域计权**：计权作用在 PCM 上，RMS、F/S 检波和 Leq 使用同一条计权信号；FFT 只负责可视化
- **首帧预热**：滤波器首次处理完整窗口建立状态，之后只积分新推进的 hop，避免重叠窗口重复计入
- **停止排空**：停止时摘 tap 后继续处理队列和不足一帧的尾样本，报告不丢最后一个峰值/尾段
- **静音语义**：数字静音的计权均方值为 0，SPL/Leq 返回 `-∞`，不会落到约 0 dB 的伪读数
- **复数 FFT（`vDSP_fft_zop`）**：避开 `vDSP_fft_zrip` 的 DC/Nyquist 打包陷阱，实部填样本、虚部填零
- **纯算法库**：`SoundSenseCore` 只依赖 Accelerate，零 AVFoundation 依赖，可直接移植 iOS

## 🚀 快速开始

### 环境要求

- macOS 12.0+
- Swift 5.5+（Xcode Command Line Tools）
- Accelerate 框架（系统自带）

### 构建

```bash
# 用构建脚本（推荐）
./scripts/build.sh

# 或手动编译
swiftc -O \
  -framework Accelerate -framework AVFoundation -framework Foundation \
  Core/Sources/SoundSenseCore/SoundSenseCore.swift \
  Core/Sources/soundsense/main.swift \
  -o soundsense
```

### 运行

```bash
# 算法验证测试（用合成信号验证准确性）
./soundsense test

# A 计权曲线扫描（对比 IEC 61672 标准值）
./soundsense sweep

# 实时麦克风测量
./soundsense live
```

### 运行 .app

构建脚本会生成 `SoundSense.app`，双击即可运行。首次运行需在 **系统设置 → 隐私与安全 → 麦克风** 中授权。

> ⚠️ 未签名的 app 首次打开时，需右键点击 → 「打开」→ 确认。

### 测试与性能基准

```bash
./scripts/typecheck_targets.sh all   # macOS / iOS / watchOS 类型检查
./scripts/logic_tests.sh             # 核心算法、存储、音频片段逻辑
./scripts/input_device_tests.sh      # macOS 输入源/按设备校准
./scripts/audio_benchmark.sh 300     # 5 分钟合成音频 DSP + 监听逻辑基准
```

`audio_benchmark` 测音频 DSP 与监听事件/统计的纯逻辑 CPU/内存，不包含麦克风采集、SwiftUI、
录音编码、系统后台策略和无线电功耗；真实续航必须在 iPhone / Apple Watch
真机上用 Instruments 的 Time Profiler 与 Energy Log 验证。

## 📁 项目结构

```
soundsense/
├── Core/                           # Swift Package（算法核心 + CLI）
│   ├── Package.swift               # Swift Package Manager 配置
│   └── Sources/
│       ├── SoundSenseCore/
│       │   └── SoundSenseCore.swift    # 核心算法（A 计权 + FFT + dBFS）
│       └── soundsense/
│           └── main.swift              # 命令行工具（test/sweep/live）
├── macOS/ iOS/ watchOS/            # 各平台 GUI 应用
│   └── (macOS/Assets.xcassets      #   应用图标，明/暗双变体)
├── scripts/
│   └── build.sh                    # 构建脚本（编译 + 打包 .app + DMG）
├── .github/
│   └── workflows/
│       ├── ci.yml                  # 三平台编译验证
│       └── release.yml             # GitHub Actions 自动发布
├── generate_icon_a3.swift          # 图标生成器（Core Graphics，A3 表盘版）
└── README.md
```

## 📱 移植到 iOS

`SoundSenseCore.swift` 可原封不动拖进 iOS 项目：

1. 将文件加入 Xcode 工程
2. iOS 端用 `AVAudioEngine` 采集（设 `.measurement` mode 关闭 AGC）
3. 调用 `meter.process(samples)` 获取 `MeterResult`
4. 设置 `calibrationOffset` 得到真实 SPL（需用标准声级计对比校准）

## 🔧 校准说明

iOS/macOS 返回的是 dBFS（数字分贝），不是物理声压级 SPL。转换关系：

```
SPL = dBFS(RMS) + 计权修正 + Offset
```

Offset 取决于设备麦克风灵敏度。依据数字 MEMS 麦克风行业惯例
（94 dB SPL @ 1 kHz ≈ −29 dBFS RMS），内建麦克风的 Offset 典型值
约 **+120 dB**（真机实测分布 117~126，离散 ±6 dB）：

- iOS 内建麦克风默认 +120，Apple Watch +115，Mac +100，外接/耳机 +90
- 旧版本的默认 +93 偏低约 30 dB（会导致环境噪音显示个位数），
  已在 v2.1 自动迁移
- 预设只是开箱估计：精确值请用设置页 **实时校准** 对照标准声级计
  （或 94 dB / 1 kHz 声校准器）实测，结果按设备持久化

原理细节（声级计链路、F/S 检波器、Leq、C−A 差异解读、误差来源）
见 `docs/calibration-notes.md`。

## 🗺 开发路线图

- [x] 核心算法（A/C 计权 + FFT + 能量域 F/S 检波 + Leq）
- [x] 命令行验证工具（test / sweep / live）
- [x] macOS .app 打包
- [x] GitHub Actions 自动发布
- [x] iOS App（SwiftUI 界面）
- [x] 校准向导（标准声级计对比）
- [x] 实时频谱图可视化
- [x] 历史记录与数据导出
- [ ] 代码签名与公证

## 📄 License

MIT License - 详见 [LICENSE](LICENSE)
