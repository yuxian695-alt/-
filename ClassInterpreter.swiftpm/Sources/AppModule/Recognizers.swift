import AVFoundation
import Speech
import CoreMedia

struct RecognitionUpdate {
    var text: String
    var isFinal: Bool
    /// 在这节课音频里的起止秒数（不含暂停）
    var start: Double?
    var end: Double?
}

enum RecognizerError: LocalizedError {
    case notAuthorized, unavailable, unsupported(String), assets(String)
    var errorDescription: String? {
        switch self {
        case .notAuthorized: return "没有语音识别权限。请到 设置 → 隐私与安全性 → 语音识别，打开“课堂同传”。"
        case .unavailable: return "这台 iPad 上的语音识别暂时不可用，请稍后再试。"
        case .unsupported(let l): return "这台 iPad 不支持离线识别 \(l)。"
        case .assets(let m): return "下载离线识别包失败：\(m)。请连上 Wi-Fi 后再试。"
        }
    }
}

/// 两种识别引擎的共同样子：喂声音进去，拿到“临时结果 / 定稿结果”。
protocol LiveRecognizer: AnyObject {
    var name: String { get }
    /// 在主线程上调用
    var onUpdate: ((RecognitionUpdate) -> Void)? { get set }
    var onError: ((Error) -> Void)? { get set }
    func start() async throws
    /// 在音频线程上调用
    func append(_ buffer: AVAudioPCMBuffer)
    func finish() async
}

enum SpeechPermission {
    static func request() async -> Bool {
        let status = await withCheckedContinuation { (c: CheckedContinuation<SFSpeechRecognizerAuthorizationStatus, Never>) in
            SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0) }
        }
        return status == .authorized
    }
}

// MARK: - 新版：iPadOS 26 起的 SpeechAnalyzer / SpeechTranscriber（为讲座这类长语音设计，完全在本机）

#if compiler(>=6.2)
@available(iOS 26.0, *)
final class AnalyzerRecognizer: LiveRecognizer, @unchecked Sendable {
    let name = "苹果离线识别"
    var onUpdate: ((RecognitionUpdate) -> Void)?
    var onError: ((Error) -> Void)?

    private let locale: Locale
    private let contextual: [String]
    private var transcriber: SpeechTranscriber?
    private var analyzer: SpeechAnalyzer?
    private var format: AVAudioFormat?
    private var input: AsyncStream<AnalyzerInput>.Continuation?
    private var resultsTask: Task<Void, Never>?
    private let converter = BufferConverter()
    private let lock = NSLock()

    init(locale: Locale, contextual: [String] = []) {
        self.locale = locale
        self.contextual = Array(contextual.filter { !$0.isEmpty }.prefix(100))
    }

    /// 这台设备支持的、和要求的语言对应的地区（例如要 ko-KR 就找 ko-KR，没有就找任何 ko）。
    static func resolve(_ locale: Locale) async -> Locale? {
        let all = await SpeechTranscriber.supportedLocales
        let want = locale.identifier(.bcp47)
        if let exact = all.first(where: { $0.identifier(.bcp47) == want }) { return exact }
        let lang = locale.language.languageCode?.identifier
        return all.first { $0.language.languageCode?.identifier == lang }
    }

    static func isInstalled(_ locale: Locale) async -> Bool {
        let want = locale.identifier(.bcp47)
        let installed = await SpeechTranscriber.installedLocales
        return installed.contains { $0.identifier(.bcp47) == want }
    }

    private static func makeTranscriber(_ locale: Locale) -> SpeechTranscriber {
        SpeechTranscriber(locale: locale,
                          transcriptionOptions: [],
                          reportingOptions: [.volatileResults, .fastResults],
                          attributeOptions: [.audioTimeRange])
    }

    /// 第一次用某种语言时下载离线识别包（需要 Wi-Fi，之后不用联网）。
    static func download(_ locale: Locale, progress: @escaping (Double) -> Void) async throws {
        guard let resolved = await resolve(locale) else { throw RecognizerError.unsupported(locale.identifier) }
        let module = makeTranscriber(resolved)
        do {
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
                let p = request.progress
                let watcher = Task { @MainActor in
                    while !Task.isCancelled && p.fractionCompleted < 1 {
                        progress(p.fractionCompleted)
                        try? await Task.sleep(nanoseconds: 300_000_000)
                    }
                }
                defer { watcher.cancel() }
                try await request.downloadAndInstall()
            }
            progress(1)
        } catch {
            throw RecognizerError.assets(error.localizedDescription)
        }
    }

    func start() async throws {
        guard let resolved = await Self.resolve(locale) else { throw RecognizerError.unsupported(locale.identifier) }
        if !(await Self.isInstalled(resolved)) {
            try await Self.download(resolved) { _ in }
        }
        let module = Self.makeTranscriber(resolved)
        let analyzer = SpeechAnalyzer(modules: [module])
        if !contextual.isEmpty {
            // 课程术语表里的原文词：让识别更容易认出专业词
            let context = AnalysisContext()
            context.contextualStrings[.general] = contextual
            try? await analyzer.setContext(context)
        }
        let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module])
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        lock.withLock {
            self.transcriber = module
            self.analyzer = analyzer
            self.format = format
            self.input = continuation
        }

        resultsTask = Task { [weak self] in
            do {
                for try await result in module.results {
                    let text = String(result.text.characters)
                    let s = result.range.start.seconds, e = result.range.end.seconds
                    let update = RecognitionUpdate(text: text, isFinal: result.isFinal,
                                                   start: s.isFinite ? s : nil, end: e.isFinite ? e : nil)
                    await self?.deliver(update)
                }
            } catch is CancellationError {
                // 下课时等得太久被取消：不算出错
            } catch {
                await self?.deliver(error)
            }
        }
        try await analyzer.start(inputSequence: stream)
    }

    @MainActor private func deliver(_ update: RecognitionUpdate) { onUpdate?(update) }
    @MainActor private func deliver(_ error: Error) { onError?(error) }

    func append(_ buffer: AVAudioPCMBuffer) {
        let (format, input) = lock.withLock { (self.format, self.input) }
        guard let input else { return }
        do {
            var converted = try format.map { try converter.convert(buffer, to: $0) } ?? buffer
            // 格式刚好一样时拿到的是麦克风的原始缓冲区，系统会重复使用它：复制一份再交出去
            if converted === buffer, let copy = Self.copy(buffer) { converted = copy }
            input.yield(AnalyzerInput(buffer: converted))
        } catch {
            // 一块声音转换失败只丢这一块
        }
    }

    private static func copy(_ b: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let out = AVAudioPCMBuffer(pcmFormat: b.format, frameCapacity: b.frameLength) else { return nil }
        out.frameLength = b.frameLength
        let src = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: b.audioBufferList))
        let dst = UnsafeMutableAudioBufferListPointer(out.mutableAudioBufferList)
        for (s, d) in zip(src, dst) {
            guard let sp = s.mData, let dp = d.mData else { return nil }
            memcpy(dp, sp, Int(min(s.mDataByteSize, d.mDataByteSize)))
        }
        return out
    }

    func finish() async {
        let (input, analyzer) = lock.withLock { () -> (AsyncStream<AnalyzerInput>.Continuation?, SpeechAnalyzer?) in
            defer { self.input = nil }
            return (self.input, self.analyzer)
        }
        input?.finish()
        try? await analyzer?.finalizeAndFinishThroughEndOfInput()
        // 等最后几句定稿送达
        if let task = resultsTask {
            let waiter = Task { await task.value }
            let timeout = Task { try? await Task.sleep(nanoseconds: 4_000_000_000); task.cancel() }
            await waiter.value
            timeout.cancel()
        }
        resultsTask = nil
    }
}
#endif

// MARK: - 旧版：SFSpeechRecognizer（iPadOS 18～25 或新版不支持该语言时使用）

final class LegacyRecognizer: LiveRecognizer, @unchecked Sendable {
    let name: String
    var onUpdate: ((RecognitionUpdate) -> Void)?
    var onError: ((Error) -> Void)?

    private let recognizer: SFSpeechRecognizer
    private let contextual: [String]
    private let lock = NSLock()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var fed: Double = 0                 // 已经喂进去的秒数（音频线程写）
    private var requestStart: Double = 0
    private var lastText = ""
    private var lastChange = Date()
    private var opened = Date()
    private var timer: Timer?
    private var running = false

    init?(locale: Locale, contextual: [String]) {
        guard let r = SFSpeechRecognizer(locale: locale) else { return nil }
        recognizer = r
        self.contextual = Array(contextual.prefix(100))
        name = r.supportsOnDeviceRecognition ? "苹果离线识别（旧版）" : "苹果识别（需联网）"
    }

    func start() async throws {
        guard await SpeechPermission.request() else { throw RecognizerError.notAuthorized }
        guard recognizer.isAvailable else { throw RecognizerError.unavailable }
        await MainActor.run {
            self.running = true
            self.begin()
            self.timer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in self?.tick() }
        }
    }

    private func begin() {
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition { req.requiresOnDeviceRecognition = true }
        req.addsPunctuation = true
        req.taskHint = .dictation
        req.contextualStrings = contextual
        lock.lock(); request = req; requestStart = fed; lock.unlock()
        lastText = ""; lastChange = Date(); opened = Date()
        task = recognizer.recognitionTask(with: req) { [weak self] result, error in
            DispatchQueue.main.async { self?.handle(result, error, req) }
        }
    }

    private func handle(_ result: SFSpeechRecognitionResult?, _ error: Error?, _ req: SFSpeechAudioBufferRecognitionRequest) {
        lock.lock(); let current = request; let base = requestStart; lock.unlock()
        guard req === current, running else { return }
        if let result {
            let text = result.bestTranscription.formattedString
            let segs = result.bestTranscription.segments
            let s = base + (segs.first?.timestamp ?? 0)
            let e = base + ((segs.last.map { $0.timestamp + $0.duration }) ?? 0)
            if result.isFinal {
                commit(text, s, e)
                rotate(commitFirst: false)
                return
            }
            if text != lastText { lastText = text; lastChange = Date() }
            onUpdate?(RecognitionUpdate(text: text, isFinal: false, start: s, end: e))
        } else if error != nil {
            // 常见的是“没听到说话”：换一个新的请求接着听
            if !lastText.isEmpty { commit(lastText, base, fedSeconds) }
            rotate(commitFirst: false)
        }
    }

    private var fedSeconds: Double { lock.lock(); defer { lock.unlock() }; return fed }

    private func commit(_ text: String, _ s: Double, _ e: Double) {
        let t = text.trimmingCharacters(in: .whitespaces)
        lastText = ""
        if !t.isEmpty { onUpdate?(RecognitionUpdate(text: t, isFinal: true, start: s, end: e)) }
    }

    /// 停顿 1.2 秒就把这句定稿；一个请求最长 50 秒，避免系统的时长限制。
    private func tick() {
        guard running else { return }
        let paused = !lastText.isEmpty && Date().timeIntervalSince(lastChange) > 1.2
        let tooLong = Date().timeIntervalSince(opened) > 50 && !lastText.isEmpty
        if paused || tooLong { rotate(commitFirst: true) }
    }

    private func rotate(commitFirst: Bool) {
        guard running else { return }
        if commitFirst, !lastText.isEmpty {
            lock.lock(); let base = requestStart; lock.unlock()
            commit(lastText, base, fedSeconds)
        }
        lock.lock(); let old = request; lock.unlock()
        let oldTask = task
        begin()
        old?.endAudio()
        oldTask?.cancel()
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        let req = request
        fed += Double(buffer.frameLength) / buffer.format.sampleRate
        lock.unlock()
        req?.append(buffer)
    }

    func finish() async {
        await MainActor.run {
            self.timer?.invalidate(); self.timer = nil
            if !self.lastText.isEmpty {
                self.lock.lock(); let base = self.requestStart; self.lock.unlock()
                self.commit(self.lastText, base, self.fedSeconds)
            }
            self.running = false
            self.lock.lock(); let req = self.request; self.request = nil; self.lock.unlock()
            req?.endAudio()
            self.task?.cancel(); self.task = nil
        }
    }
}
