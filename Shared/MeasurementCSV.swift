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
        rows.append("# 等效声级 LAeq(dB),\(String(format: "%.1f", stats.laeqSPL))")
        rows.append("# 平均 SPL(dB),\(String(format: "%.1f", stats.avgSPL))")
        rows.append("# 峰值 SPL(dB),\(String(format: "%.1f", stats.peakSPL))")
        rows.append("# 最低 SPL(dB),\(String(format: "%.1f", stats.minSPL))")
        rows.append("# 超过 85 dB 时长(秒),\(String(format: "%.0f", stats.overLimitTotal))")
        rows.append("")
        rows.append("相对时间(秒),绝对时间,SPL(dB)")
        let df = isoFormatter
        for s in stats.samples {
            let date = stats.startTime.addingTimeInterval(s.relativeTime)
            rows.append(String(format: "%.1f,%@,%.1f",
                               s.relativeTime, df.string(from: date), s.spl))
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

    private static var isoFormatter: DateFormatter {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return df
    }

    private static func iso(_ date: Date) -> String {
        isoFormatter.string(from: date)
    }
}
