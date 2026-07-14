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

#if os(iOS) || os(watchOS)

import Foundation
import AVFoundation
import SoundSenseCore
import SwiftUI

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

    // MARK: - 配置

    /// 校准偏移量(dB)。改动会立即在 worker 里重建 DBMeter。
    public var calibrationOffset: Float {
        didSet {
            worker?.updateCalibration(calibrationOffset)
        }
    }

    /// 回调节流间隔(秒)。两次回调间隔小于此值时丢弃中间帧。
    public let throttleInterval: TimeInterval

    // MARK: - 内部

    /// 在专用队列上跑的测量 worker(非隔离,只通过 meterQueue 访问)
    private var worker: MeterWorker?
    private let engine = AVAudioEngine()

    // MARK: - 初始化

    /// 创建引擎。
    /// - Parameters:
    ///   - calibrationOffset: 校准偏移量(dB),用于 dBFS→SPL 转换。
    ///   - throttleInterval: 回调节流间隔。iOS 建议 0.06(约 16fps),watchOS 建议 0.2(省电)。
    ///   - fftSize: FFT 点数,默认 4096(与核心算法一致)。
    public init(calibrationOffset: Float = 0,
                throttleInterval: TimeInterval = 0.06,
                fftSize: Int = 4096) {
        self.calibrationOffset = calibrationOffset
        self.throttleInterval = throttleInterval
        self.worker = MeterWorker(fftSize: fftSize,
                                  throttleInterval: throttleInterval,
                                  calibrationOffset: calibrationOffset) { [weak self] result in
            // worker 回调发生在 meterQueue 上;切回主线程更新状态
            Task { @MainActor in
                self?.latestResult = result
            }
        }
        self.permissionGranted = AVAudioSession.sharedInstance().recordPermission == .granted
    }

    // MARK: - 权限

    /// 请求麦克风权限(异步)。
    public func requestPermission() async -> Bool {
        guard !permissionGranted else { return true }
        let granted = await withCheckedContinuation { continuation in
            AVAudioSession.sharedInstance().requestRecordPermission { allowed in
                continuation.resume(returning: allowed)
            }
        }
        permissionGranted = granted
        return granted
    }

    // MARK: - 启动 / 停止

    /// 启动采集。
    public func start() async {
        guard state != .running, state != .starting else { return }

        if !permissionGranted {
            state = .starting
            let ok = await requestPermission()
            if !ok {
                state = .denied
                return
            }
        }

        state = .starting
        do {
            try configureSession()
            try installTapIfNeeded()
            try engine.start()
            state = .running
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    /// 停止采集。
    public func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        try? AVAudioSession.sharedInstance().setActive(false,
                                                        options: [.notifyOthersOnDeactivation])
        worker?.reset()
        state = .stopped
    }

    // MARK: - 内部实现

    private func configureSession() throws {
        let session = AVAudioSession.sharedInstance()
        // .measurement 尽量关闭 AGC/高通,保证测量精度(与 macOS LiveMeter 一致)
        // 选项按平台区分:watchOS 不支持 defaultToSpeaker;allowBluetooth 在 watchOS 11+ 才有。
        try session.setCategory(.playAndRecord,
                                mode: .measurement,
                                options: platformCategoryOptions())
        try session.setActive(true, options: [])
    }

    /// 按 platform 返回合法的 category options
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

    private func installTapIfNeeded() throws {
        let inputNode = engine.inputNode
        let format = inputNode.outputFormat(forBus: 0)

        // 采样率变化时通知 worker 重建 DBMeter
        worker?.updateSampleRate(Float(format.sampleRate))

        let bufferSize = AVAudioFrameCount(worker!.fftSize)
        // installTap 重复装会崩;这里 stop() 已 remove,正常情况下不会重复。
        // 但为防御,用 do/catch 包一层。
        inputNode.installTap(onBus: 0, bufferSize: bufferSize, format: format) { [weak self] buffer, _ in
            guard let self = self else { return }
            guard let channelData = buffer.floatChannelData?[0] else { return }
            let frameLength = Int(buffer.frameLength)
            // 复制到可控 buffer(installTap 回调里的 buffer 会被复用)
            let samples = Array(UnsafeBufferPointer(start: channelData, count: frameLength))
            // 跨 actor 投递样本:worker 自身在 meterQueue 上串行处理,线程安全
            self.worker?.enqueue(samples)
        }
    }

    deinit {
        // deinit 不能在 @MainActor 上安全操作 engine;调用方应在视图销毁前 stop()。
        // 这里只做尽力清理。
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
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

    init(fftSize: Int,
         throttleInterval: TimeInterval,
         calibrationOffset: Float,
         callback: @escaping (MeterResult) -> Void) {
        self.fftSize = fftSize
        self.throttleInterval = throttleInterval
        self.callback = callback
        self.meter = DBMeter(config: MeterConfig(sampleRate: 48000,
                                                  fftSize: fftSize,
                                                  calibrationOffset: calibrationOffset))
    }

    /// 投递一批样本(可从任意线程调用)
    func enqueue(_ samples: [Float]) {
        meterQueue.async { [weak self] in
            self?.process(samples)
        }
    }

    /// 更新采样率(下次处理前生效)
    func updateSampleRate(_ sampleRate: Float) {
        meterQueue.async { [weak self] in
            guard let self = self else { return }
            // 重建 meter(保留当前 offset)
            self.meter = DBMeter(config: MeterConfig(sampleRate: sampleRate,
                                                      fftSize: self.fftSize,
                                                      calibrationOffset: self.meter.config.calibrationOffset))
        }
    }

    /// 更新校准偏移量
    func updateCalibration(_ offset: Float) {
        meterQueue.async { [weak self] in
            guard let self = self else { return }
            self.meter = DBMeter(config: MeterConfig(sampleRate: self.meter.config.sampleRate,
                                                      fftSize: self.fftSize,
                                                      calibrationOffset: offset))
        }
    }

    /// 清空缓冲
    func reset() {
        meterQueue.async { [weak self] in
            self?.sampleBuffer.removeAll(keepingCapacity: true)
            self?.lastCallbackTime = 0
        }
    }

    /// 在 meterQueue 上执行(私有,只通过 meterQueue.async 调用)
    private func process(_ incoming: [Float]) {
        sampleBuffer.append(contentsOf: incoming)
        // 限制缓冲上限,避免内存增长
        if sampleBuffer.count > fftSize * 2 {
            sampleBuffer.removeFirst(sampleBuffer.count - fftSize)
        }
        guard sampleBuffer.count >= fftSize else { return }

        // 取前 fftSize 个样本处理
        let frame = Array(sampleBuffer.prefix(fftSize))
        // 滑窗:丢弃一半,实现 50% 重叠(更平滑)
        sampleBuffer.removeFirst(fftSize / 2)

        guard let result = meter.process(frame) else { return }

        // 节流(用 Date 计时,跨平台;CACurrentMediaTime 在 watchOS 不可用)
        let now = Date.timeIntervalSinceReferenceDate
        if now - lastCallbackTime < throttleInterval {
            return
        }
        lastCallbackTime = now

        callback(result)
    }
}

#endif
