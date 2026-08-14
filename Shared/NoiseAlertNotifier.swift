//
//  NoiseAlertNotifier.swift
//  SoundSense
//
//  噪声暴露本地通知:连续超过 85 dB 达到阈值时发系统通知(iOS / macOS 共用)。
//

#if os(iOS) || os(macOS)

import Foundation
import UserNotifications

public enum NoiseAlertNotifier {

    private static let notificationID = "com.dinghao.soundsense.exposure"

    /// 请求通知权限(App 内警告横幅不依赖此权限;系统通知需要)。
    public static func requestAuthorization() {
        let center = UNUserNotificationCenter.current()
        center.delegate = NoiseAlertNotifierDelegate.shared
        center.getNotificationSettings { settings in
            switch settings.authorizationStatus {
            case .notDetermined:
                center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
            default:
                break
            }
        }
    }

    /// 发送暴露警告通知(静默失败:权限未授予时只是不弹)。
    public static func notifyExposure(db: Float, seconds: Int) {
        let content = UNMutableNotificationContent()
        content.title = "噪音过高 ⚠️"
        content.body = String(format: "环境噪音已连续 %d 秒超过 %.0f dB,长时间暴露可能损伤听力,建议离开或做好防护。", seconds, db)
        content.sound = .default

        let request = UNNotificationRequest(identifier: notificationID,
                                            content: content,
                                            trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}

/// 让 App 在前台时也能显示系统通知横幅
final class NoiseAlertNotifierDelegate: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NoiseAlertNotifierDelegate()

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler:
                                @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}

#endif
