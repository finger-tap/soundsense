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

        // 只分享 UIImage:保证"存储图像"(存相册)选项稳定出现,
        // 微信等收图方对 UIImage 的兼容也没问题
        let controller = UIActivityViewController(activityItems: [image],
                                                  applicationActivities: nil)
        controller.excludedActivityTypes = [.assignToContact, .addToReadingList]
        return controller
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
