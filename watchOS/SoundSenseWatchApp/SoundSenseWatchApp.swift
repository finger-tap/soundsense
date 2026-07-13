//
//  SoundSenseWatchApp.swift
//  SoundSenseWatch
//
//  独立 watchOS 应用入口。
//

import SwiftUI

@main
struct SoundSenseWatchApp: App {
    var body: some Scene {
        WindowGroup {
            WatchMeterView()
        }
    }
}
