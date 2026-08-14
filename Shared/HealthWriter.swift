//
//  HealthWriter.swift
//  SoundSense iOS
//
//  Apple 健康集成:把每次测量的等效声级(LAeq)写入健康 App 的
//  "环境声级暴露",与耳机音量数据并列展示。仅 iOS。
//

#if os(iOS)

import Foundation
import HealthKit
import UIKit

/// 健康数据写入器。健康权限不可用 / 未授权时静默失败,不影响测量。
@MainActor
enum HealthWriter {

    /// 健康功能是否可用(模拟器 / iPad 无健康 App 时为 false)
    static var isAvailable: Bool {
        HKHealthStore.isHealthDataAvailable()
    }

    /// 请求写入授权(用户在设置里打开开关时调用一次)
    static func requestAuthorization() async -> Bool {
        guard isAvailable,
              let type = HKObjectType.quantityType(forIdentifier: .environmentalAudioExposure)
        else { return false }
        let store = HKHealthStore()
        return await withCheckedContinuation { continuation in
            store.requestAuthorization(toShare: [type], read: []) { success, _ in
                continuation.resume(returning: success)
            }
        }
    }

    /// 写入一次测量的等效声级(测量停止时调用)
    static func save(stats: MeasurementStats) async {
        guard isAvailable, stats.duration >= 60,
              let type = HKObjectType.quantityType(forIdentifier: .environmentalAudioExposure)
        else { return }
        let store = HKHealthStore()
        let unit = HKUnit.decibelAWeightedSoundPressureLevel()
        let quantity = HKQuantity(unit: unit, doubleValue: Double(stats.laeqSPL))
        let sample = HKQuantitySample(type: type,
                                      quantity: quantity,
                                      start: stats.startTime,
                                      end: stats.endTime,
                                      metadata: [
                                        HKMetadataKeyDeviceName: UIDevice.current.name,
                                      ])
        do {
            try await store.save([sample])
        } catch {
            // 静默失败:健康写入是附加能力,不阻塞主流程
        }
    }
}

#endif
