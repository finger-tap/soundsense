//
//  SoundSenseApp.swift
//  SoundSense iOS
//
//  iOS 应用入口。
//

import SwiftUI
import UIKit

@main
struct SoundSenseApp: App {
    init() {
        // 导航栏标题统一白色:深色背景上默认深色标题几乎看不见。
        // 按钮颜色由各视图显式指定(SwiftUI foregroundColor 优先于全局外观)。
        // 背景保留半透明玻璃效果。
        let appearance = UINavigationBarAppearance()
        appearance.titleTextAttributes = [.foregroundColor: UIColor.white]
        appearance.largeTitleTextAttributes = [.foregroundColor: UIColor.white]
        UINavigationBar.appearance().standardAppearance = appearance
        UINavigationBar.appearance().scrollEdgeAppearance = appearance
        UINavigationBar.appearance().compactAppearance = appearance

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
