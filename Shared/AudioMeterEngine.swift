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
// CoreAudio:macOS 输入设备切换与无设备预检
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
    /// 授权请求进行中。防止快速连点“开始”并发触发多个系统权限弹窗。
    private var isRequestingPermission = false
    /// 本次 App 运行是否已经主动请求过麦克风权限。
    /// 某些 ad-hoc/未签名构建下 TCC 可能持续返回 notDetermined；若每次都请求，
    /// 用户会看到反复弹窗。每次运行最多请求一次，后续引导用户去系统设置。
    private var didAttemptPermissionThisLaunch = false
    #if os(macOS)
    /// 当前生效输入设备的 UID(nil = 跟随系统默认)。仅 macOS 支持选源。
    @Published public private(set) var activeInputDeviceUID: String?
    #endif

    // MARK: - 配置

    /// 校准偏移量(dB)。改动会立即同步到 worker;本次测量的 Leq/峰值
    /// 都基于同一标定,运行中微调不会把历史数据清零。
    public var calibrationOffset: Float {
        didSet {
            worker?.updateCalibration(calibrationOffset)
        }
    }

    /// 频率计权方式(A/C)。
    /// 为防止同一场报告混用 A/C 数据,测量运行中不允许切换;
    /// 调用方应先 stop(),切换后再 start()。
    public var weighting: Weighting {
        get { storedWeighting }
        set {
            guard newValue != storedWeighting else { return }
            guard state != .running && state != .starting else { return }
            storedWeighting = newValue
            worker?.updateWeighting(newValue)
        }
    }

    /// 时间计权方式(F/S, IEC 61672)。
    /// 当前峰值指标随 F/S 改变(LAFmax/LASmax),同样要求停止后切换。
    public var timeWeighting: TimeWeighting {
        get { storedTimeWeighting }
        set {
            guard newValue != storedTimeWeighting else { return }
            guard state != .running && state != .starting else { return }
            storedTimeWeighting = newValue
            worker?.updateTimeWeighting(newValue)
        }
    }

    /// 回调节流间隔(秒)。两次 UI 回调间隔小于此值时丢弃中间帧。
    /// 注意:节流只影响刷新频率,不影响测量统计;worker 会在每次回调时携带
    /// 全部已处理帧的 Leq 与峰值。
    public let throttleInterval: TimeInterval
    /// stop() 的“冻结采集 -> 读取最终统计 -> 完成清理”两阶段标记。
    private var isFinalizing = false
    /// 每场测量的回调代次,用于丢弃上一场排在主线程队列里的迟到结果。
    private let callbackGeneration: CallbackGenerationBox

    /// 本次 AudioMeterEngine 会话处理过的全部帧中的最高时间计权 SPL。
    /// 由 worker 在节流之前累计,因此 UI 掉帧或节流不会漏掉短峰值。
    /// start()/stop() 会清零。
    @Published public private(set) var sessionPeakSPL: Float = -.greatestFiniteMagnitude
    /// 本次会话最近一帧对应的核心 Leq(按核心 hop 能量积分,覆盖全部帧)。
    @Published public private(set) var sessionLeqSPL: Float = -.greatestFiniteMagnitude
    /// 本次会话 Leq 实际覆盖时长(秒),可用于确认统计没有因节流而缩短。
    @Published public private(set) var sessionLeqDuration: TimeInterval = 0
    /// 本次会话因处理队列积压而丢弃的样本数。0 才表示报告覆盖全部采集数据。
    @Published public private(set) var sessionDroppedSampleCount = 0
    /// 最近一次由分析队列交付的结果。与 `latestResult` 不同，它不节流，
    /// 仅用于后台/测试观察；UI 仍应使用节流后的 `latestResult`。
    public private(set) var latestAnalysisResult: MeterResult?
    /// 音频链路是否发生过中断/重配，但随后已自动恢复。
    /// 调用方应把它作为“本次统计不连续”的诊断，不应据此清空已测数据。
    @Published public private(set) var didRecoverAudioRoute = false
    /// 音频采集因系统中断/设备重配而暂停时给 UI 的说明。
    @Published public private(set) var audioRecoveryNote: String?
    /// 是否真正跨越过一次音频中断/路由重配。用于事件时间轴和报告的
    /// 完整性说明，不能用墙钟去伪造中断期间的声级。
    @Published public private(set) var audioDiscontinuityCount = 0
    /// 音频时钟累计被中断/设备重配吞掉的墙钟时长(秒)。
    /// 事件时间轴用它校正，避免恢复后事件时间整体提前。
    @Published public private(set) var audioWallClockGap: TimeInterval = 0
    /// worker 已交付给分析消费者的累计音频时长。收尾时用它建立队列屏障，
    /// 确保最后一批分析结果已经落账再生成报告。
    @Published public private(set) var deliveredAnalysisDuration: TimeInterval = 0
    /// tap 实际收到第一帧/最后一帧的时间。报告据此扣除启动等待等空白。
    /// 音频线程直接写入线程安全盒子，避免每个 tap 向主线程投递一次 Task。
    private let captureTimeRangeBox = CaptureTimeRangeBox()
    // MARK: - 内部

    /// 在专用队列上跑的测量 worker(非隔离,只通过 meterQueue 访问)
    private var worker: MeterWorker?
    /// 整场会话是否计算 FFT 频谱。
    private let spectrumEnabled: Bool
    private let engine = AVAudioEngine()
    /// 标记 tap 是否已安装(installTap 重复装会抛异常)
    private var tapInstalled = false
    /// 活跃输入采样率(tap 安装时确定;录音器据此设计降采样)
    public private(set) var activeSampleRate: Float = 48000
    /// 样本挂点:录音器等外部消费者由此收到与测量同源的 PCM 分块
    private let sinkBox = SampleSinkBox()
    /// 不节流的 hop 分析挂点。长时间监听/方向测试的事件检测从这里消费，
    /// UI 仍只订阅节流后的 @Published 结果，二者互不影响。
    private let analysisSinkBox = AnalysisSinkBox()
    private var isStopping = false
    /// macOS 配置变化通知与手动切换设备共用同一把重入锁。
    private var isReconfiguringAudio = false
    /// 采集第一帧的墙钟锚点。音频 worker 只读取它，不读取 MainActor 状态。
    private let captureWallClockAnchor = WallClockAnchor()
    /// 音频时钟 → 墙钟映射。由 worker 在批次交付时写入，不依赖最终累计 gap。
    private let analysisClock = AnalysisClock()
    /// 通知令牌由独立对象持有；对象释放时会自动注销，避免 ViewModel
    /// 反复创建后残留观察者，也避开 @MainActor 类的 deinit 隔离限制。
    private let audioNotificationBag = AudioNotificationBag()
    #if os(macOS)
    /// 当前绑定到 inputNode 的设备 ID(nil = 从未显式绑定,跟随系统默认)。
    /// 自己记账而不反问 AUAudioUnit:避免依赖可读性不确定的 API,且切换失败回滚要用。
    private var activeInputDeviceID: AudioDeviceID?
    #endif
    /// 当前选中的 macOS 输入设备 UID。nil = 跟随系统默认。
    /// 该值只用于预检:即使尚未把设备绑定到 AUAudioUnit,也必须检查用户选中的设备。
    private var preferredInputDeviceUID: String?
    private var storedWeighting: Weighting
    private var storedTimeWeighting: TimeWeighting
    /// 非节流分析结果的轻量快照锁。MeterWorker 在后台队列写，
    /// 测试或诊断从主线程读。
    private let analysisSnapshotLock = NSLock()
    #if !os(macOS)
    private var isHandlingAudioInterruption = false
    private var shouldResumeAfterInterruption = false
    #endif
    /// 当前中断/重配开始时的墙钟锚点。
    private var audioGapStartedAt: Date?

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
                timeWeighting: TimeWeighting = .fast,
                inputDeviceUID: String? = nil,
                spectrumEnabled: Bool = true,
                lowBandAnalysisInterval: TimeInterval = 0.5) {
        self.calibrationOffset = calibrationOffset
        self.throttleInterval = throttleInterval
        self.spectrumEnabled = spectrumEnabled
        self.storedWeighting = weighting
        self.storedTimeWeighting = timeWeighting
        self.preferredInputDeviceUID = inputDeviceUID
        analysisSinkBox.resume()
        let callbackGeneration = CallbackGenerationBox()
        self.callbackGeneration = callbackGeneration
        self.worker = MeterWorker(fftSize: fftSize,
                                  throttleInterval: throttleInterval,
                                  calibrationOffset: calibrationOffset,
                                  weighting: weighting,
                                  timeWeighting: timeWeighting,
                                  spectrumEnabled: spectrumEnabled,
                                  lowBandAnalysisInterval: lowBandAnalysisInterval,
                                  analysisCallback: { _ in }) { [weak self] result, peak in
            // worker 回调发生在 meterQueue 上;切回主线程更新状态
            let generation = callbackGeneration.current
            Task { @MainActor [weak self] in
                guard let self = self,
                      self.callbackGeneration.current == generation,
                      self.state == .running || self.isFinalizing else { return }
                self.latestResult = result
                self.sessionPeakSPL = peak
                self.sessionLeqSPL = result.leqSPL
                self.sessionLeqDuration = result.leqDuration
                self.sessionDroppedSampleCount = result.totalDroppedSampleCount
            }
        }
        let analysisWorker = worker
        worker?.setAnalysisCallback { [weak self, weak analysisWorker] results in
            // 约 0.25 秒音频时钟一批，保留每个 hop，同时避免高频
            // 跨线程调度成为长时间监听的固定开销。
            guard let self, let analysisWorker, !results.isEmpty else { return }
            let generation = self.callbackGeneration.current
            guard self.callbackGeneration.current == generation else { return }
            self.analysisSinkBox.deliver(results)
            self.recordDeliveredAnalysis(results, worker: analysisWorker,
                                         generation: generation)
            if let last = results.last {
                self.storeLatestAnalysisResult(last)
            }
        }
    #if os(macOS)
        // 只查询，不触发系统弹窗；真正的请求只在用户点击“开始”后发生一次。
        self.permissionGranted =
            AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    #else
        self.permissionGranted = AVAudioSession.sharedInstance().recordPermission == .granted
        #endif
        installAudioNotifications()
    }

    /// 主界面预检用:当前是否存在可用输入设备。
    public var hasAudioInput: Bool {
        #if os(macOS)
        return Self.hasMacAudioInputDevice(uid: preferredInputDeviceUID)
        #else
        Self.hasAvailableAudioInput(engine.inputNode)
        #endif
    }

    // MARK: - 权限

    /// 请求麦克风权限(异步)。
    public func requestPermission() async -> Bool {
        #if os(macOS)
        // 显式管理 TCC 授权，避免 AVAudioEngine 在每次启动时隐式触发弹窗。
        // 每次都读取真实状态，避免系统设置中授权/撤销后仍使用旧缓存。
        // denied/restricted 直接返回，不重复弹；notDetermined 每次运行只请求一次。
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        permissionGranted = status == .authorized
        switch status {
        case .authorized:
            return true
        case .denied, .restricted:
            return false
        case .notDetermined:
            guard !didAttemptPermissionThisLaunch,
                  !isRequestingPermission else { return false }
            didAttemptPermissionThisLaunch = true
            isRequestingPermission = true
            defer { isRequestingPermission = false }
            let granted = await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .audio) { allowed in
                    continuation.resume(returning: allowed)
                }
            }
            permissionGranted = granted
            return granted
        @unknown default:
            return false
        }
        #else
        let status = AVAudioSession.sharedInstance().recordPermission
        permissionGranted = status == .granted
        switch status {
        case .granted:
            return true
        case .denied:
            return false
        case .undetermined:
            guard !didAttemptPermissionThisLaunch,
                  !isRequestingPermission else { return false }
            didAttemptPermissionThisLaunch = true
            isRequestingPermission = true
            defer { isRequestingPermission = false }
            let granted = await withCheckedContinuation { continuation in
                AVAudioSession.sharedInstance().requestRecordPermission { allowed in
                    continuation.resume(returning: allowed)
                }
            }
            permissionGranted = granted
            return granted
        @unknown default:
            return false
        }
        #endif
    }

    // MARK: - 启动 / 停止

    /// 主界面/菜单栏在发起启动前刷新设备可用性。若设备刚被拔出，必须让
    /// 状态明确落在“无输入设备”而不是继续停在待机，便于 UI 给出恢复入口。
    public func refreshInputAvailability() -> Bool {
        guard state != .running && state != .starting else {
            return hasAudioInput
        }
        let available = hasAudioInput
        if !available { state = .failed(Self.noInputDeviceMessage) }
        return available
    }

    /// 启动采集。
    public func start() async {
        // 防重入:已在运行/启动中则直接返回
        if state == .running || state == .starting { return }
        if !hasAudioObservers {
            installAudioNotifications()
        }

        // 开始新的测量时,先丢弃上一场尚未完成的收尾状态。
        isFinalizing = false
        callbackGeneration.bump()
        captureTimeRangeBox.reset()
        worker?.reset()
        state = .starting
        latestResult = nil
        sessionPeakSPL = -.greatestFiniteMagnitude
        sessionLeqSPL = -.greatestFiniteMagnitude
        sessionLeqDuration = 0
        sessionDroppedSampleCount = 0
        latestAnalysisResult = nil
        didRecoverAudioRoute = false
        audioRecoveryNote = nil
        audioDiscontinuityCount = 0
        audioWallClockGap = 0
        deliveredAnalysisDuration = 0
        analysisClock.reset(generation: callbackGeneration.current)
        captureWallClockAnchor.reset()

        // 1. macOS 先检查真实硬件。无麦克风时不应请求 TCC 权限，
        // 否则用户会看到一个根本不可能完成的系统授权弹窗。
        #if os(macOS)
        guard Self.hasMacAudioInputDevice(uid: preferredInputDeviceUID) else {
            state = .failed(Self.noInputDeviceMessage)
            return
        }
        #endif

        // 2. 权限
        let granted = await requestPermission()
        if !granted {
            state = .denied
            return
        }

        // 3. 输入设备预检。无麦克风时 inputNode.installTap 会抛 Objective-C
        // NSException,Swift 的 do/catch 接不住,进程会直接崩溃。
        // macOS 必须在访问 engine.inputNode 之前查询 CoreAudio 硬件设备:
        // 无设备时 inputNode 仍可能返回非零的占位格式。
        #if os(macOS)
        guard Self.hasMacAudioInputDevice(uid: preferredInputDeviceUID) else {
            state = .failed(Self.noInputDeviceMessage)
            return
        }
        #else
        guard Self.hasAvailableAudioInput(engine.inputNode) else {
            state = .failed(Self.noInputDeviceMessage)
            return
        }
        #endif

        // 4. 配置 + 启动
        // 注意:不在主线程同步调 engine.prepare()(@MainActor 上会死锁,
        // prepare 内部会 dispatch 到主线程同步执行)。直接 start() 即可,
        // macOS 上 AVAudioEngine 不需要显式 prepare。
        do {
            try configureSession()
            #if os(macOS)
            try bindPreferredInputDeviceBeforeStart()
            #endif
            try installTapIfNeeded()
            try engine.start()
            state = .running
        } catch {
            if tapInstalled {
                engine.inputNode.removeTap(onBus: 0)
                tapInstalled = false
            }
            state = .failed(error.localizedDescription)
        }
    }

    /// 停止采集。
    public func stop() {
        // 收尾有两个入口：界面的停止按钮和视图消失时的兜底。后者可能
        // 由动画驱动重入；重复 removeTap/engine.stop 会让 AVAudioEngine
        // 在 macOS 上进入不可恢复状态。
        guard !isStopping else { return }
        isStopping = true
        defer { isStopping = false }
        callbackGeneration.bump()
        removeTapAndStopHardware()
        #if !os(macOS)
        // macOS 无 AVAudioSession
        try? AVAudioSession.sharedInstance().setActive(false,
                                                        options: [.notifyOthersOnDeactivation])
        #endif
        sinkBox.set(nil)
        analysisSinkBox.set(nil)
        worker?.reset()
        deliveredAnalysisDuration = 0
        analysisClock.reset(generation: callbackGeneration.current)
        latestResult = nil
        sessionPeakSPL = -.greatestFiniteMagnitude
        sessionLeqSPL = -.greatestFiniteMagnitude
        sessionLeqDuration = 0
        sessionDroppedSampleCount = 0
        latestAnalysisResult = nil
        didRecoverAudioRoute = false
        audioRecoveryNote = nil
        audioDiscontinuityCount = 0
        audioWallClockGap = 0
        audioGapStartedAt = nil
        state = .stopped
    }

    /// 视图/ViewModel 释放前调用，主动注销系统通知，避免反复进入页面时
    /// NotificationCenter 累积闭包和观察者令牌。
    public func tearDown() {
        stop()
        tearDownAudioNotifications()
    }

    /// 仅注销系统通知，不主动停止当前采集。下一次 start() 会重新安装。
    public func releaseSystemObservers() {
        tearDownAudioNotifications()
    }

    /// 停止但不丢弃 worker 中已采集的尾样本。监听停止按钮必须走这条路径，
    /// 再由调用方读取最终统计并调用 finishFinalization()。
    public func stopAndDrain() async -> Bool {
        await freezeForFinalization()
    }

    /// 冻结采集,等待 meter worker 处理完已入队的音频块。
    ///
    /// 报告收尾顺序:freezeForFinalization() -> 读取最终统计 -> finishFinalization()。
    /// 这样最后一批已采集但尚未处理的样本不会丢失,也不会因 UI 节流漏掉
    /// 最高的时间计权峰值。
    /// - Returns: 本次会话是否至少处理过一帧。
    @discardableResult
    public func freezeForFinalization() async -> Bool {
        let wasRunning = state == .running || state == .starting
        if !wasRunning {
            // 系统中断恢复失败时，监听页仍可停止并保存已完成的统计；
            // worker 中已有的 Leq/峰值不能被“状态已不是 running”吞掉。
            let canFinalizeStoppedSession: Bool
            switch state {
            case .stopped, .failed:
                canFinalizeStoppedSession = true
            default:
                canFinalizeStoppedSession = false
            }
            guard canFinalizeStoppedSession, !isFinalizing else { return false }
            isFinalizing = true
            let finalAnalysis = await worker?.drainAndFlush()
            if let snapshot = finalAnalysis {
                latestResult = snapshot.result
                sessionPeakSPL = snapshot.peak
                sessionLeqSPL = snapshot.result.leqSPL
                sessionLeqDuration = snapshot.result.leqDuration
                sessionDroppedSampleCount = snapshot.result.totalDroppedSampleCount
            }
            // 恢复失败/系统中断后的会话也可能有未消费的尾批；先等分析
            // 序列完整落账，再断开 sink。
            _ = await waitForAnalysisDrain()
            analysisSinkBox.set(nil)
            return latestResult != nil
        }
        // 音频线程上的时间戳更新通过 Task 回主线程；先把已排队的更新执行完，
        // 才能确定真实采集起点/终点。freeze 本身在 MainActor，await 会让出执行权。
        await Task.yield()
        removeTapAndStopHardware()
        sinkBox.set(nil)
        isFinalizing = true
        let finalAnalysis = await worker?.drainAndFlush()
        // 关键顺序:先排空 worker，再把最终 tail 交付给分析消费者，
        // 最后才断开分析挂点。若先断开，最后不足一个 hop 的统计会丢。
        if let result = finalAnalysis?.analysisResult {
            // drainAndFlush 已通过批量分析回调交付尾帧；这里只补最新快照，
            // 不能再 deliver 一次，否则 ViewModel 会把同一个 hop 积分两遍。
            storeLatestAnalysisResult(result)
        }
        analysisSinkBox.pause()
        // 交付计数只会在同一条 meterQueue 上递增。等待它追上队列
        // barrier，可严格证明尾批已经越过分析 sink，而不是靠一次 yield。
        _ = await waitForAnalysisDrain()
        if let snapshot = finalAnalysis {
            // 必须在 freeze 返回前同步写回；不能再依赖一次异步 UI 回调，
            // 否则 ViewModel 可能在回调到达前就生成报告。
            callbackGeneration.bump()
            latestResult = snapshot.result
            sessionPeakSPL = snapshot.peak
            sessionLeqSPL = snapshot.result.leqSPL
            sessionLeqDuration = snapshot.result.leqDuration
            sessionDroppedSampleCount = snapshot.result.totalDroppedSampleCount
        }
        state = .stopped
        return latestResult != nil
    }

    /// 本次 tap 实际覆盖的时间范围。没有帧时返回 nil。
    public var captureTimeRange: ClosedRange<Date>? {
        captureTimeRangeBox.range
    }

    /// 结束冻结会话,清空本次测量的统计。
    /// 必须在读取最终统计并生成报告之后调用。
    public func finishFinalization() {
        guard isFinalizing else { return }
        callbackGeneration.bump()
        worker?.reset()
        analysisSinkBox.resume()
        latestResult = nil
        sessionPeakSPL = -.greatestFiniteMagnitude
        sessionLeqSPL = -.greatestFiniteMagnitude
        sessionLeqDuration = 0
        sessionDroppedSampleCount = 0
        latestAnalysisResult = nil
        deliveredAnalysisDuration = 0
        analysisClock.reset(generation: callbackGeneration.current)
        isFinalizing = false
        state = .stopped
    }

    /// 只摘 tap 并停硬件;不清空会话统计。
    private func removeTapAndStopHardware() {
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        engine.stop()
    }

    // MARK: - 系统音频中断 / 路由变化

    private func installAudioNotifications() {
        guard !hasAudioObservers else { return }
        var tokens: [NSObjectProtocol] = []
        #if !os(macOS)
        let center = NotificationCenter.default
        tokens.append(center.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] notification in
            Task { @MainActor in
                self?.handleInterruption(notification)
            }
        })
        tokens.append(center.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] notification in
            Task { @MainActor in
                self?.handleRouteChange(notification)
            }
        })
        #else
        let center = NotificationCenter.default
        tokens.append(center.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.recoverAfterConfigurationChange()
            }
        })
        #endif
        audioNotificationBag.replace(with: tokens)
    }

    private var hasAudioObservers: Bool {
        audioNotificationBag.isInstalled
    }

    private func tearDownAudioNotifications() {
        audioNotificationBag.removeAll()
    }

    #if !os(macOS)
    private func handleInterruption(_ notification: Notification) {
        guard let raw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        switch type {
        case .began:
            guard state == .running || state == .starting else { return }
            isHandlingAudioInterruption = true
            shouldResumeAfterInterruption = true
            audioGapStartedAt = captureTimeRangeBox.lastDate ?? Date()
            removeTapAndStopHardware()
            worker?.cancelPendingWork()
            audioDiscontinuityCount += 1
            audioRecoveryNote = "音频被系统中断，正在等待恢复；中断期间不计入连续统计。"
            state = .stopped
        case .ended:
            guard isHandlingAudioInterruption else { return }
            isHandlingAudioInterruption = false
            let optionsRaw = notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            let options = AVAudioSession.InterruptionOptions(rawValue: optionsRaw)
            guard shouldResumeAfterInterruption,
                  options.contains(.shouldResume) else {
                shouldResumeAfterInterruption = false
                audioRecoveryNote = "音频中断已结束，请手动重新开始测量。"
                return
            }
            shouldResumeAfterInterruption = false
            Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    try self.configureSession()
                    try self.installTapIfNeeded()
                    try self.engine.start()
                    self.accumulateAudioWallClockGap()
                    self.worker?.resumeAfterInterruption()
                    self.state = .running
                    self.didRecoverAudioRoute = true
                    self.audioRecoveryNote = "音频链路已自动恢复；中断时段不计入测量。"
                } catch {
                    self.audioRecoveryNote = "音频中断后恢复失败：\(error.localizedDescription)"
                    self.state = .failed(error.localizedDescription)
                }
            }
        @unknown default:
            break
        }
    }

    private func handleRouteChange(_ notification: Notification) {
        guard state == .running || state == .starting,
              let raw = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: raw) else { return }
        switch reason {
        case .oldDeviceUnavailable, .newDeviceAvailable, .override,
             .routeConfigurationChange, .categoryChange:
            restartCaptureAfterRouteChange()
        default:
            break
        }
    }

    private func restartCaptureAfterRouteChange() {
        guard !isHandlingAudioInterruption else { return }
        audioGapStartedAt = captureTimeRangeBox.lastDate ?? Date()
        removeTapAndStopHardware()
        worker?.cancelPendingWork()
        audioDiscontinuityCount += 1
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try self.configureSession()
                try self.installTapIfNeeded()
                try self.engine.start()
                self.accumulateAudioWallClockGap()
                self.worker?.resumeAfterInterruption()
                self.state = .running
                self.didRecoverAudioRoute = true
                self.audioRecoveryNote = "输入设备已切换，测量已自动恢复。"
            } catch {
                self.audioRecoveryNote = "输入设备切换后恢复失败：\(error.localizedDescription)"
                self.state = .failed(error.localizedDescription)
            }
        }
    }
    #else
    private func recoverAfterConfigurationChange() {
        guard state == .running || state == .starting else { return }
        guard !isReconfiguringAudio else { return }
        isReconfiguringAudio = true
        audioGapStartedAt = captureTimeRangeBox.lastDate ?? Date()
        removeTapAndStopHardware()
        worker?.cancelPendingWork()
        audioDiscontinuityCount += 1
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.isReconfiguringAudio = false }
            do {
                try self.installTapIfNeeded()
                try self.engine.start()
                self.accumulateAudioWallClockGap()
                self.worker?.resumeAfterInterruption()
                self.state = .running
                self.didRecoverAudioRoute = true
                self.audioRecoveryNote = "音频设备配置已变化，采集已自动恢复。"
            } catch {
                self.audioRecoveryNote = "音频重配后恢复失败：\(error.localizedDescription)"
                self.state = .failed(error.localizedDescription)
            }
        }
    }
    #endif

    /// 中断结束后累计墙钟损失。上限只用于防止系统时间跳变。
    private func accumulateAudioWallClockGap() {
        guard let start = audioGapStartedAt else { return }
        audioGapStartedAt = nil
        let gap = min(86_400, max(0, Date().timeIntervalSince(start)))
        if gap > 0 {
            audioWallClockGap += gap
        }
    }

    /// 将音频时钟位置映射到会话墙钟。映射断点由音频 worker 在批次交付时
    /// 记录，因此事件之后才发生的中断不会倒推影响更早的事件。
    public func wallClockDate(forAudioTime audioTime: TimeInterval,
                              duration: TimeInterval = 0) -> Date {
        analysisClock.wallClockDate(forAudioTime: audioTime, duration: duration,
                                    fallback: captureTimeRangeBox.firstDate ?? Date())
    }

    /// 记录一批结果交付时的音频/墙钟锚点，并推进可从主线程观察的屏障计数。
    private nonisolated func recordDeliveredAnalysis(
        _ results: [MeterResult],
        worker: MeterWorker,
        generation: UInt64
    ) {
        let batchDuration = results.reduce(0.0) {
            $0 + max(0, $1.coveredDuration)
        }
        let delivered = worker.deliveredAnalysisDuration + batchDuration
        worker.deliveredAnalysisDuration = delivered
        analysisClock.record(results: results,
                             deliveredDuration: delivered,
                             wallClock: captureWallClockAnchor.resolved(),
                             generation: generation)
        // 交付最终在 MainActor 上落账。这个回调与 sink 投递顺序一致，
        // 因此“计数器已追上”也意味着更早的分析批次已进入 ViewModel。
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            MainActor.assumeIsolated {
                guard self.callbackGeneration.current == generation else { return }
                self.deliveredAnalysisDuration = max(
                    self.deliveredAnalysisDuration, delivered)
            }
        }
    }

    /// worker 屏障返回后，继续让 MainActor 有机会接收交付计数。
    /// 正常情况下两三次让出即可；20 次仅用于极端卡顿时的有界兜底。
    private func waitForAnalysisDrain() async -> Bool {
        guard let worker else { return true }
        worker.barrier()
        let expected = worker.deliveredAnalysisDuration
        for _ in 0..<240 {
            if deliveredAnalysisDuration >= expected - 0.000_1 {
                return true
            }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        return deliveredAnalysisDuration >= expected - 0.000_1
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
        preferredInputDeviceUID = uid

        // 待机时只记录选择，不触碰 inputNode/AUAudioUnit。设备绑定推迟到
        // start() 且授权完成后，避免“仅切换输入源”就弹出麦克风权限。
        guard state == .running else {
            activeInputDeviceUID = uid
            return
        }

        // 与 AVAudioEngineConfigurationChange 的通知处理互斥。否则一次
        // 手动切换可能同时走“手动重配”和“配置变化恢复”，重复摘/装 tap。
        guard !isReconfiguringAudio else { return }
        isReconfiguringAudio = true
        defer { isReconfiguringAudio = false }

        // 上面已保证运行中，这里无需再次判断。
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

        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        engine.stop()

        do {
            if let target = targetDeviceID, target != previousDeviceID {
                try engine.inputNode.auAudioUnit.setDeviceID(target)
            }
            activeInputDeviceID = targetDeviceID ?? previousDeviceID
            activeInputDeviceUID = uid

            try installTapIfNeeded()
            try engine.start()
            state = .running
        } catch {
            // 切换失败:尽力回滚到切换前的绑定,让测量链路尽可能继续可用
            if let previousDeviceID = previousDeviceID {
                try? engine.inputNode.auAudioUnit.setDeviceID(previousDeviceID)
            }
            activeInputDeviceID = previousDeviceID
            activeInputDeviceUID = previousUID
            do {
                try installTapIfNeeded()
                try engine.start()
                state = .running
            } catch {
                // 回滚也失败:摘掉 tap,明确报失败,避免留下半配置的引擎
                if tapInstalled {
                    engine.inputNode.removeTap(onBus: 0)
                    tapInstalled = false
                }
                state = .failed(error.localizedDescription)
            }
        }
    }

    /// 在已获得麦克风授权后绑定待机时选择好的输入设备。
    /// 设备列表在待机期间可能变化，因此启动时重新按 UID 解析设备 ID。
    private func bindPreferredInputDeviceBeforeStart() throws {
        if let uid = preferredInputDeviceUID, !uid.isEmpty {
            guard let deviceID = Self.macInputDeviceID(forUID: uid),
                  Self.hasInputChannels(deviceID) else {
                throw AudioInputError.unavailable
            }
            try engine.inputNode.auAudioUnit.setDeviceID(deviceID)
            activeInputDeviceID = deviceID
            activeInputDeviceUID = uid
        } else if activeInputDeviceID != nil {
            // 从固定设备切回“跟随系统默认”时，绑定当前默认设备。
            guard let deviceID = Self.systemDefaultInputDeviceID(),
                  Self.hasInputChannels(deviceID) else {
                throw AudioInputError.unavailable
            }
            try engine.inputNode.auAudioUnit.setDeviceID(deviceID)
            activeInputDeviceID = deviceID
            activeInputDeviceUID = nil
        }
    }

    #endif

    // MARK: - 样本挂点

    /// 设置/清除样本挂点(线程安全;tap 在音频线程每帧调用)
    public func setSampleSink(_ sink: (@Sendable ([Float]) -> Void)?) {
        sinkBox.set(sink)
    }

    /// 设置完整 hop 分析回调。结果按约 0.25 秒音频时钟批量交付，
    /// 不丢帧但减少跨线程调度；回调运行在内部测量队列。
    public func setAnalysisSink(_ sink: (@Sendable ([MeterResult]) -> Void)?) {
        analysisSinkBox.set(sink)
    }

    /// 方向倾向测试切换点位时重置 F/S 显示检波器。
    /// 不触碰 Leq、主测量统计或滤波器历史，只避免上一点位的指数平均
    /// 拖尾进入下一点位。命令在 meterQueue 上按音频块顺序执行。
    public func resetDisplayDetectorForNewPosition() {
        worker?.resetDisplayDetector()
    }

    private func storeLatestAnalysisResult(_ result: MeterResult) {
        analysisSnapshotLock.lock()
        latestAnalysisResult = result
        analysisSnapshotLock.unlock()
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
        #if os(macOS)
        // 硬件可能在预检与安装 tap 之间被拔掉,安装前再确认一次。
        guard Self.hasMacAudioInputDevice(uid: preferredInputDeviceUID) else {
            throw AudioInputError.unavailable
        }
        #endif
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
        guard Self.hasAvailableAudioInput(inputNode) else {
            throw AudioInputError.unavailable
        }
        // 蓝牙耳机常以 HFP 低采样率输入并带系统自动增益,读数不可用于声压测量。
        // 这不是硬件缺失,但仍应阻止“能启动却严重失真”的场景。
        if let port = AVAudioSession.sharedInstance().currentRoute.inputs.first,
           port.portType == .bluetoothHFP || port.portType == .bluetoothLE {
            throw AudioInputError.unreliableBluetooth
        }
        #endif

        // 若 format 采样率不合法(占位值),用 48000 兜底。
        let sampleRate = (format.sampleRate > 0 && format.sampleRate.isFinite)
                         ? Float(format.sampleRate) : 48000
        worker?.updateSampleRate(sampleRate)
        activeSampleRate = sampleRate

        // 防御性移除旧 tap(installTap 重复装会抛 "tap already installed")。
        // 只在确实装过时调用:无设备/半配置状态下 removeTap 本身也可能抛 ObjC 异常。
        if tapInstalled {
            inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }

        let tapFormat = format.sampleRate > 0 ? format : nil
        let bufferSize = AVAudioFrameCount(worker!.fftSize)
        inputNode.installTap(onBus: 0, bufferSize: bufferSize, format: tapFormat) { [weak self] buffer, _ in
            guard let self = self else { return }
            guard let channelData = buffer.floatChannelData?[0] else { return }
            let frameLength = Int(buffer.frameLength)
            let samples = Array(UnsafeBufferPointer(start: channelData, count: frameLength))
            let now = Date()
            self.captureWallClockAnchor.mark(now)
            self.captureTimeRangeBox.mark(now)
            self.sinkBox.deliver(samples)
            self.worker?.enqueue(samples)
        }
        tapInstalled = true
    }

    // MARK: - 输入设备

    public nonisolated static let noInputDeviceMessage = "未检测到可用的麦克风。请连接麦克风，或在系统设置中检查输入设备。"

    /// 检查当前是否有可用的音频输入。
    /// 除格式外还校验硬件通道数;蓝牙/虚拟设备可能出现采样率非零
    /// 但实际没有输入通道的情况。
    public static func hasAvailableAudioInput(_ inputNode: AVAudioInputNode) -> Bool {
        let format = inputNode.outputFormat(forBus: 0)
        return format.sampleRate.isFinite
            && format.sampleRate > 0
            && format.channelCount > 0
    }

    #if os(macOS)
    /// 通过 CoreAudio 查询真实输入设备。不能先用 AVAudioEngine.inputNode
    /// 探测:没有硬件时它可能返回占位格式,随后 installTap 会触发 ObjC 异常。
    /// - Parameter uid: 指定设备 UID;nil/空时检查系统默认输入。
    public static func hasMacAudioInputDevice(uid: String? = nil) -> Bool {
        if let uid, !uid.isEmpty {
            return macInputDeviceID(forUID: uid).map(hasInputChannels) == true
        }
        return systemDefaultInputDeviceID().map(hasInputChannels) == true
    }

    private static func systemDefaultInputDeviceID() -> AudioDeviceID? {
        var deviceID = AudioDeviceID(kAudioObjectUnknown)
        var deviceAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceSize = UInt32(MemoryLayout<AudioDeviceID>.size)
        let deviceStatus = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &deviceAddress,
            0,
            nil,
            &deviceSize,
            &deviceID
        )
        guard deviceStatus == noErr, deviceID != kAudioObjectUnknown else { return nil }
        return deviceID
    }

    /// 按 UID 在 CoreAudio 设备列表中定位输入设备。
    private static func macInputDeviceID(forUID uid: String) -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr,
              size >= UInt32(MemoryLayout<AudioDeviceID>.size) else { return nil }

        let count = Int(size) / MemoryLayout<AudioDeviceID>.stride
        var ids = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else {
            return nil
        }

        for id in ids {
            var uidAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceUID,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var value: Unmanaged<CFString>?
            var valueSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            guard AudioObjectGetPropertyData(id, &uidAddress, 0, nil, &valueSize, &value) == noErr,
                  let retained = value else { continue }
            if (retained.takeRetainedValue() as String) == uid { return id }
        }
        return nil
    }

    /// 设备是否至少有一个输入通道。
    private static func hasInputChannels(_ deviceID: AudioDeviceID) -> Bool {
        var streamAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var streamSize: UInt32 = 0
        let sizeStatus = AudioObjectGetPropertyDataSize(
            deviceID,
            &streamAddress,
            0,
            nil,
            &streamSize
        )
        guard sizeStatus == noErr, streamSize >= UInt32(MemoryLayout<AudioBufferList>.size) else {
            return false
        }

        let bufferListMemory = UnsafeMutableRawPointer.allocate(
            byteCount: Int(streamSize),
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { bufferListMemory.deallocate() }

        let dataStatus = AudioObjectGetPropertyData(
            deviceID,
            &streamAddress,
            0,
            nil,
            &streamSize,
            bufferListMemory
        )
        guard dataStatus == noErr else { return false }

        let bufferList = bufferListMemory.bindMemory(to: AudioBufferList.self, capacity: 1)
        return UnsafeMutableAudioBufferListPointer(bufferList)
            .contains { $0.mNumberChannels > 0 }
    }
    #endif

    deinit {
        // deinit 不能在 @MainActor 上安全操作 engine;调用方应在视图销毁前 stop()。
        // 这里只做尽力清理。
        // @MainActor 属性不能在 deinit 中安全访问；观察者随 NotificationCenter
        // 的弱引用在对象销毁后自动失效，engine 也会随 self 一起释放。
    }
}

private enum AudioInputError: LocalizedError {
    case unavailable
    case unreliableBluetooth

    var errorDescription: String? {
        switch self {
        case .unavailable:
            return AudioMeterEngine.noInputDeviceMessage
        case .unreliableBluetooth:
            return "当前使用蓝牙通话麦克风，系统会降低采样率并自动增益，读数不可靠。请改用手机、手表或外接测量麦克风。"
        }
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

private final class AnalysisSinkBox: @unchecked Sendable {
    private let lock = NSLock()
    private var sink: (@Sendable ([MeterResult]) -> Void)?
    private var isPaused = false

    func set(_ s: (@Sendable ([MeterResult]) -> Void)?) {
        lock.lock()
        sink = s
        isPaused = false
        lock.unlock()
    }

    /// 冻结收尾时暂停交付，但保留 sink；下一场 start() 可恢复。
    func pause() {
        lock.lock(); isPaused = true; lock.unlock()
    }

    func resume() {
        lock.lock(); isPaused = false; lock.unlock()
    }

    func deliver(_ results: [MeterResult]) {
        lock.lock()
        let s = isPaused ? nil : sink
        lock.unlock()
        s?(results)
    }
}

/// NotificationCenter 返回的令牌需要显式注销。由本对象持有后，
/// 即使调用方忘记 tearDown，token 也会随对象释放自动清理。
private final class AudioNotificationBag: @unchecked Sendable {
    private let lock = NSLock()
    private var tokens: [NSObjectProtocol] = []

    var isInstalled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !tokens.isEmpty
    }

    func replace(with newTokens: [NSObjectProtocol]) {
        lock.lock()
        let oldTokens = tokens
        tokens = newTokens
        lock.unlock()
        let center = NotificationCenter.default
        oldTokens.forEach(center.removeObserver)
    }

    func removeAll() {
        replace(with: [])
    }

    deinit {
        removeAll()
    }
}

/// 分析结果的线程安全收件箱。
///
/// `MeterWorker` 约每 0.25 秒交付一批结果。如果主线程长时间卡顿，
/// 每个批次都直接 `DispatchQueue.main.async` 会让待处理闭包和频率轴数组
/// 无界堆积。这里只允许一个主线程排空任务，并在收件箱内保留有界结果。
final class AnalysisDeliveryInbox: @unchecked Sendable {
    struct DrainPayload {
        let results: [MeterResult]
        let overflowed: Bool
    }

    private let lock = NSLock()
    private var results: [MeterResult] = []
    private var drainScheduled = false
    private var overflowed = false
    private var generation: UInt64 = 0
    private let maxResults: Int

    init(maxResults: Int = 256) {
        self.maxResults = max(1, maxResults)
    }

    /// 开始/结束一场会话时递增代次，迟到的旧闭包不能写入新会话。
    func reset() {
        lock.lock()
        generation &+= 1
        results.removeAll(keepingCapacity: true)
        drainScheduled = false
        overflowed = false
        lock.unlock()
    }

    var currentGeneration: UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return generation
    }

    func enqueue(_ incoming: [MeterResult],
                 generation: UInt64,
                 schedule: @escaping @Sendable () -> Void) {
        var shouldSchedule = false
        lock.lock()
        guard self.generation == generation else {
            lock.unlock()
            return
        }
        results.append(contentsOf: incoming)
        if results.count > maxResults {
            results.removeFirst(results.count - maxResults)
            overflowed = true
        }
        // 若当前有排空任务正在执行，takeAll 已经清掉 drainScheduled，
        // 这里的后续批次需要再排一次；否则要等下一批到达才可能唤醒。
        if !drainScheduled {
            drainScheduled = true
            shouldSchedule = true
        }
        lock.unlock()
        if shouldSchedule {
            DispatchQueue.main.async(execute: schedule)
        }
    }

    func takeAll(generation: UInt64) -> DrainPayload? {
        lock.lock()
        guard self.generation == generation else {
            lock.unlock()
            return nil
        }
        // 主线程闭包取出快照后，立即允许后续批次安排下一次排空；
        // 这样排空期间到达的数据不会因为 drainScheduled 已置 false
        // 又没人安排任务而滞留。
        drainScheduled = false
        let drained = results
        let didOverflow = overflowed
        results.removeAll(keepingCapacity: true)
        overflowed = false
        lock.unlock()
        return DrainPayload(results: drained, overflowed: didOverflow)
    }

    /// 闭包代次过期或被页面状态拒绝时，必须释放排空标记；
    /// 否则后续 enqueue 会误以为仍有任务在排队。
    func abandonDrain() {
        lock.lock()
        drainScheduled = false
        lock.unlock()
    }

    /// 释放排空标记，并检查箱内是否已有新数据。
    /// 返回 true 表示调用方应立刻投递新的主线程闭包。
    func abandonDrainAndCheckPending() -> Bool {
        lock.lock()
        drainScheduled = false
        let hasPending = !results.isEmpty
        lock.unlock()
        return hasPending
    }

    var hasPendingWork: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !results.isEmpty || drainScheduled
    }
}

private final class WallClockAnchor: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date?

    func reset() {
        lock.lock()
        value = nil
        lock.unlock()
    }

    func mark(_ date: Date) {
        lock.lock()
        // 中断/路由重配后，音频时钟会从新的采样位置继续。事件映射必须
        // 使用最新采集墙钟锚点，否则后续事件会被整体映射到中断前。
        value = date
        lock.unlock()
    }

    func resolved() -> Date {
        lock.lock()
        defer { lock.unlock() }
        return value ?? Date()
    }
}

/// 音频线程写、主线程读的采集时间范围。
/// 时间戳更新不应为了两个 Date 每个音频缓冲都创建 MainActor Task。
private final class CaptureTimeRangeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var first: Date?
    private var last: Date?

    func reset() {
        lock.lock()
        first = nil
        last = nil
        lock.unlock()
    }

    func mark(_ date: Date) {
        lock.lock()
        if first == nil { first = date }
        last = date
        lock.unlock()
    }

    var firstDate: Date? {
        lock.lock()
        defer { lock.unlock() }
        return first
    }

    var lastDate: Date? {
        lock.lock()
        defer { lock.unlock() }
        return last
    }

    var range: ClosedRange<Date>? {
        lock.lock()
        defer { lock.unlock() }
        guard let first, let last, last >= first else { return nil }
        return first...last
    }
}

/// 音频时钟到墙钟的映射器。
/// worker 写入，主线程读取；断点表示某个音频累计时长在对应墙钟时刻已经交付。
/// 这比“整场最终 gap”更准确，因为中断只影响它之后的时间。
private final class AnalysisClock: @unchecked Sendable {
    private struct Anchor {
        let audioTime: TimeInterval
        let wallTime: Date
    }

    private let lock = NSLock()
    private var anchors: [Anchor] = []
    private var firstSampleDate: Date?
    private var lastSampleDate: Date?
    private var lastAudioTime: TimeInterval = 0
    private var generation: UInt64 = 0

    func reset(generation: UInt64) {
        lock.lock()
        anchors.removeAll(keepingCapacity: true)
        firstSampleDate = nil
        lastSampleDate = nil
        lastAudioTime = 0
        self.generation = generation
        lock.unlock()
    }

    func record(results: [MeterResult],
                deliveredDuration: TimeInterval,
                wallClock: Date,
                generation: UInt64) {
        guard let last = results.last,
              last.integratedSampleCount > 0 else { return }
        lock.lock()
        guard self.generation == generation else {
            lock.unlock()
            return
        }

        if firstSampleDate == nil { firstSampleDate = wallClock }
        lastSampleDate = wallClock
        lastAudioTime = deliveredDuration
        anchors.append(Anchor(audioTime: deliveredDuration, wallTime: wallClock))
        // 一个锚点覆盖约 0.25s；保留两分钟足够跨过常见主线程卡顿，
        // 又不会让过夜监听无限增长。
        if anchors.count > 480 {
            anchors.removeFirst(anchors.count - 480)
        }
        lock.unlock()
    }

    func wallClockDate(forAudioTime audioTime: TimeInterval,
                       duration: TimeInterval,
                       fallback: Date) -> Date {
        lock.lock()
        let resolvedFallback = lastSampleDate ?? firstSampleDate ?? fallback
        let first = firstSampleDate
        let anchor = anchors.last(where: {
            $0.audioTime + 0.000_1 >= audioTime
        }) ?? anchors.min(by: {
            abs($0.audioTime - audioTime) < abs($1.audioTime - audioTime)
        })
        lock.unlock()

        guard let anchor else {
            return resolvedFallback
        }
        let offset = max(0, anchor.audioTime - max(0, audioTime))
        let base = anchor.wallTime.addingTimeInterval(-offset)
        // 事件可能跨越一次中断；不要把事件起点倒推到采集开始之前。
        if let first, base < first {
            return first
        }
        return base
    }
}

/// worker 音频队列读取、主线程推进的测量代次。
private final class CallbackGenerationBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: UInt64 = 0

    var current: UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func bump() {
        lock.lock()
        value &+= 1
        lock.unlock()
    }
}

// MARK: - MeterWorker(非隔离,在专用队列上工作)

/// 样本处理 worker。所有可变状态(`sampleBuffer`、`meter`、`lastCallbackTime`)
/// 都只在 `meterQueue` 上访问,因此对它是线程安全的。
private final class MeterWorker: @unchecked Sendable {

    let fftSize: Int
    let throttleInterval: TimeInterval
    private let callback: (MeterResult, Float) -> Void
    private var analysisCallback: ([MeterResult]) -> Void

    private let meterQueue = DispatchQueue(label: "com.dinghao.soundsense.meter", qos: .userInitiated)
    private var meter: DBMeter
    private var sampleBuffer: [Float] = []
    private var lastCallbackTime: CFTimeInterval = 0
    /// 节流前的会话峰值(LAFmax/LASmax),保存为未加校准偏移的值。
    /// 这样运行中微调校准时,历史峰值会与新读数一起整体平移。
    private var sessionPeakUncalibrated: Float = -.greatestFiniteMagnitude
    // 当前 meter 的构建参数(rebuild 用)
    private var currentSampleRate: Float
    private var currentOffset: Float
    private var currentWeighting: Weighting
    private var currentTimeWeighting: TimeWeighting
    private let spectrumEnabled: Bool
    private let lowBandAnalysisInterval: TimeInterval
    /// 最近一次成功处理的帧结果。stop 收尾时用它绕过节流再发一次。
    private var lastProcessedResult: MeterResult?
    /// 完整 hop 结果先在 meterQueue 内聚合，再一次性交给上层。
    private var pendingAnalysisResults: [MeterResult] = []
    private var pendingAnalysisDuration: TimeInterval = 0
    private let analysisBatchDuration: TimeInterval = 0.25
    /// 只有在 meterQueue 上访问；用于收尾时证明此前交付计数已全部生成。
    var deliveredAnalysisDuration: TimeInterval = 0

    init(fftSize: Int,
         throttleInterval: TimeInterval,
         calibrationOffset: Float,
         weighting: Weighting,
         timeWeighting: TimeWeighting = .fast,
         spectrumEnabled: Bool = true,
         lowBandAnalysisInterval: TimeInterval = 0.5,
         analysisCallback: @escaping ([MeterResult]) -> Void,
         callback: @escaping (MeterResult, Float) -> Void) {
        self.fftSize = fftSize
        self.throttleInterval = throttleInterval
        self.analysisCallback = analysisCallback
        self.callback = callback
        self.currentSampleRate = 48000
        self.currentOffset = calibrationOffset
        self.currentWeighting = weighting
        self.currentTimeWeighting = timeWeighting
        self.spectrumEnabled = spectrumEnabled
        self.lowBandAnalysisInterval = lowBandAnalysisInterval
        self.meter = DBMeter(config: MeterConfig(sampleRate: 48000,
                                                  fftSize: fftSize,
                                                  calibrationOffset: calibrationOffset,
                                                  weighting: weighting,
                                                  timeWeighting: timeWeighting,
                                                  spectrumEnabled: spectrumEnabled,
                                                  lowBandAnalysisInterval: lowBandAnalysisInterval))
    }

    /// 投递一批样本(可从任意线程调用)
    func enqueue(_ samples: [Float]) {
        meterQueue.async { [weak self] in
            self?.process(samples)
        }
    }

    /// 在 meterQueue 上排一个空任务。它返回后，调用前已入队的音频块和
    /// 分析回调都已按顺序完成。
    func barrier() {
        meterQueue.sync {}
    }

    func setAnalysisCallback(_ callback: @escaping ([MeterResult]) -> Void) {
        meterQueue.async { [weak self] in
            self?.analysisCallback = callback
        }
    }

    /// 在 meterQueue 上按当前参数重建 meter
    /// - Parameter preserveSessionStats: 采样率变化时保留已累计的 Leq/检波器状态。
    private func rebuildMeter(preserveSessionStats: Bool = false) {
        let previous = meter
        meter = DBMeter(config: MeterConfig(sampleRate: currentSampleRate,
                                            fftSize: fftSize,
                                            calibrationOffset: currentOffset,
                                            weighting: currentWeighting,
                                            timeWeighting: currentTimeWeighting,
                                            spectrumEnabled: spectrumEnabled,
                                            lowBandAnalysisInterval: lowBandAnalysisInterval))
        if preserveSessionStats {
            meter.adoptSessionState(from: previous)
        }
    }

    /// 更新采样率(下次处理前生效)
    func updateSampleRate(_ sampleRate: Float) {
        meterQueue.async { [weak self] in
            guard let self = self else { return }
            guard abs(sampleRate - self.currentSampleRate) > 0.5 else { return }
            self.currentSampleRate = sampleRate
            self.rebuildMeter(preserveSessionStats: true)
        }
    }

    /// 更新校准偏移量
    func updateCalibration(_ offset: Float) {
        meterQueue.async { [weak self] in
            guard let self = self else { return }
            self.currentOffset = offset
            self.meter.setCalibrationOffset(offset)
        }
    }

    /// 更新频率计权(A/C)
    func updateWeighting(_ weighting: Weighting) {
        meterQueue.async { [weak self] in
            guard let self = self else { return }
            self.currentWeighting = weighting
            self.meter.setWeighting(weighting)
        }
    }

    /// 更新时间计权(F/S)
    func updateTimeWeighting(_ timeWeighting: TimeWeighting) {
        meterQueue.async { [weak self] in
            guard let self = self else { return }
            self.currentTimeWeighting = timeWeighting
            self.meter.setTimeWeighting(timeWeighting)
        }
    }

    func resetDisplayDetector() {
        meterQueue.async { [weak self] in
            self?.meter.resetDetector()
        }
    }

    /// 清空缓冲
    func reset() {
        meterQueue.async { [weak self] in
            guard let self = self else { return }
            self.sampleBuffer.removeAll(keepingCapacity: true)
            self.lastCallbackTime = 0
            self.sessionPeakUncalibrated = -.greatestFiniteMagnitude
            self.lastProcessedResult = nil
            self.lastTailResult = nil
            self.pendingAnalysisResults.removeAll(keepingCapacity: true)
            self.pendingAnalysisDuration = 0
            self.processCount = 0
            self.deliveredAnalysisDuration = 0
            // 新一场测量必须从头建立滤波器/检波器/Leq 状态。只清检波器会让
            // 上一场末尾的 IIR 历史渗入下一场首个 hop。
            self.meter.resetSmoothing()
        }
    }

    /// 系统中断/路由切换时丢弃仍在旧时钟上的缓冲和尚未处理的回调，
    /// 但不重置 Leq/峰值：已完成的测量仍然有效。
    func cancelPendingWork() {
        meterQueue.async { [weak self] in
            guard let self = self else { return }
            self.sampleBuffer.removeAll(keepingCapacity: true)
            self.lastProcessedResult = nil
            self.lastTailResult = nil
            self.pendingAnalysisResults.removeAll(keepingCapacity: true)
            self.pendingAnalysisDuration = 0
            self.lastCallbackTime = 0
            self.meter.resetFilter()
            self.meter.resetDetector()
        }
    }

    /// 恢复后第一帧与中断前没有连续音频时间关系，重新预热滤波器后
    /// 从新的一帧开始计 Leq，避免把中断空窗误当作静音。
    func resumeAfterInterruption() {
        meterQueue.async { [weak self] in
            guard let self = self else { return }
            // 已完成的 Leq/峰值保留；只重置和旧音频时钟相连的滤波器、
            // 检波器与尾部重叠状态。
            self.meter.resetFilter()
            self.meter.resetDetector()
            self.lastCallbackTime = 0
            self.processCount = 0
        }
    }

    /// 排空已入队的音频块并返回最终快照。
    func drainAndFlush() async -> MeterFinalSnapshot? {
        await withCheckedContinuation { continuation in
            meterQueue.async { [weak self] in
                guard let self = self else {
                    continuation.resume(returning: nil)
                    return
                }
                // 停止硬件后仍可能有不足一个 FFT hop 的样本留在缓冲区。
                // 将它们接着滤波器状态处理，避免短促的末段峰值和 Leq 时长丢失。
                if !self.sampleBuffer.isEmpty {
                    let tail = self.sampleBuffer
                    self.sampleBuffer.removeAll(keepingCapacity: true)
                    // 只要处理过至少一个窗，缓冲区开头就是上一窗已积分的
                    // 重叠前缀；跳过这半个 hop，只统计其后的新样本。
                    let hop = self.fftSize / 2
                    let skip = self.processCount > 0 ? min(hop, tail.count) : 0
                    if let result = self.meter.processTail(tail, skipSamples: skip) {
                        self.lastProcessedResult = result
                        self.lastTailResult = result
                        self.enqueueAnalysis(result)
                        let uncalibrated = result.splA - self.currentOffset
                        if uncalibrated > self.sessionPeakUncalibrated {
                            self.sessionPeakUncalibrated = uncalibrated
                        }
                    }
                }
                self.flushAnalysisBatch()
                guard let result = self.lastProcessedResult else {
                    continuation.resume(returning: nil)
                    return
                }
                let peak = self.sessionPeakUncalibrated.isFinite
                    ? self.sessionPeakUncalibrated + self.currentOffset
                    : -.greatestFiniteMagnitude
                continuation.resume(returning: MeterFinalSnapshot(
                    result: result,
                    analysisResult: self.lastTailResult,
                    peak: peak))
            }
        }
    }

    private var processCount = 0
    /// 仅记录本进程生命周期内最近一次 `processTail()` 的结果，
    /// 避免 freeze 时把上一帧普通 hop 再投递一次（重复统计）。
    private var lastTailResult: MeterResult?

    /// 发送最新结果。`force=false` 时保留 UI 节流。
    private func emitLatestCallback(force: Bool) {
        let now = Date.timeIntervalSinceReferenceDate
        if !force && now - lastCallbackTime < throttleInterval { return }
        lastCallbackTime = now

        guard let result = lastProcessedResult else { return }
        let peak = sessionPeakUncalibrated.isFinite
            ? sessionPeakUncalibrated + currentOffset
            : -.greatestFiniteMagnitude
        callback(result, peak)
    }

    /// 在 meterQueue 上聚合完整 hop 结果。
    private func enqueueAnalysis(_ result: MeterResult) {
        pendingAnalysisResults.append(result)
        pendingAnalysisDuration += max(0, result.coveredDuration)
        if pendingAnalysisDuration >= analysisBatchDuration {
            flushAnalysisBatch()
        }
    }

    private func flushAnalysisBatch() {
        guard !pendingAnalysisResults.isEmpty else { return }
        let batch = pendingAnalysisResults
        pendingAnalysisResults.removeAll(keepingCapacity: true)
        pendingAnalysisDuration = 0
        analysisCallback(batch)
    }

    /// 在 meterQueue 上执行(私有,只通过 meterQueue.async 调用)
    private func process(_ incoming: [Float]) {
        sampleBuffer.append(contentsOf: incoming)

        // 防御:队列积压(处理不过来)时丢最旧数据,保证缓冲不无界增长。
        // 正常路径由下方 while 循环按 50% 重叠推进排空。
        if sampleBuffer.count > fftSize * 4 {
            let dropped = sampleBuffer.count - fftSize
            sampleBuffer.removeFirst(dropped)
            meter.reportDroppedSamples(dropped)
        }

        // 50% 重叠推进:每凑满一个窗处理一次,窗口推进 fftSize/2。
        // (旧实现每 tap 只处理一次且每次只移除半个窗,数据会越积越多,
        //  积到上限又被整块丢弃 —— 两边都造成读数失真。)
        let hop = fftSize / 2
        var lastResult: MeterResult?
        while sampleBuffer.count >= fftSize {
            let frame = Array(sampleBuffer.prefix(fftSize))
            lastResult = meter.process(frame, hopSamples: hop)
            if let result = lastResult {
                lastProcessedResult = result
                enqueueAnalysis(result)
                let uncalibrated = result.splA - currentOffset
                if uncalibrated > sessionPeakUncalibrated {
                    sessionPeakUncalibrated = uncalibrated
                }
            }
            sampleBuffer.removeFirst(hop)
            processCount += 1
        }

        guard lastResult != nil else { return }
        emitLatestCallback(force: false)
    }
}

private struct MeterFinalSnapshot {
    let result: MeterResult
    let analysisResult: MeterResult?
    let peak: Float
}

/// 把共享分析结果按样本时间轴映射到“当前测量段”，
/// 并保证每个 hop 只被消费一次。
///
/// 这不是 UI 状态，只保存最近一次的样本位置。采样率变化时会用秒数
/// 换算旧位置，避免设备/路由切换后出现负时间或跳段。
public struct AnalysisTimelineCursor {
    private var lastSampleEnd: Double?
    private var lastSampleRate: Float?
    private var unanchoredSeconds: Double = 0

    public init() {}

    /// 消费一个分析结果，返回它在本测量/点位中的相对时间范围。
    /// 返回值 `.lowerBound` 用于统计；`upperBound` 用于下一帧的积分起点。
    /// 若结果是重复样本（完整位置 + 数量未前进），返回 nil。
    public mutating func consume(_ result: MeterResult,
                                 origin: Date,
                                 now: Date) -> ClosedRange<TimeInterval>? {
        guard result.integratedSampleCount > 0,
              result.sampleRate.isFinite,
              result.sampleRate > 0 else { return nil }

        let position = Double(result.samplePosition)
        let count = Double(result.integratedSampleCount)
        let rate = Double(result.sampleRate)

        if let previousEnd = lastSampleEnd {
            if position + count <= previousEnd + 0.5 {
                return nil
            }
            // 正常 hop 的 samplePosition 应严格接续；若样本位置跳变
            //（设备重绑/采样率重建），用挂钟时间作为兜底，并按秒数桥接。
            if lastSampleRate == result.sampleRate,
               position > previousEnd + 0.5 {
                unanchoredSeconds += (position - previousEnd) / rate
            }
        }

        lastSampleEnd = position + count
        lastSampleRate = result.sampleRate

        let wallElapsed = max(0, now.timeIntervalSince(origin))
        let sampleElapsed = unanchoredSeconds + (position + count) / rate
        let duration = count / rate
        // 挂钟可能因为启动等待/主线程调度落后于样本时间；样本位置是
        // 同一设备内的单调权威时钟，不能把区间硬截到墙钟之前。
        let maxElapsed = max(wallElapsed, sampleElapsed)
        let upper = max(0, maxElapsed)
        let lower = max(0, upper - duration)
        return lower...upper
    }

    public mutating func reset() {
        lastSampleEnd = nil
        lastSampleRate = nil
        unanchoredSeconds = 0
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
