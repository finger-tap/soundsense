//
//  MeterTheme.swift
//  SoundSense
//
//  跨平台共享的视觉常量:颜色、渐变、字号。
//  设计语言:精密声级计仪器面板 —— 蓝黑石墨底、暖灰文字、
//  青瓷绿信号色、发丝线描边与低饱和语义色。
//

import SwiftUI

/// 闻声共享视觉主题
public enum MeterTheme {

    // MARK: - 背景(近黑蓝,带极轻的斜向明度过渡)
    /// 与旧名兼容:全局背景渐变
    public static let backgroundGradient = LinearGradient(
        colors: [
            Color(red: 0.043, green: 0.064, blue: 0.071),
            Color(red: 0.028, green: 0.045, blue: 0.052),
            Color(red: 0.021, green: 0.034, blue: 0.040),
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    // MARK: - 面板 / 控件
    /// 卡片面板色(蓝黑石墨)
    public static let panel = Color(red: 0.067, green: 0.093, blue: 0.101)
    /// 抬升面板:用于需要与背景拉开层级的交互卡片
    public static let elevatedPanel = Color(red: 0.090, green: 0.121, blue: 0.128)
    /// 面板的柔和斜向渐变,避免大面积纯色卡片显得扁平
    public static let panelGradient = LinearGradient(
        colors: [elevatedPanel, panel],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
    /// 发丝线描边
    public static let hairline = Color(red: 0.68, green: 0.79, blue: 0.79).opacity(0.12)
    /// 与旧名兼容
    public static let cardBackground = panel
    public static let cardBorder = hairline

    // MARK: - 强调色
    /// 青瓷绿:比荧光青更沉静,与 AppIcon 保持呼应
    public static let waveColor = Color(red: 0.43, green: 0.78, blue: 0.70)
    /// 主操作按钮的轻量渐变
    public static let primaryActionGradient = LinearGradient(
        colors: [
            Color(red: 0.48, green: 0.82, blue: 0.74),
            Color(red: 0.28, green: 0.61, blue: 0.56),
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
    /// 黄铜色:用于“注意”级别的信息,不使用高饱和黄
    public static let brass = Color(red: 0.80, green: 0.67, blue: 0.39)

    // MARK: - 文字
    /// 暖白,比纯白更适合深色仪器界面
    public static let primaryText = Color(red: 0.95, green: 0.94, blue: 0.91)
    /// 次要信息在深色背景上保持足够对比度
    public static let secondaryText = Color(red: 0.68, green: 0.74, blue: 0.74)
    /// 辅助说明/占位文案
    public static let tertiaryText = Color(red: 0.48, green: 0.55, blue: 0.56)
    /// 风险提示色
    public static let riskColor = Color(red: 0.90, green: 0.47, blue: 0.41)

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
