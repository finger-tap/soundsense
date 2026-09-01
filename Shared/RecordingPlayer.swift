//
//  RecordingPlayer.swift
//  SoundSense
//
//  录音回放:AVAudioPlayer 的 ObservableObject 封装,历史详情页共用(iOS/macOS)。
//  文件缺失/损坏 → isAvailable=false,UI 降级为"录音不可用"。
//

#if os(iOS) || os(macOS)

import AVFoundation
import Combine

@MainActor
public final class RecordingPlayer: NSObject, ObservableObject {

    @Published public private(set) var isPlaying = false
    /// 0...1
    @Published public private(set) var progress: Double = 0
    @Published public private(set) var duration: TimeInterval = 0
    @Published public private(set) var isAvailable = false

    private var player: AVAudioPlayer?
    private var timer: Timer?

    public func load(url: URL) {
        stop()
        if let p = try? AVAudioPlayer(contentsOf: url) {
            player = p
            duration = p.duration
            isAvailable = p.duration > 0
        } else {
            player = nil
            duration = 0
            isAvailable = false
        }
    }

    public func togglePlayPause() {
        guard let p = player, isAvailable else { return }
        if p.isPlaying {
            p.pause()
            isPlaying = false
        } else {
            #if os(iOS)
            // 测量会话已停用;回放前切到 playback,避免听筒小声
            try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
            try? AVAudioSession.sharedInstance().setActive(true)
            #endif
            p.play()
            isPlaying = true
            startTimer()
        }
    }

    public func stop() {
        player?.stop()
        player?.currentTime = 0
        isPlaying = false
        progress = 0
        timer?.invalidate()
        timer = nil
    }

    private func startTimer() {
        timer?.invalidate()
        let t = Timer(timeInterval: 0.2, repeats: true) { _ in
            Task { @MainActor [weak self] in
                self?.tick()
            }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func tick() {
        guard let p = player, duration > 0 else { return }
        if p.isPlaying {
            progress = min(1, p.currentTime / duration)
        } else {   // 自然播完
            isPlaying = false
            progress = 0
            timer?.invalidate()
            timer = nil
        }
    }

    /// m:ss
    public static func formatTime(_ t: TimeInterval) -> String {
        let s = max(0, Int(t))
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

#endif
