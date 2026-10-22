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
    public var clipFile: String?

    private enum CodingKeys: String, CodingKey {
        case id, time, peakSPL, duration, avgLowRatio, type, guess, clipFile
    }

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
    /// 单个会话保留的事件明细上限。超出后仅保留最近条目，累计数量、
    /// 事件峰值和已丢弃条数仍完整保存，避免过夜监听无限增长。
    public static let maxRetainedEvents = 1_000

    public let id: UUID
    public let startTime: Date
    /// nil = 仍在进行/异常中断未落
    public var endTime: Date?
    /// 会话结束(或当前累计)的统计
    public var overallLaeq: Float
    public var minSPL: Float
    public var maxSPL: Float
    /// 监听时的频率计权("A"/"C")。旧记录为 nil，按 A 计权兼容。
    public var weighting: String?
    /// 监听时的时间计权("F"/"S")。旧记录为 nil，按 F 计权兼容。
    public var timeWeighting: String?
    public let thresholdOverBackground: Float
    /// 可选的夜间绝对阈值。nil = 仅按相对背景阈值触发。
    public var absoluteThreshold: Float? = nil
    public var events: [MonitorEvent]
    /// 本次会话累计事件数(包括已因明细上限淘汰的条目)。
    public var totalEventCount: Int
    /// 因明细保留上限而未保存在 `events` 中的历史事件数。
    public var droppedEventCount: Int
    /// 本次会话所有事件的峰值，即使明细已被淘汰仍保留。
    public var eventPeakSPL: Float?
    /// 近期事件的平均低频占比。即使旧明细被淘汰，类型统计仍可持续更新。
    public var recentAvgLowRatio: Float?
    /// 被系统回收等异常结束
    public var abnormalEnd: Bool
    /// 采集/分析链路曾丢帧或积压。最终 Leq/峰值仍来自引擎全帧统计，
    /// 但事件时间线可能不完整。
    public var captureIncomplete: Bool
    /// 事件片段录制链路因编码/写盘队列积压而丢弃的 PCM 块数。
    /// 旧记录没有此字段时为 0；大于 0 表示部分事件录音可能缺音。
    public var droppedClipBlockCount: Int

    public init(id: UUID = UUID(), startTime: Date, endTime: Date? = nil,
                overallLaeq: Float, minSPL: Float, maxSPL: Float,
                weighting: String? = nil, timeWeighting: String? = nil,
                thresholdOverBackground: Float, absoluteThreshold: Float? = nil,
                events: [MonitorEvent] = [],
                totalEventCount: Int? = nil,
                droppedEventCount: Int = 0,
                eventPeakSPL: Float? = nil,
                recentAvgLowRatio: Float? = nil,
                abnormalEnd: Bool = false,
                captureIncomplete: Bool = false,
                droppedClipBlockCount: Int = 0) {
        self.id = id
        self.startTime = startTime
        self.endTime = endTime
        self.overallLaeq = overallLaeq
        self.minSPL = minSPL
        self.maxSPL = maxSPL
        self.weighting = weighting
        self.timeWeighting = timeWeighting
        self.thresholdOverBackground = thresholdOverBackground
        self.absoluteThreshold = absoluteThreshold
        self.events = events
        self.totalEventCount = totalEventCount ?? events.count
        self.droppedEventCount = max(0, droppedEventCount)
        self.eventPeakSPL = eventPeakSPL
        self.recentAvgLowRatio = recentAvgLowRatio
        self.abnormalEnd = abnormalEnd
        self.captureIncomplete = captureIncomplete
        self.droppedClipBlockCount = max(0, droppedClipBlockCount)
    }

    private enum CodingKeys: String, CodingKey {
        case id, startTime, endTime, overallLaeq, minSPL, maxSPL
        case weighting, timeWeighting
        case thresholdOverBackground, absoluteThreshold, events, abnormalEnd
        case captureIncomplete, totalEventCount, droppedEventCount, eventPeakSPL
        case recentAvgLowRatio, droppedClipBlockCount
    }

    /// 兼容旧版本没有 absoluteThreshold / abnormalEnd 字段的 JSON。
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        startTime = try container.decode(Date.self, forKey: .startTime)
        endTime = try container.decodeIfPresent(Date.self, forKey: .endTime)
        overallLaeq = try container.decode(Float.self, forKey: .overallLaeq)
        minSPL = try container.decode(Float.self, forKey: .minSPL)
        maxSPL = try container.decode(Float.self, forKey: .maxSPL)
        weighting = try container.decodeIfPresent(String.self, forKey: .weighting)
        timeWeighting = try container.decodeIfPresent(String.self, forKey: .timeWeighting)
        thresholdOverBackground = try container.decode(
            Float.self, forKey: .thresholdOverBackground)
        absoluteThreshold = try container.decodeIfPresent(
            Float.self, forKey: .absoluteThreshold)
        events = try container.decode([MonitorEvent].self, forKey: .events)
        totalEventCount = try container.decodeIfPresent(
            Int.self, forKey: .totalEventCount) ?? events.count
        droppedEventCount = max(0, try container.decodeIfPresent(
            Int.self, forKey: .droppedEventCount) ?? 0)
        eventPeakSPL = try container.decodeIfPresent(
            Float.self, forKey: .eventPeakSPL)
        recentAvgLowRatio = try container.decodeIfPresent(
            Float.self, forKey: .recentAvgLowRatio)
        abnormalEnd = try container.decodeIfPresent(
            Bool.self, forKey: .abnormalEnd) ?? false
        captureIncomplete = try container.decodeIfPresent(
            Bool.self, forKey: .captureIncomplete) ?? false
        droppedClipBlockCount = max(0, try container.decodeIfPresent(
            Int.self, forKey: .droppedClipBlockCount) ?? 0)
    }

    /// 等效声级名称，如 LAeq / LCeq。
    public var leqMetricLabel: String {
        "L\(resolvedWeighting)eq"
    }

    /// 时间计权峰值名称，如 LAFmax / LCSmax。
    public var peakMetricLabel: String {
        "L\(resolvedWeighting)\(resolvedTimeWeighting)max"
    }

    public var resolvedWeighting: String {
        weighting?.uppercased() == "C" ? "C" : "A"
    }

    public var resolvedTimeWeighting: String {
        timeWeighting?.uppercased() == "S" ? "S" : "F"
    }

    /// 追加事件并维护有界明细。调用方应从事件总数和峰值读取完整统计。
    public mutating func appendEvent(_ event: MonitorEvent) {
        events.append(event)
        totalEventCount += 1
        if event.peakSPL > (eventPeakSPL ?? -.greatestFiniteMagnitude) {
            eventPeakSPL = event.peakSPL
        }
        if recentAvgLowRatio == nil {
            recentAvgLowRatio = event.avgLowRatio
        } else {
            // 使用 256 条滑动平均；明细淘汰不影响后续分类输入。
            let retained = min(totalEventCount, 256)
            recentAvgLowRatio! +=
                (event.avgLowRatio - recentAvgLowRatio!) / Float(retained)
        }
        let overflow = events.count - Self.maxRetainedEvents
        if overflow > 0 {
            events.removeFirst(overflow)
            droppedEventCount += overflow
        }
    }
}

public final class MonitorSessionStore: ObservableObject {

    public static let shared = MonitorSessionStore()

    /// 最多保留的会话条数
    public static let maxSessions = 20

    @Published public private(set) var sessions: [MonitorSession] = []

    private let fileURL: URL
    /// 监听事件的 JSON 写入合并窗口。事件本身很小，但每次都同步重写
    /// 全部会话会在高频事件时造成不必要的磁盘 I/O。内存状态立即更新，
    /// 磁盘最多延迟这么久；停止监听/退出前调用 flush() 强制落盘。
    ///
    /// 注意这里必须是“固定节流”而不是取消后重新计时：如果事件持续到达，
    /// debounce 会让保存任务一直推迟，进程异常退出时可能整场监听都没有落盘。
    private static let saveCoalescingInterval: TimeInterval = 5.0
    private var pendingSave: DispatchWorkItem?
    private let persistenceQueue = DispatchQueue(
        label: "com.dinghao.soundsense.monitorStore.save",
        qos: .utility)
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

    /// 立即把当前内存状态写入磁盘。停止监听、删除、App 退出前调用。
    public func flush() {
        commit(cancelScheduledSave: true)
    }

    /// 等待此前提交的所有写入完成。测试和需要立即返回的场景使用。
    public func flushAndWait() {
        flush()
        persistenceQueue.sync {}
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
        scheduleSave()
    }

    /// App 启动时把上次被系统/进程直接结束、没来得及落 endTime 的会话收口。
    /// 不标记为“进行中”，否则历史永远停在进行中，也无法区分正常结束。
    public func finalizeInterruptedSessions(at date: Date = Date()) {
        var changed = false
        for index in sessions.indices where sessions[index].endTime == nil {
            sessions[index].endTime = date
            sessions[index].abnormalEnd = true
            changed = true
        }
        if changed { save() }
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
            finalizeInterruptedSessions()
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

    /// 结构性变更(新增/删除/清空)立即落盘；事件追加等高频更新走合并写入。
    private func save() {
        commit(cancelScheduledSave: true)
    }

    private func scheduleSave() {
        // 已有待执行任务时只更新内存快照；任务触发时会读取最新 sessions。
        // 这样高频事件最多每 5 秒写一次，而不是被每个新事件不断饿死。
        guard pendingSave == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingSave = nil
            self.commit(cancelScheduledSave: false)
        }
        pendingSave = work
        DispatchQueue.main.asyncAfter(
            deadline: .now() + Self.saveCoalescingInterval,
            execute: work)
    }

    /// 串行队列保证原子文件写入按提交顺序完成。
    private func commit(cancelScheduledSave: Bool) {
        if cancelScheduledSave {
            pendingSave?.cancel()
            pendingSave = nil
        }
        let snapshot = sessions
        let url = fileURL
        persistenceQueue.async {
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            try? data.write(to: url, options: [.atomic])
        }
    }
}

#endif
