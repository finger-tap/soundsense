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
            HStack(spacing: 8) {
                Text(level.emoji)
                    .font(.title2)
                VStack(alignment: .leading, spacing: 2) {
                    Text(level.label)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundColor(.white)
                    Text(level.detail)
                        .font(.system(size: 12))
                        .foregroundColor(MeterTheme.secondaryText)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(
                Capsule().fill(level.color.opacity(0.18))
            )
            .overlay(
                Capsule().stroke(level.color.opacity(0.5), lineWidth: 1)
            )
        } else {
            HStack(spacing: 8) {
                Text("🔇")
                    .font(.title2)
                Text("等待声音...")
                    .font(.system(size: 15))
                    .foregroundColor(MeterTheme.secondaryText)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Capsule().fill(MeterTheme.cardBackground))
        }
    }
}
