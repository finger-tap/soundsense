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
        // 手表三点测试结果接收
        WatchSyncManager.shared.activate()
    }

    var body: some Scene {
        WindowGroup {
            MainMeterView()
        }
    }
}
