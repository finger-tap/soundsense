//
//  SoundSenseCore.swift
//  SoundSenseCore
//
//  核心算法库 -- 从 PCM 样本计算 A 计权声压级。
//  只依赖 Accelerate，不依赖 AVFoundation，方便移植到 iOS。
//

import Foundation
import Accelerate

// MARK: - 公共类型

/// 一次测量结果
public struct MeterResult: CustomStringConvertible, Equatable {
    /// 全频段 dBFS（未计权），用于调试对比
    public let dbfsFlat: Float
    /// A/C 计权后的 dBFS，用于调试对比
    public let dbfsAWeighted: Float
    /// 时间计权后的声压级 = 能量域指数平均(IEC 61672 F/S) + offset。
    /// 计权方式由 config.weighting 决定（A 或 C），字段名沿用历史。
    public let splA: Float
    /// 本帧瞬时声压级（未做时间计权），调试对比用
    public let splInstant: Float
    /// 本次测量以来的等效连续声级 Leq（按计权能量积分，与 F/S 显示检波器无关）
    public let leqSPL: Float
    /// Leq 实际覆盖的时长（秒）。用于报告和诊断，不依赖 UI 回调频率。
    public let leqDuration: TimeInterval
    /// 因处理队列积压而丢弃的样本数。正常应为 0。
    public let droppedSampleCount: Int
    /// 本次测量丢弃的样本累计数。正常应为 0。
    public let totalDroppedSampleCount: Int
    /// 本结果覆盖的音频时长(秒)。由采样位置与采样率得出，不依赖 UI 调度。
    public let coveredDuration: TimeInterval
    /// 本结果对应的第一个新积分样本的累计位置。
    /// 长会话需要按结果增量消费时，可用它与上一帧的结束位置判断是否有跳帧。
    public let samplePosition: Int64
    /// 本结果新增积分覆盖的样本数。首帧只统计最后一个 hop。
    public let integratedSampleCount: Int
    /// `samplePosition` 对应的输出采样率。重建 DBMeter 时累计位置会保留，
    /// 但采样率变化后不能直接比较两个位置。
    public let sampleRate: Float
    /// 当前记录的 Leq 是否覆盖了全部已采集样本。
    public var measurementCoverageComplete: Bool {
        totalDroppedSampleCount == 0
    }
    /// FFT 前半段幅度谱（0 ~ Nyquist），用于绘制频谱图，可选
    public let spectrum: [Float]
    /// 对应频谱每个 bin 的中心频率
    public let frequencies: [Float]

    public var description: String {
        let dropped = totalDroppedSampleCount > 0
            ? ", dropped \(totalDroppedSampleCount)"
            : ""
        return String(format: "dBFS(flat)=%6.1f  dBFS(A)=%6.1f  SPL=%5.1f dB (inst %5.1f, Leq %5.1f / %.2fs%@)",
                      dbfsFlat, dbfsAWeighted, splA, splInstant,
                      leqSPL, leqDuration, dropped)
    }
}

/// 时间计权（IEC 61672-1）：对均方声压（能量域）做一阶指数平均，
/// 时间常数 Fast = 125 ms，Slow = 1 s。绝不能在 dB 域做平均。
public enum TimeWeighting: String, Equatable, CaseIterable {
    /// F: τ = 125 ms，常规测量（默认）
    case fast
    /// S: τ = 1 s，起伏大的环境取平均观感
    case slow

    /// 指数平均时间常数（秒）
    public var tau: TimeInterval {
        switch self {
        case .fast: return 0.125
        case .slow: return 1.0
        }
    }

    public var label: String {
        switch self {
        case .fast: return "F (125 ms)"
        case .slow: return "S (1 s)"
        }
    }
}

/// 计权方式
public enum Weighting: String, Equatable {
    /// A 计权:模拟人耳响度感受,环境噪音标准(默认)
    case a
    /// C 计权:低频衰减少,适合测低频噪音(音响、空调、机械)
    case c
}

/// 分贝计配置
public struct MeterConfig {
    public var sampleRate: Float
    public var fftSize: Int
    public var calibrationOffset: Float
    public var weighting: Weighting
    /// 时间计权(F/S)，默认 Fast(125 ms)
    public var timeWeighting: TimeWeighting
    /// 是否计算 FFT 频谱。长监听不需要完整频谱时关闭可显著降低 CPU 和耗电。
    public var spectrumEnabled: Bool
    /// 关闭 `spectrumEnabled` 时仍以较低频率计算低频频谱。
    ///
    /// 监听/事件分类只需要 <200 Hz 功率占比，不需要每 hop 都做完整 FFT。
    /// 无频谱时低频占比会变成 nil，进而把所有冲击声误判成未知类型。
    public var lowBandAnalysisInterval: TimeInterval

    public init(sampleRate: Float = 48000,
                fftSize: Int = 4096,
                calibrationOffset: Float = 0,
                weighting: Weighting = .a,
                timeWeighting: TimeWeighting = .fast,
                spectrumEnabled: Bool = true,
                lowBandAnalysisInterval: TimeInterval = 0.5) {
        self.sampleRate = sampleRate
        self.fftSize = fftSize
        self.calibrationOffset = calibrationOffset
        self.weighting = weighting
        self.timeWeighting = timeWeighting
        self.spectrumEnabled = spectrumEnabled
        self.lowBandAnalysisInterval = lowBandAnalysisInterval
    }
}

// MARK: - AWeighting 滤波器

/// IEC 61672 A 计权传递函数。
///
/// A 计权模拟人耳对中高频更敏感的特性：
/// - 1~5 kHz 附近增益最大（约 +0.5~+1.3 dB）
/// - 低频被大幅衰减（100 Hz ≈ -19 dB，20 Hz ≈ -50 dB）
/// - 高端逐渐滚降（10 kHz ≈ -5 dB）
public enum AWeighting {

    /// 计算给定频率的 A 计权增益（dB）。
    /// 解析公式来自 IEC 61672-1 的模拟传递函数。
    public static func gain(at frequency: Float) -> Float {
        if frequency <= 0 { return -.greatestFiniteMagnitude }

        let f2 = frequency * frequency
        let numerator = 12194.0 * 12194.0 * f2 * f2
        let denominator = (f2 + 20.6 * 20.6)
            * sqrt((f2 + 107.7 * 107.7) * (f2 + 737.9 * 737.9))
            * (f2 + 12194.0 * 12194.0)
        let ra = numerator / denominator

        // 归一化：f = 1000 Hz 时的 Ra
        let f0: Float = 1000
        let f02 = f0 * f0
        let num0 = 12194.0 * 12194.0 * f02 * f02
        let den0 = (f02 + 20.6 * 20.6)
            * sqrt((f02 + 107.7 * 107.7) * (f02 + 737.9 * 737.9))
            * (f02 + 12194.0 * 12194.0)
        let raMax = num0 / den0

        // A(f) = 20·log10(Ra(f) / Ra(1000))。
        // IEC 61672-1 的 A(f) = 20·log10(Ra) + 2.00，其中 +2.00 恰等于
        // -20·log10(Ra(1000))（Ra(1000)=0.7943），故按 1 kHz 归一化即等价。
        return 20.0 * log10(ra / raMax)
    }

    /// 批量计算频率数组对应的 A 计权线性振幅倍数。
    public static func linearGains(for frequencies: [Float]) -> [Float] {
        frequencies.map { f in pow(10.0, gain(at: f) / 20.0) }
    }
}

/// IEC 61672 C 计权:低频衰减远小于 A 计权,
/// 用于评估低频噪音(音响、空调、机械振动)的实际声能。
public enum CWeighting {

    public static func gain(at frequency: Float) -> Float {
        if frequency <= 0 { return -.greatestFiniteMagnitude }

        // IEC 61672-1 C 计权只有两个极点(A 计权专属的 107.7/737.9
        // 中频谐振因子不属于 C):
        //   Rc(f) = 12194²·f² / ((f²+20.6²)·(f²+12194²))
        let f2 = frequency * frequency
        let numerator = 12194.0 * 12194.0 * f2
        let denominator = (f2 + 20.6 * 20.6) * (f2 + 12194.0 * 12194.0)
        let rc = numerator / denominator

        // 归一化:f = 1000 Hz 时的 Rc
        let f0: Float = 1000
        let f02 = f0 * f0
        let num0 = 12194.0 * 12194.0 * f02
        let den0 = (f02 + 20.6 * 20.6) * (f02 + 12194.0 * 12194.0)
        let rcMax = num0 / den0

        return 20.0 * log10(rc / rcMax)
    }

    public static func linearGains(for frequencies: [Float]) -> [Float] {
        frequencies.map { f in pow(10.0, gain(at: f) / 20.0) }
    }
}

// MARK: - 时域 A/C 计权滤波器

/// IEC 61672 A/C 计权的时域 IIR 实现。
///
/// 计权不能只在频谱图上做修正:声级计的 RMS 检波器、F/S 时间计权和 Leq
/// 都应作用在同一条计权后的时域信号上。这里用模拟原型极点经
/// 预畸变双线性变换得到稳定的数字极点,再在 1 kHz 归一化。
///
/// 双线性变换在高频段会产生频率压缩;为了不把这种误差带入声级,
/// 在原型极点之后加一个可优化的数字极点,并用三次多项式补偿高频响应。
/// 拟合只在初始化时做一次,目标曲线直接来自 IEC 61672 的解析式。
public struct WeightingFilter {

    /// 一个二阶 IIR section。`a1/a2` 采用
    /// `H(z) = (b0 + b1 z^-1 + b2 z^-2) / (1 + a1 z^-1 + a2 z^-2)` 的符号。
    private struct Section {
        let b0: Double
        let b1: Double
        let b2: Double
        let a1: Double
        let a2: Double
        var x1: Double = 0
        var x2: Double = 0
        var y1: Double = 0
        var y2: Double = 0

        mutating func process(_ x: Double) -> Double {
            let y = b0 * x + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
            x2 = x1
            x1 = x
            y2 = y1
            y1 = y
            return y
        }

        func magnitude(z1r: Double, z1i: Double,
                       z2r: Double, z2i: Double) -> Double {
            let nr = b0 + b1 * z1r + b2 * z2r
            let ni = b1 * z1i + b2 * z2i
            let dr = 1 + a1 * z1r + a2 * z2r
            let di = a1 * z1i + a2 * z2i
            let n2 = nr * nr + ni * ni
            let d2 = dr * dr + di * di
            guard d2 > 1e-30 else { return 0 }
            return sqrt(max(0, n2 / d2))
        }
    }

    /// 补偿双线性变换高频压缩的三次 FIR。
    private struct TrimFIR {
        let b0: Double
        let b1: Double
        let b2: Double
        let b3: Double
        var x1: Double = 0
        var x2: Double = 0
        var x3: Double = 0

        mutating func process(_ x: Double) -> Double {
            let y = b0 * x + b1 * x1 + b2 * x2 + b3 * x3
            x3 = x2
            x2 = x1
            x1 = x
            return y
        }

        func magnitude(z1r: Double, z1i: Double,
                       z2r: Double, z2i: Double,
                       z3r: Double, z3i: Double) -> Double {
            let r = b0 + b1 * z1r + b2 * z2r + b3 * z3r
            let i = b1 * z1i + b2 * z2i + b3 * z3i
            return sqrt(max(0, r * r + i * i))
        }
    }

    public let weighting: Weighting
    public let sampleRate: Float
    private var sections: [Section]
    private var trim: TrimFIR

    public init(weighting: Weighting, sampleRate: Float) {
        let fs = Double(max(sampleRate, 1))
        self.weighting = weighting
        self.sampleRate = sampleRate

        let design = Self.makeDesign(weighting: weighting, sampleRate: fs)
        self.sections = design.sections
        self.trim = TrimFIR(b0: design.trim[0], b1: design.trim[1],
                            b2: design.trim[2], b3: design.trim[3])
    }

    /// 当前数字滤波器在指定频率的幅度响应(dB, 1 kHz 归一化)。
    /// 用于回归测试和诊断,不参与实时链路。
    public func gain(at frequency: Float) -> Float {
        let fs = Double(max(sampleRate, 1))
        guard frequency > 0, Double(frequency) < fs * 0.5 else {
            return -.greatestFiniteMagnitude
        }
        let w = 2 * Double.pi * Double(frequency) / fs
        let z1r = cos(w)
        let z1i = -sin(w)
        let z2r = cos(2 * w)
        let z2i = -sin(2 * w)
        let z3r = cos(3 * w)
        let z3i = -sin(3 * w)
        var magnitude = 1.0
        for section in sections {
            magnitude *= section.magnitude(z1r: z1r, z1i: z1i,
                                           z2r: z2r, z2i: z2i)
        }
        magnitude *= trim.magnitude(z1r: z1r, z1i: z1i,
                                    z2r: z2r, z2i: z2i,
                                    z3r: z3r, z3i: z3i)
        return Float(20 * log10(max(magnitude, 1e-30)))
    }

    /// 对一段 PCM 做计权并返回均方值。
    /// - Parameters:
    ///   - filterRange: 需要喂入滤波器、推进其状态的样本范围。
    ///   - measurementRange: 参与均方值统计的范围;默认与 filterRange 相同。
    ///
    /// 首帧需要喂入完整窗口预热滤波器,但只统计最后一个 hop,
    /// 这样 Leq 的时长与样本覆盖范围严格一致。
    public mutating func meanSquare(of samples: [Float],
                                    filterRange: Range<Int>,
                                    measurementRange: Range<Int>? = nil) -> Double {
        let lower = max(0, filterRange.lowerBound)
        let upper = min(samples.count, filterRange.upperBound)
        guard lower < upper else { return 0 }
        let measure = measurementRange ?? filterRange
        let measureLower = max(lower, measure.lowerBound)
        let measureUpper = min(upper, measure.upperBound)
        guard measureLower < measureUpper else { return 0 }

        var sum = 0.0
        var count = 0
        for i in lower..<upper {
            var x = Double(samples[i])
            for s in sections.indices {
                x = sections[s].process(x)
            }
            x = trim.process(x)
            if i >= measureLower && i < measureUpper {
                sum += x * x
                count += 1
            }
        }
        return count > 0 ? sum / Double(count) : 0
    }

    public mutating func reset() {
        for i in sections.indices {
            sections[i].x1 = 0
            sections[i].x2 = 0
            sections[i].y1 = 0
            sections[i].y2 = 0
        }
        trim.x1 = 0
        trim.x2 = 0
        trim.x3 = 0
    }

    // MARK: - 设计

    private struct Design {
        let sections: [Section]
        let trim: [Double]
    }

    private struct Complex {
        var r: Double
        var i: Double

        static func * (lhs: Complex, rhs: Complex) -> Complex {
            Complex(r: lhs.r * rhs.r - lhs.i * rhs.i,
                    i: lhs.r * rhs.i + lhs.i * rhs.r)
        }
    }

    private struct FitPoint {
        let frequency: Double
        let targetDB: Double
        let z1: Complex
        let z2: Complex
        let z3: Complex
    }

    private static let fitFrequencies: [Double] = [
        20, 25, 31.5, 40, 50, 63, 80, 100, 125, 160, 200,
        250, 315, 400, 500, 630, 800, 1000, 1250, 1600, 2000,
        2500, 3150, 4000, 5000, 6300, 8000, 10000, 12500, 16000, 20000,
        // 低采样率不会用到这些点；96 kHz 设备需要继续约束 20 kHz 以上的
        // A/C 滚降，否则超声能量会被当成可听声计入 SPL。
        24000, 31500, 40000
    ]

    private static func makeDesign(weighting: Weighting, sampleRate fs: Double) -> Design {
        let critical: [(Double, Int)]
        let zeroCount: Int
        switch weighting {
        case .a:
            critical = [(20.6, 2), (107.7, 1), (737.9, 1), (12194, 2)]
            zeroCount = 4
        case .c:
            critical = [(20.6, 2), (12194, 2)]
            zeroCount = 2
        }

        let poles = critical.flatMap { frequency, count in
            Array(repeating: prewarpedPole(frequency, sampleRate: fs), count: count)
        }

        // 高频端超过 Nyquist 时目标曲线本身已不可测;把原型频率夹在
        // Nyquist 内,至少保证滤波器稳定且低频段仍然准确。
        let points = fitFrequencies
            .filter { $0 < fs * 0.48 }
            .map { frequency -> FitPoint in
                let w = 2 * Double.pi * frequency / fs
                let z1 = Complex(r: cos(w), i: -sin(w))
                let z2 = z1 * z1
                let z3 = z2 * z1
                let target = weighting == .a
                    ? Double(AWeighting.gain(at: Float(frequency)))
                    : Double(CWeighting.gain(at: Float(frequency)))
                return FitPoint(frequency: frequency, targetDB: target,
                                z1: z1, z2: z2, z3: z3)
            }

        // 没有足够的频点(异常采样率)时退化为原始双线性设计。
        guard !points.isEmpty else {
            return fallbackDesign(weighting: weighting, sampleRate: fs)
        }

        // 目标曲线网格里必须有 1 kHz 点;若没有则手动补一个。
        let fitPoints: [FitPoint]
        if points.contains(where: { abs($0.frequency - 1000) < 0.001 }) {
            fitPoints = points
        } else {
            let w = 2 * Double.pi * 1000 / fs
            let z1 = Complex(r: cos(w), i: -sin(w))
            fitPoints = points + [FitPoint(frequency: 1000, targetDB: 0,
                                           z1: z1, z2: z1 * z1, z3: z1 * z1 * z1)]
        }

        func magnitude(q: [Double], trimPole: Double, at point: FitPoint) -> Double {
            let oneMinusZ = Complex(r: 1 - point.z1.r, i: -point.z1.i)
            var numerator = Complex(r: 1, i: 0)
            for _ in 0..<zeroCount {
                numerator = numerator * oneMinusZ
            }
            let qr = q[0]
                + q[1] * point.z1.r
                + q[2] * point.z2.r
                + q[3] * point.z3.r
            let qi = q[1] * point.z1.i
                + q[2] * point.z2.i
                + q[3] * point.z3.i
            numerator = numerator * Complex(r: qr, i: qi)

            var denominator = Complex(r: 1, i: 0)
            for pole in poles {
                denominator = denominator * Complex(r: 1 - pole * point.z1.r,
                                                    i: -pole * point.z1.i)
            }
            denominator = denominator * Complex(r: 1 - trimPole * point.z1.r,
                                                i: -trimPole * point.z1.i)
            let d2 = denominator.r * denominator.r + denominator.i * denominator.i
            let n2 = numerator.r * numerator.r + numerator.i * numerator.i
            guard d2 > 1e-30 else { return 0 }
            return sqrt(max(0, n2 / d2))
        }

        func fitError(q: [Double], trimPole: Double) -> Double {
            guard let reference = fitPoints.first(where: { abs($0.frequency - 1000) < 0.001 }) else {
                return .infinity
            }
            let referenceDB = 20 * log10(max(magnitude(q: q, trimPole: trimPole, at: reference), 1e-30))
            var error = 0.0
            for point in fitPoints {
                let db = 20 * log10(max(magnitude(q: q, trimPole: trimPole, at: point), 1e-30))
                let delta = db - referenceDB - point.targetDB
                error += delta * delta
            }
            return error
        }

        // 二次型目标曲面很小,确定性坐标下降 + 多个起点即可在 init 时
        // 完成拟合,不需要引入第三方优化库,也不会影响实时音频线程。
        let starts: [[Double]] = [
            [1, 3, 3, 1],
            [1, 0, 0, 0],
            [3, 3, 1, 0],
            [1, 1, 1, 1]
        ]
        let steps: [Double] = [2, 1, 0.5, 0.25, 0.125, 0.0625,
                               0.03125, 0.015625, 0.0078125, 0.00390625]
        var bestQ = starts[0]
        var bestPole = 0.25
        var bestError = Double.infinity

        for poleIndex in -19...19 {
            let trimPole = Double(poleIndex) / 20
            for start in starts {
                var q = start
                for step in steps {
                    for index in 0..<4 {
                        let old = q[index]
                        let currentError = fitError(q: q, trimPole: trimPole)
                        q[index] = old - step
                        let lowerError = fitError(q: q, trimPole: trimPole)
                        q[index] = old + step
                        let upperError = fitError(q: q, trimPole: trimPole)
                        if lowerError < currentError && lowerError <= upperError {
                            q[index] = old - step
                        } else if upperError < currentError {
                            q[index] = old + step
                        } else {
                            q[index] = old
                        }
                    }
                }
                let error = fitError(q: q, trimPole: trimPole)
                if error < bestError {
                    bestError = error
                    bestQ = q
                    bestPole = trimPole
                }
            }
        }

        // 1 kHz 归一化。1 kHz 目标为 0 dB,因此只需要把幅度缩放一次。
        if let reference = fitPoints.first(where: { abs($0.frequency - 1000) < 0.001 }) {
            let referenceMagnitude = magnitude(q: bestQ, trimPole: bestPole, at: reference)
            if referenceMagnitude > 1e-12 {
                let scale = 1 / referenceMagnitude
                bestQ = bestQ.map { $0 * scale }
            }
        }

        // 原型 section 的零点分配:
        // A: 两个低频 section 各带 (1-z^-1)^2; C: 低频 section 带两个零点。
        // 高频/额外极点 section 不再带原点零点,由三次 FIR 完成剩余形状。
        var sections: [Section] = []
        func pole(_ frequency: Double) -> Double {
            prewarpedPole(frequency, sampleRate: fs)
        }
        switch weighting {
        case .a:
            let p20 = pole(20.6)
            sections.append(Section(b0: 1, b1: -2, b2: 1,
                                    a1: -2 * p20, a2: p20 * p20))
            let p107 = pole(107.7)
            let p738 = pole(737.9)
            sections.append(Section(b0: 1, b1: -2, b2: 1,
                                    a1: -(p107 + p738), a2: p107 * p738))
            let p12k = pole(12194)
            sections.append(Section(b0: 1, b1: 0, b2: 0,
                                    a1: -2 * p12k, a2: p12k * p12k))
        case .c:
            let p20 = pole(20.6)
            sections.append(Section(b0: 1, b1: -2, b2: 1,
                                    a1: -2 * p20, a2: p20 * p20))
            let p12k = pole(12194)
            sections.append(Section(b0: 1, b1: 0, b2: 0,
                                    a1: -2 * p12k, a2: p12k * p12k))
        }

        sections.append(Section(b0: 1, b1: 0, b2: 0,
                                a1: -bestPole, a2: 0))
        return Design(sections: sections, trim: bestQ)
    }

    private static func prewarpedPole(_ frequency: Double, sampleRate fs: Double) -> Double {
        let bounded = min(max(frequency, 1), fs * 0.49)
        let omega = 2 * fs * tan(Double.pi * bounded / fs)
        return (1 - omega / (2 * fs)) / (1 + omega / (2 * fs))
    }

    /// 异常采样率下的保底设计:稳定的原始预畸变双线性结构。
    private static func fallbackDesign(weighting: Weighting, sampleRate fs: Double) -> Design {
        let p20 = prewarpedPole(20.6, sampleRate: fs)
        let p12k = prewarpedPole(12194, sampleRate: fs)
        var sections = [
            Section(b0: 1, b1: -2, b2: 1,
                    a1: -2 * p20, a2: p20 * p20),
            Section(b0: 1, b1: 0, b2: 0,
                    a1: -2 * p12k, a2: p12k * p12k)
        ]
        if weighting == .a {
            let p107 = prewarpedPole(107.7, sampleRate: fs)
            let p738 = prewarpedPole(737.9, sampleRate: fs)
            sections.insert(Section(b0: 1, b1: -2, b2: 1,
                                    a1: -(p107 + p738), a2: p107 * p738), at: 1)
        }
        // 用 1 kHz 幅度归一化保底 FIR。
        let trim: [Double] = [1, 1, 0, 0]
        let w = 2 * Double.pi * min(1000, fs * 0.48) / fs
        let z1 = Complex(r: cos(w), i: -sin(w))
        let z2 = z1 * z1
        let z3 = z2 * z1
        var magnitude = 1.0
        for section in sections {
            magnitude *= section.magnitude(z1r: z1.r, z1i: z1.i,
                                           z2r: z2.r, z2i: z2.i)
        }
        let tr0 = trim[0]
        let tr1 = trim[1] * z1.r
        let tr2 = trim[2] * z2.r
        let tr3 = trim[3] * z3.r
        let tr = tr0 + tr1 + tr2 + tr3
        let ti1 = trim[1] * z1.i
        let ti2 = trim[2] * z2.i
        let ti3 = trim[3] * z3.i
        let ti = ti1 + ti2 + ti3
        let trimMagnitude = sqrt(max(0, tr * tr + ti * ti))
        let scale: Double = magnitude * trimMagnitude > 1e-30
            ? 1 / (magnitude * trimMagnitude) : 1.0
        return Design(sections: sections, trim: trim.map { $0 * scale })
    }
}

// MARK: - 频谱显示聚合

/// 把 FFT 幅度谱按对数频率轴聚合成显示频段（频谱柱）。
///
/// 低频段的带宽会小于 FFT bin 间距（48 kHz / 4096 点 ≈ 11.7 Hz/ bin）:
/// 按区间收集 bin 时部分频段为空，直接显示会变成恒定贴底的"死柱"
/// （iOS 端 32 段下的第 2、4 根正是 24.6~30.4 Hz 与 37.4~46.1 Hz 两个空段）。
/// 空频段改用相邻 bin 在 log10(f)-dB 域的线性插值填充，柱随内容起伏。
public enum SpectrumBands {

    /// 返回 bandCount 个频段；每个频段是落在该段内的幅度值数组
    /// （无 bin 的频段为单元素插值数组），供调用方求均值后转 dB 显示。
    /// 输入为空时返回 []。
    public static func aggregate(spectrum: [Float],
                                 frequencies: [Float],
                                 bandCount: Int,
                                 minFrequency: Float,
                                 maxFrequency: Float) -> [[Float]] {
        let n = min(spectrum.count, frequencies.count)
        guard bandCount > 0, n > 1, minFrequency > 0,
              let topF = frequencies[0..<n].last, topF > 0 else { return [] }
        let spec = spectrum[0..<n]
        let freqs = frequencies[0..<n]

        // aggregate 只取到最后一个实际 bin;用 maxFrequency 表示显示宽度。
        let maxF = min(maxFrequency, topF)
        guard maxF > minFrequency else { return [] }

        let logMin = log10(minFrequency)
        let logMax = log10(maxF)
        let step = (logMax - logMin) / Float(bandCount)
        // 显示下限与各视图的 1e-7(-140 dB) 一致,插值与直读同尺度
        let binDB = spec.map { 20 * log10(max($0, 1e-7)) }
        let binLogF = freqs.map { log10(max($0, 1e-3)) }

        var bands: [[Float]] = []
        for i in 0..<bandCount {
            let lo = pow(10, logMin + Float(i) * step)
            let hi = pow(10, logMin + Float(i + 1) * step)
            var bucket: [Float] = []
            for (idx, f) in freqs.enumerated() where f >= lo && f < hi {
                bucket.append(spec[idx])
            }
            if bucket.isEmpty {
                let center = pow(10, logMin + (Float(i) + 0.5) * step)
                let db = interpolatedDB(atCenterLog: log10(center),
                                        binLogF: binLogF, binDB: binDB)
                bucket = [pow(10, db / 20)]
            }
            bands.append(bucket)
        }
        return bands
    }

    /// 把聚合桶内的幅度按功率平均后转成 dB,供频谱视图直接绘制。
    /// 幅度谱是线性量;对多 bin 桶直接算术平均会压低宽带噪声,
    /// 正确做法是先平方求平均再开方(即功率平均)。
    public static func bandLevelsDB(spectrum: [Float],
                                    frequencies: [Float],
                                    bandCount: Int,
                                    minFrequency: Float,
                                    maxFrequency: Float) -> [Float] {
        aggregate(spectrum: spectrum,
                  frequencies: frequencies,
                  bandCount: bandCount,
                  minFrequency: minFrequency,
                  maxFrequency: maxFrequency)
            .map { band in
                guard !band.isEmpty else { return -140 }
                let meanPower = band.reduce(Float(0)) { $0 + $1 * $1 } / Float(band.count)
                return 10 * log10(max(meanPower, 1e-14))
            }
    }

    /// log10(f)-dB 域线性插值；超出 bin 覆盖范围时取最近 bin 的值
    private static func interpolatedDB(atCenterLog centerLog: Float,
                                       binLogF: [Float], binDB: [Float]) -> Float {
        guard let first = binLogF.first, let last = binLogF.last, !binDB.isEmpty else {
            return -140
        }
        if centerLog <= first { return binDB[0] }
        if centerLog >= last { return binDB[binDB.count - 1] }
        var hi = 0
        while hi < binLogF.count && binLogF[hi] < centerLog { hi += 1 }
        let lo = hi - 1
        guard lo >= 0, hi < binLogF.count, binLogF[hi] > binLogF[lo] else {
            return binDB[min(max(lo, 0), binDB.count - 1)]
        }
        let t = (centerLog - binLogF[lo]) / (binLogF[hi] - binLogF[lo])
        return binDB[lo] + t * (binDB[hi] - binDB[lo])
    }
}

// MARK: - 分贝计

/// 核心分贝计：接收 PCM 样本，输出测量结果。
///
/// 对照 IEC 61672-1 声级计链路（麦克风 → 计权网络 → RMS 检波器 → 显示）：
/// ```
/// 样本 ─► A/C 时域 IIR 计权 ─► 均方值(能量域)
///      └► FFT(仅频谱显示,不参与声级计算)
/// 均方值 ─► 一阶指数平均(τ=125ms/1s, IEC F/S) ─► 10·log10 ─► + offset ─► SPL
/// ```
/// 关键点：
/// - A/C 计权在时域逐样本完成,滤波状态跨 hop 连续,重叠窗口不会重复积分；
/// - 检波器在**能量域（均方值）**做指数平均，时间常数按 IEC 61672 F/S，
///   α = 1 − exp(−Δt/τ)，Δt 为相邻处理帧的推进时长（默认半窗）；
/// - 绝对标定只由 `calibrationOffset` 决定（dBFS→SPL），语义为
///   SPL = dBFS(RMS) + offset，由设置页按设备校准。
public final class DBMeter {

    public private(set) var config: MeterConfig
    /// 时间计权后的 SPL（与最新结果一致），未处理过帧时为 -100
    public private(set) var smoothedSPL: Float = -100

    /// 检波器状态：计权均方值的一阶指数平均（能量域）
    private var emaMS: Float = 0
    private var hasEMA = false
    /// Leq 累加器保存“校准前”的计权均方值积分，输出时再加当前 offset。
    /// 这样测量中微调校准时，已累计区间也会随新的 dBFS→SPL 关系平移，
    /// 而不是把整场 Leq 清零后只统计后半段。
    /// Σ(计权均方值 × 帧时长) 与 Σ帧时长。
    private var leqEnergyTime: Double = 0
    private var leqElapsed: TimeInterval = 0
    /// 已交给调用方的累计样本位置。用于长会话检测增量是否连续。
    private var integratedSamplePosition: Int64 = 0
    /// 引擎层因积压丢弃的样本数。
    private var droppedSamples = 0

    private let log2n: vDSP_Length
    private let halfSize: Int
    private let hannWindow: [Float]
    /// 单边幅度谱归一化系数：满幅正弦的峰值 bin 应恢复为振幅本身。
    private let spectrumScale: Float
    private let spectrumDCPeakScale: Float
    private var binFrequencies: [Float]
    /// A/C 时域计权滤波器。状态必须跨调用保留。
    private var weightingFilter: WeightingFilter
    /// 首次调用处理完整窗口,但只统计末尾 hop;之后只处理新推进的 hop。
    /// FFT 仍使用完整窗口,因此首帧频谱可用,而 SPL/Leq 不会把启动前的
    /// 未观测样本计入测量。
    private var hasFilterHistory = false

    private var windowed: [Float]
    private var fftRealIn: [Float]      // FFT 输入实部 = 窗样本
    private var fftImagIn: [Float]      // FFT 输入虚部 = 全零
    private var fftRealOut: [Float]     // FFT 输出实部
    private var fftImagOut: [Float]     // FFT 输出虚部
    private var magnitudes: [Float]     // 幅度谱
    /// 上次低频分析对应的累计样本位置。
    private var lastLowBandAnalysisPosition: Int64?

    private let fftSetup: FFTSetup

    public init(config: MeterConfig = MeterConfig()) {
        self.config = config
        let n = config.fftSize
        precondition(n > 0 && (n & (n - 1)) == 0, "fftSize 必须是 2 的幂")
        precondition(n >= 4, "fftSize 至少 4")

        self.halfSize = n / 2
        self.log2n = vDSP_Length(log2(Float(n)))

        // Hann 窗
        var window = [Float](repeating: 0, count: n)
        vDSP_hann_window(&window, vDSP_Length(n), Int32(vDSP_HANN_NORM))
        self.hannWindow = window
        let windowSum = window.reduce(0, +)
        self.spectrumScale = windowSum > 0 ? 2 / windowSum : 1
        self.spectrumDCPeakScale = windowSum > 0 ? 1 / windowSum : 1

        // 频率轴 & 计权功率域权重(A 或 C)
        // 单边频谱包含 0 Hz 和 Nyquist，共 N/2 + 1 个频点。
        self.binFrequencies = (0...halfSize).map { k in
            Float(k) * config.sampleRate / Float(n)
        }
        self.weightingFilter = WeightingFilter(weighting: config.weighting,
                                               sampleRate: config.sampleRate)

        // FFT setup
        self.fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!

        // 预分配 buffer
        self.windowed = [Float](repeating: 0, count: n)
        self.fftRealIn = [Float](repeating: 0, count: n)
        self.fftImagIn = [Float](repeating: 0, count: n)
        self.fftRealOut = [Float](repeating: 0, count: n)
        self.fftImagOut = [Float](repeating: 0, count: n)
        self.magnitudes = [Float](repeating: 0, count: halfSize + 1)
    }

    deinit {
        vDSP_destroy_fftsetup(fftSetup)
    }

    /// 处理一帧单声道 Float32 PCM 样本，返回测量结果。
    /// - Parameter hopSamples: 相邻两次调用之间窗口推进的样本数，
    ///   决定时间计权的 Δt（默认 fftSize/2，即 50% 重叠）。
    public func process(_ samples: [Float], hopSamples: Int? = nil) -> MeterResult? {
        let n = config.fftSize
        guard samples.count >= n else { return nil }
        let hop = hopSamples ?? n / 2
        precondition(hop > 0, "hopSamples 必须为正")
        precondition(hop <= n, "hopSamples 不能大于 fftSize")
        let measurementRange = (n - hop)..<n

        // ---- dBFS(flat)：与计权 SPL 使用同一个 hop，避免把整窗 RMS
        // 和末 hop 的计权 RMS 相减后误当成真实 A/C 修正量。----
        let frame = Array(samples.prefix(n))
        var rmsFlat: Float = 0
        frame.withUnsafeBufferPointer { buffer in
            vDSP_rmsqv(buffer.baseAddress!.advanced(by: measurementRange.lowerBound),
                       1, &rmsFlat, vDSP_Length(measurementRange.count))
        }
        let dbfsFlat = 20 * log10(max(rmsFlat, 1e-10))

        let shouldAnalyzeLowBand: Bool
        if config.spectrumEnabled {
            shouldAnalyzeLowBand = true
        } else {
            let interval = max(0, config.lowBandAnalysisInterval)
            let minHopGap = max(1, Int((Double(config.sampleRate) * interval).rounded()))
            shouldAnalyzeLowBand = lastLowBandAnalysisPosition.map {
                integratedSamplePosition - $0 >= Int64(minHopGap)
            } ?? true
        }

        if shouldAnalyzeLowBand {
            // ---- 加 Hann 窗 ----
            vDSP_vmul(frame, 1, hannWindow, 1, &windowed, 1, vDSP_Length(n))

            // ---- 准备 FFT 输入：实部 = 窗样本，虚部 = 0 ----
            // 用标准复数 FFT (zop)，避开 zrip 的 DC/Nyquist 打包陷阱
            fftRealIn = windowed
            // fftImagIn 已经全是 0，但每次需要确保（前次可能被写）
            vDSP_vclr(&fftImagIn, 1, vDSP_Length(n))

            // ---- 前向 FFT (out-of-place) ----
            fftRealIn.withUnsafeMutableBufferPointer { realInBuf in
                fftImagIn.withUnsafeMutableBufferPointer { imagInBuf in
                    fftRealOut.withUnsafeMutableBufferPointer { realOutBuf in
                        fftImagOut.withUnsafeMutableBufferPointer { imagOutBuf in
                            var input = DSPSplitComplex(
                                realp: realInBuf.baseAddress!,
                                imagp: imagInBuf.baseAddress!
                            )
                            var output = DSPSplitComplex(
                                realp: realOutBuf.baseAddress!,
                                imagp: imagOutBuf.baseAddress!
                            )
                            vDSP_fft_zop(fftSetup, &input, 1, &output, 1,
                                         log2n, FFTDirection(FFT_FORWARD))
                        }
                    }
                }
            }

            // ---- 幅度谱 |X[k]| = sqrt(real² + imag²)，取前 N/2 个 bin ----
            // 复数 FFT 输出 N 个 bin，后 N/2 是前 N/2 的共轭（实序列对称），只需前半段
            fftRealOut.withUnsafeMutableBufferPointer { realOutBuf in
                fftImagOut.withUnsafeMutableBufferPointer { imagOutBuf in
                    var split = DSPSplitComplex(
                        realp: realOutBuf.baseAddress!,
                        imagp: imagOutBuf.baseAddress!
                    )
                    vDSP_zvabs(&split, 1, &magnitudes, 1, vDSP_Length(halfSize))
                    // zvabs 只覆盖前半段；Nyquist 位于 N/2，需单独补入，
                    // 否则频率轴与幅度谱长度不一致。
                    let nyquist = hypot(realOutBuf[halfSize], imagOutBuf[halfSize])
                    // 前 N/2 bin 是双边谱的一半，需要乘 2；DC/Nyquist
                    // 不分左右，保持单边缩放。最终满幅正弦振幅≈输入振幅。
                    for i in 0..<halfSize {
                        magnitudes[i] *= spectrumScale
                    }
                    magnitudes[0] *= spectrumDCPeakScale
                    magnitudes[halfSize] = nyquist * spectrumDCPeakScale
                }
            }
            lastLowBandAnalysisPosition = integratedSamplePosition
        }

        // ---- 时域计权 ----
        // 第一帧处理完整窗口做滤波器预热;之后每次只处理末尾新推进的 hop。
        // 调用方传入的是 50% 重叠窗口,若每帧都重算整窗会把同一段样本
        // 重复计入 Leq,也会造成时间计权响应偏快。
        let filterRange = hasFilterHistory ? measurementRange : 0..<n
        let msWeighted = Float(weightingFilter.meanSquare(of: frame,
                                                          filterRange: filterRange,
                                                          measurementRange: measurementRange))
        hasFilterHistory = true


        let dbfsA = 10 * log10(max(msWeighted, 1e-20))
        let splInstant = 10 * log10(max(msWeighted, 1e-20)) + config.calibrationOffset

        // ---- IEC 61672 时间计权检波器：能量域一阶指数平均 ----
        // α = 1 − exp(−Δt/τ)，expm1 保证小 Δt 精度；首帧直接置为当前值。
        let dt = Float(hop) / config.sampleRate
        let alpha = Float(-expm1(Double(-dt) / config.timeWeighting.tau))
        if !hasEMA {
            emaMS = msWeighted
            hasEMA = true
        } else {
            emaMS += alpha * (msWeighted - emaMS)
        }

        // ---- Leq 累加（能量域按 hop 时长积分）----
        // 每一帧都计入积分时长:一段被静音隔开的响亮事件,LAeq 必须按
        // “事件能量 / 整段测量时间”计算。只排除非有限值。
        if msWeighted.isFinite {
            leqEnergyTime += Double(msWeighted) * Double(dt)
            leqElapsed += TimeInterval(dt)
        }
        let samplePosition = integratedSamplePosition
        integratedSamplePosition += Int64(hop)

        let spl = 10 * log10(max(emaMS, 1e-20)) + config.calibrationOffset
        smoothedSPL = spl

        return MeterResult(dbfsFlat: dbfsFlat,
                           dbfsAWeighted: dbfsA,
                           splA: spl,
                           splInstant: splInstant,
                           leqSPL: currentLeq(),
                           leqDuration: leqDuration,
                           droppedSampleCount: 0,
                           totalDroppedSampleCount: droppedSamples,
                           coveredDuration: Double(hop) / Double(config.sampleRate),
                           samplePosition: samplePosition,
                           integratedSampleCount: hop,
                           sampleRate: config.sampleRate,
                           spectrum: shouldAnalyzeLowBand ? magnitudes : [],
                           frequencies: binFrequencies)
    }

    /// 处理测量结束时不足一个完整 FFT 窗口的尾部样本。
    ///
    /// 滤波器状态从上一帧连续推进。调用方应传入尚未统计的新样本；
    /// `skipSamples` 表示这批 tail 前缀已经在最近一次 `process()` 中
    /// 作为重叠窗尾部计过 Leu，必须先跳过。
    public func processTail(_ samples: [Float],
                            skipSamples: Int = 0) -> MeterResult? {
        guard !samples.isEmpty else { return nil }

        let skip = max(0, min(skipSamples, samples.count))
        let fresh = skip == 0 ? samples : Array(samples.dropFirst(skip))
        guard !fresh.isEmpty else { return nil }

        var rmsFlat: Float = 0
        vDSP_rmsqv(fresh, 1, &rmsFlat, vDSP_Length(fresh.count))
        let dbfsFlat = 20 * log10(max(rmsFlat, 1e-10))

        let msWeighted = Float(weightingFilter.meanSquare(
            of: fresh,
            filterRange: 0..<fresh.count
        ))
        hasFilterHistory = true

        let dbfsA = 10 * log10(max(msWeighted, 1e-20))
        let splInstant = dbfsA + config.calibrationOffset
        let dt = Float(fresh.count) / config.sampleRate
        let alpha = Float(-expm1(Double(-dt) / config.timeWeighting.tau))
        if !hasEMA {
            emaMS = msWeighted
            hasEMA = true
        } else {
            emaMS += alpha * (msWeighted - emaMS)
        }

        if msWeighted.isFinite, dt.isFinite, dt > 0 {
            leqEnergyTime += Double(msWeighted) * Double(dt)
            leqElapsed += TimeInterval(dt)
        }
        let samplePosition = integratedSamplePosition
        integratedSamplePosition += Int64(fresh.count)

        let spl = 10 * log10(max(emaMS, 1e-20)) + config.calibrationOffset
        smoothedSPL = spl
        return MeterResult(dbfsFlat: dbfsFlat,
                           dbfsAWeighted: dbfsA,
                           splA: spl,
                           splInstant: splInstant,
                           leqSPL: currentLeq(),
                           leqDuration: leqDuration,
                           droppedSampleCount: 0,
                           totalDroppedSampleCount: droppedSamples,
                           coveredDuration: Double(fresh.count) / Double(config.sampleRate),
                           samplePosition: samplePosition,
                           integratedSampleCount: fresh.count,
                           sampleRate: config.sampleRate,
                           // 尾部没有重新做 FFT，不能把上一窗的频谱伪装成
                           // 当前尾样本的新鲜特征。
                           spectrum: [],
                           frequencies: binFrequencies)
    }

    /// 重置时间计权检波器（下一帧直接置为当前值，不做渐变）
    public func resetDetector() {
        emaMS = 0
        hasEMA = false
    }

    /// 清空计权滤波器的历史状态。下一次 process() 会重新预热完整窗口。
    public func resetFilter() {
        weightingFilter.reset()
        hasFilterHistory = false
    }

    /// 更新频率计权。权重改变时历史 Leq 不能混用两种计权，
    /// 因此同时清空滤波器状态和 Leq，从这一刻按新计权重新测量。
    public func setWeighting(_ weighting: Weighting) {
        guard weighting != config.weighting else { return }
        config.weighting = weighting
        weightingFilter = WeightingFilter(weighting: weighting,
                                          sampleRate: config.sampleRate)
        hasFilterHistory = false
        resetDetector()
        resetLeq()
    }

    /// 更新 dBFS→SPL 校准偏移。Leq 保存的是校准前的能量积分，
    /// 这里只替换输出偏移即可覆盖整场测量。
    public func setCalibrationOffset(_ offset: Float) {
        config.calibrationOffset = offset
    }

    /// 更新 F/S 时间计权。变化检波器动态特性时重置检波器状态，
    /// 但不清空 Leq（Leq 与 F/S 无关）。
    public func setTimeWeighting(_ weighting: TimeWeighting) {
        guard weighting != config.timeWeighting else { return }
        config.timeWeighting = weighting
        resetDetector()
    }

    /// 当前运行 LAeq（等效连续声级）：对计权均方值按处理时长积分。
    /// LAeq = 10·log10(Σ(ms·dt) / Σdt) + offset。
    /// 静音的均方值为 0，对应数字域的负无穷；无帧才返回 -inf。
    public func currentLeq() -> Float {
        guard leqElapsed > 0 else { return -.greatestFiniteMagnitude }
        guard leqEnergyTime > 0 else { return -Float.infinity }
        return Float(10 * log10(leqEnergyTime / leqElapsed)) + config.calibrationOffset
    }

    /// 当前 Leq 统计覆盖的时长（秒）
    public var leqDuration: TimeInterval {
        leqElapsed
    }

    /// 只清零 Leq 累加器（保留时间计权检波器状态）
    public func resetLeq() {
        leqEnergyTime = 0
        leqElapsed = 0
        integratedSamplePosition = 0
        droppedSamples = 0
        // 低频 FFT 的调度游标也必须回到新会话起点。否则同一 DBMeter
        // 停止后立即重开时，旧会话的样本位置会让低频特征长时间不再刷新。
        lastLowBandAnalysisPosition = nil
    }

    /// 记录一次输入缓冲积压导致的数据丢弃。
    /// 这是测量完整性诊断，不参与声级计算；任何非零值都应在 UI 中明示。
    public func reportDroppedSamples(_ count: Int) {
        guard count > 0 else { return }
        droppedSamples += count
    }

    public func resetSmoothing() {
        resetFilter()
        resetDetector()
        resetLeq()
    }

    /// 接收另一个 meter 的会话统计（采样率变化重建时用）。
    /// 计权均方值是无量纲的数字域能量，跨采样率仍可连续积分。
    public func adoptSessionState(from previous: DBMeter) {
        emaMS = previous.emaMS
        hasEMA = previous.hasEMA
        leqEnergyTime = previous.leqEnergyTime
        leqElapsed = previous.leqElapsed
        integratedSamplePosition = previous.integratedSamplePosition
        droppedSamples = previous.droppedSamples
        lastLowBandAnalysisPosition = previous.lastLowBandAnalysisPosition
        // 采样率变化后旧滤波器的 z 状态不可复用;LEQ/F/S 仍连续。
        resetFilter()
        binFrequencies = (0...halfSize).map { k in
            Float(k) * config.sampleRate / Float(config.fftSize)
        }
    }
}

// MARK: - 信号生成（测试用）

public enum SignalGenerator {

    /// 纯正弦波。RMS = amplitude / sqrt(2)，dBFS = 20·log10(amplitude/√2)
    public static func sineWave(frequency: Float,
                                 amplitude: Float,
                                 sampleRate: Float,
                                 count: Int) -> [Float] {
        var output = [Float](repeating: 0, count: count)
        let phaseStep = 2 * Float.pi * frequency / sampleRate
        var phase: Float = 0
        for i in 0..<count {
            output[i] = amplitude * sin(phase)
            phase += phaseStep
        }
        return output
    }

    /// 粉红噪声（1/f），自然界常见噪声近似
    public static func pinkNoise(amplitude: Float, count: Int) -> [Float] {
        var output = [Float](repeating: 0, count: count)
        var b0: Float = 0, b1: Float = 0, b2: Float = 0, b3: Float = 0
        var b4: Float = 0, b5: Float = 0, b6: Float = 0
        for i in 0..<count {
            let white = Float.random(in: -1...1) * 2.0
            b0 = 0.99886 * b0 + white * 0.0555179
            b1 = 0.99332 * b1 + white * 0.0750759
            b2 = 0.96900 * b2 + white * 0.1538520
            b3 = 0.86650 * b3 + white * 0.3104856
            b4 = 0.55000 * b4 + white * 0.5329522
            b5 = -0.7616 * b5 - white * 0.0168980
            let pink = b0 + b1 + b2 + b3 + b4 + b5 + b6 + white * 0.5362
            b6 = white * 0.115926
            output[i] = pink * amplitude * 0.11
        }
        return output
    }

    /// 白噪声
    public static func whiteNoise(amplitude: Float, count: Int) -> [Float] {
        (0..<count).map { _ in Float.random(in: -amplitude...amplitude) }
    }
}
