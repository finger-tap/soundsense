//
//  MeasurementRecorder.swift
//  SoundSense
//
//  测量数据记录器:按每秒 1 个点的粒度采样,停止时生成统计报告。
//  跨平台(iOS / macOS 共用)。
//

import Foundation

/// 单个采样点:相对开始时间(秒)+ SPL
public struct ReportSample: Equatable, Codable {
    public let relativeTime: TimeInterval  // 距测量开始的秒数
    public let spl: Float

    public init(relativeTime: TimeInterval, spl: Float) {
        self.relativeTime = relativeTime
        self.spl = spl
    }
}

/// 测量进行中的实时统计(UI 实时刷新用)
public struct LiveMeasurementStats: Equatable {
    /// 已测量时长(秒)
    public let duration: TimeInterval
    /// 等效连续声级 LAeq(能量平均,dB)
    public let laeq: Float
    /// 峰值 SPL(dB)
    public let peak: Float
    /// 本时段内连续超过 85 dB 的时长(秒)
    public let overLimitContinuous: TimeInterval
}

/// 一次测量的完整统计
public struct MeasurementStats: Codable, Equatable, Identifiable {
    public var id: TimeInterval { startTime.timeIntervalSince1970 }
    public let startTime: Date
    public let endTime: Date
    public let duration: TimeInterval
    /// 算术平均 SPL(dB)
    public let avgSPL: Float
    /// 等效连续声级 LAeq(能量平均,dB)——声学上更规范
    public let laeqSPL: Float
    public let peakSPL: Float
    public let minSPL: Float
    /// 整场测量中 SPL ≥ 85 dB 的累计时长(秒)
    public let overLimitTotal: TimeInterval
    public let samples: [ReportSample]  // 趋势曲线用
    /// 关联录音文件名主干(Recordings/<audioID>.m4a);旧记录/无录音为 nil
    public var audioID: String?

    public init(startTime: Date, endTime: Date, duration: TimeInterval,
                avgSPL: Float, laeqSPL: Float, peakSPL: Float, minSPL: Float,
                overLimitTotal: TimeInterval, samples: [ReportSample],
                audioID: String? = nil) {
        self.startTime = startTime
        self.endTime = endTime
        self.duration = duration
        self.avgSPL = avgSPL
        self.laeqSPL = laeqSPL
        self.peakSPL = peakSPL
        self.minSPL = minSPL
        self.overLimitTotal = overLimitTotal
        self.samples = samples
        self.audioID = audioID
    }
}

/// 测量记录器:每秒采样 1 个 SPL,停止时生成统计。
/// 额外维护实时统计(LAeq / 峰值 / 暴露时长)供 UI 测量中刷新。
public final class MeasurementRecorder {

    /// 默认暴露阈值:长期暴露开始损害听力(NIOSH / WHO 建议)
    public static let defaultExposureLimit: Float = 85
    /// 连续超过阈值多久后触发警告(秒)
    public static let warningAfter: TimeInterval = 30

    /// 暴露警告阈值(dB),可由用户配置
    public var exposureLimit: Float

    public init(exposureLimit: Float = MeasurementRecorder.defaultExposureLimit) {
        self.exposureLimit = exposureLimit
    }

    private var samples: [ReportSample] = []
    private var startTime: Date?
    private var lastSampleTime: TimeInterval = -1  // 上次采样的相对时间(秒)

    // 实时统计(所有帧参与,不只是每秒采样点)
    private var energySum: Double = 0   // Σ 10^(Li/10),LAeq 累加器
    private var frameCount: Int = 0
    private var livePeak: Float = -.greatestFiniteMagnitude
    private var continuousOverSince: Date?  // 当前连续 ≥85dB 时段的起点
    private var totalOverSeconds: TimeInterval = 0
    private var lastFrameDate: Date?

    /// 开始一次新测量(清空旧数据)
    public func start() {
        samples.removeAll(keepingCapacity: true)
        startTime = Date()
        lastSampleTime = -1
        energySum = 0
        frameCount = 0
        livePeak = -.greatestFiniteMagnitude
        continuousOverSince = nil
        totalOverSeconds = 0
        lastFrameDate = Date()
    }

    /// 记录一帧 SPL。距上次记录 ≥ 1 秒才真正存一个点(降采样)。
    /// - Parameter spl: 当前 SPL(A 计权)
    public func record(spl: Float) {
        guard let start = startTime else { return }
        let nowDate = Date()
        let now = nowDate.timeIntervalSince(start)
        // 每秒采样 1 个点
        if now - lastSampleTime >= 1.0 {
            samples.append(ReportSample(relativeTime: now, spl: spl))
            lastSampleTime = now
        }

        // 实时统计
        energySum += pow(10.0, Double(spl) / 10.0)
        frameCount += 1
        if spl > livePeak { livePeak = spl }

        // 暴露时长:按帧间隔累加,只统计有限值
        if spl.isFinite {
            if spl >= exposureLimit {
                if continuousOverSince == nil { continuousOverSince = nowDate }
                if let last = lastFrameDate {
                    totalOverSeconds += nowDate.timeIntervalSince(last)
                }
            } else {
                continuousOverSince = nil
            }
        }
        lastFrameDate = nowDate
    }

    /// 当前实时统计(未开始或还没有帧返回 nil)
    public func liveStats() -> LiveMeasurementStats? {
        guard let start = startTime, frameCount > 0 else { return nil }
        return LiveMeasurementStats(
            duration: Date().timeIntervalSince(start),
            laeq: Self.laeq(energySum: energySum, frames: frameCount),
            peak: livePeak,
            overLimitContinuous: continuousOverSince.map { Date().timeIntervalSince($0) } ?? 0
        )
    }

    /// 停止测量,返回统计(样本不足 2 个返回 nil)
    public func stop() -> MeasurementStats? {
        defer {
            startTime = nil
            energySum = 0
            frameCount = 0
            livePeak = -.greatestFiniteMagnitude
            continuousOverSince = nil
            totalOverSeconds = 0
            lastFrameDate = nil
        }
        guard let start = startTime, samples.count >= 2 else { return nil }
        let end = Date()
        let spls = samples.map { $0.spl }
        let avg = spls.reduce(0, +) / Float(spls.count)
        return MeasurementStats(
            startTime: start,
            endTime: end,
            duration: end.timeIntervalSince(start),
            avgSPL: avg,
            laeqSPL: Self.laeq(energySum: energySum, frames: frameCount),
            peakSPL: spls.max() ?? 0,
            minSPL: spls.min() ?? 0,
            overLimitTotal: totalOverSeconds,
            samples: samples
        )
    }

    /// LAeq = 10·log10(Σ10^(Li/10) / n) —— 能量平均
    private static func laeq(energySum: Double, frames: Int) -> Float {
        guard frames > 0, energySum > 0 else { return 0 }
        return Float(10 * log10(energySum / Double(frames)))
    }
}
