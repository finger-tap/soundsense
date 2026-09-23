//
//  MeasurementHistoryStore.swift
//  SoundSense
//
//  测量历史持久化:JSON 记录 + 关联录音文件生命周期管理。
//  录音存 Application Support/SoundSense/Recordings/<audioID>.m4a。
//  删除/清空/淘汰/启动清扫四条路径都不留孤儿文件。
//  跨平台(iOS / macOS 共用),最多保留 50 条,新记录在前。
//

import Foundation

public final class MeasurementHistoryStore: ObservableObject {

    /// 单例:iOS / macOS 各自进程一份
    public static let shared = MeasurementHistoryStore()

    /// 最多保留的历史条数
    public static let maxRecords = 50

    @Published public private(set) var records: [MeasurementStats] = []

    private let fileURL: URL
    /// 录音目录(与 JSON 同级);注入自定义 fileURL 的测试 likewise 隔离
    public let recordingsDirectory: URL

    public init(fileURL: URL? = nil) {
        if let url = fileURL {
            self.fileURL = url
        } else {
            let dir = FileManager.default.urls(for: .applicationSupportDirectory,
                                               in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory
            let appDir = dir.appendingPathComponent("SoundSense", isDirectory: true)
            try? FileManager.default.createDirectory(at: appDir, withIntermediateDirectories: true)
            self.fileURL = appDir.appendingPathComponent("measurement_history.json")
        }
        recordingsDirectory = self.fileURL.deletingLastPathComponent()
            .appendingPathComponent("Recordings", isDirectory: true)
        try? FileManager.default.createDirectory(at: recordingsDirectory,
                                                 withIntermediateDirectories: true)
        load()
    }

    // MARK: - 录音文件路径

    /// audioID → 录音文件路径(不检查存在性)
    public func audioFileURL(forID id: String) -> URL {
        recordingsDirectory.appendingPathComponent("\(id).m4a")
    }

    // MARK: - 增删

    /// 添加一条测量记录(插入到最前);淘汰超限旧记录时连带删其录音文件
    public func add(_ stats: MeasurementStats) {
        records.insert(stats, at: 0)
        if records.count > Self.maxRecords {
            let evicted = records[Self.maxRecords...]
            let ids = evicted.compactMap { $0.audioID }
            records.removeSubrange(Self.maxRecords...)
            deleteAudioFiles(ids: ids)
        }
        save()
    }

    /// 删除指定记录(连带录音文件)
    public func delete(at offsets: IndexSet) {
        let removable = offsets.filter { $0 >= 0 && $0 < records.count }
        guard !removable.isEmpty else { return }
        let ids = removable.map { records[$0].audioID }
        for index in removable.sorted(by: >) {
            records.remove(at: index)
        }
        deleteAudioFiles(ids: ids.compactMap { $0 })
        save()
    }

    /// 清空全部历史(连带全部录音文件)
    public func removeAll() {
        records.removeAll()
        deleteAllAudioFiles()
        save()
    }

    // MARK: - 录音文件清理

    /// 删除指定 id 的录音文件(尽力删,失败不阻断)
    private func deleteAudioFiles(ids: [String]) {
        for id in ids {
            try? FileManager.default.removeItem(at: audioFileURL(forID: id))
        }
    }

    /// 清空目录内全部 m4a
    private func deleteAllAudioFiles() {
        sweepOrphans(keeping: [])
    }

    /// 孤儿清扫:目录里凡不被 keeping 引用的 m4a 一律删除(覆盖崩溃残留)
    private func sweepOrphans(keeping: Set<String>) {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: recordingsDirectory, includingPropertiesForKeys: nil) else { return }
        for url in contents where url.pathExtension.lowercased() == "m4a" {
            if !keeping.contains(url.deletingPathExtension().lastPathComponent) {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    // MARK: - 持久化

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        if let decoded = try? JSONDecoder().decode([MeasurementStats].self, from: data) {
            records = decoded
        }
        sweepOrphans(keeping: Set(records.compactMap { $0.audioID }))
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(records) else { return }
        try? data.write(to: fileURL, options: [.atomic])
    }
}
