//
//  MeasurementRecorder.swift
//  SoundSense
//
//  测量数据记录器:按每秒 1 个点的粒度采样,停止时生成统计报告。
//  跨平台(iOS / macOS 共用)。
//

import Foundation

/// 单个采样点:相对开始时间(秒)+ SPL
public struct ReportSample: Equatable {
    public let relativeTime: TimeInterval  // 距测量开始的秒数
    public let spl: Float
}

/// 一次测量的完整统计
public struct MeasurementStats {
    public let startTime: Date
    public let endTime: Date
    public let duration: TimeInterval
    public let avgSPL: Float
    public let peakSPL: Float
    public let minSPL: Float
    public let samples: [ReportSample]  // 趋势曲线用
}

/// 测量记录器:每秒采样 1 个 SPL,停止时生成统计。
public final class MeasurementRecorder {

    private var samples: [ReportSample] = []
    private var startTime: Date?
    private var lastSampleTime: TimeInterval = -1  // 上次采样的相对时间(秒)

    public init() {}

    /// 开始一次新测量(清空旧数据)
    public func start() {
        samples.removeAll(keepingCapacity: true)
        startTime = Date()
        lastSampleTime = -1
    }

    /// 记录一帧 SPL。距上次记录 ≥ 1 秒才真正存一个点(降采样)。
    /// - Parameter spl: 当前 SPL(A 计权)
    public func record(spl: Float) {
        guard let start = startTime else { return }
        let now = Date().timeIntervalSince(start)
        // 每秒采样 1 个点
        if now - lastSampleTime >= 1.0 {
            samples.append(ReportSample(relativeTime: now, spl: spl))
            lastSampleTime = now
        }
    }

    /// 停止测量,返回统计(样本不足 2 个返回 nil)
    public func stop() -> MeasurementStats? {
        guard let start = startTime, samples.count >= 2 else {
            startTime = nil
            return nil
        }
        let end = Date()
        let spls = samples.map { $0.spl }
        let avg = spls.reduce(0, +) / Float(spls.count)
        let peak = spls.max() ?? 0
        let minSPL = spls.min() ?? 0
        let stats = MeasurementStats(
            startTime: start,
            endTime: end,
            duration: end.timeIntervalSince(start),
            avgSPL: avg,
            peakSPL: peak,
            minSPL: minSPL,
            samples: samples
        )
        startTime = nil
        return stats
    }
}
