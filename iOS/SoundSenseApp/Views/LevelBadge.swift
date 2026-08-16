//
//  LevelBadge.swift
//  SoundSense iOS
//
//  噪音等级提示徽章。
//

import SwiftUI

struct LevelBadge: View {
    let level: NoiseLevel?

    var body: some View {
        if let level = level {
            HStack(spacing: 7) {
                Text(level.emoji)
                    .font(.system(size: 16))
                VStack(alignment: .leading, spacing: 1) {
                    Text(level.label)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(.white)
                    Text(level.detail)
                        .font(.system(size: 11))
                        .foregroundColor(MeterTheme.secondaryText)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(
                Capsule().fill(level.color.opacity(0.18))
            )
            .overlay(
                Capsule().stroke(level.color.opacity(0.5), lineWidth: 1)
            )
        } else {
            HStack(spacing: 7) {
                Text("🔇")
                    .font(.system(size: 16))
                Text("等待声音...")
                    .font(.system(size: 14))
                    .foregroundColor(MeterTheme.secondaryText)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(Capsule().fill(MeterTheme.cardBackground))
        }
    }
}
