//
//  MonitorSessionStore.swift
//  SoundSense
//
//  长时间监听的会话持久化:会话/事件元数据 JSON + 事件片段目录。
//  片段存 Application Support/SoundSense/Recordings/Monitor/<sessionID>/<eventID>.m4a
//  删除会话连带删片段目录;清空/淘汰/启动清扫同套生命周期。
//

#if os(iOS) || os(macOS)

import Foundation

/// 一条监听事件
public struct MonitorEvent: Codable, Equatable, Identifiable {
    public let id: UUID
    public let time: Date
    public let peakSPL: Float
    public let duration: TimeInterval
    public let avgLowRatio: Float
    public let type: NoiseType
    /// 位置推测文案(如"楼上(推测)")
    public let guess: String
    /// 片段文件名(不含路径);无录音为 nil
    public let clipFile: String?

    public init(id: UUID = UUID(), time: Date, peakSPL: Float, duration: TimeInterval,
                avgLowRatio: Float, type: NoiseType, guess: String, clipFile: String? = nil) {
        self.id = id
        self.time = time
        self.peakSPL = peakSPL
        self.duration = duration
        self.avgLowRatio = avgLowRatio
        self.type = type
        self.guess = guess
        self.clipFile = clipFile
    }
}

/// 一次监听会话
public struct MonitorSession: Codable, Equatable, Identifiable {
    public let id: UUID
    public let startTime: Date
    /// nil = 仍在进行/异常中断未落
    public var endTime: Date?
    /// 会话结束(或当前累计)的统计
    public var overallLaeq: Float
    public var minSPL: Float
    public var maxSPL: Float
    public let thresholdOverBackground: Float
    public var events: [MonitorEvent]
    /// 被系统回收等异常结束
    public var abnormalEnd: Bool

    public init(id: UUID = UUID(), startTime: Date, endTime: Date? = nil,
                overallLaeq: Float, minSPL: Float, maxSPL: Float,
                thresholdOverBackground: Float, events: [MonitorEvent] = [],
                abnormalEnd: Bool = false) {
        self.id = id
        self.startTime = startTime
        self.endTime = endTime
        self.overallLaeq = overallLaeq
        self.minSPL = minSPL
        self.maxSPL = maxSPL
        self.thresholdOverBackground = thresholdOverBackground
        self.events = events
        self.abnormalEnd = abnormalEnd
    }
}

public final class MonitorSessionStore: ObservableObject {

    public static let shared = MonitorSessionStore()

    /// 最多保留的会话条数
    public static let maxSessions = 20

    @Published public private(set) var sessions: [MonitorSession] = []

    private let fileURL: URL
    /// 片段根目录(其下按 sessionID 分子目录)
    public let baseClipsDirectory: URL

    public init(fileURL: URL? = nil) {
        if let url = fileURL {
            self.fileURL = url
        } else {
            let dir = FileManager.default.urls(for: .applicationSupportDirectory,
                                               in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory
            let appDir = dir.appendingPathComponent("SoundSense", isDirectory: true)
            try? FileManager.default.createDirectory(at: appDir, withIntermediateDirectories: true)
            self.fileURL = appDir.appendingPathComponent("monitor_sessions.json")
        }
        baseClipsDirectory = self.fileURL.deletingLastPathComponent()
            .appendingPathComponent("Recordings/Monitor", isDirectory: true)
        try? FileManager.default.createDirectory(at: baseClipsDirectory,
                                                 withIntermediateDirectories: true)
        load()
    }

    /// 会话片段目录(按需创建,调用后必定存在)
    public func clipsDirectory(sessionID: UUID) -> URL {
        let url = baseClipsDirectory.appendingPathComponent(sessionID.uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// 事件片段文件路径
    public func clipURL(sessionID: UUID, clipFile: String) -> URL {
        clipsDirectory(sessionID: sessionID).appendingPathComponent(clipFile)
    }

    // MARK: - 增删

    /// 新增会话(最新在前);淘汰超限旧会话连带删片段目录
    public func add(_ session: MonitorSession) {
        sessions.insert(session, at: 0)
        if sessions.count > Self.maxSessions {
            let evicted = sessions[Self.maxSessions...]
            sessions.removeSubrange(Self.maxSessions...)
            for s in evicted { removeClipDirectory(sessionID: s.id) }
        }
        save()
    }

    /// 更新(监听中追加事件/落 endTime 用)
    public func update(_ session: MonitorSession) {
        guard let idx = sessions.firstIndex(where: { $0.id == session.id }) else { return }
        sessions[idx] = session
        save()
    }

    /// 删除会话(连带片段目录)
    public func delete(at offsets: IndexSet) {
        let removable = offsets.filter { $0 >= 0 && $0 < sessions.count }
        guard !removable.isEmpty else { return }
        let ids = removable.map { sessions[$0].id }
        for index in removable.sorted(by: >) { sessions.remove(at: index) }
        for id in ids { removeClipDirectory(sessionID: id) }
        save()
    }

    /// 清空全部会话(连带全部片段)
    public func removeAll() {
        sessions.removeAll()
        if let contents = try? FileManager.default.contentsOfDirectory(
            at: baseClipsDirectory, includingPropertiesForKeys: nil) {
            for url in contents { try? FileManager.default.removeItem(at: url) }
        }
        save()
    }

    // MARK: - 持久化

    private func removeClipDirectory(sessionID: UUID) {
        try? FileManager.default.removeItem(at: clipsDirectory(sessionID: sessionID))
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        if let decoded = try? JSONDecoder().decode([MonitorSession].self, from: data) {
            sessions = decoded
        }
        // 孤儿清扫:不被任何会话引用的片段子目录一律删除
        let keeping = Set(sessions.map { $0.id.uuidString })
        if let contents = try? FileManager.default.contentsOfDirectory(
            at: baseClipsDirectory, includingPropertiesForKeys: nil) {
            for url in contents where !keeping.contains(url.lastPathComponent) {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(sessions) else { return }
        try? data.write(to: fileURL, options: [.atomic])
    }
}

#endif
