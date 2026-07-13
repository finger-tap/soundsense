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
    /// 最终估算声压级 = dbfsAWeighted + offset
    public let splA: Float
    /// FFT 前半段幅度谱（0 ~ Nyquist），用于绘制频谱图，可选
    public let spectrum: [Float]
    /// 对应频谱每个 bin 的中心频率
    public let frequencies: [Float]

    public var description: String {
        String(format: "dBFS(flat)=%6.1f  dBFS(A)=%6.1f  SPL(A)=%5.1f dB",
               dbfsFlat, dbfsAWeighted, splA)
    }
}

/// 分贝计配置
public struct MeterConfig {
    public var sampleRate: Float
    public var fftSize: Int
    public var calibrationOffset: Float

    public init(sampleRate: Float = 48000,
                fftSize: Int = 4096,
                calibrationOffset: Float = 0) {
        self.sampleRate = sampleRate
        self.fftSize = fftSize
        self.calibrationOffset = calibrationOffset
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

        // A(f) = 20·log10(Ra/RaMax) + 2.0
        return 20.0 * log10(ra / raMax)
    }

    /// 批量计算频率数组对应的 A 计权线性振幅倍数。
    public static func linearGains(for frequencies: [Float]) -> [Float] {
        frequencies.map { f in pow(10.0, gain(at: f) / 20.0) }
    }
}

// MARK: - 分贝计

/// 核心分贝计：接收 PCM 样本，输出测量结果。
///
/// 数据流：
/// ```
/// 样本[N] -> RMS -> dBFS(flat)
///         -> 加Hann窗 -> FFT -> |X[k]| -> ×A计权 -> 加权RMS -> dBFS(A)
/// SPL(A) = dBFS(A) + offset
/// ```
public final class DBMeter {

    public let config: MeterConfig
    public private(set) var smoothedSPL: Float = -100

    private let smoothingAlpha: Float = 0.2
    private let log2n: vDSP_Length
    private let halfSize: Int
    private let hannWindow: [Float]
    private let aWeightPowerSq: [Float]   // 每个 bin 的 A 计权线性增益的平方（功率域权重）
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

        // 频率轴 & A 计权功率域权重
        self.binFrequencies = (0..<halfSize).map { k in
            Float(k) * config.sampleRate / Float(n)
        }
        // A 计权线性增益的平方，用于功率域加权
        self.aWeightPowerSq = AWeighting.linearGains(for: binFrequencies).map { $0 * $0 }

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

    /// 处理一段单声道 Float32 PCM 样本，返回测量结果。
    public func process(_ samples: [Float]) -> MeterResult? {
        let n = config.fftSize
        guard samples.count >= n else { return nil }
        let frame = Array(samples.prefix(n))

        // ---- dBFS(flat)：对原始样本求 RMS ----
        var rmsFlat: Float = 0
        vDSP_rmsqv(frame, 1, &rmsFlat, vDSP_Length(n))
        let dbfsFlat = 20 * log10(max(rmsFlat, 1e-10))

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

        // ---- A 计权：功率域 = 振幅域增益的平方 ----
        var aWeightPower = [Float](repeating: 0, count: halfSize)
        vDSP_vmul(power, 1, aWeightPowerSq, 1, &aWeightPower, 1, vDSP_Length(halfSize))

        // ---- 功率比法算 A 计权修正量 ----
        // 原理：A 计权是在频域对每个频段重新分配权重。
        //   修正量 = 10·log10(Σ P[k]·W²[k] / Σ P[k])
        // 其中 P[k] 是功率谱，W[k] 是 A 计权线性振幅增益。
        // 任何 FFT 绝对缩放常数在分子分母中自动抵消，
        // 因此 1 kHz 纯音（W=1）的修正量天然为 0，无需标定。
        var sumPower: Float = 0
        var sumWeightedPower: Float = 0
        vDSP_sve(power, 1, &sumPower, vDSP_Length(halfSize))
        vDSP_sve(aWeightPower, 1, &sumWeightedPower, vDSP_Length(halfSize))

        let aWeightCorrection: Float
        if sumPower > 1e-20 {
            aWeightCorrection = 10 * log10(sumWeightedPower / sumPower)
        } else {
            aWeightCorrection = 0
        }

        // ---- dBFS(A) = dBFS(flat) + A计权修正量 ----
        let dbfsA = dbfsFlat + aWeightCorrection

        // ---- SPL ----
        let splA = dbfsA + config.calibrationOffset

        // ---- 时间平滑 ----
        if smoothedSPL < -90 {
            smoothedSPL = splA
        } else {
            smoothedSPL = smoothingAlpha * splA + (1 - smoothingAlpha) * smoothedSPL
        }

        return MeterResult(dbfsFlat: dbfsFlat,
                           dbfsAWeighted: dbfsA,
                           splA: splA,
                           spectrum: magnitudes,
                           frequencies: binFrequencies)
    }

    public func resetSmoothing() {
        smoothedSPL = -100
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
