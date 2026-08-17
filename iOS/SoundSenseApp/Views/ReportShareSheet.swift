//
//  ReportShareSheet.swift
//  SoundSense iOS
//
//  iOS 报告分享:用 UIActivityViewController 分享 PNG。
//  面板里内置自定义"保存到相册"活动(不依赖系统"存储图像",
//  该选项在不同系统/模拟器上时有时无)。
//

import SwiftUI
import Photos
import UIKit

/// 自定义分享活动:保存图片到系统相册。
/// 出现在分享面板的第二排动作里,图标+文字与系统动作同规格。
final class SaveToPhotosActivity: UIActivity {

    private var image: UIImage?

    override var activityType: UIActivity.ActivityType? {
        UIActivity.ActivityType("com.dinghao.soundsense.saveToPhotos")
    }

    override var activityTitle: String? { "保存到相册" }

    override var activityImage: UIImage? {
        UIImage(systemName: "photo.on.rectangle.angled")
    }

    override class var activityCategory: UIActivity.Category { .action }

    override func canPerform(withActivityItems activityItems: [Any]) -> Bool {
        activityItems.contains { $0 is UIImage }
    }

    override func prepare(withActivityItems activityItems: [Any]) {
        image = activityItems.first(where: { $0 is UIImage }) as? UIImage
    }

    override func perform() {
        let img = image
        Task { @MainActor in
            guard let img = img else {
                activityDidFinish(false)
                return
            }
            let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
            guard status == .authorized || status == .limited else {
                NotificationCenter.default.post(
                    name: .init("reportSaveToPhotosResult"), object: nil,
                    userInfo: ["message": "相册权限被拒绝,请到系统设置 → 闻声 开启"])
                activityDidFinish(false)
                return
            }
            let ok: Bool = await withCheckedContinuation { continuation in
                PHPhotoLibrary.shared().performChanges {
                    PHAssetChangeRequest.creationRequestForAsset(from: img)
                } completionHandler: { success, _ in
                    continuation.resume(returning: success)
                }
            }
            NotificationCenter.default.post(
                name: .init("reportSaveToPhotosResult"), object: nil,
                userInfo: ["message": ok ? "已保存到相册" : "保存失败,请重试"])
            activityDidFinish(ok)
        }
    }
}

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

        // 只分享 UIImage;applicationActivities 注入自定义"保存到相册"
        let controller = UIActivityViewController(
            activityItems: [image],
            applicationActivities: [SaveToPhotosActivity()])
        controller.excludedActivityTypes = [.assignToContact, .addToReadingList]
        return controller
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
