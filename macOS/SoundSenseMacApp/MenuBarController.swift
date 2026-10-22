//
//  MenuBarController.swift
//  SoundSenseMac
//
//  菜单栏模式:NSStatusItem 常驻菜单栏,用小型滚动声波显示实时噪音起伏,
//  点击可开始/停止测量、打开主窗口、退出。(macOS 12 兼容,不用 MenuBarExtra)
//

import AppKit
import Combine
import SwiftUI
import SoundSenseCore

@MainActor
final class MenuBarController: NSObject, ObservableObject {

    private var statusItem: NSStatusItem?
    private var cancellables = Set<AnyCancellable>()
    private weak var viewModel: MeterViewModel?
    private var waveformSamples: [Float] = []
    private var lastSampleTime = Date.distantPast
    private var lastMenuRefresh = Date.distantPast

    /// 装载菜单栏图标,绑定视图模型
    func attach(viewModel: MeterViewModel) {
        self.viewModel = viewModel

        let item = NSStatusBar.system.statusItem(withLength: 38)
        item.button?.title = ""
        item.button?.imagePosition = .imageOnly
        item.button?.imageScaling = .scaleProportionallyDown
        item.menu = buildMenu()
        statusItem = item

        // 数值/状态变化 → 刷新标题与菜单
        // (objectWillChange 覆盖所有 @Published 变化,含转发的 engine 状态)
        viewModel.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] in
                self?.refresh()
            }
            .store(in: &cancellables)
        refresh()
    }

    /// 卸载菜单栏图标
    func detach() {
        if let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
        }
        statusItem = nil
        cancellables.removeAll()
    }

    // MARK: - 刷新

    private func refresh() {
        guard let button = statusItem?.button else { return }
        let running = viewModel?.engine.state == .running
        let spl = viewModel?.currentSPL
        let validLevel = running && (spl?.isFinite == true) && (spl ?? -.greatestFiniteMagnitude) > -80

        if validLevel, let spl {
            let now = Date()
            // 30 Hz 引擎更新只以 10 Hz 进入菜单栏，避免无意义的绘制开销。
            if now.timeIntervalSince(lastSampleTime) >= 0.1 {
                waveformSamples = MenuBarWaveform.appending(spl, to: waveformSamples)
                lastSampleTime = now
            }
        } else if !running {
            waveformSamples.removeAll(keepingCapacity: true)
        }

        button.image = waveformImage(samples: waveformSamples, running: running)
        button.toolTip = menuBarToolTip(spl: spl, running: running)
        button.setAccessibilityLabel("闻声噪音电平")
        button.setAccessibilityValue(button.toolTip ?? "")

        // 菜单里的实时读数按 1 Hz 刷新；状态变化时立即刷新。
        let now = Date()
        if !running || now.timeIntervalSince(lastMenuRefresh) >= 1 {
            lastMenuRefresh = now
            statusItem?.menu = buildMenu()
        }
    }

    private func menuBarToolTip(spl: Float?, running: Bool) -> String {
        guard running else { return "闻声：未在测量" }
        guard let spl, spl.isFinite, spl > -80 else { return "闻声：正在测量，等待音频" }
        return String(format: "闻声：%.0f dB · 实时声波", spl)
    }

    /// 小型滚动声波。模板图由 macOS 自动反转前景色，
    /// 浅色与深色菜单栏都能保持清晰。
    private func waveformImage(samples: [Float], running: Bool) -> NSImage {
        let size = NSSize(width: 32, height: 18)
        let image = NSImage(size: size, flipped: false) { _ in
            let path = NSBezierPath()
            path.lineWidth = 1.8
            path.lineCapStyle = .round
            path.lineJoinStyle = .round

            let left: CGFloat = 2
            let right: CGFloat = 30
            let top: CGFloat = 14.5
            let bottom: CGFloat = 3.5
            let slots = max(1, MenuBarWaveform.sampleCount - 1)
            let firstSample = max(0, MenuBarWaveform.sampleCount - samples.count)

            if samples.isEmpty {
                path.move(to: NSPoint(x: left, y: 9))
                path.line(to: NSPoint(x: right, y: 9))
            } else if samples.count == 1 {
                let level = CGFloat(MenuBarWaveform.normalized(samples[0]))
                let y = bottom + level * (top - bottom)
                path.move(to: NSPoint(x: left, y: y))
                path.line(to: NSPoint(x: right, y: y))
            } else {
                for (index, sample) in samples.enumerated() {
                    let slot = firstSample + index
                    let x = left + CGFloat(slot) / CGFloat(slots) * (right - left)
                    let level = CGFloat(MenuBarWaveform.normalized(sample))
                    let y = bottom + level * (top - bottom)
                    if index == 0 {
                        path.move(to: NSPoint(x: x, y: y))
                    } else {
                        path.line(to: NSPoint(x: x, y: y))
                    }
                }
            }

            NSColor.black.withAlphaComponent(running ? 1 : 0.34).setStroke()
            path.stroke()
            return true
        }
        image.isTemplate = true
        return image
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()

        let running = viewModel?.engine.state == .running

        // 当前读数(禁用,仅展示)
        let spl = viewModel?.currentSPL ?? -.greatestFiniteMagnitude
        let level = viewModel?.noiseLevel
        let reading: String
        if spl.isFinite, spl > -80, let lv = level {
            reading = String(format: "%.1f dB · %@", spl, lv.label)
        } else {
            // 失败/被拒也要在菜单栏可见,否则用户只能开主窗才知道原因
            switch viewModel?.engine.state {
            case .running: reading = "正在测量..."
            case .denied: reading = "麦克风权限被拒绝"
            case .failed(let m): reading = "启动失败:\(m)"
            default: reading = "未在测量"
            }
        }
        menu.addItem(disabledItem(reading))

        if let live = viewModel?.liveStats {
            let lpeak = live.lpeak.isFinite
                ? String(format: "%.1f", live.lpeak)
                : "--"
            menu.addItem(disabledItem(String(
                format: "时长 %02d:%02d · LAeq %.1f · 峰值 %.1f · Lpk %@",
                Int(live.duration) / 60, Int(live.duration) % 60,
                live.laeq, live.peak, lpeak)))
        }

        menu.addItem(.separator())

        let toggle = NSMenuItem(title: running ? "停止测量" : "开始测量",
                                action: #selector(toggleMeasurement),
                                keyEquivalent: "")
        toggle.target = self
        if !running, viewModel?.analysisToolPresented == true {
            toggle.title = "噪音分析工具使用中"
            toggle.isEnabled = false
        }
        menu.addItem(toggle)

        // 权限被拒时给出系统设置的直达入口
        if viewModel?.engine.state == .denied {
            let settings = NSMenuItem(title: "打开系统设置(麦克风)…",
                                      action: #selector(openMicSettings),
                                      keyEquivalent: "")
            settings.target = self
            menu.addItem(settings)
        }

        let open = NSMenuItem(title: "打开闻声窗口", action: #selector(openMainWindow),
                              keyEquivalent: "")
        open.target = self
        menu.addItem(open)

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "退出闻声", action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        return menu
    }

    private func disabledItem(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    // MARK: - 动作

    @objc private func toggleMeasurement() {
        guard let vm = viewModel else { return }
        Task { @MainActor in
            if vm.engine.state == .running {
                await vm.stop()
            } else {
                await vm.start()
            }
        }
    }

    @objc private func openMainWindow() {
        viewModel?.openMainWindow?()
    }

    @objc private func quitApp() {
        NSApplication.shared.terminate(nil)
    }

    @objc private func openMicSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
    }
}
