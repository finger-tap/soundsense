//
//  main.swift
//  输入源功能纯逻辑断言测试(macOS,swiftc 直跑,与 Xcode 工程无关)
//
//  覆盖:
//    1. AudioInputDeviceManager.kind(forTransport:) transport → 设备类别映射
//    2. MeterViewModel.defaultOffset(forKind:) 校准预设
//    3. [String: Double] 校准字典的 UserDefaults 读写(loadOffsets 依赖的桥接转换)
//    4. 旧全局 calibrationOffset → 按设备字典的迁移(不丢用户已调好的值)
//    5. 按设备 key 的校准读写隔离(选中设备 vs systemDefault)
//
//  入口模式:main.swift 顶层代码同步,被测类型是 @MainActor,
//  故测试体放在 Task { @MainActor } 里,dispatchMain() 接管主线程。
//
import Foundation
import CoreAudio

var failures = 0
func expect(_ cond: Bool, _ name: String) {
    if cond { print("  ✓ \(name)") }
    else { failures += 1; print("  ✗ FAIL: \(name)") }
}

@MainActor
func runAllTests() async {
    let defaults = UserDefaults.standard
    let offsetsKey = "calibrationOffsetsByDevice"
    let legacyKey = "calibrationOffset"
    let uidKey = "inputDeviceUID"

    // ---- 1. transport → Kind 映射 ----
    do {
        // 'ccap' = 0x63636170:连续互通采集(iPhone 麦克风)
        expect(AudioInputDeviceManager.kind(forTransport: 0x63636170) == .continuity,
               "'ccap'(0x63636170) → continuity")
        expect(AudioInputDeviceManager.kind(forTransport: UInt32(kAudioDeviceTransportTypeBluetooth)) == .bluetooth,
               "Bluetooth → bluetooth")
        expect(AudioInputDeviceManager.kind(forTransport: UInt32(kAudioDeviceTransportTypeBluetoothLE)) == .bluetooth,
               "BluetoothLE → bluetooth")
        expect(AudioInputDeviceManager.kind(forTransport: UInt32(kAudioDeviceTransportTypeUSB)) == .usb,
               "USB → usb")
        expect(AudioInputDeviceManager.kind(forTransport: UInt32(kAudioDeviceTransportTypeThunderbolt)) == .usb,
               "Thunderbolt → usb")
        expect(AudioInputDeviceManager.kind(forTransport: UInt32(kAudioDeviceTransportTypeBuiltIn)) == .builtIn,
               "BuiltIn → builtIn")
        expect(AudioInputDeviceManager.kind(forTransport: UInt32(kAudioDeviceTransportTypeVirtual)) == .virtualDevice,
               "Virtual → virtualDevice")
        expect(AudioInputDeviceManager.kind(forTransport: UInt32(kAudioDeviceTransportTypeAggregate)) == .aggregate,
               "Aggregate → aggregate")
        expect(AudioInputDeviceManager.kind(forTransport: 0) == .other, "未知 0 → other")
        expect(AudioInputDeviceManager.kind(forTransport: 0x12345678) == .other, "未知值 → other")
    }

    // ---- 2. 校准预设(与 CalibrationDefaults 对齐:Mac 内建 100 / 外接 90 / iPhone 麦克风 120) ----
    do {
        expect(MeterViewModel.defaultOffset(forKind: .usb) == 90, "usb 预设 90(外接占位)")
        expect(MeterViewModel.defaultOffset(forKind: .bluetooth) == 90, "bluetooth 预设 90(外接占位)")
        expect(MeterViewModel.defaultOffset(forKind: .continuity) == 120, "continuity(iPhone 麦克风)预设 120")
        for kind: AudioInputDevice.Kind in [.builtIn, .virtualDevice, .aggregate, .other] {
            expect(MeterViewModel.defaultOffset(forKind: kind) == 100, "\(kind.rawValue) 预设 100")
        }
    }

    // ---- 3. [String: Double] 校准字典的 UserDefaults 桥接读写 ----
    // loadOffsets() 依赖 `dictionary(forKey:) as? [String: Double]`(NSNumber 桥接),
    // 这里直接验证该机制本身可靠(含整数值、小数值)。
    do {
        defaults.removeObject(forKey: offsetsKey)
        defaults.set(["devA": 85.0, "devB": 93.5], forKey: offsetsKey)
        let back = defaults.dictionary(forKey: offsetsKey) as? [String: Double]
        expect(back != nil, "字典 as? [String: Double] 转换成功")
        expect(back?["devA"] == 85.0 && back?["devB"] == 93.5, "Double 值往返(含小数)")
        // 整数值(如 93 而非 93.0)也必须能桥接成 Double
        defaults.set(["devC": 93], forKey: offsetsKey)
        let backInt = defaults.dictionary(forKey: offsetsKey) as? [String: Double]
        expect(backInt?["devC"] == 93.0, "Int 存储值桥接为 Double")
        // 无 key 时读出 nil → 代码里 ?? [:] 兜底
        defaults.removeObject(forKey: offsetsKey)
        expect(defaults.dictionary(forKey: offsetsKey) == nil, "无 key 时 dictionary(forKey:) 为 nil")
        defaults.removeObject(forKey: offsetsKey)
    }

    // ---- 4. 旧全局 calibrationOffset 迁移(经 CalibrationDefaults,不丢用户已调好的值) ----
    do {
        // 场景 A:只有旧自定义值 → 迁移进 systemDefault,ViewModel 读到旧值
        defaults.removeObject(forKey: offsetsKey)
        defaults.removeObject(forKey: uidKey)
        defaults.removeObject(forKey: "calibrationMigratedV2")
        defaults.set(88.0, forKey: legacyKey)
        let vm = MeterViewModel()
        expect(abs(vm.calibrationOffset - 88) < 0.001,
               "旧全局值 88 迁移为 systemDefault 校准 (得 \(vm.calibrationOffset))")
        let persisted = defaults.dictionary(forKey: offsetsKey) as? [String: Double]
        expect(persisted?["systemDefault"] == 88.0, "迁移结果已持久化到字典")

        // 场景 B:字典已有 systemDefault 值 → 不被旧值覆盖
        vm.calibrationOffset = 90
        defaults.set(70.0, forKey: legacyKey)  // 模拟旧值与字典并存
        let vm2 = MeterViewModel()
        expect(abs(vm2.calibrationOffset - 90) < 0.001,
               "字典已有值时旧全局值不覆盖 (得 \(vm2.calibrationOffset))")

        // 场景 C:旧默认 93 未手动改过 → 按 CalibrationDefaults 升级为 Mac 新默认 100
        defaults.removeObject(forKey: offsetsKey)
        defaults.removeObject(forKey: uidKey)
        defaults.removeObject(forKey: "calibrationMigratedV2")
        defaults.set(93.0, forKey: legacyKey)
        let vm3 = MeterViewModel()
        expect(abs(vm3.calibrationOffset - 100) < 0.001,
               "旧默认 93 自动升级为新默认 100 (得 \(vm3.calibrationOffset))")
    }

    // ---- 5. 按设备 key 的校准读写隔离 ----
    // 依赖真实设备枚举;沙箱/无设备环境下跳过并说明。
    do {
        defaults.removeObject(forKey: uidKey)
        let vm = MeterViewModel()
        vm.calibrationOffset = 90   // 写到 systemDefault
        let realDevices = vm.deviceManager.devices
        if let dev = realDevices.first {
            await vm.selectDevice(uid: dev.uid)
            expect(vm.selectedDeviceUID == dev.uid, "选中设备后 selectedDeviceUID 更新")
            expect(abs(vm.calibrationOffset - 100) < 0.001
                   || abs(vm.calibrationOffset - 90) < 0.001
                   || abs(vm.calibrationOffset - 120) < 0.001,
                   "新设备无记录 → 按类型预设 (得 \(vm.calibrationOffset))")
            vm.calibrationOffset = 80
            await vm.selectDevice(uid: nil)
            expect(vm.selectedDeviceUID == nil, "切回跟随系统默认")
            expect(abs(vm.calibrationOffset - 90) < 0.001,
                   "systemDefault 校准未被设备值串扰 (得 \(vm.calibrationOffset))")
            await vm.selectDevice(uid: dev.uid)
            expect(abs(vm.calibrationOffset - 80) < 0.001,
                   "设备专属校准值被记住 (得 \(vm.calibrationOffset))")
            await vm.selectDevice(uid: nil)
        } else {
            print("  - 跳过:本环境枚举不到输入设备(沙箱或无设备),设备隔离用例未执行")
        }
    }

    // ---- 6. 输入源选中状态(无真实设备也可验证) ----
    // 设置页的勾选只看“用户固定选择”,不能把系统默认设备也算成固定选择,
    // 否则“跟随系统默认”和具体设备会同时出现勾，且取消后仍像被选中。
    do {
        defaults.removeObject(forKey: uidKey)
        let vm = MeterViewModel()
        expect(vm.selectedDeviceUID == nil, "初始状态:跟随系统默认(无固定设备)")
        await vm.selectDevice(uid: "test-device-that-does-not-exist")
        expect(vm.selectedDeviceUID == nil, "不存在的设备不会留下固定选择")
        expect(!vm.devices.contains(where: { $0.uid == "test-device-that-does-not-exist" }),
               "无效 UID 不会意外进入设备列表")
    }

    // 清理测试写入的 defaults,不污染环境
    defaults.removeObject(forKey: offsetsKey)
    defaults.removeObject(forKey: legacyKey)
    defaults.removeObject(forKey: uidKey)
    defaults.removeObject(forKey: "calibrationMigratedV2")
}

Task { @MainActor in
    await runAllTests()
    if failures > 0 { print("\(failures) FAILURES"); exit(1) }
    print("ALL INPUT DEVICE TESTS PASSED")
    exit(0)
}
dispatchMain()
