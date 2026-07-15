//
//  ReportExporter.swift
//  SoundSenseMac
//
//  macOS 报告导出:用 NSSavePanel 让用户选位置,保存 PNG。
//

import AppKit

enum ReportExporter {
    /// 弹出保存面板,把报告保存为 PNG。
    static func export(stats: MeasurementStats,
                        deviceName: String,
                        calibrationOffset: Float) {
        let image = ReportRenderer.render(stats: stats,
                                           deviceName: deviceName,
                                           calibrationOffset: calibrationOffset)

        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            return
        }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = defaultFilename(stats: stats)

        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd HH:mm"
        panel.title = "导出测量报告"

        if panel.runModal() == .OK {
            if let url = panel.url {
                try? png.write(to: url)
            }
        }
    }

    /// 默认文件名:闻声报告_2026-07-14_143020.png
    private static func defaultFilename(stats: MeasurementStats) -> String {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd_HHmm"
        return "闻声报告_\(df.string(from: stats.startTime)).png"
    }
}
