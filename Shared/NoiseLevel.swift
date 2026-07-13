//
//  NoiseLevel.swift
//  SoundSense
//
//  分贝值 → 等级 / 颜色 / 文案 的纯函数映射,iOS 与 watchOS 共用。
//
//  阈值参考常见环境声压级(SPL,A 计权):
//    30 dB  极安静(图书馆、卧室)
//    40 dB  安静(安静办公室、起居室)
//    50 dB  一般(普通办公室、客厅交谈)
//    60 dB  偏吵(正常交谈、餐馆)
//    70 dB  较吵(嘈杂办公室、街道)
//    85 dB  很吵(主干道、地铁)-- 长时间暴露开始有害
//   100 dB  非常吵(演唱会、电钻)
//

import SwiftUI

/// 噪声等级
public struct NoiseLevel: Equatable {
    public enum Tier: String {
        case quiet      // 安静
        case normal     // 正常
        case moderate   // 偏吵
        case loud       // 较吵
        case veryLoud   // 很吵
        case harmful    // 有害
    }

    public let tier: Tier
    /// 简短文案(如"较吵")
    public let label: String
    /// 详细描述(如"嘈杂办公室、街道")
    public let detail: String
    /// emoji
    public let emoji: String
    /// 主色
    public let color: Color

    /// 把 SPL(A 计权,dB)映射到等级。
    /// 若 spl 为 -∞ 或异常极小值(静音),返回 nil,由调用方自行处理显示。
    public static func level(for spl: Float) -> NoiseLevel? {
        // 算法在静音时 splA 可能返回 -∞ 或极负值
        guard spl.isFinite, spl > -80 else { return nil }

        switch spl {
        case ..<35:
            return NoiseLevel(tier: .quiet,
                              label: "极安静",
                              detail: "图书馆、深夜卧室",
                              emoji: "🤫",
                              color: Color(red: 0.35, green: 0.55, blue: 1.0))
        case 35..<50:
            return NoiseLevel(tier: .normal,
                              label: "安静",
                              detail: "安静办公室、起居室",
                              emoji: "😌",
                              color: Color(red: 0.30, green: 0.85, blue: 0.95))
        case 50..<65:
            return NoiseLevel(tier: .moderate,
                              label: "正常",
                              detail: "普通交谈、办公室",
                              emoji: "🙂",
                              color: Color(red: 0.50, green: 0.90, blue: 0.50))
        case 65..<75:
            return NoiseLevel(tier: .loud,
                              label: "偏吵",
                              detail: "嘈杂街道、餐馆",
                              emoji: "😐",
                              color: Color(red: 1.0, green: 0.85, blue: 0.30))
        case 75..<90:
            return NoiseLevel(tier: .veryLoud,
                              label: "较吵",
                              detail: "主干道、地铁",
                              emoji: "😷",
                              color: Color(red: 1.0, green: 0.60, blue: 0.20))
        case 90..<105:
            return NoiseLevel(tier: .veryLoud,
                              label: "很吵",
                              detail: "演唱会、电钻",
                              emoji: "⚠️",
                              color: Color(red: 1.0, green: 0.40, blue: 0.25))
        default:
            return NoiseLevel(tier: .harmful,
                              label: "有害",
                              detail: "长时间暴露会损伤听力",
                              emoji: "🚨",
                              color: Color(red: 1.0, green: 0.20, blue: 0.25))
        }
    }
}
