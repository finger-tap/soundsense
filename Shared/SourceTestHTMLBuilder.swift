//
//  SourceTestHTMLBuilder.swift
//  SoundSense
//
//  三点声源倾向测试的 HTML 单文件报告:结论 + 三点位对比 + 录音内嵌。
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
        let verdictText = Self.verdictText(result.verdict)
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

        // 三点位对比条(以最高 LAeq 归一)
        let maxLaeq = result.positions.map { $0.laeq }.max() ?? 1
        let rows = result.positions.enumerated().map { i, p -> String in
            let pct = maxLaeq > 0 ? Int(max(4, (p.laeq / maxLaeq) * 100)) : 4
            return """
              <div class="row">
                <span class="label">\(escape(p.name))</span>
                <div class="bar"><i style="width:\(pct)%"></i></div>
                <span class="value">\(String(format: "%.1f", p.laeq)) dB · \(p.eventCount) 次事件</span>
              </div>
            """
        }.joined(separator: "\n")

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
          </div>
          <section class="card">
            <h2>三点位对比(各 30 秒)</h2>
            \(rows)
          </section>
          \(audioBlock)
          <footer>
            设备:\(escape(deviceName)) · 由闻声 SoundSense 生成<br>
            三点位增益判别法:靠墙增益显著 → 隔壁;靠顶增益显著 → 楼上
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
