//
//  ImageCanvas.swift
//  SoundSense
//
//  对 CGContext 的封装,用于 ReportRenderer 跨平台绘制图片。
//  兼容 iOS 15 / macOS 12。纯 Core Graphics + Core Text 绘制(不依赖 NSString.draw)。
//

#if os(iOS) || os(macOS)

import Foundation
import CoreGraphics
import CoreText
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// 绘制画布。所有绘制用 Core Graphics + Core Text,跨平台一致。
/// makeImage() 时创建 CGContext 执行所有绘制。
final class ImageCanvas {
    let size: CGSize
    private let cgContext: CGContext

    init(size: CGSize) {
        self.size = size
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil,
            width: Int(size.width),
            height: Int(size.height),
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: cs,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            fatalError("无法创建 CGContext")
        }
        self.cgContext = ctx
    }

    /// Y 轴翻转:CGContext 原点在左下角,调用方用左上角坐标系。
    private func fy(_ y: CGFloat) -> CGFloat { size.height - y }

    // MARK: - 基本图形

    func fill(_ rect: CGRect, color: CGColor) {
        cgContext.setFillColor(color)
        // 全屏填充不需要翻转(rect.y=0 时一致)
        cgContext.fill(rect)
    }

    func fillRound(_ rect: CGRect, color: CGColor, radius: CGFloat) {
        cgContext.setFillColor(color)
        let flipped = CGRect(x: rect.minX, y: fy(rect.minY) - rect.height,
                              width: rect.width, height: rect.height)
        let path = CGPath(roundedRect: flipped, cornerWidth: radius,
                          cornerHeight: radius, transform: nil)
        cgContext.addPath(path)
        cgContext.fillPath()
    }

    func strokeRound(_ rect: CGRect, color: CGColor, width: CGFloat, radius: CGFloat) {
        cgContext.setStrokeColor(color)
        cgContext.setLineWidth(width)
        let flipped = CGRect(x: rect.minX, y: fy(rect.minY) - rect.height,
                              width: rect.width, height: rect.height)
        let path = CGPath(roundedRect: flipped, cornerWidth: radius,
                          cornerHeight: radius, transform: nil)
        cgContext.addPath(path)
        cgContext.strokePath()
    }

    func line(from: CGPoint, to: CGPoint, color: CGColor, width: CGFloat) {
        cgContext.setStrokeColor(color)
        cgContext.setLineWidth(width)
        cgContext.move(to: CGPoint(x: from.x, y: fy(from.y)))
        cgContext.addLine(to: CGPoint(x: to.x, y: fy(to.y)))
        cgContext.strokePath()
    }

    func dashedLine(from: CGPoint, to: CGPoint, color: CGColor, width: CGFloat) {
        cgContext.setStrokeColor(color)
        cgContext.setLineWidth(width)
        cgContext.setLineDash(phase: 0, lengths: [3, 5])
        cgContext.move(to: CGPoint(x: from.x, y: fy(from.y)))
        cgContext.addLine(to: CGPoint(x: to.x, y: fy(to.y)))
        cgContext.strokePath()
        cgContext.setLineDash(phase: 0, lengths: [])
    }

    func polyline(_ points: [CGPoint], color: CGColor, width: CGFloat) {
        guard points.count >= 2 else { return }
        cgContext.setStrokeColor(color)
        cgContext.setLineWidth(width)
        cgContext.setLineCap(.round)
        cgContext.setLineJoin(.round)
        cgContext.move(to: CGPoint(x: points[0].x, y: fy(points[0].y)))
        for p in points.dropFirst() {
            cgContext.addLine(to: CGPoint(x: p.x, y: fy(p.y)))
        }
        cgContext.strokePath()
    }

    func fillPolygon(_ points: [CGPoint], color: CGColor) {
        guard points.count >= 3 else { return }
        cgContext.setFillColor(color)
        cgContext.move(to: CGPoint(x: points[0].x, y: fy(points[0].y)))
        for p in points.dropFirst() {
            cgContext.addLine(to: CGPoint(x: p.x, y: fy(p.y)))
        }
        cgContext.closePath()
        cgContext.fillPath()
    }

    // MARK: - 文字(Core Text,跨平台一致)

    #if os(iOS)
    func text(_ string: String, at point: CGPoint, font: UIFont, color: CGColor) {
        drawText(string, at: point, fontName: font.fontName, size: font.pointSize,
                 color: color)
    }
    #elseif os(macOS)
    func text(_ string: String, at point: CGPoint, font: NSFont, color: CGColor) {
        drawText(string, at: point, fontName: font.fontName, size: font.pointSize,
                 color: color)
    }
    #endif

    private func drawText(_ string: String, at point: CGPoint,
                           fontName: String, size: CGFloat, color: CGColor) {
        let ctFont = CTFontCreateWithName(fontName as CFString, size, nil)
        let attr: [CFString: Any] = [
            kCTFontAttributeName: ctFont,
            kCTForegroundColorAttributeName: color,
        ]
        let attrString = CFAttributedStringCreate(
            nil, string as CFString, attr as CFDictionary
        )
        guard let attrString = attrString else { return }
        let line = CTLineCreateWithAttributedString(attrString)

        // CTLine 用 textPosition 作为基线左端起点。CGContext 原点在左下,
        // 翻转 point.y 后就是 CG 坐标里的基线 y。
        cgContext.textPosition = CGPoint(x: point.x, y: fy(point.y))
        CTLineDraw(line, cgContext)
    }

    // MARK: - 输出图片

    func makeImage() -> PlatformImage {
        guard let cgImage = cgContext.makeImage() else {
            #if os(iOS)
            return UIImage()
            #else
            return NSImage()
            #endif
        }
        #if os(iOS)
        return UIImage(cgImage: cgImage)
        #else
        return NSImage(cgImage: cgImage, size: size)
        #endif
    }
}

#endif
