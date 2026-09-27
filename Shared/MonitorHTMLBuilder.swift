//
//  MonitorHTMLBuilder.swift
//  SoundSense
//
//  长时间监听会话的 HTML 单文件报告:统计 + 事件时间线 + 代表性片段内嵌。
//  复用 ReportHTMLBuilder 的深色主题样式。
//

#if os(iOS) || os(macOS)

import Foundation

public enum MonitorHTMLBuilder {

    public static func build(session: MonitorSession,
                             clipURLProvider: (String) -> URL?) -> String {
        let df = DateFormatter()
        df.dateFormat = "MM-dd HH:mm"
        let full = DateFormatter()
        full.dateFormat = "yyyy-MM-dd HH:mm:ss"

        let end = session.endTime.map { df.string(from: $0) } ?? "进行中"
        let abnormal = session.abnormalEnd ? " · 异常结束" : ""

        // 事件时间线行
        let eventRows = session.events.enumerated().map { i, e -> String in
            """
              <tr>
                <td>\(df.string(from: e.time))</td>
                <td>\(String(format: "%.1f", e.peakSPL)) dB</td>
                <td>\(String(format: "%.0fs", e.duration))</td>
                <td>\(escape(SourceTendencyAnalyzer.typeText(e.type)))</td>
                <td>\(escape(e.guess))</td>
              </tr>
            """
        }.joined(separator: "\n")

        // 最长的 3 个片段内嵌(其余用文件过大不内嵌,保持 HTML 体积可控)
        let longest = session.events
            .filter { $0.clipFile != nil }
            .sorted { $0.duration > $1.duration }
            .prefix(3)
        let audioBlocks = longest.compactMap { e -> String? in
            guard let clip = e.clipFile, let url = clipURLProvider(clip),
                  let data = try? Data(contentsOf: url) else { return nil }
            return """
            <div class="clip">
              <div class="clipmeta">\(df.string(from: e.time)) · \(String(format: "%.1f dB", e.peakSPL)) · \(escape(SourceTendencyAnalyzer.typeText(e.type)))</div>
              <audio controls preload="metadata" src="data:audio/mp4;base64,\(data.base64EncodedString())"></audio>
            </div>
            """
        }.joined(separator: "\n")

        return """
        <!DOCTYPE html>
        <html lang="zh-CN">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>闻声 SoundSense 监听报告</title>
        <style>
          \(ReportHTMLBuilder.themeCSS)
          table { width: 100%; border-collapse: collapse; font-size: 12px; }
          th { text-align: left; color: rgba(255,255,255,.45); font-weight: 500;
               padding: 6px 4px; border-bottom: 1px solid rgba(255,255,255,.1); }
          td { padding: 6px 4px; border-bottom: 1px solid rgba(255,255,255,.05);
               color: rgba(255,255,255,.8); }
          .clip { margin: 10px 0; }
          .clipmeta { font-size: 12px; color: rgba(255,255,255,.55); margin-bottom: 4px; }
        </style>
        </head>
        <body>
        <div class="wrap">
          <div class="brand">SOUNDSENSE</div>
          <h1>噪音监听报告</h1>
          <div class="meta">\(full.string(from: session.startTime)) — \(end)\(abnormal)</div>
          <section class="card">
            <div class="stats">
              <div class="stat"><b>\(String(format: "%.1f", session.overallLaeq))</b><span>总 LAeq dB</span></div>
              <div class="stat"><b>\(String(format: "%.0f", session.maxSPL))</b><span>峰值 dB</span></div>
              <div class="stat"><b>\(session.events.count)</b><span>异常事件</span></div>
            </div>
          </section>
          <section class="card">
            <h2>事件时间线(阈值:背景 +\(String(format: "%.0f", session.thresholdOverBackground)) dB)</h2>
            <table>
              <tr><th>时间</th><th>峰值</th><th>时长</th><th>类型</th><th>位置推测</th></tr>
              \(eventRows)
            </table>
          </section>
          <section class="card">
            <h2>代表性录音(最长的 \(longest.count) 段)</h2>
            \(audioBlocks.isEmpty ? "无片段" : audioBlocks)
          </section>
          <footer>
            事件判定:超过背景基线(L90)+\(String(format: "%.0f", session.thresholdOverBackground)) dB 的瞬态/连续声<br>
            位置推测仅供参考 · 由闻声 SoundSense 生成
          </footer>
        </div>
        </body>
        </html>
        """
    }

    /// 默认文件名:监听报告_2026-09-14_1430.html
    public static func filename(for session: MonitorSession) -> String {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd_HHmm"
        return "监听报告_\(df.string(from: session.startTime)).html"
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}

#endif
