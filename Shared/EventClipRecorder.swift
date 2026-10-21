//
//  EventClipRecorder.swift
//  SoundSense
//
//  事件片段录音器:持续消费 PCM 流,事件触发时把"pre-roll + 事件 + post-roll"
//  写成独立 AAC m4a。只存片段不全程录,长时间监听的存储占用极小。
//
//  用法:configure() 后持续 append();事件开始 beginClip()(立即落盘环形缓冲里的
//  pre-roll);事件结束 endClip()(此后再写满 postRollSeconds 自动定稿)。
//  单个片段硬上限默认 60 秒,避免超长事件持续写同一个文件。
//

#if os(iOS) || os(macOS)

import Foundation
import AVFoundation

public final class EventClipRecorder: @unchecked Sendable {

    /// 片段前导时长(秒,从环形缓冲回溯)
    public var preRollSeconds: TimeInterval = 2
    /// 片段尾随时长(秒,endClip 后继续录满)
    public var postRollSeconds: TimeInterval = 3
    /// 能整数倍降采样时优先使用的采样率
    public let targetSampleRate: Float = 24000
    /// 单片段最大时长(秒,含 pre-roll / 事件 / post-roll)
    public var maxClipDuration: TimeInterval = 60

    private let queue = DispatchQueue(label: "com.dinghao.soundsense.eventClip")
    /// 保护音频线程与片段队列之间的启用状态/待处理队列计数。
    private let stateLock = NSLock()
    private var directory: URL?
    private var decimator: FIRDecimator?
    /// 实际写入文件的采样率。非整数倍输入直接按源采样率写,避免变调/时长错误。
    private var outputSampleRate: Float = 24000

    /// 降采样后的环形缓冲(pre-roll 容量)
    private var ring: [Float] = []
    private var ringCapacity = 0

    private var file: AVAudioFile?
    private var fileURL: URL?
    private var open = false
    private var postRemaining = 0   // endClip 后还需写入的帧数
    private var clipFrames = 0
    private var maxClipFrames = 0
    private var lastCompletedURL: URL?
    /// 达到片段上限后必须停止消费 PCM，否则 append 闭包仍会在队列里
    /// 继续填充环形缓冲，长时间监听会留下无意义的待处理工作。
    private var captureEnabled = false
    private var pendingAppendCount = 0
    private var droppedAppendCount = 0
    private static let maxPendingAppendCount = 64
    /// 事件开始时被硬时限截断后,endClip 仍应能找到对应片段。
    private var closedByLimit = false
    /// 片段定稿后等待监听 VM 把 URL 关联到事件;关联后置 false。
    private var lastClipEventNeedsUpdate = false

    public init() {}

    /// 配置输出目录与输入采样率(可重复调用,清空旧缓冲)
    public func configure(directory: URL, inputSampleRate: Float) {
        queue.sync {
            self.directory = directory
            try? FileManager.default.createDirectory(at: directory,
                                                     withIntermediateDirectories: true)
            if open || postRemaining > 0 || file != nil || clipFrames > 0 {
                finalizeLocked()
            }
            let factor = Int(inputSampleRate / targetSampleRate)
            if inputSampleRate > 0,
               Float(factor) * targetSampleRate == inputSampleRate, factor > 1 {
                decimator = FIRDecimator(taps: AACWriteSupport.makeTaps(
                    count: 33, cutoffRatio: 0.45 / Float(factor)), factor: factor)
                outputSampleRate = targetSampleRate
            } else {
                decimator = nil
                outputSampleRate = inputSampleRate > 0 ? inputSampleRate : targetSampleRate
            }
            ring.removeAll(keepingCapacity: true)
            ringCapacity = Int(ceil(preRollSeconds * Double(outputSampleRate)))
            file = nil
            fileURL = nil
            lastCompletedURL = nil
            open = false
            postRemaining = 0
            clipFrames = 0
            closedByLimit = false
            lastClipEventNeedsUpdate = false
            maxClipFrames = max(1, Int(ceil(maxClipDuration * Double(outputSampleRate))))
            stateLock.lock()
            captureEnabled = true
            pendingAppendCount = 0
            droppedAppendCount = 0
            stateLock.unlock()
        }
    }

    /// 持续喂入输入采样率的样本(音频线程直调,内部转队列)
    public func append(_ samples: [Float]) {
        guard !samples.isEmpty else { return }
        stateLock.lock()
        let shouldAccept = captureEnabled
            && pendingAppendCount < Self.maxPendingAppendCount
        if shouldAccept {
            pendingAppendCount += 1
        } else if captureEnabled {
            // 磁盘/编码器短暂阻塞时丢弃新块，保持内存有界；正常路径不会走到这里。
            droppedAppendCount += 1
        }
        stateLock.unlock()
        guard shouldAccept else { return }
        queue.async { [weak self] in
            guard let self else { return }
            self.consume(samples)
            self.stateLock.lock()
            self.pendingAppendCount = max(0, self.pendingAppendCount - 1)
            self.stateLock.unlock()
        }
    }

    /// 事件开始:落盘 pre-roll 并开始实时写入。返回片段文件 URL(失败 nil)。
    @discardableResult
    public func beginClip() -> URL? {
        queue.sync {
            guard captureEnabled, let dir = directory,
                  !open, postRemaining == 0 else { return nil }
            let url = dir.appendingPathComponent("\(UUID().uuidString).m4a")
            guard let f = AACWriteSupport.openFile(forWriting: url,
                                                   targetSampleRate: outputSampleRate) else {
                return nil
            }
            file = f
            fileURL = url
            open = true
            clipFrames = 0
            closedByLimit = false
            lastClipEventNeedsUpdate = false
            lastCompletedURL = nil
            // 落盘环形缓冲里的 pre-roll
            let pre = ring
            writeActiveSamples(pre)
            return url
        }
    }

    /// 事件结束:此后写满 postRollSeconds 自动定稿。无打开片段返回 false。
    @discardableResult
    public func endClip() -> Bool {
        queue.sync {
            if closedByLimit { return true }
            guard open else { return false }
            open = false
            postRemaining = Int(ceil(postRollSeconds * Double(outputSampleRate)))
            return true
        }
    }

    /// 是否处于片段实时写入阶段(begin → end 之间)
    public var isClipOpen: Bool {
        queue.sync { open }
    }

    /// 最近一次片段文件 URL(定稿后仍保留,直到下一次 begin/configure)
    public var lastClipURL: URL? {
        queue.sync { lastCompletedURL ?? fileURL }
    }

    /// 事件已结束时,本次事件对应的片段是否已经定稿。
    public var isFinalizedForCompletedEvent: Bool {
        queue.sync {
            !open && postRemaining == 0
                && lastCompletedURL != nil && lastClipEventNeedsUpdate
        }
    }

    /// 立即结束并定稿当前片段,不再等待 post-roll。停止监听时调用。
    public func finish() {
        queue.sync {
            open = false
            postRemaining = 0
            finalizeLocked()
        }
    }

    /// 停用片段抓拍并清空环形缓冲,但保留已定稿文件的 URL。
    /// 用于单会话达到事件上限后继续长时间测量、避免无意义的音频缓冲。
    public func disableCapture() {
        queue.sync {
            stateLock.lock()
            captureEnabled = false
            stateLock.unlock()
            open = false
            postRemaining = 0
            finalizeLocked()
            ring.removeAll(keepingCapacity: false)
            directory = nil
        }
    }

    /// 监听 VM 已把最近片段关联到事件后调用,防止重复写同一条事件。
    public func markLastClipConsumed() {
        queue.sync { lastClipEventNeedsUpdate = false }
    }

    /// 等待队列排空(post-roll 定稿完成;停止监听/测试断言前调用)
    public func flush() {
        queue.sync {}
    }

    // MARK: - 队列内实现

    private func consume(_ samples: [Float]) {
        guard captureEnabled else { return }
        let out = decimator?.process(samples) ?? samples
        guard !out.isEmpty else { return }

        // 环形缓冲始终维护(为下一次片段准备 pre-roll)
        ring.append(contentsOf: out)
        if ring.count > ringCapacity {
            ring.removeFirst(ring.count - ringCapacity)
        }

        if open {
            writeActiveSamples(out)
        } else if postRemaining > 0 {
            let written = writeActiveSamples(out)
            postRemaining = max(0, postRemaining - written)
            if postRemaining == 0 && file != nil {
                finalizeLocked()
            }
        }
    }

    /// 只写当前片段剩余容量内的样本;达到硬上限立刻定稿。
    @discardableResult
    private func writeActiveSamples(_ samples: [Float]) -> Int {
        guard let file = file, !samples.isEmpty else { return 0 }
        let remaining = max(0, maxClipFrames - clipFrames)
        guard remaining > 0 else {
            finalizeLocked()
            return 0
        }
        let count = min(samples.count, remaining)
        let slice = count == samples.count ? samples : Array(samples.prefix(count))
        guard let buffer = AACWriteSupport.pcmBuffer(samples: slice,
                                                     format: file.processingFormat) else {
            return 0
        }
        do {
            try file.write(from: buffer)
        } catch {
            finalizeLocked()   // 磁盘满/编码失败:保留已有文件,停止该片段
            return 0
        }
        clipFrames += count
        if clipFrames >= maxClipFrames {
            finalizeLocked()
            closedByLimit = true
        }
        return count
    }

    /// 释放 AVAudioFile 即完成 AAC 容器收尾;保留 fileURL 供事件记录引用。
    private func finalizeLocked() {
        if clipFrames > 0 {
            lastCompletedURL = fileURL
            lastClipEventNeedsUpdate = true
        }
        file = nil
        open = false
        postRemaining = 0
        clipFrames = 0
        closedByLimit = false
    }
}

#endif
