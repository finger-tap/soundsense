//
//  SoundSenseApp.swift
//  SoundSense iOS
//
//  iOS 应用入口。
//

import SwiftUI
@main
struct SoundSenseApp: App {
    init() {
        // 手表方向倾向测试结果接收
        WatchSyncManager.shared.activate()
        // 上次若被系统直接终止，历史里的监听会话不应永远显示“进行中”。
        MonitorSessionStore.shared.finalizeInterruptedSessions()
    }

    var body: some Scene {
        WindowGroup {
            MainMeterView()
        }
    }
}
