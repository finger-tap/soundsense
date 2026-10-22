//
//  MeterTheme.swift
//  SoundSense
//
//  跨平台共享的视觉常量：颜色、渐变、字号。
//  设计语言：精密声级计仪器面板 —— 深色为石墨仪器底，浅色为雾面纸白；
//  青瓷绿信号色、发丝线描边与低饱和语义色在三端保持一致。
//

import SwiftUI
#if canImport(AppKit)
import AppKit
#elseif os(iOS)
import UIKit
#endif

/// 闻声共享视觉主题
public enum MeterTheme {

    // MARK: - 动态颜色

    private static func adaptive(
        light: (red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat),
        dark: (red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat)
    ) -> Color {
        #if canImport(AppKit)
        return Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let value = isDark ? dark : light
            return NSColor(srgbRed: value.red, green: value.green,
                           blue: value.blue, alpha: value.alpha)
        })
        #elseif os(iOS)
        return Color(uiColor: UIColor { traits in
            let value = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: value.red, green: value.green,
                           blue: value.blue, alpha: value.alpha)
        })
        #elseif os(watchOS)
        // watchOS 的 UIColor 不提供 dynamicProvider。SwiftUI 的 primary /
        // secondary 样式会随表盘明暗自动解析，因此直接映射语义前景色。
        let darkIsRequested = dark.red + dark.green + dark.blue
            < light.red + light.green + light.blue
        return darkIsRequested ? Color.secondary : Color.primary
        #else
        let value = light
        return Color(red: Double(value.red), green: Double(value.green),
                     blue: Double(value.blue), opacity: Double(value.alpha))
        #endif
    }

    // MARK: - 背景（带极轻的斜向明度过渡）

    /// 与旧名兼容：全局背景渐变
    public static let backgroundGradient = LinearGradient(
        colors: [
            adaptive(light: (0.965, 0.973, 0.971, 1),
                     dark: (0.043, 0.064, 0.071, 1)),
            adaptive(light: (0.925, 0.945, 0.941, 1),
                     dark: (0.028, 0.045, 0.052, 1)),
            adaptive(light: (0.900, 0.925, 0.920, 1),
                     dark: (0.021, 0.034, 0.040, 1)),
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    // MARK: - 面板 / 控件

    /// 卡片面板色（深色蓝黑石墨 / 浅色雾白）
    public static let panel = adaptive(
        light: (0.985, 0.990, 0.987, 1),
        dark: (0.067, 0.093, 0.101, 1)
    )

    /// 抬升面板：用于需要与背景拉开层级的交互卡片
    public static let elevatedPanel = adaptive(
        light: (1.0, 1.0, 1.0, 1),
        dark: (0.090, 0.121, 0.128, 1)
    )

    /// 面板的柔和斜向渐变，避免大面积纯色卡片显得扁平
    public static let panelGradient = LinearGradient(
        colors: [elevatedPanel, panel],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    /// 发丝线描边
    public static let hairline = adaptive(
        light: (0.16, 0.28, 0.28, 0.15),
        dark: (0.68, 0.79, 0.79, 0.12)
    )

    /// 与旧名兼容
    public static var cardBackground: Color { panel }
    public static var cardBorder: Color { hairline }

    // MARK: - 强调色

    /// 青瓷绿：比荧光青更沉静，与 AppIcon 保持呼应
    public static let waveColor = adaptive(
        light: (0.08, 0.47, 0.40, 1),
        dark: (0.43, 0.78, 0.70, 1)
    )

    /// 主操作按钮的轻量渐变
    public static let primaryActionGradient = LinearGradient(
        colors: [
            adaptive(light: (0.13, 0.58, 0.50, 1),
                     dark: (0.48, 0.82, 0.74, 1)),
            adaptive(light: (0.04, 0.40, 0.34, 1),
                     dark: (0.28, 0.61, 0.56, 1)),
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    /// 停止操作的柔和风险渐变
    public static let dangerActionGradient = LinearGradient(
        colors: [
            Color(red: 0.82, green: 0.39, blue: 0.35),
            Color(red: 0.64, green: 0.25, blue: 0.24),
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    /// 黄铜色：用于“注意”级别的信息，不使用高饱和黄
    public static let brass = adaptive(
        light: (0.49, 0.35, 0.08, 1),
        dark: (0.80, 0.67, 0.39, 1)
    )

    // MARK: - 文字

    /// 主文字，深色为暖白，浅色为深墨绿
    public static let primaryText = adaptive(
        light: (0.09, 0.15, 0.15, 1),
        dark: (0.95, 0.94, 0.91, 1)
    )

    /// 次要信息
    public static let secondaryText = adaptive(
        light: (0.28, 0.38, 0.38, 1),
        dark: (0.68, 0.74, 0.74, 1)
    )

    /// 辅助说明/占位文案
    public static let tertiaryText = adaptive(
        light: (0.42, 0.50, 0.50, 1),
        dark: (0.48, 0.55, 0.56, 1)
    )

    /// 风险提示色
    public static let riskColor = adaptive(
        light: (0.70, 0.16, 0.13, 1),
        dark: (0.90, 0.47, 0.41, 1)
    )

    /// 卡片/控件表面的低强度填充。深色下叠白，浅色下叠黑。
    public static let surfaceFill = adaptive(
        light: (0.0, 0.0, 0.0, 0.035),
        dark: (1.0, 1.0, 1.0, 0.04)
    )

    public static let surfaceStrongFill = adaptive(
        light: (0.0, 0.0, 0.0, 0.07),
        dark: (1.0, 1.0, 1.0, 0.08)
    )

    public static let controlFill = adaptive(
        light: (0.0, 0.0, 0.0, 0.055),
        dark: (1.0, 1.0, 1.0, 0.06)
    )

    public static let overlayScrim = adaptive(
        light: (0.0, 0.0, 0.0, 0.26),
        dark: (0.0, 0.0, 0.0, 0.52)
    )

    // MARK: - 字体（仪器面板语汇）

    /// 等宽数据字体（刻度、读数标签）
    public static func mono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }

    /// 分区小标签（全大写、加字距）
    public static func sectionLabel(_ size: CGFloat = 10) -> Font {
        .system(size: size, weight: .semibold, design: .monospaced)
    }
}
