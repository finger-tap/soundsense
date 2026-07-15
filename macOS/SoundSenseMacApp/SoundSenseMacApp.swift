//
//  SoundSenseMacApp.swift
//  SoundSenseMac
//
//  macOS GUI 应用入口。
//  固定窗口大小(不可缩放、不可全屏),背景撑满整个窗口,隐藏标题栏。
//

import SwiftUI
import AppKit

@main
struct SoundSenseMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            MacMainMeterView()
                .frame(width: 860, height: 780)
        }
        .windowStyle(.hiddenTitleBar)
    }
}

/// 固定窗口大小:禁止缩放、禁止全屏(避免全屏白边),仍可移动、最小化。
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        DispatchQueue.main.async {
            self.configureWindows()
        }
    }

    private func configureWindows() {
        let fixedSize = NSSize(width: 860, height: 780)
        for window in NSApplication.shared.windows {
            // 固定大小
            window.setContentSize(fixedSize)
            window.contentMinSize = fixedSize
            window.contentMaxSize = fixedSize
            // 禁止缩放
            window.styleMask.remove(.resizable)
            // 禁止全屏(阻止 Cmd+Ctrl+F,且不响应绿色按钮全屏)
            window.collectionBehavior = [.fullScreenNone]
            // 隐藏标题栏的全屏按钮(如果有)
            if let fsButton = window.standardWindowButton(.zoomButton) {
                fsButton.isHidden = true
            }
        }
    }
}
