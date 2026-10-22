//
//  AppAppearance.swift
//  SoundSense
//
//  用户外观偏好与菜单栏电平图的纯逻辑，供三端 UI 和测试共用。
//

import Foundation
import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

public enum AppAppearance: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .system: return "跟随系统"
        case .light: return "浅色"
        case .dark: return "深色"
        }
    }

    public var symbolName: String {
        switch self {
        case .system: return "circle.lefthalf.filled"
        case .light: return "sun.max.fill"
        case .dark: return "moon.fill"
        }
    }

    #if canImport(AppKit)
    /// `nil` 会清除强制外观，让 AppKit 重新跟随系统。
    public var nsAppearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }
    #endif
}

/// macOS 应用外观的唯一状态源，避免 SwiftUI 偏好与 AppKit 外观彼此漂移。
#if canImport(AppKit)
@MainActor
public final class MacAppearanceController: ObservableObject {
    public static let shared = MacAppearanceController()
    public static let defaultsKey = "appAppearance"
    private static let systemThemeNotification =
        Notification.Name("AppleInterfaceThemeChangedNotification")

    @Published public private(set) var appearance: AppAppearance
    private let defaults: UserDefaults
    private var systemThemeObserver: NSObjectProtocol?

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let raw = defaults.string(forKey: Self.defaultsKey) ?? ""
        appearance = AppAppearance(rawValue: raw) ?? .system
        systemThemeObserver = DistributedNotificationCenter.default().addObserver(
            forName: Self.systemThemeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.applyCurrent()
            }
        }
    }

    deinit {
        if let systemThemeObserver {
            DistributedNotificationCenter.default().removeObserver(systemThemeObserver)
        }
    }

    public func select(_ appearance: AppAppearance,
                       applyImmediately: Bool = true) {
        self.appearance = appearance
        defaults.set(appearance.rawValue, forKey: Self.defaultsKey)
        if applyImmediately {
            applyToAppKit(appearance)
        }
    }

    /// 启动时调用；system 模式必须显式清空 NSApplication 与窗口的 appearance。
    public func applyCurrent(applyImmediately: Bool = true) {
        if applyImmediately {
            applyToAppKit(appearance)
        }
    }

    private func applyToAppKit(_ appearance: AppAppearance) {
        let application = NSApplication.shared
        application.appearance = appearance.nsAppearance
        for window in NSApplication.shared.windows {
            window.appearance = appearance.nsAppearance
            // NSWindow 会缓存子树外观；显式失效能让 SwiftUI 立即重新解析
            // 动态 NSColor，避免从固定深色切回系统浅色后仍保留旧渲染。
            window.contentView?.needsDisplay = true
            window.contentView?.needsLayout = true
        }
        // AppKit 文档要求通过层级重新计算 effectiveAppearance；对空
        // appearance 赋值后显式触发布局，可清除此前的强制外观缓存。
        application.windows.forEach { window in
            window.invalidateShadow()
        }
    }
}
#endif

/// 菜单栏微型声波的纯逻辑，便于独立测试。
public enum MenuBarWaveform {
    /// 菜单栏最多保留最近 14 个电平样本。
    public static let sampleCount = 14

    /// 将 30...110 dB 归一化到 0...1，供折线图计算纵向位置。
    public static func normalized(_ spl: Float) -> Float {
        guard spl.isFinite else { return 0 }
        return min(1, max(0, (spl - 30) / 80))
    }

    /// 新样本从右侧进入；无信号和超过 5 秒的旧样本由录音状态清空。
    public static func appending(_ sample: Float, to samples: [Float]) -> [Float] {
        guard sample.isFinite, sample > -80 else { return samples }
        return Array((samples + [sample]).suffix(sampleCount))
    }
}
