//
//  ReportHTMLBuilder.swift
//  SoundSense
//
//  HTML 单文件报告组装:报告 PNG + 录音 base64 内嵌,浏览器打开即可回放。
//  纯字符串模板(仅 Foundation),平台侧负责生成 PNG/读取录音后传 base64 进来。
//

#if os(iOS) || os(macOS)

import Foundation

public enum ReportHTMLBuilder {

    /// 与 App 同款的深色主题 CSS(SourceTestHTMLBuilder 等复用)
    public static let themeCSS = """
      :root { color-scheme: dark; }
      body { margin: 0; background: #0b1014; color: #fff;
             font-family: -apple-system, "PingFang SC", "Helvetica Neue", sans-serif; }
      .wrap { max-width: 720px; margin: 0 auto; padding: 32px 20px 48px; }
      .brand { color: #3dd9bf; font-size: 13px; letter-spacing: 3px; font-weight: 700; }
      h1 { font-size: 26px; margin: 6px 0 4px; }
      .meta { color: rgba(255,255,255,.55); font-size: 13px; margin-bottom: 20px; }
      .card { background: rgba(255,255,255,.04); border: 1px solid rgba(255,255,255,.08);
              border-radius: 14px; padding: 16px 18px; margin-top: 16px; }
      .card h2 { font-size: 14px; color: rgba(255,255,255,.6); margin: 0 0 10px; }
      .card.warn { border-color: rgba(230,120,100,.45); background: rgba(230,120,100,.08); }
      .card.warn p { margin: 0; color: rgba(255,255,255,.75); font-size: 13px; line-height: 1.7; }
      .stats { display: flex; flex-wrap: wrap; gap: 8px; }
      .stat { flex: 1 1 100px; text-align: center; padding: 10px 4px;
              background: rgba(255,255,255,.03); border-radius: 10px; }
      .stat b { font-size: 19px; display: block; color: #3dd9bf; }
      .stat span { font-size: 11px; color: rgba(255,255,255,.45); }
      audio { width: 100%; }
      footer { margin-top: 22px; color: rgba(255,255,255,.35); font-size: 12px;
               border-top: 1px solid rgba(255,255,255,.08); padding-top: 12px;
               line-height: 1.8; }
    """

    public static func build(stats: MeasurementStats,
                             deviceName: String,
                             calibrationOffset: Float,
                             pngBase64: String,
                             audioBase64: String?) -> String {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let range = "\(df.string(from: stats.startTime)) — \(df.string(from: stats.endTime))"
        let dur = RecordingPlayer.formatTime(stats.duration)

        let audioBlock: String
        if let audio = audioBase64 {
            audioBlock = """
            <section class="card">
              <h2>现场录音</h2>
              <audio controls preload="metadata" src="data:audio/mp4;base64,\(audio)"></audio>
            </section>
            """
        } else {
            audioBlock = ""
        }

        let row = { (_ v: String, _ label: String) in
            "<div class=\"stat\"><b>\(v)</b><span>\(label)</span></div>"
        }
        let level = { (value: Float) -> String in
            value.isFinite ? String(format: "%.1f dB", value) : "--"
        }
        let exposureLabel = String(format: "超 %.0f dB 时长",
                                   stats.resolvedExposureLimit)
        let completenessBlock = stats.isCompleteCapture ? "" : """
          <section class="card warn">
            <h2>测量完整性提示</h2>
            <p>本次测量期间设备处理不及时，部分音频帧未能参与统计。
            当前 Leq、峰值与暴露时长只代表已处理的数据，建议关闭其他高负载 App 后重新测量。</p>
          </section>
        """

        return """
        <!DOCTYPE html>
        <html lang="zh-CN">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>闻声 SoundSense 噪音测量报告</title>
        <style>
          \(themeCSS)
          img.report { width: 100%; border-radius: 14px; display: block;
                       box-shadow: 0 8px 30px rgba(0,0,0,.45); }
        </style>
        </head>
        <body>
        <div class="wrap">
          <div class="brand">SOUNDSENSE</div>
          <h1>噪音测量报告</h1>
          <div class="meta">\(range) · 时长 \(dur) · \(stats.samples.count) 个采样点</div>
          <img class="report" alt="测量报告" src="data:image/png;base64,\(pngBase64)">
          <section class="card">
            <h2>关键指标</h2>
            <div class="stats">
              \(row(level(stats.laeqSPL), "\(stats.leqMetricLabel) 等效声级"))
              \(row(level(stats.peakSPL), "峰值 \(stats.peakMetricLabel)"))
              \(row(level(stats.l10), "L10"))
              \(row(level(stats.l50), "L50"))
              \(row(level(stats.l90), "L90"))
              \(row(level(stats.avgSPL), "平均"))
              \(row(level(stats.minSPL), "最低"))
              \(row(String(format: "%.0f 秒", stats.overLimitTotal), exposureLabel))
            </div>
          </section>
          \(completenessBlock)
          \(audioBlock)
          <footer>
            设备:\(escape(deviceName)) · 校准偏移:\(String(format: "%+.1f", calibrationOffset)) dB<br>
            IEC 61672-1 \(stats.resolvedWeighting) 计权 · \(stats.resolvedTimeWeighting) 时间计权 · 4096 点 FFT · vDSP · 由闻声 SoundSense 生成
          </footer>
        </div>
        </body>
        </html>
        """
    }

    /// 默认文件名:闻声报告_2026-09-01_1430.html
    public static func filename(for stats: MeasurementStats) -> String {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd_HHmm"
        return "闻声报告_\(df.string(from: stats.startTime)).html"
    }

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}

#endif
