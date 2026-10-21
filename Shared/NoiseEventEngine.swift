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
                              cutoff: Float = 200,
                              minimumFrequency: Float = 20) -> Float? {
    guard spectrum.count == frequencies.count, !spectrum.isEmpty else { return nil }
    var low: Float = 0
    var bandTotal: Float = 0
    for i in 0..<spectrum.count {
        let p = spectrum[i] * spectrum[i]
        // DC/near-DC 主要来自麦克风高通残留和手持壳体振动，不属于可听的
        // 低频噪音；若不排除，低频占比会长期虚高。
        if frequencies[i] >= minimumFrequency {
            bandTotal += p
            if frequencies[i] <= cutoff { low += p }
        }
    }
    // 分母使用 20 Hz 以上总功率，避免 DC/次声压低频占比，同时保留
    // “20–200 Hz / 20 Hz 以上”与旧版“低频 / 全频”近似的可比性。
    guard bandTotal > 0 else { return nil }
    return low / bandTotal
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
    /// 可选绝对阈值(dB)。设置后触发阈值取“背景阈值”和“绝对阈值”中较低者，
    /// 用于夜间更敏感地捕捉低强度异常声。
    public var absoluteThreshold: Float?
    /// 持续低于此时间的触发不算事件(秒)
    public var minEventDuration: TimeInterval = 0.2
    /// 结束确认滞回时长(秒)
    public var endHoldoff: TimeInterval = 2.0
    /// 结束后此间隔内的新触发并入上一事件(秒)
    public var mergeWindow: TimeInterval = 5.0
    /// 背景基线滑窗(秒)
    public var baselineWindow: TimeInterval = 60
    /// 基线 L90 的重算间隔(秒)。逐帧排序 60 秒窗口会在长时间监听里
    /// 产生可观的 CPU 开销，而 L90 没必要每 43ms 都变化。
    public var baselineUpdateInterval: TimeInterval = 1.0
    /// 低频特征刷新间隔可能长于一个 hop。超过此时长的旧特征不能继续
    /// 参与分类，否则事件会沿用发生前的频谱结论。
    public var maxLowRatioAge: TimeInterval = 1.25
    /// 事件明细内存上限。长时间监听可能产生大量事件；超过后只保留
    /// 最近的条目，累计数量与峰值仍由聚合字段完整保存。
    public var retainedEventLimit = 1_000
    /// 最近一条事件在合并窗口内再次触发时，需要临时从 events 取回
    /// 它的统计特征；若该明细已被上限淘汰，这里保留轻量副本。
    private var lastConfirmedEvent: NoiseEvent?
    /// 全新事件开始的回调(B 监听模式触发片段录制;并入 reopen 不触发)
    public var onEventStart: (() -> Void)?
    /// 触发阈值相对背景基线的增益(dB)。UI 用于解释当前灵敏度。
    public var currentThresholdDescription: String?

    // MARK: - 输出

    /// 已确认的事件(按时间顺序)
    public private(set) var events: [NoiseEvent] = []
    /// 本次会话累计确认的事件数(不受明细保留上限影响)
    public private(set) var totalEventCount = 0
    /// 因保留上限而移除的明细条数
    public private(set) var droppedEventCount = 0
    /// 本次会话所有已确认事件的峰值
    public private(set) var eventPeakSPL: Float = -.greatestFiniteMagnitude
    /// 近期事件用于类型统计；达到明细上限后仍能持续更新。
    private static let recentLowRatioLimit = 256
    private var recentLowRatios: [Float] = []
    private var recentLowRatioCursor = 0
    private var recentLowRatioSum: Float = 0
    /// 最近一条事件在 `recentLowRatios` 中的槽位；合并事件会替换
    /// 它的低频特征，而不是把同一事件重复采样两次。
    private var lastConfirmedLowRatioSlot: Int?

    // MARK: - 聚合统计(PositionStats 用)

    public private(set) var frameCount = 0
    public private(set) var minSPL: Float = .greatestFiniteMagnitude
    public private(set) var maxSPL: Float = -.greatestFiniteMagnitude
    /// 与当前运行 LAeq 相差 ≤3dB 的帧数(稳态近似)
    public private(set) var steadyCount = 0
    /// LAeq 实际覆盖的时间(秒)
    public private(set) var observedDuration: TimeInterval = 0

    // MARK: - 内部状态

    private struct Builder {
        var startTime: TimeInterval
        var startSPL: Float
        var peakSPL: Float
        var peakTime: TimeInterval
        var lowSum: Float = 0
        var lowCount = 0
        /// 短于 minEventDuration 的误触发不应启动片段录制；
        /// 达到最小时长后才通知监听器开始抓拍。
        var didNotifyStart = false
        /// 该 builder 是在 mergeWindow 内从上一事件继续出来的。
        /// 收口时它是同一事件，不能再增加累计事件数。
        var isContinuation = false

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
    private var energyTime: Double = 0
    private var lastFrameTime: TimeInterval?
    private var cachedBaseline: Float?
    private var baselineUpdatedAt: TimeInterval?
    private var latestLowRatio: Float?
    private var latestLowRatioTime: TimeInterval?

    public init() {}

    public func beginSession() {
        window.removeAll(keepingCapacity: true)
        events.removeAll(keepingCapacity: true)
        totalEventCount = 0
        droppedEventCount = 0
        eventPeakSPL = -.greatestFiniteMagnitude
        recentLowRatios.removeAll(keepingCapacity: true)
        recentLowRatioCursor = 0
        recentLowRatioSum = 0
        lastConfirmedLowRatioSlot = nil
        lastConfirmedEvent = nil
        builder = nil
        belowSince = nil
        frameCount = 0
        steadyCount = 0
        energyTime = 0
        observedDuration = 0
        lastFrameTime = nil
        cachedBaseline = nil
        baselineUpdatedAt = nil
        latestLowRatio = nil
        latestLowRatioTime = nil
        minSPL = .greatestFiniteMagnitude
        maxSPL = -.greatestFiniteMagnitude
    }

    /// 当前运行 LAeq(无帧返回 -inf)
    public func currentLaeq() -> Float {
        guard frameCount > 0, observedDuration > 0, energyTime > 0 else {
            return -.greatestFiniteMagnitude
        }
        return Float(10 * log10(energyTime / Double(observedDuration)))
    }

    /// 当前背景基线(滑窗 L90;窗不足返回 nil)
    public func currentBaseline() -> Float? {
        cachedBaseline
    }

    /// 近期事件的平均低频占比。长时间监听不会因事件明细淘汰而停止更新。
    public var recentAverageLowRatio: Float? {
        guard !recentLowRatios.isEmpty else { return nil }
        return recentLowRatioSum / Float(recentLowRatios.count)
    }

    /// 把当前仍处于活跃/结束滞回期的事件收口为快照,供停止监听时落库。
    /// 不修改引擎状态;调用方随后会丢弃该引擎。
    public func snapshotOpenEvent() -> NoiseEvent? {
        guard let b = builder else { return nil }
        let lastObserved = window.last?.t ?? b.startTime
        // 仍在最小时长内的触发只是候选，不应在停止时被伪造成事件。
        guard lastObserved - b.startTime >= minEventDuration else { return nil }
        // 已跌破阈值、只在等待 endHoldoff 时，事件实际止于 belowSince；
        // 停止时不能把后续静音滞回也算进事件时长。
        let end = belowSince ?? lastObserved
        let rise = b.peakTime - b.startTime
        let rate: Float = (b.peakSPL - b.startSPL) / Float(max(rise, 0.1))
        let avgLow: Float? = b.lowCount > 0 ? b.lowSum / Float(b.lowCount) : nil
        return NoiseEvent(startTime: b.startTime, endTime: end,
                          peakSPL: b.peakSPL, avgLowRatio: avgLow,
                          attackRate: rate)
    }

    /// 喂一帧。返回本次调用**刚确认结束**的事件(其余情况 nil)。
    @discardableResult
    public func feed(t: TimeInterval, spl: Float, lowRatio: Float?) -> NoiseEvent? {
        feed(t: t, duration: nil, spl: spl, lowRatio: lowRatio)
    }

    /// 喂一段音频的权威统计。
    /// - Parameters:
    ///   - duration: 该段样本覆盖的时长。传入时基线滑窗、事件持续/滞回/合并
    ///     全部按音频时钟推进，不受 UI 调度或后台回调间隔影响。
    ///   - t: 该段结束时的相对时间。
    @discardableResult
    public func feed(t: TimeInterval, duration: TimeInterval?,
                     spl: Float, lowRatio: Float?) -> NoiseEvent? {
        guard spl.isFinite, t.isFinite else { return nil }
        let frameDuration = max(0, duration ?? 0)
        let frameStart = max(0, t - frameDuration)

        // —— 聚合统计 ——
        let laeqBefore = currentLaeq()
        frameCount += 1
        if laeqBefore.isFinite, abs(spl - laeqBefore) <= 3 { steadyCount += 1 }
        if let last = lastFrameTime {
            let dt = duration.map { max(0, $0) } ?? max(0, t - last)
            if dt > 0 {
                energyTime += pow(10.0, Double(spl) / 10.0) * dt
                observedDuration += dt
            }
        }
        lastFrameTime = t
        if spl < minSPL { minSPL = spl }
        if spl > maxSPL { maxSPL = spl }

        // —— 基线滑窗 ——
        window.append((t, spl))
        while let first = window.first, t - first.t > baselineWindow {
            window.removeFirst()
        }
        if window.count >= 10 {
            let needsUpdate = baselineUpdatedAt.map {
                t - $0 >= baselineUpdateInterval
            } ?? true
            if needsUpdate || cachedBaseline == nil {
                let sorted = window.map { $0.spl }.sorted()
                cachedBaseline = sorted[Int(Float(sorted.count - 1) * 0.1)]
                baselineUpdatedAt = t
            }
        } else {
            cachedBaseline = nil
        }

        if let low = lowRatio {
            latestLowRatio = low
            latestLowRatioTime = t
        }
        let freshLowRatio: Float?
        if let low = latestLowRatio, let updatedAt = latestLowRatioTime,
           t - updatedAt <= maxLowRatioAge {
            freshLowRatio = low
        } else {
            freshLowRatio = nil
        }

        let threshold = triggerThreshold()
        if threshold.isFinite, let absolute = absoluteThreshold {
            let relative = threshold - Float(thresholdOverBackground)
            currentThresholdDescription = absolute < relative
                ? "绝对阈值 \(Int(absolute)) dB"
                : "背景 +\(Int(thresholdOverBackground)) dB"
        }
        var finished: NoiseEvent?

        if var b = builder {
            // —— 事件打开中(活跃或滞回) ——
            b.observe(spl: spl, lowRatio: freshLowRatio, at: t)
            if spl > threshold {
                belowSince = nil                       // 回升,继续同一事件
            } else if spl < threshold - hysteresis {
                if belowSince == nil { belowSince = frameStart }
            } else {
                // 介于两者:不进也不出,维持现状
            }
            // 只有仍处于阈值以上的事件达到最小时长后才开始抓拍；
            // 已经跌破阈值、只是在等待滞回确认的误触发不能创建空片段。
            if !b.didNotifyStart, belowSince == nil,
               t - b.startTime >= minEventDuration {
                b.didNotifyStart = true
                onEventStart?()
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
            if let last = lastConfirmedEvent, t - last.endTime <= mergeWindow {
                let continuedFromRetainedEvent = events.last == last
                if continuedFromRetainedEvent { events.removeLast() }
                var b = Builder(startTime: last.startTime,
                                startSPL: last.peakSPL,   // 近似:瞬时爬升
                                peakSPL: last.peakSPL,
                                peakTime: last.startTime)
                b.didNotifyStart = true
                b.isContinuation = true
                if let low = last.avgLowRatio { b.lowSum = low; b.lowCount = 1 }
                b.observe(spl: spl, lowRatio: freshLowRatio, at: t)
                builder = b
            } else {
                // t 是当前 hop 的结束时间，事件应从 hop 起点开始。
                var b = Builder(startTime: frameStart, startSPL: spl,
                                peakSPL: spl, peakTime: t)
                b.didNotifyStart = false
                b.observe(spl: spl, lowRatio: freshLowRatio, at: t)
                builder = b
            }
        }
        return finished
    }

    // MARK: - 内部

    private func triggerThreshold() -> Float {
        let base = currentBaseline() ?? .greatestFiniteMagnitude
        var th = base.isFinite ? base + thresholdOverBackground : .greatestFiniteMagnitude
        if let abs_ = absoluteThreshold, base.isFinite {
            th = min(th, abs_)
        }
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
        lastConfirmedEvent = event
        events.append(event)
        if !b.isContinuation {
            totalEventCount += 1
        }
        if event.peakSPL > eventPeakSPL { eventPeakSPL = event.peakSPL }
        if let low = avgLow {
            if b.isContinuation,
               let slot = lastConfirmedLowRatioSlot,
               slot < recentLowRatios.count {
                recentLowRatioSum += low - recentLowRatios[slot]
                recentLowRatios[slot] = low
            } else if recentLowRatios.count < Self.recentLowRatioLimit {
                lastConfirmedLowRatioSlot = recentLowRatios.count
                recentLowRatios.append(low)
                recentLowRatioSum += low
            } else {
                lastConfirmedLowRatioSlot = recentLowRatioCursor
                recentLowRatioSum += low - recentLowRatios[recentLowRatioCursor]
                recentLowRatios[recentLowRatioCursor] = low
                recentLowRatioCursor =
                    (recentLowRatioCursor + 1) % Self.recentLowRatioLimit
            }
        } else if !b.isContinuation {
            lastConfirmedLowRatioSlot = nil
        }
        if events.count > max(1, retainedEventLimit) {
            let overflow = events.count - max(1, retainedEventLimit)
            events.removeFirst(overflow)
            droppedEventCount += overflow
        }
        return event
    }
}
