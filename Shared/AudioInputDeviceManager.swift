//
//  AudioInputDeviceManager.swift
//  SoundSense
//
//  macOS 音频输入设备枚举与监听(CoreAudio HAL)。
//
//  职责:
//    1. 枚举系统内所有「有输入通道」的音频设备(内建 / USB / 蓝牙 / 连续互通 / 虚拟 / 聚合)
//    2. 暴露系统默认输入设备 UID(「跟随系统默认」时实际生效的设备)
//    3. 监听设备插拔与默认设备变化,0.1s 防抖后刷新列表
//
//  设计原则(方案文档第六节):探测能力,而不是判断版本。
//  代码里不做任何 macOS 版本判断 —— 枚举到连续互通设备就显示,枚举不到就不显示。
//

#if os(macOS)

import Foundation
import CoreAudio
import Combine

/// 被监听的 CoreAudio 属性地址(注册/注销需使用同一份地址)。
/// 放在文件作用域而非类静态属性:deinit 是非隔离上下文,访问 @MainActor 类的
/// 静态属性在 Swift 6 模式下是错误,文件级常量没有隔离问题。
private let kDevicesPropertyAddress = AudioObjectPropertyAddress(
    mSelector: kAudioHardwarePropertyDevices,
    mScope: kAudioObjectPropertyScopeGlobal,
    mElement: kAudioObjectPropertyElementMain)
private let kDefaultInputPropertyAddress = AudioObjectPropertyAddress(
    mSelector: kAudioHardwarePropertyDefaultInputDevice,
    mScope: kAudioObjectPropertyScopeGlobal,
    mElement: kAudioObjectPropertyElementMain)

/// 一个可用的音频输入设备
public struct AudioInputDevice: Identifiable, Equatable {
    /// 设备类别(由 CoreAudio transport type 映射而来)
    public enum Kind: String, Equatable {
        case builtIn        // 内建麦克风
        case usb            // USB / 雷电
        case bluetooth      // 蓝牙(HFP 链路,采样率低且带 AGC,不推荐)
        case continuity     // iPhone 麦克风(连续互通相机,transport 四字符码 'ccap')
        case virtualDevice  // 虚拟声卡(BlackHole / Loopback 等)
        case aggregate      // 聚合设备
        case other
    }

    /// CoreAudio 设备 ID(切换输入源时用;插拔后可能变化,不做持久化)
    public let id: AudioDeviceID
    /// 稳定标识(跨重启不变,用作校准值存储的 key)
    public let uid: String
    /// 显示名
    public let name: String
    /// 设备类别
    public let kind: Kind
    /// 输入通道总数
    public let inputChannels: Int

    /// 是否不推荐用于测量。
    /// 蓝牙输入走 HFP/HSP:采样率被砍到 8~16 kHz 且通常带自动增益,
    /// 输入电平与真实声压脱钩,分贝读数不可信(方案文档第二节)。
    public var isNotRecommended: Bool { kind == .bluetooth }

    /// 列表图标
    public var sfSymbolName: String {
        switch kind {
        case .builtIn:       return "mic.fill"
        case .usb:           return "cable.connector"
        case .bluetooth:     return "airpods"
        case .continuity:    return "iphone"
        case .virtualDevice: return "waveform"
        case .aggregate:     return "square.stack.3d.up"
        case .other:         return "mic"
        }
    }

    /// 类别中文名(列表副标题用)
    public var kindDisplayName: String {
        switch kind {
        case .builtIn:       return "内建麦克风"
        case .usb:           return "USB / 雷电"
        case .bluetooth:     return "蓝牙音频"
        case .continuity:    return "iPhone(连续互通)"
        case .virtualDevice: return "虚拟声卡"
        case .aggregate:     return "聚合设备"
        case .other:         return "其他输入"
        }
    }
}

/// 输入设备管理器。对外是 @MainActor,UI 可直接观察其 @Published 状态。
@MainActor
public final class AudioInputDeviceManager: ObservableObject {

    /// 当前可用输入设备列表(仅含输入通道 > 0 的设备)
    @Published public private(set) var devices: [AudioInputDevice] = []
    /// 系统默认输入设备的 UID
    @Published public private(set) var defaultInputUID: String?

    /// 防抖任务:插拔事件常成串触发,合并为一次刷新
    private var refreshTask: Task<Void, Never>?

    // 监听 block 需持有引用,deinit 注销时按同一引用移除。
    // 用隐式解包可选型,是为了在 init 中先完成全部存储属性初始化后再捕获 weak self。
    private var devicesListenerBlock: AudioObjectPropertyListenerBlock!
    private var defaultInputListenerBlock: AudioObjectPropertyListenerBlock!

    public init() {
        // 外层闭包也必须 weak self:block 被 HAL 和 self 双方持有,
        // 强捕获会造成循环引用导致 deinit 永不触发(监听也就无法注销)
        devicesListenerBlock = { [weak self] _, _ in
            Task { @MainActor in self?.scheduleRefresh() }
        }
        defaultInputListenerBlock = { [weak self] _, _ in
            Task { @MainActor in self?.scheduleRefresh() }
        }
        refresh()
        let system = AudioObjectID(kAudioObjectSystemObject)
        var devicesAddr = kDevicesPropertyAddress
        var defaultAddr = kDefaultInputPropertyAddress
        AudioObjectAddPropertyListenerBlock(system, &devicesAddr,
                                            DispatchQueue.main, devicesListenerBlock)
        AudioObjectAddPropertyListenerBlock(system, &defaultAddr,
                                            DispatchQueue.main, defaultInputListenerBlock)
    }

    deinit {
        refreshTask?.cancel()
        let system = AudioObjectID(kAudioObjectSystemObject)
        var devicesAddr = kDevicesPropertyAddress
        var defaultAddr = kDefaultInputPropertyAddress
        AudioObjectRemovePropertyListenerBlock(system, &devicesAddr,
                                               DispatchQueue.main, devicesListenerBlock)
        AudioObjectRemovePropertyListenerBlock(system, &defaultAddr,
                                               DispatchQueue.main, defaultInputListenerBlock)
    }

    // MARK: - 刷新

    /// 0.1s 防抖刷新:插拔瞬间设备可能尚未就绪,且插拔常触发一串连续事件
    private func scheduleRefresh() {
        refreshTask?.cancel()
        refreshTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 100_000_000)
            guard !Task.isCancelled else { return }
            self?.refresh()
        }
    }

    /// 立即重新枚举设备并解析系统默认输入
    public func refresh() {
        var result: [AudioInputDevice] = []
        for id in Self.allDeviceIDs() {
            let channels = Self.inputChannelCount(of: id)
            guard channels > 0 else { continue }  // 纯输出设备对测量无意义,过滤掉
            let name = Self.stringProperty(kAudioDevicePropertyDeviceNameCFString, of: id) ?? "未知设备"
            let uid = Self.stringProperty(kAudioDevicePropertyDeviceUID, of: id) ?? "device-\(id)"
            let transport = Self.uint32Property(kAudioDevicePropertyTransportType, of: id) ?? 0
            result.append(AudioInputDevice(id: id,
                                           uid: uid,
                                           name: name,
                                           kind: Self.kind(forTransport: transport),
                                           inputChannels: channels))
        }
        devices = result
        if let defaultID = Self.defaultInputDeviceID() {
            defaultInputUID = Self.stringProperty(kAudioDevicePropertyDeviceUID, of: defaultID)
        } else {
            defaultInputUID = nil
        }
    }

    // MARK: - CoreAudio 查询

    /// 枚举系统全部音频设备 ID
    private static func allDeviceIDs() -> [AudioDeviceID] {
        var address = kDevicesPropertyAddress
        let system = AudioObjectID(kAudioObjectSystemObject)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr,
              size > 0 else { return [] }
        let count = Int(size) / MemoryLayout<AudioDeviceID>.stride
        var ids = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    /// 设备输入方向的通道总数(遍历 input scope 的 stream configuration)
    private static func inputChannelCount(of deviceID: AudioDeviceID) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size) == noErr,
              size > 0 else { return 0 }
        // AudioBufferList 是变长结构,按实际字节数分配原始内存
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size),
                                                   alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, raw) == noErr else { return 0 }
        let bufferList = raw.bindMemory(to: AudioBufferList.self, capacity: 1)
        return UnsafeMutableAudioBufferListPointer(bufferList)
            .reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    /// 读 CFString 类型属性(设备名 / UID)。
    /// 这两个属性的文档均要求调用方负责释放返回的 CFString(+1 所有权),
    /// 故用 takeRetainedValue 交还给 ARC,避免泄漏。
    private static func stringProperty(_ selector: AudioObjectPropertySelector,
                                       of deviceID: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value) == noErr,
              let retained = value else { return nil }
        let string = retained.takeRetainedValue() as String
        return string.isEmpty ? nil : string
    }

    /// 读 UInt32 类型属性(transport type 等)
    private static func uint32Property(_ selector: AudioObjectPropertySelector,
                                       of deviceID: AudioDeviceID) -> UInt32? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    /// 系统默认输入设备 ID
    private static func defaultInputDeviceID() -> AudioDeviceID? {
        var address = kDefaultInputPropertyAddress
        let system = AudioObjectID(kAudioObjectSystemObject)
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &deviceID) == noErr,
              deviceID > 0 else { return nil }
        return deviceID
    }

    /// transport type → 设备类别。
    /// 连续互通采集设备的四字符码是 'ccap';系统常量 kAudioDeviceTransportTypeContinuityCapture
    /// 声明于 macOS 13 SDK,在 macOS 12 部署目标下引用会编译失败,这里硬编码数值(方案文档 6.1)。
    /// 常量显式转 UInt32:不同 SDK 版本下这些 C 常量的导入类型(Int32/UInt32)可能不同,
    /// 而这些四字符码都是正值,转换是安全的。
    /// internal(非 private)是为了让纯逻辑测试(Tests/logic_input)可直接验证映射表;
    /// 对外(public)API 不变。
    static func kind(forTransport transport: UInt32) -> AudioInputDevice.Kind {
        let continuityCapture = UInt32(0x63636170)  // 'ccap'
        switch transport {
        case UInt32(kAudioDeviceTransportTypeBuiltIn):
            return .builtIn
        case UInt32(kAudioDeviceTransportTypeUSB),
             UInt32(kAudioDeviceTransportTypeThunderbolt):
            return .usb
        case UInt32(kAudioDeviceTransportTypeBluetooth),
             UInt32(kAudioDeviceTransportTypeBluetoothLE):
            return .bluetooth
        case continuityCapture:
            return .continuity
        case UInt32(kAudioDeviceTransportTypeVirtual):
            return .virtualDevice
        case UInt32(kAudioDeviceTransportTypeAggregate):
            return .aggregate
        default:
            return .other
        }
    }
}

#endif
