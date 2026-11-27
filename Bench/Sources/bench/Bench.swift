import Foundation
import AVFoundation
import Speech
import Translation

/// 用法：bench <每句一个 wav 的文件夹> <讲稿，一行一句> <地区，例如 ko-KR>
///
/// 把每句话按固定停顿拼成一节“课”，按真实速度一块一块喂给苹果离线识别（和 iPad 上课时一样），
/// 记下每个结果什么时候出来；再用 App 里同一份 SoftCommitter 代码重放一遍，算出每句话
/// “老师说完 → 字幕出现 / 定下来去翻译”各用了多久。
@main
struct Bench {
    struct Event: Sendable { let text: String; let isFinal: Bool; let start: Double; let end: Double; let arrival: Double }

    /// 每句话之后停多久（秒）：有正常停顿，也有几乎不停、一口气讲下去的
    static let gaps: [Double] = [0.6, 0.6, 0.15, 0.15, 0.6, 0.15, 0.6, 0.6, 0.15, 0.6, 1.5]

    static func main() async {
        let args = CommandLine.arguments
        guard args.count >= 4 else { print("用法：bench 文件夹 讲稿 地区"); exit(2) }
        let dir = URL(fileURLWithPath: args[1])
        let refs = ((try? String(contentsOfFile: args[2], encoding: .utf8)) ?? "")
            .split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let locale = Locale(identifier: args[3])
        var report = ["## 苹果离线识别实测（\(args[3])，合成语音按真实速度播放）", ""]
        do {
            report += try await run(dir, refs: refs, locale: locale)
            report += await translation(refs)
        } catch {
            report.append("出错：\(error)")
            print(report.joined(separator: "\n"))
            exit(1)
        }
        let text = report.joined(separator: "\n")
        print(text)
        try? text.write(toFile: "bench-report.md", atomically: true, encoding: .utf8)
    }

    // MARK: 拼音频

    static func loadLecture(_ dir: URL, count: Int) throws -> (pcm: [Float], bounds: [(start: Double, end: Double)]) {
        let sr = 16000.0
        var pcm: [Float] = []
        var bounds: [(start: Double, end: Double)] = []
        for i in 0..<count {
            let f = try AVAudioFile(forReading: dir.appendingPathComponent(String(format: "%02d.wav", i)),
                                    commonFormat: .pcmFormatFloat32, interleaved: false)
            guard f.processingFormat.sampleRate == sr,
                  let buf = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: AVAudioFrameCount(f.length)) else {
                throw NSError(domain: "bench", code: 1, userInfo: [NSLocalizedDescriptionKey: "音频不是 16 kHz"])
            }
            try f.read(into: buf)
            let x = Array(UnsafeBufferPointer(start: buf.floatChannelData![0], count: Int(buf.frameLength)))
            // 去掉前后的静音，按“真正开口 / 真正说完”算时间
            let first = x.firstIndex { abs($0) > 0.01 } ?? 0
            let last = x.lastIndex { abs($0) > 0.01 } ?? (x.count - 1)
            let start = Double(pcm.count) / sr
            pcm += x[first...last]
            bounds.append((start, Double(pcm.count) / sr))
            pcm += [Float](repeating: 0, count: Int(gaps[i % gaps.count] * sr))
        }
        return (pcm, bounds)
    }

    // MARK: 识别

    static func run(_ dir: URL, refs: [String], locale: Locale) async throws -> [String] {
        let (pcm, bounds) = try loadLecture(dir, count: refs.count)
        let all = await SpeechTranscriber.supportedLocales
        let want = locale.identifier(.bcp47)
        let clock = ContinuousClock()
        let timer = SharedInstant()
        let module: any SpeechModule
        let collector: Task<[Event], Error>
        var engine = "SpeechTranscriber（App 在 iPadOS 26+ 默认用的新版），volatileResults + fastResults"
        if let resolved = all.first(where: { $0.identifier(.bcp47) == want })
            ?? all.first(where: { $0.language.languageCode == locale.language.languageCode }) {
            let transcriber = SpeechTranscriber(locale: resolved, transcriptionOptions: [],
                                                reportingOptions: [.volatileResults, .fastResults],
                                                attributeOptions: [.audioTimeRange])
            module = transcriber
            collector = Task {
                var out: [Event] = []
                for try await r in transcriber.results {
                    out.append(Event(text: String(r.text.characters), isFinal: r.isFinal,
                                     start: r.range.start.seconds, end: r.range.end.seconds, arrival: timer.since(clock)))
                }
                return out
            }
        } else {
            let dict = await DictationTranscriber.supportedLocales
            print("SpeechTranscriber 支持 \(all.count) 种语言；DictationTranscriber 支持 \(dict.count) 种")
            guard let resolved = dict.first(where: { $0.identifier(.bcp47) == want })
                    ?? dict.first(where: { $0.language.languageCode == locale.language.languageCode }) else {
                return ["- 这台 Mac（GitHub 虚拟机）上两种识别引擎都不支持 \(want)，测不了。"]
            }
            engine = "DictationTranscriber（GitHub 的虚拟机不支持新版，只能测上一代引擎；iPad 上用的是新版）"
            let transcriber = DictationTranscriber(locale: resolved, contentHints: [.farField], transcriptionOptions: [],
                                                   reportingOptions: [.volatileResults], attributeOptions: [.audioTimeRange])
            module = transcriber
            collector = Task {
                var out: [Event] = []
                for try await r in transcriber.results {
                    out.append(Event(text: String(r.text.characters), isFinal: r.isFinal,
                                     start: r.range.start.seconds, end: r.range.end.seconds, arrival: timer.since(clock)))
                }
                return out
            }
        }
        let t = clock.now
        if let req = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
            print("正在下载识别包…")
            try await req.downloadAndInstall()
            print("识别包下载用时 \(clock.now - t)")
        }
        let analyzer = SpeechAnalyzer(modules: [module])
        let target = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module])
        let (stream, input) = AsyncStream<AnalyzerInput>.makeStream()
        guard let src = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false) else { return [] }
        let converter = target.flatMap { AVAudioConverter(from: src, to: $0) }

        try await analyzer.start(inputSequence: stream)
        timer.reset(clock)
        var fed = 0
        while fed < pcm.count {
            let n = min(4096, pcm.count - fed)
            guard let buf = AVAudioPCMBuffer(pcmFormat: src, frameCapacity: AVAudioFrameCount(n)) else { break }
            buf.frameLength = AVAudioFrameCount(n)
            pcm.withUnsafeBufferPointer { p in
                buf.floatChannelData![0].update(from: p.baseAddress! + fed, count: n)
            }
            fed += n
            input.yield(AnalyzerInput(buffer: try convert(buf, converter, target)))
            let due = Double(fed) / 16000
            let now = timer.since(clock)
            if due > now { try await Task.sleep(nanoseconds: UInt64((due - now) * 1e9)) }
        }
        input.finish()
        try await analyzer.finalizeAndFinishThroughEndOfInput()
        let events = try await collector.value
        return analyze(events, refs: refs, bounds: bounds, audioSeconds: Double(pcm.count) / 16000, engine: engine)
    }

    // MARK: 算结果

    static func analyze(_ events: [Event], refs: [String], bounds: [(start: Double, end: Double)],
                        audioSeconds: Double, engine: String) -> [String] {
        let finals = events.filter(\.isFinal)
        let cer = errorRate(reference: refs.joined(separator: " "), hypothesis: finals.map(\.text).joined(separator: " "))

        // 引擎自己定稿
        let enginePieces = finals.map { (text: $0.text, at: $0.arrival) }
        // App 的做法：讲到句尾、1 秒没变就先切出来
        var sc = SoftCommitter()
        var appPieces: [(text: String, at: Double)] = []
        for e in events {
            let text = TextTools.clean(e.text)
            if e.isFinal {
                let rest = sc.final(text)
                if TextTools.letterCount(rest) > 0 { appPieces.append((rest, e.arrival)) }
            } else if let piece = sc.volatile(text, at: e.arrival).commit {
                appPieces.append((piece, e.arrival))
            }
        }
        // 屏幕上“正在说”的文字什么时候追上这句话的最后一个字
        var done = 0
        var visible: [(letters: Int, at: Double)] = []
        for e in events {
            if e.isFinal { done += TextTools.letterCount(e.text); visible.append((done, e.arrival)) }
            else { visible.append((done + TextTools.letterCount(e.text), e.arrival)) }
        }

        let refCum = cumulative(refs)
        let recognized = max(1, finals.reduce(0) { $0 + TextTools.letterCount($1.text) })
        let scale = Double(recognized) / Double(max(1, refCum.last ?? 1))
        func when(_ cum: [Int], _ times: [Double], _ k: Int) -> Double? {
            let need = Double(refCum[k]) * scale - 2
            guard let j = cum.firstIndex(where: { Double($0) >= need }) else { return nil }
            return times[j] - bounds[k].end
        }
        let live = refs.indices.map { when(visible.map(\.letters), visible.map(\.at), $0) }
        let app = refs.indices.map { when(cumulative(appPieces.map(\.text)), appPieces.map(\.at), $0) }
        let eng = refs.indices.map { when(cumulative(enginePieces.map(\.text)), enginePieces.map(\.at), $0) }

        var lines = ["**引擎**：\(engine)", ""]
        lines.append("- 一节 \(String(format: "%.0f", audioSeconds)) 秒的“课”，\(refs.count) 句话，句间停顿 0.15～0.6 秒")
        lines.append("- 错字率（按字，去掉空格标点）：**\(String(format: "%.1f%%", cer * 100))**")
        lines.append("- 老师说完一句 → 屏幕上“正在说”出现这句的最后一个字：中位数 **\(fmt(median(live.compactMap { $0 })))** 秒，最慢 \(fmt(live.compactMap { $0 }.max())) 秒")
        lines.append("- 老师说完一句 → 这句定下来、送去翻译（App 的做法）：中位数 **\(fmt(median(app.compactMap { $0 })))** 秒，最慢 \(fmt(app.compactMap { $0 }.max())) 秒")
        lines.append("- 对比：只等引擎自己定稿：中位数 \(fmt(median(eng.compactMap { $0 }))) 秒，最慢 \(fmt(eng.compactMap { $0 }.max())) 秒（引擎一共定稿 \(finals.count) 次）")
        lines.append("")
        lines.append("| # | 说完（秒） | 正在说 | App 定句 | 只等引擎 | 原句 |")
        lines.append("|---|---|---|---|---|---|")
        for k in refs.indices {
            lines.append("| \(k + 1) | \(fmt(bounds[k].end)) | \(fmt(live[k])) | \(fmt(app[k])) | \(fmt(eng[k])) | \(refs[k]) |")
        }
        lines.append("")
        lines.append("App 切出来的句子：")
        lines.append("")
        for p in appPieces { lines.append("- [\(fmt(p.at))] \(p.text)") }
        lines.append("")
        return lines
    }

    static func cumulative(_ texts: [String]) -> [Int] {
        var sum = 0
        return texts.map { sum += TextTools.letterCount($0); return sum }
    }

    /// 苹果系统翻译：GitHub 的 Mac 上一般没有预装韩中语言包，有就顺便测一下每句用时。
    static func translation(_ refs: [String]) async -> [String] {
        let ko = Locale.Language(identifier: "ko"), zh = Locale.Language(identifier: "zh-Hans")
        let status = await LanguageAvailability().status(from: ko, to: zh)
        var lines = ["### 苹果系统翻译（韩 → 中）", ""]
        switch status {
        case .installed:
            let session = TranslationSession(installedSource: ko, target: zh)
            let clock = ContinuousClock()
            var times: [Double] = []
            for s in refs {
                let t = clock.now
                if let r = try? await session.translate(s) {
                    let d = clock.now - t
                    times.append(Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18)
                    lines.append("- \(s) → \(r.targetText)")
                }
            }
            lines.append("- 每句用时中位数 **\(fmt(median(times)))** 秒")
        case .supported:
            lines.append("- 这台 Mac 没装韩中翻译包（只能在系统设置里点下载，命令行装不了），跳过。iPad 上第一次用时会弹出下载。")
        case .unsupported:
            lines.append("- 不支持韩 → 中。")
        @unknown default:
            lines.append("- 状态未知。")
        }
        return lines
    }

    // MARK: 小工具

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

    static func median(_ v: [Double]) -> Double? {
        guard !v.isEmpty else { return nil }
        let s = v.sorted()
        return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
    }

    static func fmt(_ v: Double?) -> String { v.map { String(format: "%.2f", $0) } ?? "-" }

    /// 开始计时的时刻（识别结果在另一个任务里读它）
    final class SharedInstant: @unchecked Sendable {
        private let lock = NSLock()
        private var start = ContinuousClock().now
        func reset(_ clock: ContinuousClock) { lock.withLock { start = clock.now } }
        func since(_ clock: ContinuousClock) -> Double {
            let d = clock.now - lock.withLock { start }
            return Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
        }
    }
}
