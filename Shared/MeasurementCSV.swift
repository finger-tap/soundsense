//
//  MeasurementCSV.swift
//  SoundSense
//
//  测量数据 CSV 导出:原始时间序列(时间, SPL),供分析 / 取证 / 二次处理。
//  跨平台(iOS / macOS 共用)。
//

import Foundation

public enum MeasurementCSV {

    /// 单条测量的 CSV(UTF-8,含 BOM 以兼容 Excel 直接打开)
    public static func csv(for stats: MeasurementStats) -> String {
        var rows: [String] = []
        rows.append("# 闻声 SoundSense 测量数据")
        rows.append("# 开始时间,\(iso(stats.startTime))")
        rows.append("# 结束时间,\(iso(stats.endTime))")
        rows.append("# 时长(秒),\(String(format: "%.0f", stats.duration))")
        rows.append("# 频率计权,\(stats.resolvedWeighting)")
        rows.append("# 时间计权,\(stats.resolvedTimeWeighting)")
        rows.append("# 采集完整性,\(stats.isCompleteCapture ? "完整" : "不完整（存在丢帧）")")
        rows.append("# 等效声级 \(stats.leqMetricLabel)(dB),\(level(stats.laeqSPL))")
        rows.append("# 平均 SPL(dB),\(level(stats.avgSPL))")
        rows.append("# 时间计权峰值 \(stats.peakMetricLabel)(dB),\(level(stats.peakSPL))")
        rows.append("# 统计声级 L10(dB),\(level(stats.l10))")
        rows.append("# 统计声级 L50(dB),\(level(stats.l50))")
        rows.append("# 统计声级 L90(dB),\(level(stats.l90))")
        rows.append("# 最低 SPL(dB),\(level(stats.minSPL))")
        rows.append("# 暴露阈值(dB),\(String(format: "%.0f", stats.resolvedExposureLimit))")
        rows.append("# 超过该阈值时长(秒),\(String(format: "%.0f", stats.overLimitTotal))")
        rows.append("")
        rows.append("相对时间(秒),绝对时间,SPL(dB)")
        let df = isoFormatter
        for s in stats.samples {
            let date = stats.startTime.addingTimeInterval(s.relativeTime)
            rows.append(String(format: "%.1f,%@,%@",
                               s.relativeTime, df.string(from: date), level(s.spl)))
        }
        return rows.joined(separator: "\n")
    }

    /// 多条历史记录合并 CSV
    public static func csv(forAll records: [MeasurementStats]) -> String {
        records.map(csv).joined(separator: "\n\n")
    }

    /// 默认文件名:闻声数据_2026-08-14_153000.csv
    public static func filename(for stats: MeasurementStats) -> String {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd_HHmm"
        return "闻声数据_\(df.string(from: stats.startTime)).csv"
    }

    private static let isoFormatter: DateFormatter = {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return df
    }()

    private static func iso(_ date: Date) -> String {
        isoFormatter.string(from: date)
    }

    /// CSV 不写 `-inf`/`nan`:静音或损坏的数值统一留空,避免被表格软件
    /// 误解析为无穷大而污染后续统计。
    private static func level(_ value: Float) -> String {
        guard value.isFinite else { return "" }
        return String(format: "%.1f", value)
    }
}
