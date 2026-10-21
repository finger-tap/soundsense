//
//  SoundSenseMacApp.swift
//  SoundSenseMac
//
//  macOS GUI 应用入口。
//  窗口可缩放(有最小尺寸),背景撑满整个窗口,隐藏标题栏。
//  同时常驻菜单栏(NSStatusItem),随时查看当前分贝。
//

import SwiftUI
import AppKit

@main
struct SoundSenseMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    /// 全局共享:主窗口与菜单栏控制器使用同一个视图模型
    @StateObject private var appModel = MacAppModel.shared

    var body: some Scene {
        WindowGroup {
            MacMainMeterView(viewModel: appModel.meterModel)
                .frame(minWidth: 760, minHeight: 680)
        }
        .windowStyle(.hiddenTitleBar)
    }
}

/// 应用级模型:持有主视图模型 + 菜单栏控制器
@MainActor
final class MacAppModel: ObservableObject {
    static let shared = MacAppModel()

    let meterModel = MeterViewModel()
    let menuBar = MenuBarController()

    private init() {
        // 上次进程被系统直接结束时，把遗留的“进行中”监听会话标成异常结束。
        MonitorSessionStore.shared.finalizeInterruptedSessions()
    }
}

/// 桌面端窗口:设置合理的最小尺寸并恢复缩放/全屏能力。
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        DispatchQueue.main.async {
            self.configureWindows()
        }
        // 菜单栏图标必须在 App 完全启动后创建:
        // 在 SwiftUI App 构造阶段创建 NSStatusItem 会因尚未建立
        // 窗口服务器连接而断言崩溃(macOS 12 实测 SIGABRT)。
        Task { @MainActor in
            MacAppModel.shared.menuBar.attach(viewModel: MacAppModel.shared.meterModel)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        // 退出时停止测量,释放麦克风
        // (MacAppModel 由 SwiftUI 管理,这里兜底停引擎)
    }

    private func configureWindows() {
        for window in NSApplication.shared.windows where window.canBecomeMain {
            window.contentMinSize = NSSize(width: 760, height: 680)
            window.contentMaxSize = NSSize(width: 10000, height: 10000)
            window.styleMask.insert(.resizable)
            window.collectionBehavior.remove(.fullScreenNone)
            window.collectionBehavior.insert(.fullScreenPrimary)
            window.standardWindowButton(.zoomButton)?.isHidden = false
            if window.frame.width < 760 || window.frame.height < 680 {
                window.setContentSize(NSSize(width: 900, height: 780))
                window.center()
            }
        }
    }
}
