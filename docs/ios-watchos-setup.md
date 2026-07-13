# 闻声 SoundSense —— iOS / watchOS 开发指南

本文档说明如何在 Xcode 中打开、运行、调试 iOS 与 watchOS 两个 target,以及遇到问题时的排查清单。

## 工程结构

```
soundsense/
├── SoundSense.xcodeproj/          ← Xcode 工程(手写,可签入仓库)
├── Package.swift                   ← 本地 SwiftPM 包(含 SoundSenseCore 算法库)
├── Shared/                         ← iOS / watchOS 共享代码
│   ├── AudioMeterEngine.swift      ← 跨平台音频采集 + 测量引擎
│   ├── NoiseLevel.swift            ← 分贝→等级/颜色/文案 映射
│   └── MeterTheme.swift            ← 共享配色
├── iOS/SoundSenseApp/              ← iOS App 源码(SwiftUI)
├── watchOS/SoundSenseWatchApp/     ← 独立 watchOS App 源码(SwiftUI)
├── Sources/SoundSenseCore/         ← 核心算法(三端共用,零 AVFoundation 依赖)
└── Sources/soundsense/             ← macOS 命令行工具(不受影响)
```

两个 App target 通过**本地 SwiftPM 包**引用 `SoundSenseCore`,算法库只有一份源码,iOS / watchOS / macOS CLI 三端共享。

## 部署目标(最低系统版本)

| 平台 | 最低版本 | 覆盖范围 |
|------|---------|---------|
| iOS | 15.0 | iPhone 6s 及以后,接近全覆盖 |
| watchOS | 8.0 | Apple Watch Series 3(后期)及以后 |

> 选低版本是为了最大化兼容。代价:不能用 iOS 17 的 `@Observable`、`NavigationStack`、`.onChange` 双参闭包、`contentTransition` 等 —— 代码已按此约束编写。

## 在 Xcode 中运行

### 1. 打开工程

```bash
open /Users/dinghao/工作/soundsense/SoundSense.xcodeproj
```

> ⚠️ **如果 `xcode-select` 指向 CommandLineTools**,需先切换到完整 Xcode:
> ```bash
> sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
> ```

### 2. 选择 Scheme 与目标

| 想跑的 | Scheme | Destination |
|--------|--------|-------------|
| iPhone / iPad | `SoundSense` | iPhone 模拟器或真机 |
| Apple Watch | `SoundSenseWatch` | Apple Watch 模拟器或真机 |

### 3. 首次运行需注意

- **平台 SDK**:Xcode 需已下载对应平台 runtime(iOS 18.x / watchOS 11.x)。若报错 *"iOS 18.5 is not installed"*,在 Xcode → Settings → Platforms(或 Components)下载。
- **麦克风权限**:首次运行 App 会弹权限请求,允许即可。watchOS 模拟器的麦克风来自配对的 Mac。
- **真机调试**:当前 `CODE_SIGNING_ALLOWED = NO`。要在真机上跑,需:
  1. Xcode → Signing & Capabilities → 勾选 Automatically manage signing
  2. 选你的 Apple Developer Team(免费账号即可真机调试)
  3. Bundle ID 若被占用,改成你自己的(如 `com.<你的名字>.soundsense`)

## 功能说明

### iOS App(SoundSense)

- **主屏**:大数字 SPL + 圆形仪表盘 + 实时声波条 + 频谱图 + 噪音等级徽章
- **设置页**(右上角齿轮):校准偏移量滑块(-30 ~ +60 dB,步进 0.5)
- **校准原理**:App 显示的是 dBFS(A 计权)+ 你设置的偏移量。要用标准声级计对比校准才能得到真实 SPL。

### watchOS App(SoundSenseWatch)

- **抬腕即测**:App 进入前台(`.active`)自动启动测量,进入后台自动停止。
- **界面**:中央大数字 SPL + 外圈等级色环 + 迷你声波条 + 迷你频谱。
- **省电**:节流到 5fps(200ms 一帧),适合手表。
- **平台限制**:watchOS 的 `AVAudioEngine` 只在前台工作 —— 这是系统限制,App 无法在后台持续监测(这与"抬腕即测"的使用方式匹配)。

## 体积优化(已配置)

以下 build settings 已写入 `project.pbxproj` 的 Release 配置:

| 设置 | 值 | 作用 |
|------|-----|------|
| `SWIFT_OPTIMIZATION_LEVEL` | `-O` | Release 全优化 |
| `SWIFT_COMPILATION_MODE` | `wholemodule` | Whole-module,更小更快 |
| `GCC_OPTIMIZATION_LEVEL` | `s` | 二进制 size 优先 |
| `DEAD_CODE_STRIPPING` | `YES` | 移除未引用代码 |
| `DEPLOYMENT_POSTPROCESSING` | `YES` | 启用 strip |
| `STRIP_INSTALLED_PRODUCT` | `YES` | strip 安装产物 |
| `STRIP_SWIFT_SYMBOLS` | `YES` | strip Swift 符号 |
| `LOCALIZATION_PREFERS_STRING_CATALOGS` | `YES` | 仅本地化必要语言 |

图标策略:iOS / watchOS 都用**单张 1024×1024** AppIcon(Xcode 14+ 自动生成各尺寸),不预置多尺寸,省几十~几百 KB。后续若加图标,可导出 HEIC 进一步压缩。

## 排查清单(若工程打开异常)

### 工程打不开 / 报错 "Could not resolve package dependencies"

本地包引用是 `relativePath = "../soundsense"`(相对于 `.xcodeproj` 所在目录的父目录)。若你移动了工程位置:

1. 在 Xcode 左侧 File Inspector 找到 `SoundSenseCore` 包引用
2. 确认路径指向仓库根(含 `Package.swift` 的目录)
3. 或直接编辑 `SoundSense.xcodeproj/project.pbxproj` 里 `XCLocalSwiftPackageReference` 的 `relativePath`

### 编译报错 "no such module 'SoundSenseCore'"

包没解析成功。Xcode → File → Packages → Reset Package Caches,然后 Resolve Package Versions。

### 类型错误堆积

确保 Deployment Target 没被改高。代码按 iOS 15 / watchOS 8 编写,若 target 被改到更高版本理论上向后兼容,但若被改低(< 15 / < 8)会触发可用性错误。

## 三端共存说明

| 端 | 构建方式 | 是否受 iOS/watchOS 改动影响 |
|----|---------|---------------------------|
| macOS CLI / .app | `./scripts/build.sh`(swiftc 直编译) | ❌ 不受影响 |
| macOS Release | GitHub Actions(`release.yml`) | ❌ 不受影响 |
| iOS App | Xcode(`SoundSense` scheme) | — |
| watchOS App | Xcode(`SoundSenseWatch` scheme) | — |

核心算法 `Sources/SoundSenseCore/SoundSenseCore.swift` 是三端共享的单点,改一处三端都更新。
