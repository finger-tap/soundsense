//
//  SoundSenseMacApp.swift
//  SoundSenseMac
//
//  macOS GUI 应用入口。
//  固定窗口大小(不可缩放、不可全屏),背景撑满整个窗口,隐藏标题栏。
//  同时常驻菜单栏(NSStatusItem),随时查看当前分贝。
//

import SwiftUI
import AppKit

@main
struct SoundSenseMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    /// 全局共享:主窗口与菜单栏控制器使用同一个视图模型
    @StateObject private var appModel = MacAppModel()

    var body: some Scene {
        WindowGroup {
            MacMainMeterView(viewModel: appModel.meterModel)
                .frame(width: 860, height: 780)
        }
        .windowStyle(.hiddenTitleBar)
    }
}

/// 应用级模型:持有主视图模型 + 菜单栏控制器
@MainActor
final class MacAppModel: ObservableObject {
    let meterModel = MeterViewModel()
    let menuBar = MenuBarController()

    init() {
        menuBar.attach(viewModel: meterModel)
    }
}

/// 固定窗口大小:禁止缩放、禁止全屏(避免全屏白边),仍可移动、最小化。
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        DispatchQueue.main.async {
            self.configureWindows()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        // 退出时停止测量,释放麦克风
        // (MacAppModel 由 SwiftUI 管理,这里兜底停引擎)
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
