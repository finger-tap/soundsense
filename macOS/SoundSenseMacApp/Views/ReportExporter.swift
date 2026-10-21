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

    /// 导出声源方向倾向 HTML 报告。
    static func exportSourceHTML(result: SourceTestResult,
                                 deviceName: String,
                                 audioURL: URL?) {
        let audioBase64 = audioURL.flatMap { try? Data(contentsOf: $0) }?
            .base64EncodedString()
        let html = SourceTestHTMLBuilder.build(result: result,
                                               deviceName: deviceName,
                                               audioBase64: audioBase64)
        saveHTML(html,
                 filename: SourceTestHTMLBuilder.filename(for: result),
                 title: "导出声源方向倾向报告")
    }

    /// 导出监听 HTML 报告。片段按最长 3 段内嵌，避免文件无限膨胀。
    static func exportMonitorHTML(session: MonitorSession,
                                  store: MonitorSessionStore) {
        let html = MonitorHTMLBuilder.build(session: session) { clipFile in
            store.clipURL(sessionID: session.id, clipFile: clipFile)
        }
        saveHTML(html,
                 filename: MonitorHTMLBuilder.filename(for: session),
                 title: "导出监听报告")
    }

    private static func saveHTML(_ html: String,
                                 filename: String,
                                 title: String) {
        guard let data = html.data(using: .utf8) else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.html]
        panel.nameFieldStringValue = filename
        panel.title = title
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
