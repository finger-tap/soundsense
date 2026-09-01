//
//  ReportExporter.swift
//  SoundSenseMac
//
//  macOS 报告导出:NSSavePanel 保存 PNG / 含录音的 HTML 单文件。
//

import AppKit
import UniformTypeIdentifiers

enum ReportExporter {
    /// 弹出保存面板,把报告保存为 PNG。
    static func export(stats: MeasurementStats,
                        deviceName: String,
                        calibrationOffset: Float) {
        let image = ReportRenderer.render(stats: stats,
                                           deviceName: deviceName,
                                           calibrationOffset: calibrationOffset)
        guard let png = pngData(from: image) else { return }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = defaultFilename(stats: stats)
        panel.title = "导出测量报告"

        if panel.runModal() == .OK, let url = panel.url {
            do {
                try png.write(to: url)
            } catch {
                let alert = NSAlert()
                alert.messageText = "导出失败"
                alert.informativeText = error.localizedDescription
                alert.runModal()
            }
        }
    }

    /// 导出 HTML 单文件报告(报告图 + 录音 base64 内嵌,浏览器可直接播放)
    static func exportHTML(stats: MeasurementStats,
                           deviceName: String,
                           calibrationOffset: Float,
                           audioURL: URL?) {
        let image = ReportRenderer.render(stats: stats,
                                          deviceName: deviceName,
                                          calibrationOffset: calibrationOffset)
        let pngBase64 = (pngData(from: image) ?? Data()).base64EncodedString()
        let audioBase64 = audioURL.flatMap { try? Data(contentsOf: $0) }?.base64EncodedString()
        let html = ReportHTMLBuilder.build(stats: stats, deviceName: deviceName,
                                           calibrationOffset: calibrationOffset,
                                           pngBase64: pngBase64, audioBase64: audioBase64)
        guard let data = html.data(using: .utf8) else { return }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.html]
        panel.nameFieldStringValue = ReportHTMLBuilder.filename(for: stats)
        panel.title = "导出完整报告"

        if panel.runModal() == .OK, let url = panel.url {
            do {
                try data.write(to: url)
            } catch {
                let alert = NSAlert()
                alert.messageText = "导出失败"
                alert.informativeText = error.localizedDescription
                alert.runModal()
            }
        }
    }

    /// NSImage → PNG 数据
    static func pngData(from image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    /// 默认文件名:闻声报告_2026-07-14_143020.png
    private static func defaultFilename(stats: MeasurementStats) -> String {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd_HHmm"
        return "闻声报告_\(df.string(from: stats.startTime)).png"
    }
}
