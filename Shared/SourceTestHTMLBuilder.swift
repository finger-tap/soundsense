//
//  SourceTestHTMLBuilder.swift
//  SoundSense
//
//  声源方向倾向测试的 HTML 单文件报告:结论 + 四点位对比 + 录音内嵌。
//  复用 ReportHTMLBuilder 的深色主题样式。
//

#if os(iOS) || os(macOS)

import Foundation

public enum SourceTestHTMLBuilder {

    public static func build(result: SourceTestResult,
                             deviceName: String,
                             audioBase64: String?) -> String {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let verdictText = result.rejectedByDrift
            ? "环境变化过大"
            : Self.verdictText(result.verdict)
        let confidenceText = Self.confidenceText(result.confidence)
        let typeText = Self.typeText(result.noiseType)

        let audioBlock: String
        if let audio = audioBase64 {
            audioBlock = """
            <section class="card">
              <h2>测试现场录音</h2>
              <audio controls preload="metadata" src="data:audio/mp4;base64,\(audio)"></audio>
            </section>
            """
        } else {
            audioBlock = ""
        }

        // 四点位对比条使用相对差值,避免 40 dB 与 45 dB 看起来完全一样长。
        let finiteLaeq = result.positions.map { $0.laeq }.filter { $0.isFinite }
        let minLaeq = finiteLaeq.min() ?? 0
        let maxLaeq = max(finiteLaeq.max() ?? 1, minLaeq + 1)
        let rows = result.positions.enumerated().map { i, p -> String in
            let pct = Int(max(4, ((p.laeq - minLaeq) / (maxLaeq - minLaeq)) * 100))
            return """
              <div class="row">
                <span class="label">\(escape(p.name))</span>
                <div class="bar"><i style="width:\(pct)%"></i></div>
                <span class="value">\(String(format: "%.1f", p.laeq)) dB · \(p.eventCount) 次事件</span>
              </div>
            """
        }.joined(separator: "\n")
        let driftSubline: String
        if result.rejectedByDrift {
            let drift = result.centerDrift.map { String(format: "%.1f dB", $0) } ?? "超过 2 dB"
            driftSubline = "中央复测漂移 \(drift)，环境变化过大，本次不下方向结论"
        } else if let drift = result.centerDrift {
            driftSubline = String(format: "中央复测漂移 %.1f dB，环境稳定性校验通过", drift)
        } else {
            driftSubline = "旧版三位置记录，无中央复测漂移数据"
        }

        return """
        <!DOCTYPE html>
        <html lang="zh-CN">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>闻声 SoundSense 声源倾向测试报告</title>
        <style>
          \(ReportHTMLBuilder.themeCSS)
          .row { display: flex; align-items: center; gap: 10px; margin: 8px 0; }
          .row .label { width: 92px; font-size: 13px; color: rgba(255,255,255,.7); }
          .row .bar { flex: 1; height: 14px; background: rgba(255,255,255,.06);
                      border-radius: 7px; overflow: hidden; }
          .row .bar i { display: block; height: 100%; background: #3dd9bf; border-radius: 7px; }
          .row .value { width: 150px; text-align: right; font-size: 12px;
                        color: rgba(255,255,255,.55); }
          .verdict { font-size: 30px; font-weight: 800; color: #3dd9bf; }
          .sub { color: rgba(255,255,255,.5); font-size: 13px; margin-top: 4px; }
        </style>
        </head>
        <body>
        <div class="wrap">
          <div class="brand">SOUNDSENSE</div>
          <h1>声源倾向测试报告</h1>
          <div class="meta">\(df.string(from: result.startTime)) · 测试时长 \(RecordingPlayer.formatTime(result.duration))</div>
          <div class="card">
            <div class="verdict">\(verdictText)</div>
            <div class="sub">置信度:\(confidenceText) · 噪音类型:\(typeText) · 推测仅供参考</div>
            <div class="sub">\(driftSubline)</div>
          </div>
          <section class="card">
            <h2>点位对比(当前流程每点 30 秒)</h2>
            \(rows)
          </section>
          \(audioBlock)
          <footer>
            设备:\(escape(deviceName)) · 由闻声 SoundSense 生成<br>
            方向倾向判别:靠墙有效增益 ≥ 3 dB 且领先 → 倾向隔壁；靠顶有效增益 ≥ 3 dB 且领先 → 倾向楼上。<br>
            单麦克风无法做真实三维定位；中央复测漂移 > 2 dB 时不下结论。
          </footer>
        </div>
        </body>
        </html>
        """
    }

    /// 默认文件名:声源测试_2026-09-14_1430.html
    public static func filename(for result: SourceTestResult) -> String {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd_HHmm"
        return "声源测试_\(df.string(from: result.startTime)).html"
    }

    static func verdictText(_ v: TendencyVerdict) -> String {
        SourceTendencyAnalyzer.verdictText(v)
    }

    static func confidenceText(_ c: Confidence) -> String {
        SourceTendencyAnalyzer.confidenceText(c)
    }

    static func typeText(_ t: NoiseType) -> String {
        SourceTendencyAnalyzer.typeText(t)
    }

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}

#endif
