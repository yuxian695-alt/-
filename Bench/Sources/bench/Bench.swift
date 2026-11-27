import Foundation
import AVFoundation
import Speech
import Translation

/// 用法：bench <音频文件> <参考文本> <地区，例如 ko-KR>
/// 按真实速度把音频一块一块喂给识别（和 iPad 上课时一样），记录每个结果什么时候出来。
@main
struct Bench {
    struct Event: Sendable { let text: String; let isFinal: Bool; let start: Double; let end: Double; let arrival: Double }

    static func main() async {
        let args = CommandLine.arguments
        guard args.count >= 4 else { print("用法：bench 音频 参考文本 地区"); exit(2) }
        let audio = URL(fileURLWithPath: args[1])
        let reference = (try? String(contentsOfFile: args[2], encoding: .utf8)) ?? ""
        let locale = Locale(identifier: args[3])
        var report = ["## 苹果离线识别实测（\(args[3])，按真实速度喂音频）", ""]
        do {
            for fast in [true, false] {
                let r = try await run(audio, locale: locale, fast: fast, reference: reference)
                report += r
            }
            report += await translation(reference: reference)
        } catch {
            report.append("出错：\(error)")
            print(report.joined(separator: "\n"))
            exit(1)
        }
        let text = report.joined(separator: "\n")
        print(text)
        try? text.write(toFile: "bench-report.md", atomically: true, encoding: .utf8)
    }

    static func run(_ url: URL, locale: Locale, fast: Bool, reference: String) async throws -> [String] {
        let all = await SpeechTranscriber.supportedLocales
        let want = locale.identifier(.bcp47)
        guard let resolved = all.first(where: { $0.identifier(.bcp47) == want })
                ?? all.first(where: { $0.language.languageCode == locale.language.languageCode }) else {
            return ["- 这台 Mac 的 SpeechTranscriber 不支持 \(want)（支持 \(all.count) 种）"]
        }
        let transcriber = SpeechTranscriber(locale: resolved, transcriptionOptions: [],
                                            reportingOptions: fast ? [.volatileResults, .fastResults] : [.volatileResults],
                                            attributeOptions: [.audioTimeRange])
        let clock = ContinuousClock()
        var t = clock.now
        if let req = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            print("正在下载识别包…")
            try await req.downloadAndInstall()
            print("识别包下载用时 \(clock.now - t)")
        }
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let target = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])
        let (stream, input) = AsyncStream<AnalyzerInput>.makeStream()

        let file = try AVAudioFile(forReading: url)
        let fmt = file.processingFormat
        let converter = target.flatMap { AVAudioConverter(from: fmt, to: $0) }
        t = clock.now
        let t0 = t
        let collector = Task { () throws -> [Event] in
            var out: [Event] = []
            for try await r in transcriber.results {
                let d = clock.now - t0
                let arrival = Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
                out.append(Event(text: String(r.text.characters), isFinal: r.isFinal,
                                 start: r.range.start.seconds, end: r.range.end.seconds, arrival: arrival))
            }
            return out
        }
        try await analyzer.start(inputSequence: stream)

        var fed: AVAudioFramePosition = 0
        while fed < file.length {
            guard let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: 4096) else { break }
            try file.read(into: buf, frameCount: 4096)
            if buf.frameLength == 0 { break }
            fed += AVAudioFramePosition(buf.frameLength)
            input.yield(AnalyzerInput(buffer: try convert(buf, converter, target)))
            let due = Double(fed) / fmt.sampleRate
            let d = clock.now - t0
            let now = Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
            if due > now { try await Task.sleep(nanoseconds: UInt64((due - now) * 1e9)) }
        }
        let audioSeconds = Double(fed) / fmt.sampleRate
        input.finish()
        try await analyzer.finalizeAndFinishThroughEndOfInput()
        let events = try await collector.value

        let finals = events.filter(\.isFinal)
        let volatile = events.filter { !$0.isFinal && $0.end.isFinite && $0.end > 0 }
        let finalLag = finals.filter { $0.end.isFinite }.map { $0.arrival - $0.end }
        let volLag = volatile.map { $0.arrival - $0.end }
        let hyp = finals.map(\.text).joined(separator: " ")
        let cer = errorRate(reference: reference, hypothesis: hyp)
        var lines = ["### 设置：\(fast ? "volatileResults + fastResults（App 用的）" : "只有 volatileResults")", ""]
        lines.append("- 音频 \(String(format: "%.1f", audioSeconds)) 秒，定稿 \(finals.count) 段，临时结果 \(volatile.count) 次")
        lines.append("- 错字率（按字，去掉空格标点）：**\(String(format: "%.1f%%", cer * 100))**")
        lines.append("- 一段话说完 → 定稿文字出来：中位数 **\(fmt2(median(finalLag)))** 秒，最慢 \(fmt2(finalLag.max())) 秒")
        lines.append("- 正在说的临时文字落后实时：中位数 **\(fmt2(median(volLag)))** 秒，90% 不超过 \(fmt2(percentile(volLag, 0.9))) 秒")
        lines.append("")
        lines.append("| 开始 | 结束 | 出来 | 定稿文字 |")
        lines.append("|---|---|---|---|")
        for f in finals { lines.append("| \(fmt2(f.start)) | \(fmt2(f.end)) | \(fmt2(f.arrival)) | \(f.text) |") }
        lines.append("")
        return lines
    }

    /// 苹果系统翻译：GitHub 的 Mac 上一般没有预装韩中语言包，有就顺便测一下每句用时。
    static func translation(reference: String) async -> [String] {
        let ko = Locale.Language(identifier: "ko"), zh = Locale.Language(identifier: "zh-Hans")
        let status = await LanguageAvailability().status(from: ko, to: zh)
        var lines = ["### 苹果系统翻译（韩 → 中）", ""]
        switch status {
        case .installed:
            let session = TranslationSession(installedSource: ko, target: zh)
            let clock = ContinuousClock()
            var times: [Double] = []
            for s in reference.split(separator: "\n").map(String.init) where !s.isEmpty {
                let t = clock.now
                if let r = try? await session.translate(s) {
                    let d = clock.now - t
                    times.append(Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18)
                    lines.append("- \(s) → \(r.targetText)")
                }
            }
            lines.append("- 每句用时中位数 **\(fmt2(median(times)))** 秒")
        case .supported:
            lines.append("- 这台 Mac 没装韩中翻译包（需要在系统设置里点下载，命令行不能装），跳过。iPad 上第一次用时会弹出下载。")
        case .unsupported:
            lines.append("- 不支持韩 → 中。")
        @unknown default:
            lines.append("- 状态未知。")
        }
        return lines
    }

    static func convert(_ buf: AVAudioPCMBuffer, _ converter: AVAudioConverter?, _ target: AVAudioFormat?) throws -> AVAudioPCMBuffer {
        guard let converter, let target else { return buf }
        let cap = AVAudioFrameCount(Double(buf.frameLength) * target.sampleRate / buf.format.sampleRate) + 16
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: cap) else { return buf }
        var used = false
        var err: NSError?
        _ = converter.convert(to: out, error: &err) { _, status in
            if used { status.pointee = .noDataNow; return nil }
            used = true
            status.pointee = .haveData
            return buf
        }
        if let err { throw err }
        return out
    }

    static func normalize(_ s: String) -> [Character] {
        Array(s.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(Character.init))
    }

    static func errorRate(reference: String, hypothesis: String) -> Double {
        let r = normalize(reference), h = normalize(hypothesis)
        guard !r.isEmpty else { return 0 }
        var prev = Array(0...h.count)
        for i in 1...r.count {
            var cur = [i] + Array(repeating: 0, count: h.count)
            for j in stride(from: 1, through: h.count, by: 1) {
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (r[i - 1] == h[j - 1] ? 0 : 1))
            }
            prev = cur
        }
        return Double(prev[h.count]) / Double(r.count)
    }

    static func median(_ v: [Double]) -> Double? { percentile(v, 0.5) }
    static func percentile(_ v: [Double], _ p: Double) -> Double? {
        guard !v.isEmpty else { return nil }
        let s = v.sorted()
        return s[min(s.count - 1, Int(p * Double(s.count)))]
    }
    static func fmt2(_ v: Double?) -> String { v.map { String(format: "%.2f", $0) } ?? "-" }
}
