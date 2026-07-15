//
//  ReportShareSheet.swift
//  SoundSense iOS
//
//  iOS 报告分享:用 UIActivityViewController 分享 PNG(微信/收藏/保存图片等)。
//

import SwiftUI
import UIKit

/// 包装 UIActivityViewController 供 SwiftUI 使用。
struct ReportShareSheet: UIViewControllerRepresentable {
    let stats: MeasurementStats
    let deviceName: String
    let calibrationOffset: Float

    func makeUIViewController(context: Context) -> UIActivityViewController {
        // 生成报告图片
        let image = ReportRenderer.render(stats: stats,
                                           deviceName: deviceName,
                                           calibrationOffset: calibrationOffset)

        // 写临时文件(分享文件比分享 UIImage 更兼容微信)
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd_HHmm"
        let filename = "闻声报告_\(df.string(from: stats.startTime)).png"
        let tmpURL = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
        if let pngData = image.pngData() {
            try? pngData.write(to: tmpURL)
        }

        let items: [Any] = [image, tmpURL]
        let controller = UIActivityViewController(activityItems: items,
                                                    applicationActivities: nil)
        controller.excludedActivityTypes = [.assignToContact, .addToReadingList]
        return controller
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
