//
//  MeterTheme.swift
//  SoundSense
//
//  跨平台共享的视觉常量:颜色、渐变、字号。
//  设计语言:精密声级计仪器面板 —— 扁平石墨底、发丝线描边、
//  等宽刻度字体、按听力风险分级的语义色。
//

import SwiftUI

/// 闻声共享视觉主题
public enum MeterTheme {

    // MARK: - 背景(深石墨,微冷调;告别蓝紫渐变的模板感)
    /// 与旧名兼容:全局背景"渐变"(现在是极轻的上下明度过渡)
    public static let backgroundGradient = LinearGradient(
        colors: [
            Color(red: 0.050, green: 0.071, blue: 0.088),
            Color(red: 0.038, green: 0.056, blue: 0.070),
        ],
        startPoint: .top,
        endPoint: .bottom
    )

    // MARK: - 面板 / 控件
    /// 卡片面板色(石墨)
    public static let panel = Color(red: 0.075, green: 0.102, blue: 0.125)
    /// 发丝线描边
    public static let hairline = Color.white.opacity(0.08)
    /// 与旧名兼容
    public static let cardBackground = panel
    public static let cardBorder = hairline

    // MARK: - 强调色
    /// 信号青(安静档的主色,与 AppIcon 呼应)
    public static let waveColor = Color(red: 0.24, green: 0.85, blue: 0.75)

    // MARK: - 文字
    public static let primaryText = Color.white
    public static let secondaryText = Color.white.opacity(0.60)

    // MARK: - 字体(仪器面板语汇)
    /// 等宽数据字体(刻度、读数标签)
    public static func mono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
    /// 分区小标签(全大写、加字距)
    public static func sectionLabel(_ size: CGFloat = 10) -> Font {
        .system(size: size, weight: .semibold, design: .monospaced)
    }
}
