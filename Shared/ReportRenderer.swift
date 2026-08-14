//
//  ReportRenderer.swift
//  SoundSense
//
//  用 Core Graphics 绘制测量报告图片。
//  跨平台(iOS UIImage / macOS NSImage),兼容 iOS 15 / macOS 12(不用 ImageRenderer)。
//
//  设计语言:精密声级计报告单 —— 石墨底、发丝线、
//  巨型 LAeq 读数 + dB 标尺(与 App 内同款签名元素)、
//  去卡片化的统计条、带 LAeq 参考线的趋势图。
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

    // MARK: - 调色板(与 App 内 MeterTheme 一致)

    private static let ink = rgb(0.043, 0.063, 0.078)
    private static let teal = rgb(0.24, 0.85, 0.75)
    private static let amber = rgb(0.96, 0.72, 0.29)
    private static let coral = rgb(1.0, 0.48, 0.35)
    private static let alarm = rgb(1.0, 0.27, 0.24)
    private static let blue = rgb(0.35, 0.55, 1.0)

    /// 绘制报告图片
    public static func render(stats: MeasurementStats,
                               deviceName: String,
                               calibrationOffset: Float) -> PlatformImage {
        let size = CGSize(width: 1080, height: 1620)
        let r = ImageCanvas(size: size)

        drawBackground(r)
        drawHeader(r, stats: stats)
        drawHero(r, stats: stats)
        drawStatStrip(r, stats: stats)
        if stats.overLimitTotal >= 1 {
            drawExposureBanner(r, stats: stats)
        }
        drawTrendChart(r, stats: stats)
        drawFooter(r, stats: stats, deviceName: deviceName, offset: calibrationOffset)

        return r.makeImage()
    }

    // MARK: - 背景

    private static func drawBackground(_ r: ImageCanvas) {
        r.fill(CGRect(x: 0, y: 0, width: 1080, height: 1620), color: ink)
    }

    // MARK: - 页眉(标题左,时间右,发丝线分隔)

    private static func drawHeader(_ r: ImageCanvas, stats: MeasurementStats) {
        // 眉题
        r.text("SOUNDSENSE", at: CGPoint(x: 80, y: 76),
               font: boldFont(20), color: teal)
        r.text("噪音测量报告", at: CGPoint(x: 80, y: 140),
               font: boldFont(50), color: rgb(1, 1, 1))

        // 右侧时间块(右对齐)
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd HH:mm"
        let timeRange = "\(df.string(from: stats.startTime)) — \(df.string(from: stats.endTime))"
        drawRight(r, timeRange, rightX: 1000, y: 82,
                  font: font(22), color: rgb(1, 1, 1, 0.7))
        drawRight(r, "时长 \(formatDuration(stats.duration)) · \(stats.samples.count) 个采样点",
                  rightX: 1000, y: 118,
                  font: font(20), color: rgb(1, 1, 1, 0.4))

        r.line(from: CGPoint(x: 80, y: 190), to: CGPoint(x: 1000, y: 190),
               color: rgb(1, 1, 1, 0.12), width: 1)
    }

    // MARK: - 主读数:巨型 LAeq + dB 标尺(签名元素)

    private static func drawHero(_ r: ImageCanvas, stats: MeasurementStats) {
        // 小标签
        drawCentered(r, "等效连续声级 LAeq", atX: 540, y: 250,
                     font: font(20), color: rgb(1, 1, 1, 0.45))
        // 巨型读数
        let value = String(format: "%.1f", stats.laeqSPL)
        drawCentered(r, value, atX: 540, y: 400,
                     font: boldFont(150), color: teal)
        drawCentered(r, "dB(A)", atX: 540, y: 440,
                     font: font(22), color: rgb(1, 1, 1, 0.4))

        // dB 标尺(与 App 内 DBRulerGauge 同款)
        drawRuler(r, x0: 80, x1: 1000, baseline: 540,
                  value: stats.laeqSPL, color: teal)
    }

    /// 水平 dB 标尺:刻度 + 分区色带 + 85 风险刻度 + 指针
    private static func drawRuler(_ r: ImageCanvas, x0: CGFloat, x1: CGFloat,
                                  baseline: CGFloat, value: Float, color: CGColor) {
        let minDB: Float = 30, maxDB: Float = 120
        let toX: (Float) -> CGFloat = { db in
            x0 + CGFloat((db - minDB) / (maxDB - minDB)) * (x1 - x0)
        }

        // 分区色带
        let zones: [(Float, Float, CGColor)] = [
            (30, 50, blue), (50, 65, rgb(0.30, 0.82, 0.62)),
            (65, 75, amber), (75, 90, coral), (90, 120, alarm),
        ]
        for (from, to, zc) in zones {
            let xA = toX(max(minDB, from)), xB = toX(min(maxDB, to))
            r.fill(CGRect(x: xA, y: baseline, width: xB - xA, height: 9), color: zc)
        }

        // 刻度(每 5 dB)
        var db = minDB
        while db <= maxDB {
            let x = toX(db)
            let isMajor = Int(db) % 10 == 0
            let isRisk = abs(db - 85) < 0.01
            let tickH: CGFloat = isRisk ? 26 : (isMajor ? 16 : 8)
            let tickColor = isRisk ? alarm : rgb(1, 1, 1, isMajor ? 0.5 : 0.22)
            r.line(from: CGPoint(x: x, y: baseline - tickH),
                   to: CGPoint(x: x, y: baseline),
                   color: tickColor, width: isRisk ? 2.5 : 1.5)
            db += 5
        }

        // 基线
        r.line(from: CGPoint(x: x0, y: baseline), to: CGPoint(x: x1, y: baseline),
               color: rgb(1, 1, 1, 0.3), width: 1.5)

        // 刻度数字(每 20 dB)+ 风险刻度数字
        for labelDB in [30, 50, 70, 110] {
            drawCentered(r, "\(labelDB)", atX: toX(Float(labelDB)), y: baseline + 38,
                         font: font(17), color: rgb(1, 1, 1, 0.4))
        }
        drawCentered(r, "85", atX: toX(85), y: baseline + 38,
                     font: boldFont(17), color: alarm)

        // 指针(LAeq 位置)
        let v = max(minDB, min(maxDB, value))
        let nx = toX(v)
        r.line(from: CGPoint(x: nx, y: baseline - 46), to: CGPoint(x: nx, y: baseline),
               color: color, width: 4)
        r.fillCircle(center: CGPoint(x: nx, y: baseline - 46), radius: 7, color: color)
    }

    // MARK: - 统计条(四列,发丝线分隔,无卡片)

    private static func drawStatStrip(_ r: ImageCanvas, stats: MeasurementStats) {
        let y: CGFloat = 660
        let colW: CGFloat = (1000 - 80) / 4
        let items: [(String, String, CGColor)] = [
            (String(format: "%.1f", stats.peakSPL), "峰值 PEAK", coral),
            (String(format: "%.1f", stats.avgSPL), "平均 AVG", rgb(1, 1, 1, 0.85)),
            (String(format: "%.1f", stats.minSPL), "最低 MIN", blue),
            (String(format: "%.0f s", stats.overLimitTotal), "超 85dB 时长", amber),
        ]
        for (i, item) in items.enumerated() {
            let cx = 80 + colW * CGFloat(i) + colW / 2
            drawCentered(r, item.0, atX: cx, y: y + 52,
                         font: boldFont(42), color: item.2)
            drawCentered(r, item.1, atX: cx, y: y,
                         font: font(17), color: rgb(1, 1, 1, 0.4))
            if i > 0 {
                r.line(from: CGPoint(x: 80 + colW * CGFloat(i), y: y - 12),
                       to: CGPoint(x: 80 + colW * CGFloat(i), y: y + 62),
                       color: rgb(1, 1, 1, 0.08), width: 1)
            }
        }
    }

    // MARK: - 暴露提示条

    private static func drawExposureBanner(_ r: ImageCanvas, stats: MeasurementStats) {
        let rect = CGRect(x: 80, y: 745, width: 920, height: 56)
        r.fillRound(rect, color: rgb(1.0, 0.27, 0.24, 0.85), radius: 12)
        r.text("⚠️ " + String(format: "测量期间有 %.0f 秒超过 85 dB,长时间暴露可能损伤听力",
                              stats.overLimitTotal),
               at: CGPoint(x: 104, y: 780),
               font: font(21), color: rgb(1, 1, 1))
    }

    // MARK: - 趋势图

    private static func drawTrendChart(_ r: ImageCanvas, stats: MeasurementStats) {
        let chartTop: CGFloat = 850
        let panelRect = CGRect(x: 80, y: chartTop, width: 920, height: 560)
        r.fillRound(panelRect, color: rgb(1, 1, 1, 0.03), radius: 18)
        r.strokeRound(panelRect, color: rgb(1, 1, 1, 0.08), width: 1, radius: 18)

        r.text("SPL 趋势 · 每秒采样", at: CGPoint(x: 112, y: chartTop + 40),
               font: boldFont(20), color: rgb(1, 1, 1, 0.45))

        let plotX0: CGFloat = 130, plotX1: CGFloat = 960
        let plotY0: CGFloat = chartTop + 80, plotY1: CGFloat = chartTop + 470
        let minDB: Float = 30, maxDB: Float = 100
        let yFor: (Float) -> CGFloat = { db in
            plotY0 + (1 - CGFloat((db - minDB) / (maxDB - minDB))) * (plotY1 - plotY0)
        }

        // 网格线 + Y 轴刻度(右对齐在绘图区左侧)
        for db in [40, 60, 80] {
            let y = yFor(Float(db))
            r.dashedLine(from: CGPoint(x: plotX0, y: y), to: CGPoint(x: plotX1, y: y),
                         color: rgb(1, 1, 1, 0.07), width: 1)
            drawRight(r, "\(db)", rightX: plotX0 - 14, y: y + 7,
                      font: font(16), color: rgb(1, 1, 1, 0.3))
        }

        // LAeq 参考线
        let laeqY = yFor(max(minDB, min(maxDB, stats.laeqSPL)))
        r.dashedLine(from: CGPoint(x: plotX0, y: laeqY), to: CGPoint(x: plotX1, y: laeqY),
                     color: rgb(0.24, 0.85, 0.75, 0.5), width: 1.5)
        drawRight(r, String(format: "LAeq %.1f", stats.laeqSPL),
                  rightX: plotX1, y: laeqY - 10,
                  font: font(16), color: rgb(0.24, 0.85, 0.75, 0.9))

        let samples = stats.samples
        guard samples.count >= 2 else { return }

        // 折线点
        let maxT = samples.last!.relativeTime
        let points = samples.map { s -> CGPoint in
            let x = plotX0 + CGFloat(s.relativeTime / maxT) * (plotX1 - plotX0)
            let clamped = max(minDB, min(maxDB, s.spl))
            return CGPoint(x: x, y: yFor(clamped))
        }

        // 渐变感填充(两层透明度)
        var fill = points
        fill.append(CGPoint(x: points.last!.x, y: plotY1))
        fill.append(CGPoint(x: points.first!.x, y: plotY1))
        r.fillPolygon(fill, color: rgb(0.24, 0.85, 0.75, 0.10))

        r.polyline(points, color: teal, width: 2.5)

        // 峰值标记点
        if let peakIdx = samples.firstIndex(where: { $0.spl == stats.peakSPL }) {
            let p = points[peakIdx]
            r.fillCircle(center: p, radius: 5, color: coral)
            drawCentered(r, String(format: "峰值 %.1f", stats.peakSPL),
                         atX: min(max(p.x, plotX0 + 90), plotX1 - 90), y: p.y - 18,
                         font: boldFont(17), color: coral)
        }

        // X 轴时间刻度(首 / 中 / 尾)
        let tf = DateFormatter()
        tf.dateFormat = "HH:mm:ss"
        drawCentered(r, tf.string(from: stats.startTime), atX: plotX0, y: plotY1 + 34,
                     font: font(15), color: rgb(1, 1, 1, 0.3))
        drawCentered(r, tf.string(from: stats.startTime
            .addingTimeInterval(maxT / 2)), atX: (plotX0 + plotX1) / 2, y: plotY1 + 34,
            font: font(15), color: rgb(1, 1, 1, 0.3))
        drawCentered(r, tf.string(from: stats.endTime), atX: plotX1, y: plotY1 + 34,
                     font: font(15), color: rgb(1, 1, 1, 0.3))
    }

    // MARK: - 页脚

    private static func drawFooter(_ r: ImageCanvas, stats: MeasurementStats,
                                    deviceName: String, offset: Float) {
        let fy: CGFloat = 1470
        r.line(from: CGPoint(x: 80, y: fy), to: CGPoint(x: 1000, y: fy),
               color: rgb(1, 1, 1, 0.08), width: 1)

        let appVer = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "1.0"
        r.text("闻声 SoundSense v\(appVer)", at: CGPoint(x: 80, y: fy + 34),
               font: font(18), color: rgb(1, 1, 1, 0.4))
        r.text("设备:\(deviceName)  ·  校准偏移:\(String(format: "%+.1f", offset)) dB",
               at: CGPoint(x: 80, y: fy + 66),
               font: font(18), color: rgb(1, 1, 1, 0.4))

        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd HH:mm:ss"
        drawRight(r, "生成于 \(df.string(from: Date()))", rightX: 1000, y: fy + 34,
                  font: font(16), color: rgb(1, 1, 1, 0.3))
        drawRight(r, "IEC 61672-1 A 计权 · 4096 点 FFT · vDSP",
                  rightX: 1000, y: fy + 64,
                  font: font(16), color: rgb(1, 1, 1, 0.3))
    }

    // MARK: - 工具

    /// 右对齐文字(point 是文字右端 x)
    private static func drawRight(_ r: ImageCanvas, _ string: String,
                                  rightX: CGFloat, y: CGFloat,
                                  font: PlatformFont, color: CGColor) {
        r.text(string, at: CGPoint(x: rightX - r.textWidth(string, font: font), y: y),
               font: font, color: color)
    }

    /// 水平居中文字(atX 是中心 x;y 是基线)
    private static func drawCentered(_ r: ImageCanvas, _ string: String,
                                     atX: CGFloat, y: CGFloat,
                                     font: PlatformFont, color: CGColor) {
        r.text(string, at: CGPoint(x: atX - r.textWidth(string, font: font) / 2, y: y),
               font: font, color: color)
    }

    private static func formatDuration(_ seconds: TimeInterval) -> String {
        let s = Int(seconds)
        if s >= 3600 { return String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60) }
        return String(format: "%d 分 %02d 秒", s / 60, s % 60)
    }
}

// MARK: - 跨平台抽象

#if os(iOS)
public typealias PlatformImage = UIImage
public typealias PlatformFont = UIFont
#elseif os(macOS)
public typealias PlatformImage = NSImage
public typealias PlatformFont = NSFont
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
