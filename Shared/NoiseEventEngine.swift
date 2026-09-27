//
//  NoiseEventEngine.swift
//  SoundSense
//
//  噪音事件引擎(纯逻辑,多端复用):背景基线 + 瞬态事件检测 + 合并 + 类型特征。
//  输入为逐帧 (相对时间, SPL, 低频功率占比);输出离散噪音事件与聚合统计。
//
//  事件判定:SPL > 背景(滑窗 L90) + thresholdOverBackground 或 > absoluteThreshold,
//  持续 ≥ minEventDuration 才算事件;回落到 阈值−hysteresis 以下连续 endHoldoff 秒
//  确认结束;结束 mergeWindow 秒内的新触发并入上一事件。
//

import Foundation

/// 频谱低频功率占比(< cutoff)。spectrum 为幅度谱,与 frequencies 一一对应。
public func lowFrequencyRatio(spectrum: [Float], frequencies: [Float],
                              cutoff: Float = 200) -> Float? {
    guard spectrum.count == frequencies.count, !spectrum.isEmpty else { return nil }
    var low: Float = 0
    var total: Float = 0
    for i in 0..<spectrum.count {
        let p = spectrum[i] * spectrum[i]
        total += p
        if frequencies[i] <= cutoff { low += p }
    }
    guard total > 0 else { return nil }
    return low / total
}

/// 一次离散噪音事件
public struct NoiseEvent: Equatable, Codable {
    public var startTime: TimeInterval
    public var endTime: TimeInterval
    public var peakSPL: Float
    /// 事件帧平均低频占比(无频谱数据时为 nil)
    public var avgLowRatio: Float?
    /// 起振陡度 dB/s(理想方波脉冲为 0;真实缓起声音为正)
    public var attackRate: Float

    public var duration: TimeInterval { endTime - startTime }
}

public final class NoiseEventEngine {

    // MARK: - 可调参数

    /// 触发阈值:背景基线 + 此值(dB)
    public var thresholdOverBackground: Float = 10
    /// 结束滞回:低于(阈值−此值)连续 endHoldoff 秒确认结束
    public var hysteresis: Float = 3
    /// 可选绝对阈值(dB)。设置后触发阈值取两者较大(夜间模式用)
    public var absoluteThreshold: Float?
    /// 持续低于此时间的触发不算事件(秒)
    public var minEventDuration: TimeInterval = 0.2
    /// 结束确认滞回时长(秒)
    public var endHoldoff: TimeInterval = 2.0
    /// 结束后此间隔内的新触发并入上一事件(秒)
    public var mergeWindow: TimeInterval = 5.0
    /// 背景基线滑窗(秒)
    public var baselineWindow: TimeInterval = 60

    /// 全新事件开始的回调(B 监听模式触发片段录制;并入 reopen 不触发)
    public var onEventStart: (() -> Void)?

    // MARK: - 输出

    /// 已确认的事件(按时间顺序)
    public private(set) var events: [NoiseEvent] = []

    // MARK: - 聚合统计(PositionStats 用)

    public private(set) var frameCount = 0
    public private(set) var minSPL: Float = .greatestFiniteMagnitude
    public private(set) var maxSPL: Float = -.greatestFiniteMagnitude
    /// 与当前运行 LAeq 相差 ≤3dB 的帧数(稳态近似)
    public private(set) var steadyCount = 0

    // MARK: - 内部状态

    private struct Builder {
        var startTime: TimeInterval
        var startSPL: Float
        var peakSPL: Float
        var peakTime: TimeInterval
        var lowSum: Float = 0
        var lowCount = 0

        mutating func observe(spl: Float, lowRatio: Float?, at t: TimeInterval) {
            if spl > peakSPL { peakSPL = spl; peakTime = t }
            if let low = lowRatio { lowSum += low; lowCount += 1 }
        }
    }

    /// 基线滑窗 (t, spl)
    private var window: [(t: TimeInterval, spl: Float)] = []
    /// 打开中的事件(活跃或结束滞回期);nil = 空闲
    private var builder: Builder?
    private var belowSince: TimeInterval?
    private var energySum: Double = 0

    public init() {}

    public func beginSession() {
        window.removeAll(keepingCapacity: true)
        events.removeAll(keepingCapacity: true)
        builder = nil
        belowSince = nil
        frameCount = 0
        steadyCount = 0
        energySum = 0
        minSPL = .greatestFiniteMagnitude
        maxSPL = -.greatestFiniteMagnitude
    }

    /// 当前运行 LAeq(无帧返回 -inf)
    public func currentLaeq() -> Float {
        guard frameCount > 0, energySum > 0 else { return -.greatestFiniteMagnitude }
        return Float(10 * log10(energySum / Double(frameCount)))
    }

    /// 当前背景基线(滑窗 L90;窗不足返回 nil)
    public func currentBaseline() -> Float? {
        guard window.count >= 10 else { return nil }
        let sorted = window.map { $0.spl }.sorted()
        return sorted[Int(Float(sorted.count - 1) * 0.1)]
    }

    /// 喂一帧。返回本次调用**刚确认结束**的事件(其余情况 nil)。
    @discardableResult
    public func feed(t: TimeInterval, spl: Float, lowRatio: Float?) -> NoiseEvent? {
        // —— 聚合统计 ——
        let laeqBefore = currentLaeq()
        frameCount += 1
        if laeqBefore.isFinite, abs(spl - laeqBefore) <= 3 { steadyCount += 1 }
        energySum += pow(10.0, Double(spl) / 10.0)
        if spl < minSPL { minSPL = spl }
        if spl > maxSPL { maxSPL = spl }

        // —— 基线滑窗 ——
        window.append((t, spl))
        while let first = window.first, t - first.t > baselineWindow {
            window.removeFirst()
        }

        let threshold = triggerThreshold()
        var finished: NoiseEvent?

        if var b = builder {
            // —— 事件打开中(活跃或滞回) ——
            b.observe(spl: spl, lowRatio: lowRatio, at: t)
            if spl > threshold {
                belowSince = nil                       // 回升,继续同一事件
            } else if spl < threshold - hysteresis {
                if belowSince == nil { belowSince = t }
            } else {
                // 介于两者:不进也不出,维持现状
            }
            if let since = belowSince, t - since >= endHoldoff {
                // 结束确认(收口后 builder 保持 nil,不得复活)
                builder = nil
                belowSince = nil
                finished = close(builder: &b, endTime: since)
            } else {
                builder = b
            }
        } else if spl > threshold {
            // —— 空闲中越限:并入上一事件 或 开新事件 ——
            if let last = events.last, t - last.endTime <= mergeWindow {
                events.removeLast()
                var b = Builder(startTime: last.startTime,
                                startSPL: last.peakSPL,   // 近似:瞬时爬升
                                peakSPL: last.peakSPL,
                                peakTime: last.startTime)
                if let low = last.avgLowRatio { b.lowSum = low; b.lowCount = 1 }
                b.observe(spl: spl, lowRatio: lowRatio, at: t)
                builder = b
            } else {
                var b = Builder(startTime: t, startSPL: spl,
                                peakSPL: spl, peakTime: t)
                b.observe(spl: spl, lowRatio: lowRatio, at: t)
                builder = b
                onEventStart?()
            }
        }
        return finished
    }

    // MARK: - 内部

    private func triggerThreshold() -> Float {
        let base = currentBaseline() ?? .greatestFiniteMagnitude
        var th = base.isFinite ? base + thresholdOverBackground : .greatestFiniteMagnitude
        if let abs_ = absoluteThreshold, base.isFinite { th = max(th, abs_) }
        return th
    }

    /// 收口:时长不足丢弃;否则入 events 并返回
    private func close(builder b: inout Builder, endTime: TimeInterval) -> NoiseEvent? {
        guard endTime - b.startTime >= minEventDuration else { return nil }
        let rise = b.peakTime - b.startTime
        let rate: Float = (b.peakSPL - b.startSPL) / Float(max(rise, 0.1))
        let avgLow: Float? = b.lowCount > 0 ? b.lowSum / Float(b.lowCount) : nil
        let event = NoiseEvent(startTime: b.startTime, endTime: endTime,
                               peakSPL: b.peakSPL, avgLowRatio: avgLow, attackRate: rate)
        events.append(event)
        return event
    }
}
