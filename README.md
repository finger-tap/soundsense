# 闻声 SoundSense

> 环境噪音分贝计 -- 基于 IEC 61672 A 计权标准的精确噪音测量工具

闻声（SoundSense）是一个用 Swift 编写的噪音分贝测量工具。核心算法使用 Accelerate/vDSP 进行 FFT 频谱分析和 A 计权处理，符合 IEC 61672 国际标准。

## ✨ 功能特性

- **A 计权测量** -- 按 IEC 61672-1 标准实现，模拟人耳对不同频率的敏感度
- **FFT 频谱分析** -- 使用 Accelerate 框架的 vDSP 进行 4096 点 FFT，实时频域处理
- **功率比算法** -- A 计权修正采用功率比法，不受 FFT 缩放影响，1 kHz 参考点精度 < 0.1 dB
- **实时测量** -- 通过 AVAudioEngine 采集麦克风数据，实时显示分贝值和声波条
- **算法自验证** -- 内置单元测试，用数学上已知分贝的合成信号验证算法准确性

## 📊 算法验证结果

| 验证项 | 结果 | 精度 |
|--------|------|------|
| dBFS 计算（5 个振幅档） | ✅ 全通过 | 误差 < 0.01 dB |
| A 计权频域修正（6 个频率） | ✅ 全通过 | 偏差 < 0.1 dB |
| A 计权曲线（12 频率 vs IEC 61672） | ✅ 全通过 | 偏差 < 0.1 dB |
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
PCM Float32 样本 [N=4096]
  │
  ├──────────────────────────┐
  ▼                          ▼
时域 RMS                  加 Hann 窗 → vDSP FFT
  │                          │
  ▼                          ▼
dBFS(flat)              频域功率谱 |X[k]|²
                             │
                             ▼
                      × A 计权功率权重 W²[k]
                             │
                             ▼
                      修正量 = 10·log₁₀(Σ P·W² / Σ P)
                             │
  ◄──────────────────────────┘
  │
  ▼
dBFS(A) = dBFS(flat) + 修正量
  │
  ▼
SPL(A) = dBFS(A) + 校准偏移量
```

### 核心设计

- **功率比法**：A 计权修正量 = `10·log₁₀(Σ P[k]·W²[k] / Σ P[k])`，FFT 的任何绝对缩放在比值中自动抵消，1 kHz 纯音修正量天然为 0
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
SPL = dBFS(A) + Offset
```

Offset 取决于设备麦克风灵敏度，需用标准声级计对比实测。详见代码中的校准向导设计。

## 🗺 开发路线图

- [x] 核心算法（A 计权 + FFT + dBFS）
- [x] 命令行验证工具（test / sweep / live）
- [x] macOS .app 打包
- [x] GitHub Actions 自动发布
- [ ] iOS App（SwiftUI 界面）
- [ ] 校准向导（标准声级计对比）
- [ ] 实时频谱图可视化
- [ ] 历史记录与数据导出
- [ ] 代码签名与公证

## 📄 License

MIT License - 详见 [LICENSE](LICENSE)
