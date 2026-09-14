//
//  EventClipRecorder.swift
//  SoundSense
//
//  事件片段录音器:持续消费 PCM 流,事件触发时把"pre-roll + 事件 + post-roll"
//  写成独立 AAC m4a。只存片段不全程录,长时间监听的存储占用极小。
//
//  用法:configure() 后持续 append();事件开始 beginClip()(立即落盘环形缓冲里的
//  pre-roll);事件结束 endClip()(此后再写满 postRollSeconds 自动定稿)。
//

#if os(iOS) || os(macOS)

import Foundation
import AVFoundation

public final class EventClipRecorder: @unchecked Sendable {

    /// 片段前导时长(秒,从环形缓冲回溯)
    public var preRollSeconds: TimeInterval = 2
    /// 片段尾随时长(秒,endClip 后继续录满)
    public var postRollSeconds: TimeInterval = 3
    /// 目标采样率(与 SessionAudioRecorder 一致)
    public let targetSampleRate: Float = 24000

    private let queue = DispatchQueue(label: "com.dinghao.soundsense.eventClip")
    private var directory: URL?
    private var decimator: FIRDecimator?

    /// 降采样后的环形缓冲(pre-roll 容量)
    private var ring: [Float] = []
    private var ringCapacity = 0

    private var file: AVAudioFile?
    private var fileURL: URL?
    private var open = false
    private var postRemaining = 0   // endClip 后还需写入的帧数

    public init() {}

    /// 配置输出目录与输入采样率(可重复调用,清空旧缓冲)
    public func configure(directory: URL, inputSampleRate: Float) {
        queue.sync {
            self.directory = directory
            try? FileManager.default.createDirectory(at: directory,
                                                     withIntermediateDirectories: true)
            let factor = Int(inputSampleRate / targetSampleRate)
            if inputSampleRate > 0,
               Float(factor) * targetSampleRate == inputSampleRate, factor > 1 {
                decimator = FIRDecimator(taps: AACWriteSupport.makeTaps(
                    count: 33, cutoffRatio: 0.45 / Float(factor)), factor: factor)
            } else {
                decimator = nil
            }
            ring.removeAll(keepingCapacity: true)
            ringCapacity = Int(ceil(preRollSeconds * Double(targetSampleRate)))
            file = nil
            fileURL = nil
            open = false
            postRemaining = 0
        }
    }

    /// 持续喂入输入采样率的样本(音频线程直调,内部转队列)
    public func append(_ samples: [Float]) {
        guard !samples.isEmpty else { return }
        queue.async { [weak self] in
            self?.consume(samples)
        }
    }

    /// 事件开始:落盘 pre-roll 并开始实时写入。返回片段文件 URL(失败 nil)。
    @discardableResult
    public func beginClip() -> URL? {
        queue.sync {
            guard let dir = directory, !open, postRemaining == 0 else { return nil }
            let url = dir.appendingPathComponent("\(UUID().uuidString).m4a")
            guard let f = AACWriteSupport.openFile(forWriting: url,
                                                   targetSampleRate: targetSampleRate) else {
                return nil
            }
            file = f
            fileURL = url
            open = true
            // 落盘环形缓冲里的 pre-roll
            let pre = ring
            writeToFile(pre)
            return url
        }
    }

    /// 事件结束:此后写满 postRollSeconds 自动定稿。无打开片段返回 false。
    @discardableResult
    public func endClip() -> Bool {
        queue.sync {
            guard open else { return false }
            open = false
            postRemaining = Int(ceil(postRollSeconds * Double(targetSampleRate)))
            return true
        }
    }

    /// 是否处于片段实时写入阶段(begin → end 之间)
    public var isClipOpen: Bool {
        queue.sync { open }
    }

    /// 等待队列排空(post-roll 定稿完成;停止监听/测试断言前调用)
    public func flush() {
        queue.sync {}
    }

    // MARK: - 队列内实现

    private func consume(_ samples: [Float]) {
        let out = decimator?.process(samples) ?? samples
        guard !out.isEmpty else { return }

        // 环形缓冲始终维护(为下一次片段准备 pre-roll)
        ring.append(contentsOf: out)
        if ring.count > ringCapacity {
            ring.removeFirst(ring.count - ringCapacity)
        }

        if open {
            writeToFile(out)
        } else if postRemaining > 0 {
            writeToFile(out)
            postRemaining = max(0, postRemaining - out.count)
            if postRemaining == 0 {
                file = nil        // 定稿(AVAudioFile 释放即完成)
                fileURL = nil
            }
        }
    }

    private func writeToFile(_ samples: [Float]) {
        guard let file = file,
              let buffer = AACWriteSupport.pcmBuffer(samples: samples,
                                                     format: file.processingFormat) else { return }
        try? file.write(from: buffer)
    }
}

#endif
