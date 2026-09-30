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
    /// A 计权 dBFS（未计权），用于调试对比
    public let dbfsAWeighted: Float
    /// 时间计权后的声压级 = 能量域指数平均(IEC 61672 F/S) + offset。
    /// 计权方式由 config.weighting 决定（A 或 C），字段名沿用历史。
    public let splA: Float
    /// 本帧瞬时声压级（未做时间计权），调试对比用
    public let splInstant: Float
    /// FFT 前半段幅度谱（0 ~ Nyquist），用于绘制频谱图，可选
    public let spectrum: [Float]
    /// 对应频谱每个 bin 的中心频率
    public let frequencies: [Float]

    public var description: String {
        String(format: "dBFS(flat)=%6.1f  dBFS(A)=%6.1f  SPL=%5.1f dB (inst %5.1f)",
               dbfsFlat, dbfsAWeighted, splA, splInstant)
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

    public init(sampleRate: Float = 48000,
                fftSize: Int = 4096,
                calibrationOffset: Float = 0,
                weighting: Weighting = .a,
                timeWeighting: TimeWeighting = .fast) {
        self.sampleRate = sampleRate
        self.fftSize = fftSize
        self.calibrationOffset = calibrationOffset
        self.weighting = weighting
        self.timeWeighting = timeWeighting
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
        guard bandCount > 0, n > 0, minFrequency > 0,
              let topF = frequencies[0..<n].last, topF > 0 else { return [] }
        let spec = spectrum[0..<n]
        let freqs = frequencies[0..<n]

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
/// 样本[N] ──────────────► RMS² ──────────────► ×计权功率比 ──► 均方值(能量域)
///         └► 加Hann窗 → FFT → |X[k]|² → Σ P·W²/Σ P ─┘
/// 能量域均方值 ─► 一阶指数平均(τ=125ms/1s, IEC F/S) ─► 10·log10 ─► + offset ─► SPL
/// ```
/// 关键点：
/// - 计权比值法：任何 FFT 绝对缩放常数在 Σ P·W²/Σ P 中自动抵消，
///   1 kHz 纯音（W=1）的修正量天然为 0，无需标定曲线；
/// - 检波器在**能量域（均方值）**做指数平均，时间常数按 IEC 61672 F/S，
///   α = 1 − exp(−Δt/τ)，Δt 为相邻处理帧的推进时长（默认半窗）；
/// - 绝对标定只由 `calibrationOffset` 决定（dBFS→SPL），语义为
///   SPL = dBFS(RMS) + offset，由设置页按设备校准。
public final class DBMeter {

    public let config: MeterConfig
    /// 时间计权后的 SPL（与最新结果一致），未处理过帧时为 -100
    public private(set) var smoothedSPL: Float = -100

    /// 检波器状态：计权均方值的一阶指数平均（能量域）
    private var emaMS: Float = 0
    private var hasEMA = false
    /// Leq 累加器：Σ 计权均方值 + 帧数（Double 累加防精度损失）
    private var leqSumMS: Double = 0
    private var leqFrames: Int = 0

    private let log2n: vDSP_Length
    private let halfSize: Int
    private let hannWindow: [Float]
    private let aWeightPowerSq: [Float]   // 每个 bin 的计权线性增益的平方（功率域权重）
    private let binFrequencies: [Float]

    private var windowed: [Float]
    private var fftRealIn: [Float]      // FFT 输入实部 = 窗样本
    private var fftImagIn: [Float]      // FFT 输入虚部 = 全零
    private var fftRealOut: [Float]     // FFT 输出实部
    private var fftImagOut: [Float]     // FFT 输出虚部
    private var magnitudes: [Float]     // 幅度谱

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

        // 频率轴 & 计权功率域权重(A 或 C)
        self.binFrequencies = (0..<halfSize).map { k in
            Float(k) * config.sampleRate / Float(n)
        }
        let linearGains: [Float]
        switch config.weighting {
        case .a:
            linearGains = AWeighting.linearGains(for: binFrequencies)
        case .c:
            linearGains = CWeighting.linearGains(for: binFrequencies)
        }
        self.aWeightPowerSq = linearGains.map { $0 * $0 }

        // FFT setup
        self.fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!

        // 预分配 buffer
        self.windowed = [Float](repeating: 0, count: n)
        self.fftRealIn = [Float](repeating: 0, count: n)
        self.fftImagIn = [Float](repeating: 0, count: n)
        self.fftRealOut = [Float](repeating: 0, count: n)
        self.fftImagOut = [Float](repeating: 0, count: n)
        self.magnitudes = [Float](repeating: 0, count: halfSize)
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
        let frame = Array(samples.prefix(n))
        let hop = hopSamples ?? n / 2
        precondition(hop > 0, "hopSamples 必须为正")

        // ---- dBFS(flat)：对原始样本求 RMS ----
        var rmsFlat: Float = 0
        vDSP_rmsqv(frame, 1, &rmsFlat, vDSP_Length(n))
        let dbfsFlat = 20 * log10(max(rmsFlat, 1e-10))
        let msFlat = rmsFlat * rmsFlat

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
            }
        }

        // ---- 功率谱（幅度平方）----
        var power = [Float](repeating: 0, count: halfSize)
        vDSP_vsq(magnitudes, 1, &power, 1, vDSP_Length(halfSize))

        // ---- 计权：功率域 = 振幅域增益的平方 ----
        var weightedPower = [Float](repeating: 0, count: halfSize)
        vDSP_vmul(power, 1, aWeightPowerSq, 1, &weightedPower, 1, vDSP_Length(halfSize))

        // ---- 功率比法算计权修正量 ----
        //   修正量 = 10·log10(Σ P[k]·W²[k] / Σ P[k])
        // 窗函数同时作用于分子分母，对宽带/窄带信号均近似抵消。
        var sumPower: Float = 0
        var sumWeightedPower: Float = 0
        vDSP_sve(power, 1, &sumPower, vDSP_Length(halfSize))
        vDSP_sve(weightedPower, 1, &sumWeightedPower, vDSP_Length(halfSize))

        let weightCorrectionDB: Float
        if sumPower > 1e-20 {
            weightCorrectionDB = 10 * log10(sumWeightedPower / sumPower)
        } else {
            weightCorrectionDB = 0   // 静音:均方值本身为 0,修正量无意义
        }
        let weightPowerRatio: Float = sumPower > 1e-20 ? sumWeightedPower / sumPower : 0

        // ---- 本帧计权均方值（数字域）----
        // 10·log10(msWeighted) = dbfsFlat + weightCorrectionDB
        let msWeighted = msFlat * weightPowerRatio
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

        // ---- Leq 累加（能量域，帧等时长 → 算术平均均方值）----
        leqSumMS += Double(msWeighted)
        leqFrames += 1

        let spl = 10 * log10(max(emaMS, 1e-20)) + config.calibrationOffset
        smoothedSPL = spl

        let dbfsA = dbfsFlat + weightCorrectionDB

        return MeterResult(dbfsFlat: dbfsFlat,
                           dbfsAWeighted: dbfsA,
                           splA: spl,
                           splInstant: splInstant,
                           spectrum: magnitudes,
                           frequencies: binFrequencies)
    }

    /// 重置时间计权检波器（下一帧直接置为当前值，不做渐变）
    public func resetDetector() {
        emaMS = 0
        hasEMA = false
    }

    /// 当前运行 LAeq（等效连续声级）：对本进程所有帧的计权均方值做能量平均。
    /// 帧按固定 hop 处理、等时长，LAeq = 10·log10(Σ ms / N) + offset。
    /// 无帧返回 -inf。
    public func currentLeq() -> Float {
        guard leqFrames > 0, leqSumMS > 0 else { return -.greatestFiniteMagnitude }
        return Float(10 * log10(leqSumMS / Double(leqFrames))) + config.calibrationOffset
    }

    /// 当前 Leq 统计覆盖的时长（秒）
    public var leqDuration: TimeInterval {
        guard leqFrames > 0 else { return 0 }
        return TimeInterval(leqFrames) * (TimeInterval(config.fftSize / 2) / TimeInterval(config.sampleRate))
    }

    /// 只清零 Leq 累加器（保留时间计权检波器状态）
    public func resetLeq() {
        leqSumMS = 0
        leqFrames = 0
    }

    public func resetSmoothing() {
        resetDetector()
        resetLeq()
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
