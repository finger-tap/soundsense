//
//  SoundSenseMacApp.swift
//  SoundSenseMac
//
//  macOS GUI 应用入口。
//

import SwiftUI

@main
struct SoundSenseMacApp: App {
    var body: some Scene {
        WindowGroup {
            MacMainMeterView()
                .frame(minWidth: 640, minHeight: 480)
                .frame(width: 820, height: 600)
        }
    }
}
