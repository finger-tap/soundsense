//
//  MeterViewModel.swift
//  SoundSenseMac
//
//  macOS 主视图模型:复用共享 AudioMeterEngine + 测量记录。
//  并负责输入源选择(设备列表转发 / 切换 / 按设备存校准值)。
//

import SwiftUI
import Combine
import SoundSenseCore

@MainActor
final class MeterViewModel: ObservableObject {

    /// 引擎:创建后不变。它的 @Published 变化通过下面 cancellables 转发。
    let engine: AudioMeterEngine
    /// 输入设备管理器(枚举系统输入源、监听插拔)
    let deviceManager = AudioInputDeviceManager()
    /// 可用输入设备列表(转发自 deviceManager,供设置页展示)
    @Published private(set) var devices: [AudioInputDevice] = []
    /// 系统默认输入设备 UID(「跟随系统默认」时实际生效的设备)
    @Published private(set) var defaultInputUID: String?
    @Published private(set) var history: [Float] = []
    @Published private(set) var noiseLevel: NoiseLevel?
    /// 最近一次测量的统计(停止检测后填充,用于导出报告)
    @Published private(set) var lastStats: MeasurementStats?
    /// 测量进行中的实时统计(时长 / LAeq / 峰值),nil = 未在测量
    @Published private(set) var liveStats: LiveMeasurementStats?
    /// 噪声暴露警告:连续超过 85 dB 达到阈值后置 true,回落或重开后复位
    @Published private(set) var exposureWarning = false
    /// 测量历史(持久化)
    let historyStore = MeasurementHistoryStore.shared

    /// 大屏历史数组容量大一些
    private let historyCapacity = 120
    /// 订阅 engine / deviceManager 的变化,转发给本 ViewModel,让 UI 能刷新
    private var cancellables = Set<AnyCancellable>()
    /// 测量记录器(每秒采样 1 点,停止时生成报告数据)
    private let recorder: MeasurementRecorder
    /// 检测同步录音器(与测量同源样本写 AAC m4a)
    private let sessionRecorder = SessionAudioRecorder()
    /// 启动时是否检测到麦克风(菜单栏控制器启动时据此给用户反馈)
    @Published var hasAudioInput = true
    /// 每秒刷新实时统计的定时器
    private var liveTimer: Timer?
    /// 每场测量只发一次暴露通知
    private var exposureNotified = false

    /// 选中的输入设备 UID;nil = 跟随系统默认。持久化。
    @AppStorage("inputDeviceUID") private var storedInputDeviceUID: String?
    /// 频率计权(A/C),持久化
    @AppStorage("weighting") private var storedWeighting: String = "A"
    /// 暴露警告阈值(dB),持久化
    @AppStorage("warningThreshold") private var storedThreshold: Double = Double(MeasurementRecorder.defaultExposureLimit)

    /// 当前选择的输入设备 UID;nil = 跟随系统默认
    var selectedDeviceUID: String? { storedInputDeviceUID }

    // MARK: - 校准值(按输入设备分别保存)

    /// 「跟随系统默认」在校准字典里的 key
    private static let systemDefaultKey = "systemDefault"

    /// 校准值存储:UserDefaults key "calibrationOffsetsByDevice",[设备UID: 偏移量]。
    /// 不同麦克风灵敏度差异可达 20 dB 以上,校准值必须跟着设备走,
    /// 否则切源后读数错了用户还无感知(方案文档坑 1)。
    private var offsetsByDevice: [String: Double] {
        get { Self.loadOffsets() }
        set { Self.saveOffsets(newValue) }
    }

    private static func loadOffsets() -> [String: Double] {
        UserDefaults.standard.dictionary(forKey: "calibrationOffsetsByDevice") as? [String: Double] ?? [:]
    }

    private static func saveOffsets(_ offsets: [String: Double]) {
        UserDefaults.standard.set(offsets, forKey: "calibrationOffsetsByDevice")
    }

    /// 各设备类型的校准预设初值(与 CalibrationDefaults 对齐;均为开箱估计,需实测微调)
    static func defaultOffset(forKind kind: AudioInputDevice.Kind) -> Double {
        switch kind {
        case .continuity:
            // 连续互通用的是 iPhone 本机麦克风,按 iOS 内建典型值
            return Double(CalibrationDefaults.iosBuiltIn)
        case .usb, .bluetooth:
            // 外接/耳机麦克风灵敏度离散极大,仅为开箱占位,务必校准
            return Double(CalibrationDefaults.external)
        default:
            // 内建 / 虚拟 / 聚合 / 未知:按 Mac 内建保守估计
            return Double(CalibrationDefaults.macBuiltIn)
        }
    }

    /// 当前生效设备在校准字典里的 key
    private var currentCalibrationKey: String { storedInputDeviceUID ?? Self.systemDefaultKey }

    /// 当前生效设备的类别(用于无校准记录时给预设初值)
    private var currentDeviceKind: AudioInputDevice.Kind {
        guard let uid = storedInputDeviceUID,
              let device = devices.first(where: { $0.uid == uid }) else { return .builtIn }
        return device.kind
    }

    var calibrationOffset: Float {
        get { Float(offsetsByDevice[currentCalibrationKey] ?? Self.defaultOffset(forKind: currentDeviceKind)) }
        set {
            // 写入当前设备的 key(预设按钮/滑杆都是「为当前设备」调值)
            var offsets = offsetsByDevice
            offsets[currentCalibrationKey] = Double(newValue)
            offsetsByDevice = offsets
            engine.calibrationOffset = newValue
            // offsetsByDevice 不走 @Published/@AppStorage,手动通知 UI 刷新
            objectWillChange.send()
        }
    }

    var weighting: Weighting {
        get { storedWeighting == "C" ? .c : .a }
        set {
            storedWeighting = newValue.rawValue.uppercased()
            engine.weighting = newValue
        }
    }

    /// 超阈值时发系统通知开关(默认关,不弹权限窗;App 内横幅始终有效)
    @AppStorage("systemNotificationsEnabled") var systemNotificationsEnabled: Bool = false

    var warningThreshold: Float {
        get { Float(storedThreshold) }
        set {
            storedThreshold = Double(newValue)
            recorder.exposureLimit = newValue
        }
    }

    init() {
        // 兼容迁移:旧版全局 calibrationOffset 经 CalibrationDefaults 迁移
        // (仍是旧默认 +93 且未手动改过 → 平台新默认;手动改过的原样保留),
        // 并入按设备字典的 systemDefault 键。
        var offsets = Self.loadOffsets()
        if offsets[Self.systemDefaultKey] == nil {
            offsets[Self.systemDefaultKey] = Double(CalibrationDefaults.resolved(platformDefault: CalibrationDefaults.macBuiltIn))
            Self.saveOffsets(offsets)
        }

        // 初始校准值:当前选中设备(持久化的 inputDeviceUID)的记录,无记录按类型预设。
        // 预设与 CalibrationDefaults 对齐(Mac 内建 +100 / 外接 +90 / iPhone 麦克风 +120),
        // 开箱即显示 SPL 而非裸 dBFS;精确值需设置页对照标准声级计实测。
        let selectedUID = UserDefaults.standard.string(forKey: "inputDeviceUID")
        var selectedKind: AudioInputDevice.Kind = .builtIn
        if let uid = selectedUID,
           let device = deviceManager.devices.first(where: { $0.uid == uid }) {
            selectedKind = device.kind
        }
        let offset = Float(offsets[selectedUID ?? Self.systemDefaultKey]
                           ?? Self.defaultOffset(forKind: selectedKind))
        let weightingRaw = UserDefaults.standard.string(forKey: "weighting") ?? "A"
        let weighting: Weighting = weightingRaw == "C" ? .c : .a
        let threshold = Float(UserDefaults.standard.object(forKey: "warningThreshold") as? Double
                              ?? Double(MeasurementRecorder.defaultExposureLimit))
        let e = AudioMeterEngine(calibrationOffset: offset,
                                  throttleInterval: 1.0 / 30.0,  // 30fps,桌面端更流畅
                                  fftSize: 4096,
                                  weighting: weighting)
        self.engine = e
        self.recorder = MeasurementRecorder(exposureLimit: threshold)
        e.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)

        // 转发设备列表;选中的设备被拔出时回退「跟随系统默认」并应用到引擎
        deviceManager.$devices
            .receive(on: RunLoop.main)
            .sink { [weak self] devices in
                guard let self = self else { return }
                self.devices = devices
                if let uid = self.storedInputDeviceUID,
                   !devices.contains(where: { $0.uid == uid }) {
                    Task { await self.selectDevice(uid: nil) }
                }
            }
            .store(in: &cancellables)
        deviceManager.$defaultInputUID
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.defaultInputUID = $0 }
            .store(in: &cancellables)
    }

    func start() async {
        hasAudioInput = engine.hasAudioInput
        guard hasAudioInput else { return }
        // 选定了非默认输入源:启动前先绑定设备,保证 installTap 读到正确的设备格式
        if let uid = storedInputDeviceUID,
           let device = deviceManager.devices.first(where: { $0.uid == uid }) {
            await engine.setInputDevice(device.id, uid: uid)
        }
        await engine.start()
        guard engine.state == .running else { return }
        recorder.start()
        sessionRecorder.startSession(directory: historyStore.recordingsDirectory,
                                      inputSampleRate: engine.activeSampleRate)
        engine.setSampleSink { [weak sessionRecorder] samples in
            sessionRecorder?.append(samples)
        }
        exposureWarning = false
        exposureNotified = false
        startLiveTimer()
        if systemNotificationsEnabled {
            NoiseAlertNotifier.requestAuthorization()
        }
    }

    /// 重新探测输入设备;从系统设置接回麦克风后无需重启 App。
    func refreshAudioInputAvailability() {
        hasAudioInput = engine.hasAudioInput
    }

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

    // MARK: - 输入源切换

    /// 切换输入源。
    /// 顺序(方案文档坑 1):旧设备校准值写回 → 更新选择 → 载入新设备校准值 → 应用到引擎。
    func selectDevice(uid: String?) async {
        // 1. 当前偏移量写回旧设备的 key(校准跟着设备走,不串)
        var offsets = offsetsByDevice
        offsets[currentCalibrationKey] = Double(engine.calibrationOffset)
        offsetsByDevice = offsets

        // 2. 更新选择(uid 对应的设备已不存在时按「跟随系统默认」处理)
        let device = uid.flatMap { u -> AudioInputDevice? in
            deviceManager.devices.first { $0.uid == u }
        }
        let effectiveUID = (uid == nil) ? nil : device?.uid
        storedInputDeviceUID = effectiveUID

        // 3. 载入新设备的校准值(无记录按类型给预设初值),并同步到引擎
        let newOffset = Float(offsets[currentCalibrationKey]
                              ?? Self.defaultOffset(forKind: device?.kind ?? .builtIn))
        engine.calibrationOffset = newOffset
        objectWillChange.send()

        // 4. 应用到引擎(engine 内部处理运行中的摘 tap / 停 / 重配 / 重启)
        await engine.setInputDevice(device?.id, uid: effectiveUID)

        // 5. 运行中切换后:引擎的公开 stop() 会清掉样本挂点(sinkBox.set(nil))。
        //    防御性重挂 sink —— 无论切换路径上挂点是否被清,都保证同步录音不丢数据,
        //    这是容易漏的点。
        if engine.state == .running, sessionRecorder.isActive {
            engine.setSampleSink { [weak sessionRecorder] samples in
                sessionRecorder?.append(samples)
            }
        }
    }

    /// 消费一帧结果:更新历史与等级,并记录到报告采样。
    func consume(_ result: MeterResult) {
        let spl = result.splA
        history.append(spl)
        if history.count > historyCapacity {
            history.removeFirst(history.count - historyCapacity)
        }
        noiseLevel = NoiseLevel.level(for: spl)
        recorder.record(spl: spl)
        liveStats = recorder.liveStats()

        // 暴露警告:连续超限达到阈值
        if let live = liveStats,
           live.overLimitContinuous >= MeasurementRecorder.warningAfter {
            exposureWarning = true
            if !exposureNotified {
                exposureNotified = true
                if systemNotificationsEnabled {
                    NoiseAlertNotifier.notifyExposure(
                    db: recorder.exposureLimit,
                        seconds: Int(live.overLimitContinuous))
                }
            }
        }
    }

    var currentSPL: Float {
        engine.latestResult?.splA ?? -.greatestFiniteMagnitude
    }

    /// 是否正在同步录音(测量中恒 true,除非录音器启动失败)
    var isRecording: Bool { sessionRecorder.isActive }

    /// 设备名(用于报告页脚)
    var deviceName: String {
        ProcessInfo.processInfo.hostName
    }

    // MARK: - 实时统计定时器

    private func startLiveTimer() {
        liveTimer?.invalidate()
        let timer = Timer(timeInterval: 1.0, repeats: true) { _ in
            Task { @MainActor [weak self] in
                guard let self = self, self.engine.state == .running else { return }
                self.liveStats = self.recorder.liveStats()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        liveTimer = timer
    }

    private func stopLiveTimer() {
        liveTimer?.invalidate()
        liveTimer = nil
    }
}
