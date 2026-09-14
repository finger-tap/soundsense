//
//  SourceTestStore.swift
//  SoundSense
//
//  三点声源倾向测试的持久化:JSON 结果 + 关联录音文件生命周期。
//  录音存 Application Support/SoundSense/Recordings/Tests/<audioID>.m4a
//  (与测量历史录音目录隔离)。删除/清空/淘汰/启动清扫不留孤儿文件。
//

#if os(iOS) || os(macOS)

import Foundation

public final class SourceTestStore: ObservableObject {

    public static let shared = SourceTestStore()

    /// 最多保留的测试结果条数
    public static let maxResults = 20

    @Published public private(set) var results: [SourceTestResult] = []

    private let fileURL: URL
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
            self.fileURL = appDir.appendingPathComponent("source_tests.json")
        }
        recordingsDirectory = self.fileURL.deletingLastPathComponent()
            .appendingPathComponent("Recordings/Tests", isDirectory: true)
        try? FileManager.default.createDirectory(at: recordingsDirectory,
                                                 withIntermediateDirectories: true)
        load()
    }

    /// audioID → 录音文件路径(不检查存在性)
    public func audioFileURL(forID id: String) -> URL {
        recordingsDirectory.appendingPathComponent("\(id).m4a")
    }

    /// 添加结果(最新在前);淘汰超限旧条目连带删录音
    public func add(_ result: SourceTestResult) {
        results.insert(result, at: 0)
        if results.count > Self.maxResults {
            let ids = results[Self.maxResults...].compactMap { $0.audioID }
            results.removeSubrange(Self.maxResults...)
            deleteAudioFiles(ids: ids)
        }
        save()
    }

    /// 删除指定结果(连带录音)
    public func delete(at offsets: IndexSet) {
        let removable = offsets.filter { $0 >= 0 && $0 < results.count }
        guard !removable.isEmpty else { return }
        let ids = removable.compactMap { results[$0].audioID }
        for index in removable.sorted(by: >) { results.remove(at: index) }
        deleteAudioFiles(ids: ids)
        save()
    }

    /// 清空全部结果(连带全部录音)
    public func removeAll() {
        results.removeAll()
        if let contents = try? FileManager.default.contentsOfDirectory(
            at: recordingsDirectory, includingPropertiesForKeys: nil) {
            for url in contents { try? FileManager.default.removeItem(at: url) }
        }
        save()
    }

    // MARK: - 持久化

    private func deleteAudioFiles(ids: [String]) {
        for id in ids {
            try? FileManager.default.removeItem(at: audioFileURL(forID: id))
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        if let decoded = try? JSONDecoder().decode([SourceTestResult].self, from: data) {
            results = decoded
        }
        // 孤儿清扫:目录里凡不被引用的 m4a 一律删除
        let keeping = Set(results.compactMap { $0.audioID })
        if let contents = try? FileManager.default.contentsOfDirectory(
            at: recordingsDirectory, includingPropertiesForKeys: nil) {
            for url in contents where url.pathExtension.lowercased() == "m4a" {
                if !keeping.contains(url.deletingPathExtension().lastPathComponent) {
                    try? FileManager.default.removeItem(at: url)
                }
            }
        }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(results) else { return }
        try? data.write(to: fileURL, options: [.atomic])
    }
}

#endif
