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

    private enum CodingKeys: String, CodingKey {
        case relativeTime, spl
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        relativeTime = try c.decode(TimeInterval.self, forKey: .relativeTime)
        // null 表示本次采样是无有效声压的数字静音。
        spl = try c.decodeIfPresent(Float.self, forKey: .spl) ?? -Float.infinity
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(relativeTime, forKey: .relativeTime)
        if spl.isFinite {
            try c.encode(spl, forKey: .spl)
        } else {
            try c.encodeNil(forKey: .spl)
        }
    }
}

/// 测量进行中的实时统计(UI 实时刷新用)
public struct LiveMeasurementStats: Equatable {
    /// 已测量时长(秒)
    public let duration: TimeInterval
    /// 等效连续声级 LAeq(计权能量按时间积分,dB)
    public let laeq: Float
    /// 本次测量以来的最高时间计权 SPL(dB),即 LAFmax/LASmax(取决于 F/S)
    public let peak: Float
    /// 本时段内连续超过用户设定阈值的时长(秒)
    public let overLimitContinuous: TimeInterval
    /// 是否存在因处理积压被丢弃的样本。
    public var captureIncomplete: Bool = false
}

/// 一次测量的完整统计
public struct MeasurementStats: Codable, Equatable, Identifiable {
    public var id: TimeInterval { startTime.timeIntervalSince1970 }
    public let startTime: Date
    public let endTime: Date
    public let duration: TimeInterval
    /// 算术平均 SPL(dB)
    public let avgSPL: Float
    /// 等效连续声级 LAeq,T(计权能量按时间积分,dB)
    public let laeqSPL: Float
    /// 本次测量以来的最高时间计权 SPL(dB),即 LAFmax/LASmax/LCFmax/LCSmax。
    public let peakSPL: Float
    /// 统计分位数(基于 1 Hz 趋势点;噪声评价用 L10/L50/L90)
    public let l10: Float
    public let l50: Float
    public let l90: Float
    public let minSPL: Float
    /// 整场测量中 SPL ≥ 用户设定暴露阈值的累计时长(秒)
    public let overLimitTotal: TimeInterval
    /// 生成该记录时使用的暴露阈值(dB)。旧记录为 nil,按 85 dB 解释。
    public let exposureLimit: Float?
    /// 频率计权("A"/"C")。旧记录为 nil,按 A 计权兼容。
    public let weighting: String?
    /// 时间计权("F"/"S")。旧记录为 nil,按 F 计权兼容。
    public let timeWeighting: String?
    /// 本次统计是否覆盖了全部采集样本。旧记录为 nil，按 true 兼容。
    /// false 表示处理队列曾积压丢帧，Leq/峰值只能代表已处理部分。
    public let completeCapture: Bool?
    public let samples: [ReportSample]  // 趋势曲线用
    /// 关联录音文件名主干(Recordings/<audioID>.m4a);旧记录/无录音为 nil
    public var audioID: String?

    /// JSON 不能表示 -inf/nan。静音测量在运行时用 -inf 表达"无有效声压",
    /// 持久化时写成 null,读取时恢复 -inf,避免整批历史记录编码失败。
    private struct NullableLevel: Encodable {
        let value: Float

        func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            if value.isFinite {
                try container.encode(value)
            } else {
                try container.encodeNil()
            }
        }
    }

    private enum CodingKeys: String, CodingKey {
        case startTime, endTime, duration, avgSPL, laeqSPL, peakSPL
        case l10, l50, l90, minSPL, overLimitTotal, exposureLimit
        case weighting, timeWeighting, completeCapture, samples, audioID
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        startTime = try c.decode(Date.self, forKey: .startTime)
        endTime = try c.decode(Date.self, forKey: .endTime)
        duration = try c.decode(TimeInterval.self, forKey: .duration)
        avgSPL = try c.decodeIfPresent(Float.self, forKey: .avgSPL) ?? -Float.infinity
        laeqSPL = try c.decodeIfPresent(Float.self, forKey: .laeqSPL) ?? -Float.infinity
        peakSPL = try c.decodeIfPresent(Float.self, forKey: .peakSPL) ?? -Float.infinity
        minSPL = try c.decodeIfPresent(Float.self, forKey: .minSPL) ?? -Float.infinity
        overLimitTotal = try c.decode(TimeInterval.self, forKey: .overLimitTotal)
        exposureLimit = try c.decodeIfPresent(Float.self, forKey: .exposureLimit)
        weighting = try c.decodeIfPresent(String.self, forKey: .weighting)
        timeWeighting = try c.decodeIfPresent(String.self, forKey: .timeWeighting)
        completeCapture = try c.decodeIfPresent(Bool.self, forKey: .completeCapture)
        samples = try c.decode([ReportSample].self, forKey: .samples)
        audioID = try c.decodeIfPresent(String.self, forKey: .audioID)
        let computed = AcousticStatistics.from(samples: samples)
        l10 = try c.decodeIfPresent(Float.self, forKey: .l10) ?? computed?.l10 ?? 0
        l50 = try c.decodeIfPresent(Float.self, forKey: .l50) ?? computed?.l50 ?? 0
        l90 = try c.decodeIfPresent(Float.self, forKey: .l90) ?? computed?.l90 ?? 0
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(startTime, forKey: .startTime)
        try c.encode(endTime, forKey: .endTime)
        try c.encode(duration, forKey: .duration)
        try c.encode(NullableLevel(value: avgSPL), forKey: .avgSPL)
        try c.encode(NullableLevel(value: laeqSPL), forKey: .laeqSPL)
        try c.encode(NullableLevel(value: peakSPL), forKey: .peakSPL)
        try c.encode(NullableLevel(value: l10), forKey: .l10)
        try c.encode(NullableLevel(value: l50), forKey: .l50)
        try c.encode(NullableLevel(value: l90), forKey: .l90)
        try c.encode(NullableLevel(value: minSPL), forKey: .minSPL)
        try c.encode(overLimitTotal, forKey: .overLimitTotal)
        try c.encodeIfPresent(exposureLimit, forKey: .exposureLimit)
        try c.encodeIfPresent(weighting, forKey: .weighting)
        try c.encodeIfPresent(timeWeighting, forKey: .timeWeighting)
        try c.encodeIfPresent(completeCapture, forKey: .completeCapture)
        try c.encode(samples, forKey: .samples)
        try c.encodeIfPresent(audioID, forKey: .audioID)
    }

    public init(startTime: Date, endTime: Date, duration: TimeInterval,
                avgSPL: Float, laeqSPL: Float, peakSPL: Float,
                l10: Float? = nil, l50: Float? = nil, l90: Float? = nil,
                minSPL: Float,
                overLimitTotal: TimeInterval,
                exposureLimit: Float? = nil,
                weighting: String? = nil,
                timeWeighting: String? = nil,
                completeCapture: Bool? = nil,
                samples: [ReportSample],
                audioID: String? = nil) {
        self.startTime = startTime
        self.endTime = endTime
        self.duration = duration
        self.avgSPL = avgSPL
        self.laeqSPL = laeqSPL
        self.peakSPL = peakSPL
        let stats = AcousticStatistics.from(samples: samples)
        self.l10 = l10 ?? stats?.l10 ?? 0
        self.l50 = l50 ?? stats?.l50 ?? 0
        self.l90 = l90 ?? stats?.l90 ?? 0
        self.minSPL = minSPL
        self.overLimitTotal = overLimitTotal
        self.exposureLimit = exposureLimit
        self.weighting = weighting
        self.timeWeighting = timeWeighting
        self.completeCapture = completeCapture
        self.samples = samples
        self.audioID = audioID
    }

    /// 展示与导出用的暴露阈值。旧记录没有该字段时按 85 dB 兼容。
    public var resolvedExposureLimit: Float {
        guard let exposureLimit, exposureLimit.isFinite else {
            return MeasurementRecorder.defaultExposureLimit
        }
        return exposureLimit
    }

    /// 频率计权口径。旧记录没有该字段时按 A 计权兼容。
    public var resolvedWeighting: String {
        weighting?.uppercased() == "C" ? "C" : "A"
    }

    /// 时间计权口径。旧记录没有该字段时按 F 计权兼容。
    public var resolvedTimeWeighting: String {
        timeWeighting?.uppercased() == "S" ? "S" : "F"
    }

    /// 等效声级名称,如 LAeq / LCeq。
    public var leqMetricLabel: String {
        "L\(resolvedWeighting)eq"
    }

    /// 时间计权峰值名称,如 LAFmax / LASmax / LCFmax / LCSmax。
    public var peakMetricLabel: String {
        "L\(resolvedWeighting)\(resolvedTimeWeighting)max"
    }

    /// 报告是否覆盖全部采集样本。旧记录没有该字段，默认视为完整。
    public var isCompleteCapture: Bool {
        completeCapture ?? true
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
    /// 记录口径(A/C),报告与历史据此显示 LAeq/LCeq 等名称。
    public var weighting = "A"
    /// 记录口径(F/S),报告与历史据此显示 LAFmax/LASmax 等名称。
    public var timeWeighting = "F"

    public init(exposureLimit: Float = MeasurementRecorder.defaultExposureLimit) {
        self.exposureLimit = exposureLimit
    }

    private var samples: [ReportSample] = []
    private var startTime: Date?
    // 实时统计(所有帧参与,不只是每秒采样点)
    //
    // Leq 必须是能量 × 时间的积分,不能被 UI 回调节流或每秒趋势采样改变。
    // record() 因此接收 recorder 自身的两次调用时间差作为 dt,并在每个 dt 区间内
    // 使用该区间的能量值。调用方从同一 meter 下发连续帧时,这就是标准 Leq。
    private var energyTime: Double = 0
    private var frameTime: TimeInterval = 0
    /// 第一帧已处理的 hop 时长。用于 UI 显示与引擎稀疏回调时的基线，
    /// 避免把本次观测开始前的时间误算进测量时长。
    private var initialFrameDuration: TimeInterval = 0
    private var frameCount: Int = 0
    /// 核心 DBMeter 对整个会话的积分结果。和 UI 回调解耦,优先用于报告。
    private var meterLeq: Float?
    /// 引擎节流前看到的全部帧峰值。即使某次 UI 回调恰好没有触发,
    /// 下一次回调也会把这个峰值带进来,stop() 不应回退到 1 Hz 趋势点。
    private var enginePeak: Float?
    private var livePeak: Float = -.greatestFiniteMagnitude
    private var continuousOverSince: Date?  // 当前连续 ≥85dB 时段的起点
    private var totalOverSeconds: TimeInterval = 0
    private var lastFrameDate: Date?
    private var lastFrameSPL: Float?
    private var lastSampleDate: Date?
    /// 本场测量是否出现过处理队列丢帧。
    private var sessionCaptureIncomplete = false

    /// 开始一次新测量(清空旧数据)
    public func start() {
        samples.removeAll(keepingCapacity: true)
        startTime = nil
        energyTime = 0
        frameTime = 0
        initialFrameDuration = 0
        frameCount = 0
        meterLeq = nil
        enginePeak = nil
        livePeak = -.greatestFiniteMagnitude
        continuousOverSince = nil
        totalOverSeconds = 0
        lastFrameDate = nil
        lastFrameSPL = nil
        lastSampleDate = nil
        sessionCaptureIncomplete = false
    }

    /// 记录一帧时间计权 SPL(A/C 由引擎决定)。
    /// - Parameter spl: 当前显示值 LAF/LAS(dB)
    ///
    /// Leq 按真实时间间隔积分;趋势曲线仍每秒降采样一次。
    /// 注意:这里接收的是 F/S 时间计权后的值,因此用于趋势、峰值和暴露时长;
    /// 真正声学意义的 Leq 应使用同源的瞬时计权能量值(见 MeterResult.leqSPL)。
    public func record(spl: Float) {
        record(spl: spl, sessionPeak: nil, sessionLeq: nil, sessionLeqDuration: 0)
    }

    /// 记录一帧,同时接收引擎在节流前累计的全帧统计。
    /// - Parameters:
    ///   - spl: 当前时间计权显示值(趋势/峰值/暴露计时)
    ///   - sessionPeak: 引擎全部处理帧的峰值;nil 时回退到本方法收到的帧
    ///   - sessionLeq: 引擎按固定 hop 能量积分得到的 Leq;nil 时回退到本方法时间积分
    ///   - sessionLeqDuration: 引擎 Leq 覆盖时长(秒)
    public func record(spl: Float,
                       sessionPeak: Float?,
                       sessionLeq: Float?,
                       sessionLeqDuration: TimeInterval) {
        guard !sessionLeqDuration.isNaN else { return }
        let nowDate = Date()
        // 权限/设备准备完成后的第一帧才是真实测量起点。避免把启动等待
        // 当作静音计入报告时长和 Leq。
        if startTime == nil {
            startTime = nowDate
            lastFrameDate = nowDate
            initialFrameDuration = max(0, sessionLeqDuration)
        }
        guard let start = startTime else { return }
        let now = nowDate.timeIntervalSince(start)

        // 连续超限时长必须在更新 lastFrameDate 之前累加。超过 2 s 的跳变
        // 通常来自主线程卡顿/后台恢复，暴露计时不猜测整段状态。
        let frameDelta = lastFrameDate.map {
            max(0, min(nowDate.timeIntervalSince($0), 2.0))
        } ?? 0

        // 首帧只用当前帧建立基线;之后按完整帧间隔积分 Leq。主线程卡顿
        // 时仍要保持 Leq 的“总测量时长”分母，否则丢掉静音时段会把 Leq
        // 系统性抬高。间隔用左端点（上一帧）补满：不知道卡顿期间的真实
        // 变化时，保留最后一次已观测读数比用当前读数回填更少假设。
        if let last = lastFrameDate {
            let dt = max(0, nowDate.timeIntervalSince(last))
            if dt > 0 {
                let held = lastFrameSPL.flatMap { $0.isFinite ? $0 : nil }
                    ?? (spl.isFinite ? spl : nil)
                if let held {
                    let energy = pow(10.0, Double(held) / 10.0)
                    energyTime += energy * dt
                    frameTime += dt
                }
            }
        }

        // 每秒采样 1 个点
        if lastSampleDate == nil || nowDate.timeIntervalSince(lastSampleDate!) >= 1.0 {
            samples.append(ReportSample(relativeTime: now, spl: spl))
            lastSampleDate = nowDate
        }

        // 实时统计
        frameCount += 1
        if let peak = sessionPeak, peak.isFinite {
            enginePeak = max(enginePeak ?? peak, peak)
            livePeak = max(livePeak, peak)
        } else if spl > livePeak {
            livePeak = spl
        }
        if let leq = sessionLeq, leq.isFinite, sessionLeqDuration > 0 {
            meterLeq = leq
        }

        // 暴露时长:按帧间隔累加,只统计有限值
        if spl.isFinite {
            if spl >= exposureLimit {
                if continuousOverSince == nil { continuousOverSince = nowDate }
                totalOverSeconds += frameDelta
            } else {
                continuousOverSince = nil
            }
        }
        lastFrameDate = nowDate
        lastFrameSPL = spl
    }

    /// 当前实时统计(未开始或还没有帧返回 nil)
    public func liveStats() -> LiveMeasurementStats? {
        guard startTime != nil, frameCount > 0 else { return nil }
        return LiveMeasurementStats(
            // 与 Leq 的积分窗口保持一致。若真实回调暂时稀疏，下一次 record()
            // 会把间隔补进 Leq；这里不把尚未纳入统计的墙钟时间显示得更长。
            duration: max(initialFrameDuration, frameTime),
            laeq: meterLeq ?? Self.laeq(energyTime: energyTime, duration: frameTime),
            peak: livePeak,
            overLimitContinuous: continuousOverSince.map { Date().timeIntervalSince($0) } ?? 0,
            captureIncomplete: sessionCaptureIncomplete
        )
    }

    /// 由调用方在每帧写入引擎的完整性状态（0 = 完整）。
    public func updateCaptureCompleteness(droppedSampleCount: Int) {
        sessionCaptureIncomplete = droppedSampleCount > 0
    }

    /// 停止测量,返回统计。
    /// - Parameters:
    ///   - sessionPeak: 引擎排空音频队列后的最终峰值。
    ///   - sessionLeq: 引擎排空队列后的最终 Leq。
    ///   - sessionLeqDuration: 上述 Leq 覆盖的真实时长。
    public func stop(sessionPeak: Float? = nil,
                     sessionLeq: Float? = nil,
                     sessionLeqDuration: TimeInterval = 0,
                     captureStart: Date? = nil,
                     captureEnd: Date? = nil,
                     completeCapture: Bool = true) -> MeasurementStats? {
        defer {
            startTime = nil
            energyTime = 0
            frameTime = 0
            initialFrameDuration = 0
            frameCount = 0
            meterLeq = nil
            enginePeak = nil
            livePeak = -.greatestFiniteMagnitude
            continuousOverSince = nil
            totalOverSeconds = 0
            lastFrameDate = nil
            lastFrameSPL = nil
            lastSampleDate = nil
            sessionCaptureIncomplete = false
        }
        guard var start = startTime, frameCount > 0 else { return nil }
        // 引擎的真实采集区间优先于 UI 首/末回调时间。
        if let captureStart, captureEnd != nil,
           Date().timeIntervalSince(captureStart) < 86_400 {
            start = captureStart
        }
        let end = captureEnd ?? Date()
        let endDate = end.timeIntervalSince(start)
        let spls = samples.map { $0.spl }
        let avg = spls.isEmpty ? 0 : spls.reduce(0, +) / Float(spls.count)
        let acousticStats = AcousticStatistics.from(samples: samples)
        let tailDuration = max(0, min(end.timeIntervalSince(lastFrameDate ?? end), 2.0))
        let tailSPL = lastFrameSPL.flatMap { $0.isFinite ? $0 : nil }
        let finalLeq: Float
        if let sessionLeq, sessionLeq.isFinite, sessionLeqDuration > 0 {
            // stop 收尾时引擎已排空队列并处理尾样本，这里直接采用其最终值。
            finalLeq = sessionLeq
        } else if let leq = meterLeq {
            // 核心 Leq 是按真实 hop 时长积分的权威值,不受主线程回调节流影响。
            finalLeq = leq
        } else {
            if let tailSPL, tailDuration > 0 {
                energyTime += pow(10.0, Double(tailSPL) / 10.0) * tailDuration
                frameTime += tailDuration
            }
            finalLeq = Self.laeq(energyTime: energyTime, duration: frameTime)
        }

        if let lastSPL = lastFrameSPL, lastSPL >= exposureLimit {
            totalOverSeconds += tailDuration
        }
        let finalPeak: Float
        if let sessionPeak, sessionPeak.isFinite {
            finalPeak = sessionPeak
        } else {
            finalPeak = enginePeak ?? (livePeak.isFinite ? livePeak : (spls.max() ?? 0))
        }
        return MeasurementStats(
            startTime: start,
            endTime: end,
            duration: endDate,
            avgSPL: avg,
            laeqSPL: finalLeq,
            // 1 Hz 趋势点会漏掉短峰值;峰值必须来自全部帧。
            peakSPL: finalPeak,
            l10: acousticStats?.l10,
            l50: acousticStats?.l50,
            l90: acousticStats?.l90,
            minSPL: spls.min() ?? finalPeak,
            overLimitTotal: totalOverSeconds,
            exposureLimit: exposureLimit,
            weighting: weighting,
            timeWeighting: timeWeighting,
            completeCapture: completeCapture,
            samples: samples
        )
    }

    /// LAeq,T = 10·log10(Σ10^(Li/10)·dti / Σdti)
    private static func laeq(energyTime: Double, duration: TimeInterval) -> Float {
        guard duration > 0 else { return -.greatestFiniteMagnitude }
        guard energyTime > 0 else { return -Float.infinity }
        return Float(10 * log10(energyTime / duration))
    }
}
