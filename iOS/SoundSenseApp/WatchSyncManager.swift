//
//  WatchSyncManager.swift
//  SoundSense iOS
//
//  接收手表发来的三点测试结果,解码后入 SourceTestStore,并发通知供 UI 提示。
//

import Foundation
import WatchConnectivity

final class WatchSyncManager: NSObject, WCSessionDelegate {

    static let shared = WatchSyncManager()
    /// UI 监听此通知提示"手表测试结果已同步"
    static let receivedNotification = Notification.Name("watchSourceTestReceived")

    private override init() {
        super.init()
    }

    func activate() {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        session.delegate = self
        session.activate()
    }

    // MARK: - WCSessionDelegate

    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState,
                 error: Error?) {}

    func sessionDidBecomeInactive(_ session: WCSession) {}

    func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }

    func session(_ session: WCSession, didReceiveMessageData data: Data) {
        guard let results = try? JSONDecoder().decode([SourceTestResult].self, from: data),
              let result = results.first else { return }
        SourceTestStore.shared.add(result)
        NotificationCenter.default.post(name: Self.receivedNotification, object: nil)
    }
}
