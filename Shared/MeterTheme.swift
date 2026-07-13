//
//  MeterTheme.swift
//  SoundSense
//
//  跨平台共享的视觉常量:颜色、渐变、字号。
//  保持与 AppIcon 一致的深蓝→紫底 + 青色声波风格。
//

import SwiftUI

/// 闻声共享视觉主题
public enum MeterTheme {

    // MARK: - 背景渐变(与 AppIcon 一致:深蓝 → 紫)
    public static let backgroundGradient = LinearGradient(
        colors: [
            Color(red: 0.06, green: 0.08, blue: 0.22),   // 深蓝
            Color(red: 0.22, green: 0.10, blue: 0.40),   // 紫
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    // MARK: - 声波 / 强调色
    /// 青色声波(与 AppIcon 内圈一致)
    public static let waveColor = Color(red: 0.30, green: 0.85, blue: 0.95)
    /// 中心高亮
    public static let glowColor = Color(red: 0.55, green: 0.95, blue: 1.0)

    // MARK: - 卡片 / 控件
    public static let cardBackground = Color.white.opacity(0.06)
    public static let cardBorder = Color.white.opacity(0.12)
    public static let primaryText = Color.white
    public static let secondaryText = Color.white.opacity(0.65)
}
