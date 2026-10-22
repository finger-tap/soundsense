//
//  SourceTendencyAnalyzer.swift
//  SoundSense
//
//  声源倾向判定器(纯逻辑,多端复用):
//  依据四点位(中央基准/靠墙/靠顶/中央复测)统计判定
//  "倾向楼上/隔壁/无法判断 + 置信度",并拒绝时间漂移过大的测试。
//  依据事件率/低频占比/稳态占比分类噪音类型,并为监听事件做位置推测。
//
//  输出均为方向倾向推测,不是声学三维定位;UI 侧必须带"仅供参考"类文案。
//

import Foundation

/// 单个点位统计(由测试 VM 从 NoiseEventEngine 聚合构建)
public struct PositionStats: Codable, Equatable {
    public let name: String
    public let laeq: Float
    public let minSPL: Float
    public let maxSPL: Float
    public let eventCount: Int
    /// 事件帧平均低频占比(无频谱时 0)
    public let avgLowRatio: Float
    /// 接近该点最终 LAeq(±3dB) 的帧占比。旧记录中可能按运行 LAeq 累积。
    public let steadyRatio: Float
    /// 当前聚合器实际积分覆盖的时长(秒);旧记录无此字段时为 nil。
    public let observedDuration: TimeInterval?

    public init(name: String, laeq: Float, minSPL: Float, maxSPL: Float,
                eventCount: Int, avgLowRatio: Float, steadyRatio: Float,
                observedDuration: TimeInterval? = nil) {
        self.name = name
        self.laeq = laeq
        self.minSPL = minSPL
        self.maxSPL = maxSPL
        self.eventCount = eventCount
        self.avgLowRatio = avgLowRatio
        self.steadyRatio = steadyRatio
        self.observedDuration = observedDuration
    }
}

/// 声源方向倾向结论
public enum TendencyVerdict: String, Codable {
    case upstairs, neighbor, inconclusive
}

public enum Confidence: String, Codable {
    case low, medium, high
}

public enum NoiseType: String, Codable {
    case impact, continuous, mixed, unknown
}

/// 一次方向倾向测试的完整结果(存储/同步/展示共用)
public struct SourceTestResult: Codable, Equatable, Identifiable {
    public let id: UUID
    public let startTime: Date
    public let duration: TimeInterval
    /// 当前流程为 [中央基准, 靠墙, 靠顶, 中央复测];
    /// 旧记录兼容 [中央, 靠墙, 靠顶]。
    public let positions: [PositionStats]
    public let verdict: TendencyVerdict
    public let confidence: Confidence
    public let noiseType: NoiseType
    /// 中央基准与复测的 LAeq 差值;旧三位置记录无此字段时为 nil。
    public let centerDrift: Float?
    /// 是否因环境变化导致本次方向结论不可用。
    public let rejectedByDrift: Bool
    /// 测试录音(Recordings/Tests/<audioID>.m4a);手表测试/无录音为 nil
    public var audioID: String?

    public init(id: UUID = UUID(), startTime: Date, duration: TimeInterval,
                positions: [PositionStats], verdict: TendencyVerdict,
                confidence: Confidence, noiseType: NoiseType,
                centerDrift: Float? = nil, rejectedByDrift: Bool = false,
                audioID: String? = nil) {
        self.id = id
        self.startTime = startTime
        self.duration = duration
        self.positions = positions
        self.verdict = verdict
        self.confidence = confidence
        self.noiseType = noiseType
        self.centerDrift = centerDrift
        self.rejectedByDrift = rejectedByDrift
        self.audioID = audioID
    }

    private enum CodingKeys: String, CodingKey {
        case id, startTime, duration, positions, verdict, confidence, noiseType
        case centerDrift, rejectedByDrift, audioID
    }

    /// 兼容旧版三位置 JSON:缺少漂移字段时按“未拒绝”解码。
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        startTime = try c.decode(Date.self, forKey: .startTime)
        duration = try c.decode(TimeInterval.self, forKey: .duration)
        positions = try c.decode([PositionStats].self, forKey: .positions)
        verdict = try c.decode(TendencyVerdict.self, forKey: .verdict)
        confidence = try c.decode(Confidence.self, forKey: .confidence)
        noiseType = try c.decode(NoiseType.self, forKey: .noiseType)
        centerDrift = try c.decodeIfPresent(Float.self, forKey: .centerDrift)
        rejectedByDrift = try c.decodeIfPresent(Bool.self, forKey: .rejectedByDrift) ?? false
        audioID = try c.decodeIfPresent(String.self, forKey: .audioID)
    }
}

/// 点位统计累积器(与 NoiseEventEngine 配合使用;iOS/watch VM 共用)
public struct PositionStatsBuilder {
    /// 稳态近似只需要逐帧的 SPL 分布；保留每个 hop 的完整数组会让
    /// 过夜监听积累到几十万项。这里保留一个足够精确的确定性蓄水池样本。
    private static let retainedSampleLimit = 20_000
    public private(set) var frameCount = 0
    public private(set) var energySum: Double = 0
    public private(set) var observedDuration: TimeInterval = 0
    public private(set) var minSPL: Float = .greatestFiniteMagnitude
    public private(set) var maxSPL: Float = -.greatestFiniteMagnitude
    public private(set) var steadyCount = 0
    /// 用于收尾时计算最终稳态占比的确定性加权样本。
    /// 每次压缩都把相邻两项合并并累加权重，因此权重总和始终等于帧数。
    private var frameSamples: [(spl: Float, weight: Int)] = []
    private var compactionParity = 0
    private var lastFrameTime: TimeInterval?
    private var lastFrameSPL: Float?

    public init() {}

    /// 按帧到达时间做能量 × 时间积分。同一帧的多个消费者(Builder 和
    /// NoiseEventEngine)必须传同一个相对时间，不能各自再取一次 Date()。
    public mutating func observe(spl: Float, at t: TimeInterval) {
        observe(spl: spl, duration: lastFrameTime.map { max(0, t - $0) }, at: t)
    }

    /// 按一段音频的权威时长积分。`duration` 为 nil 时退回相邻时间差。
    public mutating func observe(spl: Float, duration: TimeInterval?,
                                 at t: TimeInterval) {
        guard spl.isFinite, t.isFinite else { return }
        let laeq = currentLaeq()
        frameCount += 1
        if laeq.isFinite, abs(spl - laeq) <= 3 { steadyCount += 1 }
        if frameSamples.count >= Self.retainedSampleLimit {
            // 成对合并相邻样本并累加权重，保留约一半内存；交替选择
            // 每组代表，避免长期只偏向固定奇偶位置的帧。
            var compacted: [(spl: Float, weight: Int)] = []
            compacted.reserveCapacity(
                frameSamples.count / 2 + frameSamples.count % 2 + 1)
            var index = 0
            if compactionParity == 1 {
                compacted.append(frameSamples[0])
                index = 1
            }
            while index < frameSamples.count {
                if index + 1 < frameSamples.count {
                    let keep = compactionParity == 0 ? index : index + 1
                    compacted.append((
                        spl: frameSamples[keep].spl,
                        weight: frameSamples[index].weight
                            + frameSamples[index + 1].weight
                    ))
                    index += 2
                } else {
                    compacted.append(frameSamples[index])
                    index += 1
                }
            }
            frameSamples = compacted
            compactionParity ^= 1
        }
        frameSamples.append((spl, 1))
        let dt = duration.map { max(0, $0) }
            ?? lastFrameTime.map { max(0, t - $0) }
            ?? 0
        if dt > 0 {
            energySum += pow(10.0, Double(spl) / 10.0) * dt
            observedDuration += dt
        }
        lastFrameTime = t
        lastFrameSPL = spl
        if spl < minSPL { minSPL = spl }
        if spl > maxSPL { maxSPL = spl }
    }

    public func currentLaeq() -> Float {
        guard observedDuration > 0, energySum > 0 else { return -.greatestFiniteMagnitude }
        return Float(10 * log10(energySum / Double(observedDuration)))
    }

    /// 收尾积分：把最后一个回调到停表之间的尾段也计入 Leq。
    public mutating func finish(at t: TimeInterval) {
        guard let last = lastFrameTime, let spl = lastFrameSPL, t > last else { return }
        // 尾段没有更细的样本，按最后已知 SPL 保持计算。
        energySum += pow(10.0, Double(spl) / 10.0) * (t - last)
        observedDuration += t - last
        lastFrameTime = t
        recomputeSteadyCount()
    }

    /// 结合该点位的事件引擎,生成 PositionStats
    public func snapshot(name: String, engine: NoiseEventEngine) -> PositionStats {
        let finalLaeq = currentLaeq()
        let steady = finalLaeq.isFinite
            ? frameSamples.reduce(0) { partial, sample in
                partial + (abs(sample.spl - finalLaeq) <= 3
                           ? sample.weight : 0)
            }
            : steadyCount
        return PositionStats(
            name: name,
            laeq: finalLaeq,
            minSPL: minSPL.isFinite ? minSPL : 0,
            maxSPL: maxSPL.isFinite ? maxSPL : 0,
            eventCount: engine.totalEventCount,
            avgLowRatio: engine.recentAverageLowRatio ?? 0,
            steadyRatio: frameCount > 0 ? Float(steady) / Float(frameCount) : 0,
            observedDuration: observedDuration)
    }

    /// 结束点位时先补齐最后一段，再生成最终快照。
    /// 调用方若已提前保存了近似快照，应直接用返回值替换，不能追加。
    public mutating func finishAndSnapshot(name: String,
                                           engine: NoiseEventEngine,
                                           endTime: TimeInterval) -> PositionStats {
        finish(at: endTime)
        return snapshot(name: name, engine: engine)
    }

    /// 稳态占比必须在点位结束后相对最终 LAeq 重算,不能拿运行初期的 LAeq 做基准。
    private mutating func recomputeSteadyCount() {
        let finalLaeq = currentLaeq()
        guard finalLaeq.isFinite else {
            steadyCount = 0
            return
        }
        steadyCount = frameSamples.reduce(0) { partial, sample in
            partial + (abs(sample.spl - finalLaeq) <= 3
                       ? sample.weight : 0)
        }
    }
}

/// 方向测试点位时间轴。一个分析 hop 可能跨过 30 秒边界，必须按音频时长
/// 拆成前一点位尾段和后一点位首段，不能把整帧只归给任意一侧。
public enum SourceTestTimeline {
    public static func split(elapsed: TimeInterval,
                             duration: TimeInterval,
                             positionDuration: TimeInterval)
        -> (current: TimeInterval, overflow: TimeInterval) {
        let safeDuration = max(0, duration)
        let remaining = max(0, positionDuration - max(0, elapsed))
        let current = min(safeDuration, remaining)
        return (current, max(0, safeDuration - current))
    }
}

/// 对逐帧 SPL 序列计算标准噪声统计量。
/// - 输入应使用同一时间计权(F/S)下的显示值;帧序列只作一次性报告分析。
/// - `samples` 为 (相对时间, SPL),按时间升序更佳,内部会重新排序。
public struct AcousticStatistics: Equatable {
    public let laeq: Float
    public let l10: Float
    public let l50: Float
    public let l90: Float
    public let peak: Float

    /// 用等时间间隔样本计算分位数;实际测量建议传入每秒 1 点的趋势序列。
    public static func from(samples: [ReportSample]) -> AcousticStatistics? {
        // 历史数据或导入数据可能并非按时间排序。先稳定排序再做时间积分,
        // 否则负 dt 会被丢弃,导致 Leq 覆盖时长与样本数量不一致。
        let valid = samples
            .filter { $0.spl.isFinite && $0.relativeTime.isFinite }
            .sorted { $0.relativeTime < $1.relativeTime }
        guard !valid.isEmpty else { return nil }

        var energyTime: Double = 0
        var duration: TimeInterval = 0
        for i in valid.indices {
            let level = pow(10.0, Double(valid[i].spl) / 10.0)
            let dt: TimeInterval
            if i + 1 < valid.count {
                dt = max(0, valid[i + 1].relativeTime - valid[i].relativeTime)
            } else if i > 0 {
                dt = max(0, valid[i].relativeTime - valid[i - 1].relativeTime)
            } else {
                dt = 1
            }
            if dt > 0 {
                energyTime += level * dt
                duration += dt
            }
        }

        let sorted = valid.map(\.spl).sorted()
        func exceeded(_ percentage: Float) -> Float {
            // L10/L50/L90 = 测量时间内分别有 10/50/90% 的声级超过它,
            // 即升序分布的 90/50/10% 分位。传入的是“超过时间占比”。
            let rank = max(0, min(sorted.count - 1,
                                  Int(ceil((1 - percentage / 100)
                                           * Float(sorted.count - 1)))))
            return sorted[rank]
        }
        let laeq = duration > 0 && energyTime > 0
            ? Float(10 * log10(energyTime / Double(duration)))
            : -.greatestFiniteMagnitude
        return AcousticStatistics(laeq: laeq,
                                  l10: exceeded(10),
                                  l50: exceeded(50),
                                  l90: exceeded(90),
                                  peak: sorted.last ?? 0)
    }
}

public enum SourceTendencyAnalyzer {

    /// 判定常量(调参入口)
    /// 有效增益下限 / 主导侧领先下限(dB)
    public static let minGain: Float = 3
    public static let dominanceGap: Float = 2.5
    /// 置信度分界:主导增益 ≥6 高 / ≥3.5 中 / 其余低(dB)
    public static let highGain: Float = 6
    public static let mediumGain: Float = 3.5
    /// 中央基准与复测相差超过此值时,时间和环境已发生明显变化,不再下结论。
    public static let maxCenterDrift: Float = 2
    /// 冲击类事件上限(秒)。更长的持续声不能仅因为低频重就判成脚步/撞击。
    public static let maxImpactDuration: TimeInterval = 3
    /// 连续声下限(秒)。与监听事件的收口窗口一致。
    public static let minContinuousDuration: TimeInterval = 8

    /// 方向倾向判定。positions 顺序 [中央, 靠墙, 靠顶] 或
    /// [中央, 靠墙, 靠顶, 中央复测]。
    public static func analyze(positions: [PositionStats],
                               duration: TimeInterval) -> (verdict: TendencyVerdict,
                                                           confidence: Confidence,
                                                           noiseType: NoiseType,
                                                           centerDrift: Float?,
                                                           rejectedByDrift: Bool) {
        let drift = centerDrift(positions)
        let rejected = drift.map { $0 > maxCenterDrift } ?? false
        let (verdict, confidence) = rejected
            ? (.inconclusive, .low)
            : verdictAndConfidence(positions)
        let type = classifyType(positions: positions, duration: duration)
        return (verdict, confidence, type, drift, rejected)
    }

    private static func verdictAndConfidence(
        _ positions: [PositionStats]) -> (TendencyVerdict, Confidence) {
        guard positions.count == 3 || positions.count == 4 else {
            return (.inconclusive, .low)
        }
        // 非有限值会让 max()/差值比较产生看似“主导”的伪结论。
        guard positions.allSatisfy({ $0.laeq.isFinite }) else {
            return (.inconclusive, .low)
        }
        let center = averageCenter(positions)
        let wallGain = positions[1].laeq - center
        let ceilingGain = positions[2].laeq - center
        let wallDominant = wallGain >= minGain && wallGain - ceilingGain >= dominanceGap
        let ceilingDominant = ceilingGain >= minGain && ceilingGain - wallGain >= dominanceGap
        let dominant = max(wallGain, ceilingGain)
        let confidence: Confidence
        if dominant >= highGain { confidence = .high }
        else if dominant >= mediumGain { confidence = .medium }
        else { confidence = .low }
        if wallDominant { return (.neighbor, confidence) }
        if ceilingDominant { return (.upstairs, confidence) }
        return (.inconclusive, .low)
    }

    /// 有复测时取前后中央的能量平均作为基准;旧三位置记录只用首个中央。
    private static func averageCenter(_ positions: [PositionStats]) -> Float {
        if positions.count == 4 {
            let first = Double(positions[0].laeq)
            let repeatLevel = Double(positions[3].laeq)
            return Float(10 * log10((pow(10, first / 10) + pow(10, repeatLevel / 10)) / 2))
        }
        return positions[0].laeq
    }

    public static func centerDrift(_ positions: [PositionStats]) -> Float? {
        guard positions.count == 4,
              positions[0].laeq.isFinite,
              positions[3].laeq.isFinite else { return nil }
        return abs(positions[3].laeq - positions[0].laeq)
    }

    /// 噪音类型:事件率 + 低频占比 + 稳态占比
    private static func classifyType(positions: [PositionStats],
                                     duration: TimeInterval) -> NoiseType {
        guard duration > 0, !positions.isEmpty else { return .unknown }
        // 复测中央只用于漂移校验,不能重复计入声学类型统计。
        let typePositions = positions.count == 4 ? Array(positions.prefix(3)) : positions
        let observed = typePositions.compactMap { $0.observedDuration }.reduce(0, +)
        let classifiedDuration = observed > 0 ? observed : duration
        let totalEvents = typePositions.reduce(0) { $0 + $1.eventCount }
        let rate = Float(totalEvents) / Float(max(classifiedDuration, 1) / 60) // 事件/分钟
        let avgLow = typePositions.map { $0.avgLowRatio }.reduce(0, +)
            / Float(typePositions.count)
        let avgSteady = typePositions.map { $0.steadyRatio }.reduce(0, +)
            / Float(typePositions.count)

        // “混合”必须优先于单向分类：事件密集但持续底噪也很明显时，
        // 若先判 impact，会把实际同时存在的持续声完全吞掉。
        if avgSteady >= 0.6 && rate >= 2 { return .mixed }
        if rate >= 6 { return .impact }
        if rate >= 2 && avgLow >= 0.5 { return .impact }
        if avgSteady >= 0.6 && rate < 2 { return .continuous }
        if rate >= 2 || avgSteady >= 0.6 { return .mixed }
        return .unknown
    }

    /// 监听事件的点位推测(启发式;有标定时提升一致结论的表述)
    public static func guessPosition(lowRatio: Float, isImpact: Bool,
                                     calibration: SourceTestResult?) -> String {
        // 被中央漂移校验拒绝的历史结果不能当作有效标定。
        let calibration = calibration?.rejectedByDrift == true ? nil : calibration
        // 未完成房间标定时，不能仅凭低频把冲击声归到楼上。低频既可能来自
        // 楼上脚步，也可能来自窗外交通、楼下设备或室内空调。
        guard let calibration else {
            return isImpact ? "位置未标定" : "不确定"
        }
        guard calibration.confidence != .low else { return "不确定（标定置信度低）" }
        if isImpact {
            if calibration.verdict == .upstairs,
               lowRatio >= 0.5 {
                return "楼上(推测·标定一致)"
            }
            return calibration.verdict == .neighbor
                ? "不确定（与墙体标定不一致）"
                : "不确定"
        }
        // 连续声更接近空气传声；只有房间标定明确指向隔壁时，才给出
        // “标定一致”的提示，不能把每次连续声默认解释成隔壁。
        if calibration.verdict == .neighbor {
            return "隔壁(推测·标定一致)"
        }
        return "不确定"
    }

    /// 仅根据事件的时域形态判断是否为冲击类，不使用低频占比。
    /// 低频占比说明能量分布，不能说明它是不是撞击。
    public static func isImpactLike(duration: TimeInterval,
                                    attackRate: Float) -> Bool {
        guard duration > 0, duration <= maxImpactDuration else { return false }
        // 极短事件即使起振率受 43ms hop 限制接近 0，也按瞬态处理；
        // 较长事件若仍在 3 秒内，需要明显的快速起振。
        return duration <= 1.5 || attackRate >= 8
    }

    /// 监听事件的类型与位置推测统一入口，避免 iOS/macOS 两套规则漂移。
    public static func classifyMonitorEvent(lowRatio: Float?,
                                            duration: TimeInterval,
                                            attackRate: Float,
                                            calibration: SourceTestResult?)
        -> (type: NoiseType, guess: String) {
        let isImpact = isImpactLike(duration: duration, attackRate: attackRate)
        let type: NoiseType
        if isImpact {
            type = .impact
        } else if duration >= minContinuousDuration {
            type = .continuous
        } else {
            type = .unknown
        }
        let guess = guessPosition(lowRatio: lowRatio ?? 0,
                                  isImpact: isImpact,
                                  calibration: calibration)
        return (type, guess)
    }

    // MARK: - 展示文案(多端共用)

    public static func verdictText(_ v: TendencyVerdict) -> String {
        switch v {
        case .upstairs: return "倾向楼上"
        case .neighbor: return "倾向隔壁"
        case .inconclusive: return "无法判断"
        }
    }

    public static func driftText(_ drift: Float?) -> String? {
        guard let drift else { return nil }
        return String(format: "中央复测漂移 %.1f dB", drift)
    }

    /// 展示用一句话结论,统一包含“方向倾向”和漂移拒绝语义。
    public static func summaryText(_ result: SourceTestResult) -> String {
        if result.rejectedByDrift {
            let drift = result.centerDrift.map { String(format: "%.1f dB", $0) } ?? "超过阈值"
            return "环境变化过大，本次不下方向结论（中央漂移 \(drift)）"
        }
        return "\(verdictText(result.verdict)) · 置信度 \(confidenceText(result.confidence))"
    }

    public static func confidenceText(_ c: Confidence) -> String {
        switch c {
        case .high: return "较高"
        case .medium: return "中等"
        case .low: return "较低"
        }
    }

    public static func typeText(_ t: NoiseType) -> String {
        switch t {
        case .impact: return "脚步/撞击类"
        case .continuous: return "说话/电视类"
        case .mixed: return "混合"
        case .unknown: return "未知"
        }
    }
}
