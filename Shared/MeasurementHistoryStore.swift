//
//  MeasurementHistoryStore.swift
//  SoundSense
//
//  测量历史持久化:把每次 MeasurementStats 存为 JSON,供历史列表回看 / 重新导出。
//  存储位置:Application Support/SoundSense/measurement_history.json
//  跨平台(iOS / macOS 共用),最多保留 50 条,新记录在前。
//

import Foundation

public final class MeasurementHistoryStore: ObservableObject {

    /// 单例:iOS / macOS 各自进程一份
    public static let shared = MeasurementHistoryStore()

    /// 最多保留的历史条数
    private let maxRecords = 50

    @Published public private(set) var records: [MeasurementStats] = []

    private let fileURL: URL

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
        load()
    }

    // MARK: - 增删

    /// 添加一条测量记录(插入到最前)
    public func add(_ stats: MeasurementStats) {
        records.insert(stats, at: 0)
        if records.count > maxRecords {
            records.removeLast(records.count - maxRecords)
        }
        save()
    }

    /// 删除指定记录
    public func delete(at offsets: IndexSet) {
        guard let first = offsets.first, first < records.count else { return }
        records.remove(atOffsets: offsets)
        save()
    }

    /// 清空全部历史
    public func removeAll() {
        records.removeAll()
        save()
    }

    // MARK: - 持久化

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        if let decoded = try? JSONDecoder().decode([MeasurementStats].self, from: data) {
            records = decoded
        }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(records) else { return }
        try? data.write(to: fileURL, options: [.atomic])
    }
}
