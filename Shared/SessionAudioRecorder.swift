//
//  SessionAudioRecorder.swift
//  SoundSense
//
//  检测同步录音器:把 AudioMeterEngine tap 送来的 PCM 分块写成 AAC m4a。
//  仅 iOS / macOS 编译(watchOS 不录音)。
//
//  管线:输入(设备速率 Float32 单声道)→ FIR 低通 → 整数倍降采样(48k→24k)
//        → AVAudioFile(.m4a / AAC / 48kbps)。全程私有串行队列,写失败自动停用,
//        测量主流程不受影响。到 maxDuration 停写保文件;不足 minKeepDuration 丢弃。
//

#if os(iOS) || os(macOS)

import Foundation
import AVFoundation

/// AAC m4a 写盘共享辅助(SessionAudioRecorder / EventClipRecorder 复用)
enum AACWriteSupport {

    /// Hamming 窗 sinc 低通系数(cutoffRatio = fc / 输入速率,归一化增益 1)
    static func makeTaps(count: Int, cutoffRatio: Float) -> [Float] {
        let m = count - 1
        var taps = (0..<count).map { i -> Float in
            let k = Float(i) - Float(m) / 2
            let sinc = abs(k) < 1e-6
                ? 2 * Float.pi * cutoffRatio
                : sin(2 * Float.pi * cutoffRatio * k) / k
            let window = 0.54 - 0.46 * cos(2 * Float.pi * Float(i) / Float(m))
            return sinc * window
        }
        let sum = taps.reduce(0, +)
        if sum != 0 { for i in taps.indices { taps[i] /= sum } }
        return taps
    }

    /// 打开 AAC 24kHz 单声道写盘(码率设置被拒时回退 quality 设置)
    static func openFile(forWriting url: URL, targetSampleRate: Float) -> AVAudioFile? {
        let base: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: Double(targetSampleRate),
            AVNumberOfChannelsKey: 1,
        ]
        var withBitrate = base
        withBitrate[AVEncoderBitRateKey] = 48000
        var withQuality = base
        withQuality[AVEncoderAudioQualityKey] = AVAudioQuality.high.rawValue
        return (try? AVAudioFile(forWriting: url, settings: withBitrate))
            ?? (try? AVAudioFile(forWriting: url, settings: withQuality))
    }

    static func pcmBuffer(samples: [Float], format: AVAudioFormat) -> AVAudioPCMBuffer? {
        guard samples.count <= Int(AVAudioFrameCount.max),
              let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                            frameCapacity: AVAudioFrameCount(samples.count))
        else { return nil }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        if let dst = buffer.floatChannelData?[0] {
            for i in 0..<samples.count { dst[i] = samples[i] }
        }
        return buffer
    }
}

/// FIR 低通 + 整数倍抽取(跨块连续,输出点为输入绝对位置 factor-1, 2·factor-1, …)
struct FIRDecimator {
    let taps: [Float]
    let factor: Int
    private var stream: [Float] = []   // 从 nextEnd-(n-1) 起的输入样本
    private var basePos = 0            // stream[0] 的绝对样本位置
    private var nextEnd: Int           // 下一个输出窗口末端的绝对位置

    init(taps: [Float], factor: Int) {
        self.taps = taps
        self.factor = max(1, factor)
        nextEnd = taps.count - 1
    }

    mutating func process(_ input: [Float]) -> [Float] {
        guard !input.isEmpty else { return [] }
        stream.append(contentsOf: input)
        let n = taps.count
        var out: [Float] = []
        out.reserveCapacity(input.count / factor + 1)
        while nextEnd < basePos + stream.count {
            let e = nextEnd - basePos
            var acc: Float = 0
            for j in 0..<n {
                let idx = e - j
                if idx >= 0 { acc += stream[idx] * taps[n - 1 - j] }
            }
            out.append(acc)
            nextEnd += factor
        }
        let keepFrom = max(0, nextEnd - (n - 1) - basePos)
        if keepFrom > 0 {
            stream.removeFirst(keepFrom)
            basePos += keepFrom
        }
        return out
    }
}

public final class SessionAudioRecorder: @unchecked Sendable {

    /// 单场录音时长上限(秒),到点停写保文件,测量继续
    public var maxDuration: TimeInterval = 3600
    /// 低于此时长(秒)的会话在结束时丢弃
    public var minKeepDuration: TimeInterval = 3
    /// 目标采样率(Hz)
    public let targetSampleRate: Float = 24000

    private let queue = DispatchQueue(label: "com.dinghao.soundsense.sessionRecorder")
    private var file: AVAudioFile?
    private var fileURL: URL?
    private var decimator: FIRDecimator?
    private var writtenFrames = 0
    private var stopped = true   // 未开始 / 已结束 / 已失败 / 已到上限

    /// 开始一次会话。返回 audioID(文件名主干);失败返回 nil(录音停用)。
    @discardableResult
    public func startSession(directory: URL, inputSampleRate: Float) -> String? {
        queue.sync { () -> String? in
            _ = finishLocked(keep: false)   // 异常残留先清
            guard inputSampleRate > 0 else { return nil }
            try? FileManager.default.createDirectory(at: directory,
                                                     withIntermediateDirectories: true)
            let id = UUID().uuidString
            let url = directory.appendingPathComponent("\(id).m4a")
            file = AACWriteSupport.openFile(forWriting: url, targetSampleRate: targetSampleRate)
            if file == nil { return nil }
            fileURL = url
            let factor = Int(inputSampleRate / targetSampleRate)
            if Float(factor) * targetSampleRate == inputSampleRate && factor > 1 {
                decimator = FIRDecimator(taps: AACWriteSupport.makeTaps(
                    count: 33, cutoffRatio: 0.45 / Float(factor)), factor: factor)
            } else {
                decimator = nil   // 速率不整除:原速率直写(AAC 编码器自适配)
            }
            writtenFrames = 0
            stopped = false
            return id
        }
    }

    /// 追加样本(音频线程直调,内部转队列)。
    /// 队列外读 stopped:该 Bool 只会 false→true 单向翻转,读到旧值 false
    /// 只会多排一个空转块,writeLocked 会再校验,无竞变风险。
    public func append(_ samples: [Float]) {
        guard !samples.isEmpty, !stopped else { return }
        queue.async { [weak self] in
            guard let self = self, !self.stopped else { return }
            self.writeLocked(samples)
        }
    }

    /// 结束会话:keep 且时长达标返回文件 URL,否则删文件返回 nil。
    @discardableResult
    public func finishSession(keep: Bool) -> URL? {
        queue.sync { finishLocked(keep: keep) }
    }

    /// 是否有进行中的会话(UI 的"录音中"红点用)
    public var isActive: Bool {
        queue.sync { !stopped }
    }

    // MARK: - 队列内实现

    private func writeLocked(_ samples: [Float]) {
        guard !stopped, let file = file else { return }
        let out = decimator?.process(samples) ?? samples
        guard !out.isEmpty,
              let buffer = Self.pcmBuffer(samples: out, format: file.processingFormat) else { return }
        do {
            try file.write(from: buffer)
            writtenFrames += out.count
            if durationLocked >= maxDuration { stopped = true }
        } catch {
            stopped = true   // 磁盘满等:停用录音,不影响测量
        }
    }

    private func finishLocked(keep: Bool) -> URL? {
        defer {
            file = nil
            fileURL = nil
            decimator = nil
            stopped = true
        }
        guard let url = fileURL else { return nil }
        if !keep || durationLocked < minKeepDuration {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        return url
    }

    private var durationLocked: TimeInterval {
        TimeInterval(writtenFrames) / TimeInterval(targetSampleRate)
    }

    private static func pcmBuffer(samples: [Float], format: AVAudioFormat) -> AVAudioPCMBuffer? {
        AACWriteSupport.pcmBuffer(samples: samples, format: format)
    }
}

#endif
