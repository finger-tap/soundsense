//
//  SourceTendencyAnalyzer.swift
//  SoundSense
//
//  声源倾向判定器(纯逻辑,多端复用):
//  依据三点位(中央/靠墙/靠顶)统计判定"倾向楼上/隔壁/无法判断 + 置信度",
//  依据事件率/低频占比/稳态占比分类噪音类型,并为监听事件做位置推测。
//
//  输出均为推测性质,UI 侧必须带"仅供参考"类文案。
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
    /// 接近 LAeq(±3dB) 的帧占比
    public let steadyRatio: Float

    public init(name: String, laeq: Float, minSPL: Float, maxSPL: Float,
                eventCount: Int, avgLowRatio: Float, steadyRatio: Float) {
        self.name = name
        self.laeq = laeq
        self.minSPL = minSPL
        self.maxSPL = maxSPL
        self.eventCount = eventCount
        self.avgLowRatio = avgLowRatio
        self.steadyRatio = steadyRatio
    }
}

/// 三点测试结论
public enum TendencyVerdict: String, Codable {
    case upstairs, neighbor, inconclusive
}

public enum Confidence: String, Codable {
    case low, medium, high
}

public enum NoiseType: String, Codable {
    case impact, continuous, mixed, unknown
}

/// 一次三点测试的完整结果(存储/同步/展示共用)
public struct SourceTestResult: Codable, Equatable, Identifiable {
    public let id: UUID
    public let startTime: Date
    public let duration: TimeInterval
    /// 顺序固定 [中央, 靠墙, 靠顶]
    public let positions: [PositionStats]
    public let verdict: TendencyVerdict
    public let confidence: Confidence
    public let noiseType: NoiseType
    /// 测试录音(Recordings/Tests/<audioID>.m4a);手表测试/无录音为 nil
    public var audioID: String?

    public init(id: UUID = UUID(), startTime: Date, duration: TimeInterval,
                positions: [PositionStats], verdict: TendencyVerdict,
                confidence: Confidence, noiseType: NoiseType, audioID: String? = nil) {
        self.id = id
        self.startTime = startTime
        self.duration = duration
        self.positions = positions
        self.verdict = verdict
        self.confidence = confidence
        self.noiseType = noiseType
        self.audioID = audioID
    }
}

public enum SourceTendencyAnalyzer {

    /// 判定常量(调参入口)
    /// 有效增益下限 / 主导侧领先下限(dB)
    public static let minGain: Float = 2
    public static let dominanceGap: Float = 2
    /// 置信度分界:主导增益 ≥5 高 / ≥3 中 / 其余低(dB)
    public static let highGain: Float = 5
    public static let mediumGain: Float = 3

    /// 三点位判定。positions 顺序 [中央, 靠墙, 靠顶]。
    public static func analyze(positions: [PositionStats],
                               duration: TimeInterval) -> (verdict: TendencyVerdict,
                                                           confidence: Confidence,
                                                           noiseType: NoiseType) {
        let (verdict, confidence) = verdictAndConfidence(positions)
        let type = classifyType(positions: positions, duration: duration)
        return (verdict, confidence, type)
    }

    private static func verdictAndConfidence(
        _ positions: [PositionStats]) -> (TendencyVerdict, Confidence) {
        guard positions.count == 3 else { return (.inconclusive, .low) }
        let center = positions[0].laeq
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

    /// 噪音类型:事件率 + 低频占比 + 稳态占比
    private static func classifyType(positions: [PositionStats],
                                     duration: TimeInterval) -> NoiseType {
        guard duration > 0, !positions.isEmpty else { return .unknown }
        let totalEvents = positions.reduce(0) { $0 + $1.eventCount }
        let rate = Float(totalEvents) / Float(duration / 60)   // 事件/分钟
        let avgLow = positions.map { $0.avgLowRatio }.reduce(0, +) / Float(positions.count)
        let avgSteady = positions.map { $0.steadyRatio }.reduce(0, +) / Float(positions.count)
        if rate >= 6 { return .impact }
        if rate >= 2 && avgLow >= 0.5 { return .impact }
        if avgSteady >= 0.6 && rate < 2 { return .continuous }
        if rate >= 2 || avgSteady >= 0.6 { return .mixed }
        return .unknown
    }

    /// 监听事件的点位推测(启发式;有标定时提升一致结论的表述)
    public static func guessPosition(lowRatio: Float, isImpact: Bool,
                                     calibration: SourceTestResult?) -> String {
        if isImpact {
            if lowRatio >= 0.5 {
                if calibration?.verdict == .upstairs { return "楼上(推测·标定一致)" }
                return "楼上(推测)"
            }
            return "不确定"
        }
        // 连续声(说话/电视/音乐)典型为穿墙空气传声
        if calibration?.verdict == .neighbor { return "隔壁(推测·标定一致)" }
        return "隔壁(推测)"
    }
}
