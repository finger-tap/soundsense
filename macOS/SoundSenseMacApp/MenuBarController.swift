//
//  MenuBarController.swift
//  SoundSenseMac
//
//  菜单栏模式:NSStatusItem 常驻菜单栏,实时显示当前分贝,
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

    /// 装载菜单栏图标,绑定视图模型
    func attach(viewModel: MeterViewModel) {
        self.viewModel = viewModel

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        item.button?.title = "-- dB"
        item.menu = buildMenu()
        statusItem = item

        // 数值/状态变化 → 刷新标题与菜单
        Publishers.CombineLatest(viewModel.$liveStats, viewModel.engine.$latestResult)
            .receive(on: RunLoop.main)
            .sink { [weak self] _, _ in
                self?.refresh()
            }
            .store(in: &cancellables)
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
        let spl = viewModel?.currentSPL
        if let spl = spl, spl.isFinite, spl > -80 {
            button.title = String(format: "%.0f dB", spl)
        } else {
            button.title = "-- dB"
        }
        // 重建菜单(条目少,开销可忽略)
        statusItem?.menu = buildMenu()
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
            reading = running ? "正在测量..." : "未在测量"
        }
        menu.addItem(disabledItem(reading))

        if let live = viewModel?.liveStats {
            menu.addItem(disabledItem(String(
                format: "时长 %02d:%02d · LAeq %.1f · 峰值 %.1f",
                Int(live.duration) / 60, Int(live.duration) % 60, live.laeq, live.peak)))
        }

        menu.addItem(.separator())

        let toggle = NSMenuItem(title: running ? "停止测量" : "开始测量",
                                action: #selector(toggleMeasurement),
                                keyEquivalent: "")
        toggle.target = self
        menu.addItem(toggle)

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
                vm.stop()
            } else {
                await vm.start()
            }
        }
    }

    @objc private func openMainWindow() {
        NSApplication.shared.activate(ignoringOtherApps: true)
        for window in NSApplication.shared.windows
        where window.windowController?.window?.contentViewController != nil
            || window.contentView != nil {
            // 激活并置前主窗口(排除菜单栏面板等无边框窗口)
            if window.canBecomeMain {
                window.makeKeyAndOrderFront(nil)
                return
            }
        }
    }

    @objc private func quitApp() {
        NSApplication.shared.terminate(nil)
    }
}
