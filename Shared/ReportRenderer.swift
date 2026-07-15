//
//  ReportRenderer.swift
//  SoundSense
//
//  用 Core Graphics 绘制测量报告为图片。
//  跨平台(iOS UIImage / macOS NSImage),兼容 iOS 15 / macOS 12(不用 ImageRenderer)。
//

#if os(iOS) || os(macOS)

import Foundation
import CoreGraphics
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

public enum ReportRenderer {

    /// 绘制报告图片
    /// - Parameters:
    ///   - stats: 测量统计
    ///   - deviceName: 设备名(如 "MacBook Pro" / "iPhone 15")
    ///   - calibrationOffset: 校准偏移量
    /// - Returns: 平台对应图片类型(UIImage / NSImage)
    public static func render(stats: MeasurementStats,
                               deviceName: String,
                               calibrationOffset: Float) -> PlatformImage {
        let size = CGSize(width: 1080, height: 1620)
        let renderer = ImageCanvas(size: size)

        drawBackground(renderer)
        drawTitle(renderer)
        drawSummary(renderer, stats: stats)
        drawTrendChart(renderer, stats: stats)
        drawFooter(renderer, stats: stats, deviceName: deviceName, offset: calibrationOffset)

        return renderer.makeImage()
    }

    // MARK: - 绘制各部分

    private static func drawBackground(_ r: ImageCanvas) {
        r.fill(CGRect(x: 0, y: 0, width: 1080, height: 1620),
               color: rgb(0.06, 0.07, 0.09))
    }

    private static func drawTitle(_ r: ImageCanvas) {
        r.text("闻声 SoundSense",
               at: CGPoint(x: 80, y: 110),
               font: boldFont(48), color: rgb(1, 1, 1))
        r.text("噪音测量报告",
               at: CGPoint(x: 80, y: 170),
               font: font(26), color: rgb(0.6, 0.85, 0.75))
        // 分隔线
        r.line(from: CGPoint(x: 80, y: 215),
               to: CGPoint(x: 1000, y: 215),
               color: rgb(1, 1, 1, 0.1), width: 1)
    }

    private static func drawSummary(_ r: ImageCanvas, stats: MeasurementStats) {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd HH:mm"

        // 摘要区标题
        r.text("测量摘要", at: CGPoint(x: 80, y: 270),
               font: boldFont(24), color: rgb(1, 1, 1, 0.5))

        // 时间信息
        let timeRange = "\(df.string(from: stats.startTime)) — \(df.string(from: stats.endTime))"
        r.text(timeRange, at: CGPoint(x: 80, y: 310),
               font: font(20), color: rgb(1, 1, 1, 0.7))
        r.text("时长 \(formatDuration(stats.duration))",
               at: CGPoint(x: 80, y: 345),
               font: font(18), color: rgb(1, 1, 1, 0.5))

        // 三个数值卡片:平均 / 峰值 / 最低
        let cardY: CGFloat = 400
        let cardH: CGFloat = 160
        let cardW: CGFloat = 280
        let gap: CGFloat = 30
        let startX: CGFloat = 80

        drawStatCard(r, x: startX, y: cardY, w: cardW, h: cardH,
                     label: "平均", value: stats.avgSPL, color: rgb(0.24, 0.83, 0.69))
        drawStatCard(r, x: startX + cardW + gap, y: cardY, w: cardW, h: cardH,
                     label: "峰值", value: stats.peakSPL, color: rgb(1.0, 0.6, 0.2))
        drawStatCard(r, x: startX + (cardW + gap) * 2, y: cardY, w: cardW, h: cardH,
                     label: "最低", value: stats.minSPL, color: rgb(0.4, 0.6, 1.0))
    }

    private static func drawStatCard(_ r: ImageCanvas, x: CGFloat, y: CGFloat,
                                      w: CGFloat, h: CGFloat,
                                      label: String, value: Float, color: CGColor) {
        // 卡片背景
        let roundRect = CGRect(x: x, y: y, width: w, height: h)
        r.fillRound(roundRect, color: rgb(1, 1, 1, 0.05), radius: 16)
        r.strokeRound(roundRect, color: rgb(1, 1, 1, 0.08), width: 1, radius: 16)
        // 标签
        r.text(label, at: CGPoint(x: x + 24, y: y + 28),
               font: font(18), color: rgb(1, 1, 1, 0.5))
        // 数值
        let valueStr = String(format: "%.1f", value)
        r.text(valueStr, at: CGPoint(x: x + 24, y: y + 64),
               font: boldFont(54), color: color)
        // 单位
        r.text("dB(A)", at: CGPoint(x: x + 24, y: y + 130),
               font: font(16), color: rgb(1, 1, 1, 0.4))
    }

    private static func drawTrendChart(_ r: ImageCanvas, stats: MeasurementStats) {
        let chartX: CGFloat = 80
        let chartY: CGFloat = 630
        let chartW: CGFloat = 920
        let chartH: CGFloat = 580

        // 标题
        r.text("SPL 趋势曲线", at: CGPoint(x: chartX, y: chartY - 10),
               font: boldFont(24), color: rgb(1, 1, 1, 0.5))

        // 图表背景
        let bgRect = CGRect(x: chartX, y: chartY, width: chartW, height: chartH)
        r.fillRound(bgRect, color: rgb(1, 1, 1, 0.03), radius: 16)

        let samples = stats.samples
        let minDB: CGFloat = 30
        let maxDB: CGFloat = 100
        let padTop: CGFloat = 30
        let padBottom: CGFloat = 50
        let drawH = chartH - padTop - padBottom

        // Y 轴参考线(40/60/80 dB)
        for db in [40, 60, 80] {
            let y = chartY + padTop + (1 - (CGFloat(db) - minDB) / (maxDB - minDB)) * drawH
            r.dashedLine(from: CGPoint(x: chartX + 20, y: y),
                         to: CGPoint(x: chartX + chartW - 20, y: y),
                         color: rgb(1, 1, 1, 0.06), width: 1)
            r.text("\(db)", at: CGPoint(x: chartX + chartW - 50, y: y - 8),
                   font: font(13), color: rgb(1, 1, 1, 0.3))
        }

        guard samples.count >= 2 else { return }

        // 计算折线点
        let maxT = samples.last!.relativeTime
        let points = samples.map { s -> CGPoint in
            let x = chartX + 20 + CGFloat(s.relativeTime / maxT) * (chartW - 40)
            let clamped = max(minDB, min(maxDB, CGFloat(s.spl)))
            let y = chartY + padTop + (1 - (clamped - minDB) / (maxDB - minDB)) * drawH
            return CGPoint(x: x, y: y)
        }

        // 渐变填充
        var fillPath = points
        fillPath.append(CGPoint(x: points.last!.x, y: chartY + chartH - padBottom))
        fillPath.append(CGPoint(x: points.first!.x, y: chartY + chartH - padBottom))
        r.fillPolygon(fillPath, color: rgb(0.24, 0.83, 0.69, 0.2))

        // 折线
        r.polyline(points, color: rgb(0.24, 0.83, 0.69), width: 2.5)
    }

    private static func drawFooter(_ r: ImageCanvas, stats: MeasurementStats,
                                    deviceName: String, offset: Float) {
        let fy: CGFloat = 1440
        r.line(from: CGPoint(x: 80, y: fy),
               to: CGPoint(x: 1000, y: fy),
               color: rgb(1, 1, 1, 0.08), width: 1)

        let appVer = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "1.0"
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd HH:mm:ss"

        r.text("闻声 SoundSense v\(appVer)",
               at: CGPoint(x: 80, y: fy + 25),
               font: font(15), color: rgb(1, 1, 1, 0.4))
        r.text("设备:\(deviceName)  ·  校准偏移:\(String(format: "%+.1f", offset)) dB",
               at: CGPoint(x: 80, y: fy + 52),
               font: font(15), color: rgb(1, 1, 1, 0.4))
        r.text("生成于 \(df.string(from: Date()))",
               at: CGPoint(x: 80, y: fy + 79),
               font: font(13), color: rgb(1, 1, 1, 0.3))
    }

    // MARK: - 工具

    private static func formatDuration(_ seconds: TimeInterval) -> String {
        let m = Int(seconds) / 60
        let s = Int(seconds) % 60
        if m > 0 { return "\(m) 分 \(s) 秒" }
        return "\(s) 秒"
    }
}

// MARK: - 跨平台抽象

#if os(iOS)
public typealias PlatformImage = UIImage
#elseif os(macOS)
public typealias PlatformImage = NSImage
#endif

/// CGColor 工厂
private func rgb(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1.0) -> CGColor {
    CGColor(red: r, green: g, blue: b, alpha: a)
}

#if os(iOS)
private func boldFont(_ size: CGFloat) -> UIFont { UIFont.boldSystemFont(ofSize: size) }
private func font(_ size: CGFloat) -> UIFont { UIFont.systemFont(ofSize: size) }
#elseif os(macOS)
private func boldFont(_ size: CGFloat) -> NSFont { NSFont.boldSystemFont(ofSize: size) }
private func font(_ size: CGFloat) -> NSFont { NSFont.systemFont(ofSize: size) }
#endif

#endif // os(iOS) || os(macOS)
