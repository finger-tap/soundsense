//
//  AudioMeterEngine.swift
//  SoundSense
//
//  跨平台(iOS / watchOS)实时音频采集 + 分贝测量引擎。
//
//  职责:
//    1. 配置 AVAudioSession(.playAndRecord / .measurement)
//    2. 启动 AVAudioEngine,在 inputNode 上 installTap 取 Float32 单声道样本
//    3. 喂给 SoundSenseCore.DBMeter,得到 MeterResult
//    4. 按节流间隔把结果回调给上层(主线程)
//
//  macOS 命令行工具不编译此文件(它有自己的 LiveMeter 实现)。
//
//  watchOS 注意:AVAudioEngine 只在 App 前台活跃时工作,进入后台会被系统挂起。
//  本引擎不做后台保活 —— 由调用方在 scenePhase 变化时 start()/stop()。
//

// macOS:configureSession 空(macOS 无 AVAudioSession);iOS/watchOS 配置 session。
// AVAudioEngine + installTap + DBMeter 调度逻辑三端一致。
#if os(iOS) || os(watchOS) || os(macOS)

import Foundation
import AVFoundation
import SoundSenseCore
import SwiftUI
#if os(macOS)
// CoreAudio:macOS 输入设备切换(查询系统默认输入设备)用
import CoreAudio
#endif

/// 采集状态
public enum AudioMeterState: Equatable {
    case stopped
    case starting
    case running
    /// 权限被拒绝
    case denied
    /// 启动失败(含错误描述)
    case failed(String)
}

/// 实时测量引擎。对外是 @MainActor,UI 可直接观察其 @Published 状态。
///
/// 内部样本处理放在专用串行队列上(`meterQueue`),不阻塞主线程;
/// `DBMeter` 与样本缓冲归该队列私有,与 MainActor 隔离。
@MainActor
public final class AudioMeterEngine: ObservableObject {

    // MARK: - 对外状态

    /// 当前采集状态
    @Published public private(set) var state: AudioMeterState = .stopped
    /// 最新一帧测量结果(每次回调更新)
    @Published public private(set) var latestResult: MeterResult?
    /// 麦克风权限状态
    @Published public private(set) var permissionGranted: Bool = false
    #if os(macOS)
    /// 当前生效输入设备的 UID(nil = 跟随系统默认)。仅 macOS 支持选源。
    @Published public private(set) var activeInputDeviceUID: String?
    #endif

    // MARK: - 配置

    /// 校准偏移量(dB)。改动会立即在 worker 里重建 DBMeter。
    public var calibrationOffset: Float {
        didSet {
            worker?.updateCalibration(calibrationOffset)
        }
    }

    /// 频率计权方式(A/C)。改动会立即在 worker 里重建 DBMeter。
    public var weighting: Weighting {
        didSet {
            worker?.updateWeighting(weighting)
        }
    }

    /// 时间计权方式(F/S, IEC 61672)。改动会立即在 worker 里重建 DBMeter。
    public var timeWeighting: TimeWeighting {
        didSet {
            worker?.updateTimeWeighting(timeWeighting)
        }
    }

    /// 回调节流间隔(秒)。两次回调间隔小于此值时丢弃中间帧。
    public let throttleInterval: TimeInterval

    // MARK: - 内部

    /// 在专用队列上跑的测量 worker(非隔离,只通过 meterQueue 访问)
    private var worker: MeterWorker?
    private let engine = AVAudioEngine()
    /// 标记 tap 是否已安装(installTap 重复装会抛异常)
    private var tapInstalled = false
    /// 活跃输入采样率(tap 安装时确定;录音器据此设计降采样)
    public private(set) var activeSampleRate: Float = 48000
    /// 样本挂点:录音器等外部消费者由此收到与测量同源的 PCM 分块
    private let sinkBox = SampleSinkBox()
    #if os(macOS)
    /// 当前绑定到 inputNode 的设备 ID(nil = 从未显式绑定,跟随系统默认)。
    /// 自己记账而不反问 AUAudioUnit:避免依赖可读性不确定的 API,且切换失败回滚要用。
    private var activeInputDeviceID: AudioDeviceID?
    #endif

    // MARK: - 初始化

    /// 创建引擎。
    /// - Parameters:
    ///   - calibrationOffset: 校准偏移量(dB),用于 dBFS→SPL 转换。
    ///   - throttleInterval: 回调节流间隔。iOS 建议 0.06(约 16fps),watchOS 建议 0.2(省电)。
    ///   - fftSize: FFT 点数,默认 4096(与核心算法一致)。
    public init(calibrationOffset: Float = 0,
                throttleInterval: TimeInterval = 0.06,
                fftSize: Int = 4096,
                weighting: Weighting = .a,
                timeWeighting: TimeWeighting = .fast) {
        self.calibrationOffset = calibrationOffset
        self.throttleInterval = throttleInterval
        self.weighting = weighting
        self.timeWeighting = timeWeighting
        self.worker = MeterWorker(fftSize: fftSize,
                                  throttleInterval: throttleInterval,
                                  calibrationOffset: calibrationOffset,
                                  weighting: weighting,
                                  timeWeighting: timeWeighting) { [weak self] result in
            // worker 回调发生在 meterQueue 上;切回主线程更新状态
            Task { @MainActor in
                self?.latestResult = result
            }
        }
        #if os(macOS)
        // macOS:授权由 engine.start() 触发系统弹窗处理,这里默认 false。
        // start() 会调用 requestPermission()(macOS 直接返回 true),不卡。
        self.permissionGranted = false
        #else
        self.permissionGranted = AVAudioSession.sharedInstance().recordPermission == .granted
        #endif
    }

    // MARK: - 权限

    /// 请求麦克风权限(异步)。
    public func requestPermission() async -> Bool {
        guard !permissionGranted else { return true }
        #if os(macOS)
        // macOS:不调前置请求 API(AVAudioApplication.requestRecordPermission 需要
        // macOS 14.2+ 且行为不稳,容易卡住)。直接返回 true,让 engine.start()/
        // installTap 触发系统级授权弹窗。权限被拒时 start() 会抛错,catch 里置 failed。
        // 首次授权成功后,系统记住权限,后续 start() 不再弹窗。
        permissionGranted = true
        return true
        #else
        let granted = await withCheckedContinuation { continuation in
            AVAudioSession.sharedInstance().requestRecordPermission { allowed in
                continuation.resume(returning: allowed)
            }
        }
        permissionGranted = granted
        return granted
        #endif
    }

    // MARK: - 启动 / 停止

    /// 启动采集。
    public func start() async {
        // 防重入:已在运行/启动中则直接返回
        if state == .running || state == .starting { return }

        state = .starting

        // 1. 权限
        let granted = await requestPermission()
        if !granted {
            state = .denied
            return
        }

        // 2. 配置 + 启动
        // 注意:不在主线程同步调 engine.prepare()(@MainActor 上会死锁,
        // prepare 内部会 dispatch 到主线程同步执行)。直接 start() 即可,
        // macOS 上 AVAudioEngine 不需要显式 prepare。
        do {
            try configureSession()
            try installTapIfNeeded()
            try engine.start()
            state = .running
        } catch {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
            state = .failed(error.localizedDescription)
        }
    }

    /// 停止采集。
    public func stop() {
        engine.inputNode.removeTap(onBus: 0)
        tapInstalled = false
        engine.stop()
        #if !os(macOS)
        // macOS 无 AVAudioSession
        try? AVAudioSession.sharedInstance().setActive(false,
                                                        options: [.notifyOthersOnDeactivation])
        #endif
        sinkBox.set(nil)
        worker?.reset()
        latestResult = nil
        state = .stopped
    }

    // MARK: - 输入设备切换(仅 macOS)

    #if os(macOS)
    /// 切换输入设备。
    ///
    /// - Parameters:
    ///   - deviceID: 目标设备的 AudioDeviceID;nil 表示跟随系统默认。
    ///   - uid: 目标设备的 UID,用于对外展示与校准值记账。
    ///
    /// 严格顺序(方案文档坑 2,一步都不能少):
    /// 运行中先摘 tap → 停引擎 → setDeviceID → 用新 format 重装 tap → 重启。
    /// 切设备后 inputNode 的 format 不会自动更新,直接重装 tap 会因采样率/通道数
    /// 与硬件不匹配而崩溃;installTapIfNeeded 已改为优先读 inputFormat(forBus: 0) 规避,
    /// 且其中 worker.updateSampleRate 会随重装自动执行(A 计权频率映射依赖正确采样率)。
    public func setInputDevice(_ deviceID: AudioDeviceID?, uid: String?) async {
        let wasRunning = (state == .running)
        let previousDeviceID = activeInputDeviceID
        let previousUID = activeInputDeviceUID

        // AUAudioUnit 没有「解除绑定、回到系统默认」的 API。
        // 目标是系统默认时,显式解析为当前默认设备再绑定;语义上仍是跟随系统
        // (系统默认再变化时,由上层监听设备列表兜底回退)。
        var targetDeviceID = deviceID
        if targetDeviceID == nil, activeInputDeviceID != nil {
            targetDeviceID = Self.systemDefaultInputDeviceID()
        }

        // 从未绑定过设备且目标仍是系统默认:无需任何重配,只更新记账
        guard targetDeviceID != nil || activeInputDeviceID != nil else {
            activeInputDeviceUID = uid
            return
        }

        if wasRunning {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
            engine.stop()
        }

        do {
            if let target = targetDeviceID, target != previousDeviceID {
                try engine.inputNode.auAudioUnit.setDeviceID(target)
            }
            activeInputDeviceID = targetDeviceID ?? previousDeviceID
            activeInputDeviceUID = uid

            if wasRunning {
                try installTapIfNeeded()
                try engine.start()
                state = .running
            }
        } catch {
            // 切换失败:尽力回滚到切换前的绑定,让测量链路尽可能继续可用
            if let previousDeviceID = previousDeviceID {
                try? engine.inputNode.auAudioUnit.setDeviceID(previousDeviceID)
            }
            activeInputDeviceID = previousDeviceID
            activeInputDeviceUID = previousUID
            if wasRunning {
                do {
                    try installTapIfNeeded()
                    try engine.start()
                    state = .running
                } catch {
                    // 回滚也失败:摘掉 tap,明确报失败,避免留下半配置的引擎
                    engine.inputNode.removeTap(onBus: 0)
                    tapInstalled = false
                    state = .failed(error.localizedDescription)
                }
            } else {
                state = .failed(error.localizedDescription)
            }
        }
    }

    /// 查询系统默认输入设备 ID(CoreAudio)
    private static func systemDefaultInputDeviceID() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                         &address, 0, nil, &size, &deviceID) == noErr,
              deviceID > 0 else { return nil }
        return deviceID
    }
    #endif

    // MARK: - 样本挂点

    /// 设置/清除样本挂点(线程安全;tap 在音频线程每帧调用)
    public func setSampleSink(_ sink: (@Sendable ([Float]) -> Void)?) {
        sinkBox.set(sink)
    }

    // MARK: - 内部实现

    private func configureSession() throws {
        #if os(macOS)
        // macOS 没有 AVAudioSession,无需配置。AVAudioEngine 可直接启动。
        // (macOS 上 engine.start() 会触发系统级麦克风授权弹窗)
        #else
        let session = AVAudioSession.sharedInstance()
        // .measurement 尽量关闭 AGC/高通,保证测量精度(与 macOS LiveMeter 一致)
        // 选项按平台区分:watchOS 不支持 defaultToSpeaker;allowBluetooth 在 watchOS 11+ 才有。
        try session.setCategory(.playAndRecord,
                                mode: .measurement,
                                options: platformCategoryOptions())
        try session.setActive(true, options: [])
        #endif
    }

    /// 按 platform 返回合法的 category options(仅 iOS/watchOS 用,macOS 不调用此函数)
    #if !os(macOS)
    private func platformCategoryOptions() -> AVAudioSession.CategoryOptions {
        #if os(watchOS)
        // watchOS:defaultToSpeaker 和 allowBluetooth 都不可用或受限。
        // 测分贝只需要麦克风输入,用空 options 最稳,跨 SDK 版本兼容。
        return []
        #else
        // iOS
        return [.allowBluetooth, .defaultToSpeaker]
        #endif
    }
    #endif

    private func installTapIfNeeded() throws {
        let inputNode = engine.inputNode

        #if os(macOS)
        // macOS:切设备后 outputFormat 与 inputFormat 可能不同步,且 outputFormat
        // 可能拿到 0 通道(方案文档坑 2)。优先 inputFormat(forBus: 0) —— 它反映
        // 输入硬件的实际格式;非法(0 采样率/0 通道)时回退 outputFormat。
        // 未切设备时两者一致,行为与原来相同。
        let hwFormat = inputNode.inputFormat(forBus: 0)
        let format = (hwFormat.sampleRate > 0 && hwFormat.channelCount > 0)
                     ? hwFormat : inputNode.outputFormat(forBus: 0)
        #else
        // iOS / watchOS:沿用 outputFormat,行为完全不变
        let format = inputNode.outputFormat(forBus: 0)
        #endif

        // 若 format 采样率不合法(占位值),用 48000 兜底。
        let sampleRate = (format.sampleRate > 0 && format.sampleRate.isFinite)
                         ? Float(format.sampleRate) : 48000
        worker?.updateSampleRate(sampleRate)
        activeSampleRate = sampleRate

        // 防御性移除旧 tap(installTap 重复装会抛 "tap already installed")。
        inputNode.removeTap(onBus: 0)

        let tapFormat = format.sampleRate > 0 ? format : nil
        let bufferSize = AVAudioFrameCount(worker!.fftSize)
        inputNode.installTap(onBus: 0, bufferSize: bufferSize, format: tapFormat) { [weak self] buffer, _ in
            guard let self = self else { return }
            guard let channelData = buffer.floatChannelData?[0] else { return }
            let frameLength = Int(buffer.frameLength)
            let samples = Array(UnsafeBufferPointer(start: channelData, count: frameLength))
            self.sinkBox.deliver(samples)
            self.worker?.enqueue(samples)
        }
        tapInstalled = true
    }

    deinit {
        // deinit 不能在 @MainActor 上安全操作 engine;调用方应在视图销毁前 stop()。
        // 这里只做尽力清理。
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }
}

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

// MARK: - MeterWorker(非隔离,在专用队列上工作)

/// 样本处理 worker。所有可变状态(`sampleBuffer`、`meter`、`lastCallbackTime`)
/// 都只在 `meterQueue` 上访问,因此对它是线程安全的。
private final class MeterWorker: @unchecked Sendable {

    let fftSize: Int
    let throttleInterval: TimeInterval
    private let callback: (MeterResult) -> Void

    private let meterQueue = DispatchQueue(label: "com.dinghao.soundsense.meter", qos: .userInitiated)
    private var meter: DBMeter
    private var sampleBuffer: [Float] = []
    private var lastCallbackTime: CFTimeInterval = 0
    // 当前 meter 的构建参数(rebuild 用)
    private var currentSampleRate: Float
    private var currentOffset: Float
    private var currentWeighting: Weighting
    private var currentTimeWeighting: TimeWeighting

    init(fftSize: Int,
         throttleInterval: TimeInterval,
         calibrationOffset: Float,
         weighting: Weighting,
         timeWeighting: TimeWeighting = .fast,
         callback: @escaping (MeterResult) -> Void) {
        self.fftSize = fftSize
        self.throttleInterval = throttleInterval
        self.callback = callback
        self.currentSampleRate = 48000
        self.currentOffset = calibrationOffset
        self.currentWeighting = weighting
        self.currentTimeWeighting = timeWeighting
        self.meter = DBMeter(config: MeterConfig(sampleRate: 48000,
                                                  fftSize: fftSize,
                                                  calibrationOffset: calibrationOffset,
                                                  weighting: weighting,
                                                  timeWeighting: timeWeighting))
    }

    /// 投递一批样本(可从任意线程调用)
    func enqueue(_ samples: [Float]) {
        meterQueue.async { [weak self] in
            self?.process(samples)
        }
    }

    /// 在 meterQueue 上按当前参数重建 meter
    private func rebuildMeter() {
        meter = DBMeter(config: MeterConfig(sampleRate: currentSampleRate,
                                            fftSize: fftSize,
                                            calibrationOffset: currentOffset,
                                            weighting: currentWeighting,
                                            timeWeighting: currentTimeWeighting))
    }

    /// 更新采样率(下次处理前生效)
    func updateSampleRate(_ sampleRate: Float) {
        meterQueue.async { [weak self] in
            guard let self = self else { return }
            self.currentSampleRate = sampleRate
            self.rebuildMeter()
        }
    }

    /// 更新校准偏移量
    func updateCalibration(_ offset: Float) {
        meterQueue.async { [weak self] in
            guard let self = self else { return }
            self.currentOffset = offset
            self.rebuildMeter()
        }
    }

    /// 更新频率计权(A/C)
    func updateWeighting(_ weighting: Weighting) {
        meterQueue.async { [weak self] in
            guard let self = self else { return }
            self.currentWeighting = weighting
            self.rebuildMeter()
        }
    }

    /// 更新时间计权(F/S)
    func updateTimeWeighting(_ timeWeighting: TimeWeighting) {
        meterQueue.async { [weak self] in
            guard let self = self else { return }
            self.currentTimeWeighting = timeWeighting
            self.rebuildMeter()
        }
    }

    /// 清空缓冲
    func reset() {
        meterQueue.async { [weak self] in
            guard let self = self else { return }
            self.sampleBuffer.removeAll(keepingCapacity: true)
            self.lastCallbackTime = 0
            self.meter.resetDetector()
            self.meter.resetLeq()
        }
    }

    private var processCount = 0

    /// 在 meterQueue 上执行(私有,只通过 meterQueue.async 调用)
    private func process(_ incoming: [Float]) {
        sampleBuffer.append(contentsOf: incoming)

        // 防御:队列积压(处理不过来)时丢最旧数据,保证缓冲不无界增长。
        // 正常路径由下方 while 循环按 50% 重叠推进排空。
        if sampleBuffer.count > fftSize * 4 {
            sampleBuffer.removeFirst(sampleBuffer.count - fftSize)
        }

        // 50% 重叠推进:每凑满一个窗处理一次,窗口推进 fftSize/2。
        // (旧实现每 tap 只处理一次且每次只移除半个窗,数据会越积越多,
        //  积到上限又被整块丢弃 —— 两边都造成读数失真。)
        let hop = fftSize / 2
        var lastResult: MeterResult?
        while sampleBuffer.count >= fftSize {
            let frame = Array(sampleBuffer.prefix(fftSize))
            lastResult = meter.process(frame, hopSamples: hop)
            sampleBuffer.removeFirst(hop)
            processCount += 1
        }

        guard let result = lastResult else { return }

        // 节流
        let now = Date.timeIntervalSinceReferenceDate
        if now - lastCallbackTime < throttleInterval {
            return
        }
        lastCallbackTime = now

        callback(result)
    }
}

// MARK: - 校准默认值(dBFS → SPL 偏移)

/// dBFS→SPL 校准默认值与旧默认迁移(三端共用,Foundation only)。
///
/// 原理:数字 MEMS 麦克风行业惯例(Analog Devices/Knowles/Infineon 规格书),
/// 94 dB SPL @ 1 kHz 正弦对应 -26 dBFS(峰值参考)≈ -29 dBFS(RMS 参考;
/// 本工程 dBFS 用 vDSP_rmsqv,即 RMS 参考)。由此
///   SPL ≈ dBFS(RMS) + 120~123
/// 真机实测(Empa 2015 报告 / Faber SoundMeter 出厂灵敏度)落在约 117~126 dB,
/// 离散约 ±6 dB。旧默认 +93 比真实值低约 30 dB,正是"A 计权环境噪音只有
/// 个位数"的根因。任何预设都只是开箱估计 —— 精确值必须用设置页的
/// 校准向导对照标准声级计(或 94 dB 声校准器)实测。
public enum CalibrationDefaults {

    /// iOS 内建麦克风典型值
    public static let iosBuiltIn: Float = 120
    /// 外接/耳机麦克风:灵敏度离散极大,此值仅为开箱占位,务必校准
    public static let external: Float = 90
    /// Mac 内建麦克风(无公开实测数据,按同类 MEMS 保守估计)
    public static let macBuiltIn: Float = 100
    /// Apple Watch 内建麦克风(同上)
    public static let watchBuiltIn: Float = 115

    private static let offsetKey = "calibrationOffset"
    private static let migratedKey = "calibrationMigratedV2"

    /// 读取生效偏移量。
    /// 兼容迁移:旧版本默认 +93(无依据估计)。从未手动改过且仍等于 93 的
    /// 安装,自动升级到平台新默认;手动改过的值原样保留。
    public static func resolved(platformDefault: Float,
                                defaults: UserDefaults = .standard) -> Float {
        guard defaults.object(forKey: offsetKey) != nil else { return platformDefault }
        defer { defaults.set(true, forKey: migratedKey) }
        let value = Float(defaults.double(forKey: offsetKey))
        guard !defaults.bool(forKey: migratedKey), value == 93 else { return value }
        return platformDefault
    }
}

#endif
