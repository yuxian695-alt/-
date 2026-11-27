import Foundation
import SwiftUI
import UIKit
import Speech

/// 音频线程和主线程之间传东西用的小盒子
final class SharedBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T
    init(_ value: T) { self.value = value }
    func get() -> T { lock.lock(); defer { lock.unlock() }; return value }
    func set(_ newValue: T) { lock.lock(); value = newValue; lock.unlock() }
}

/// 上课时变得很快的东西（计时、音量、正在说的话）单独放，免得整张字幕表跟着一起刷新。
@MainActor
final class LiveNow: ObservableObject {
    @Published var elapsed: Double = 0
    @Published var level: Float = 0
    @Published var gainDb: Float = 0
    @Published var source = ""
    @Published var target = ""
}

/// 一节课从开始到结束：麦克风 → 识别 → 切句 → 术语替换 → 翻译 → 保存。
@MainActor
final class LiveController: ObservableObject {
    enum Phase: Equatable { case idle, starting, running, paused, stopping }

    @Published private(set) var phase: Phase = .idle
    @Published var presented = false
    @Published private(set) var current: ClassSession?
    @Published private(set) var status = ""
    @Published var notice: String?
    @Published var startError: String?
    @Published var finishedID: UUID?
    let now = LiveNow()

    private let store: Store
    private let translator: TranslationService
    private var capture: AudioCapture?
    private let recognizer = SharedBox<LiveRecognizer?>(nil)
    private let levelBox = SharedBox<Float>(0)
    private var offset: Double = 0
    private var terms: [Term] = []
    private var liveTranslate = true
    private var volatileGen = 0
    private var lastVolatileSent = ""
    private var lastVolatileAt = Date.distantPast
    private var ticker: Task<Void, Never>?
    private var dirty = false
    private var lastSave = Date()
    private var inFlight = 0
    private var fellBack = false

    init(store: Store, translator: TranslationService) {
        self.store = store
        self.translator = translator
    }

    var isLive: Bool { phase == .running || phase == .paused }

    // MARK: 开始

    func start(pair: LanguagePair, course: String) async {
        guard phase == .idle else { return }
        phase = .starting
        presented = true
        notice = nil
        startError = nil
        fellBack = false
        status = "正在打开麦克风…"
        do {
            guard await AudioCapture.requestPermission() else { throw CaptureError.noPermission }
            status = "正在准备语音识别…"
            let speechOK = await SpeechPermission.request()
            terms = store.terms(for: course)
            liveTranslate = Prefs.bool(Prefs.liveTranslate, default: true)
            translator.configure(source: pair.source, target: pair.target)

            offset = 0
            let rec = try await makeRecognizer(pair, speechAuthorized: speechOK)
            let record = Prefs.bool(Prefs.record, default: true)
            var s = ClassSession(title: Self.title(course), course: course, started: Date(),
                                 sourceLang: pair.source, targetLang: pair.target)
            s.engine = rec.name
            s.hasAudio = record
            current = s

            status = "正在开始录音…"
            let cap = AudioCapture(startGainDb: Float(Prefs.double(Prefs.startGain, default: 12)),
                                   autoGain: Prefs.bool(Prefs.autoGain, default: true))
            Self.wire(cap, recognizer, levelBox)
            cap.onInterrupted = { [weak self] message in self?.notice = message }
            try cap.start(recordTo: record ? store.segmentFolder(s.id) : nil)
            capture = cap
            store.save(s)
            lastSave = Date()
            UIApplication.shared.isIdleTimerDisabled = true
            phase = .running
            status = ""
            startTicker()
        } catch {
            await teardown()
            phase = .idle
            presented = false
            // 等全屏界面收起来再弹提示，不然提示框可能弹不出来
            try? await Task.sleep(nanoseconds: 700_000_000)
            startError = error.localizedDescription
        }
    }

    /// 音频线程上直接把声音交给当前的识别引擎（不经过主线程，延迟最低）。
    nonisolated private static func wire(_ cap: AudioCapture, _ box: SharedBox<LiveRecognizer?>, _ level: SharedBox<Float>) {
        cap.onBuffer = { buffer in box.get()?.append(buffer) }
        cap.onLevel = { peak in level.set(peak) }
    }

    private func makeRecognizer(_ pair: LanguagePair, speechAuthorized: Bool) async throws -> LiveRecognizer {
        let locale = Locale(identifier: pair.source)
        let hints = terms.map(\.source)
        #if compiler(>=6.2)
        if #available(iOS 26.0, *), !Prefs.bool(Prefs.legacyEngine, default: false) {
            if await AnalyzerRecognizer.resolve(locale) != nil {
                let r = AnalyzerRecognizer(locale: locale, contextual: hints)
                attach(r)
                do {
                    status = "正在准备离线识别（第一次用要下载，需 Wi-Fi）…"
                    try await r.start()
                    return r
                } catch {
                    r.onUpdate = nil
                    r.onError = nil
                    notice = "新版识别没能启动（\(error.localizedDescription)），已改用旧版识别。"
                }
            }
        }
        #endif
        guard speechAuthorized else { throw RecognizerError.notAuthorized }
        guard let r = LegacyRecognizer(locale: locale, contextual: hints) else { throw RecognizerError.unsupported(pair.label) }
        attach(r)
        try await r.start()
        return r
    }

    private func attach(_ r: LiveRecognizer) {
        r.onUpdate = { [weak self] update in self?.handle(update) }
        r.onError = { [weak self] error in self?.recognizerFailed(error) }
        recognizer.set(r)
    }

    /// 新版识别中途出错：自动换旧版接着听，不用老师停下来。
    private func recognizerFailed(_ error: Error) {
        guard isLive, !fellBack, let s = current else {
            notice = "识别出错：\(error.localizedDescription)"
            return
        }
        fellBack = true
        notice = "识别引擎出错，已自动换成旧版识别继续听。"
        Task { [weak self] in
            guard let self else { return }
            let old = self.recognizer.get()
            old?.onUpdate = nil
            old?.onError = nil
            self.recognizer.set(nil)
            await old?.finish()
            guard self.isLive,
                  let r = LegacyRecognizer(locale: Locale(identifier: s.sourceLang), contextual: self.terms.map(\.source)) else { return }
            self.offset = self.capture?.elapsed ?? 0
            self.attach(r)
            do {
                try await r.start()
                self.current?.engine = r.name
            } catch {
                self.notice = "识别停了：\(error.localizedDescription)。请结束后重新开始。"
            }
        }
    }

    // MARK: 识别结果

    private func handle(_ u: RecognitionUpdate) {
        guard current != nil, phase != .idle else { return }
        let text = TextTools.clean(u.text)
        if !u.isFinal {
            now.source = text
            if text.isEmpty { now.target = "" }
            sendVolatile(force: false)
            return
        }
        volatileGen += 1
        now.source = ""
        now.target = ""
        lastVolatileSent = ""
        translator.dropVolatile()
        guard !TextTools.isFiller(text) else { return }

        let heard = capture?.elapsed ?? now.elapsed
        let end = u.end.map { $0 + offset } ?? heard
        let start = u.start.map { $0 + offset } ?? max(0, end - Double(TextTools.letterCount(text)) * 0.12)
        let audioDelay = max(0, heard - end)
        let arrived = Date()
        let pieces = TextTools.splitSentences(text)
        let total = max(1, pieces.reduce(0) { $0 + TextTools.letterCount($1) })
        var t = start
        for p in pieces {
            let share = max(0, end - start) * Double(TextTools.letterCount(p)) / Double(total)
            let line = Line(start: t, end: t + share, source: p)
            t += share
            current?.lines.append(line)
            // 延迟 = 这句说完 → 中文出现
            translate(line, extraLag: (end - line.end) + audioDelay, arrived: arrived)
        }
        dirty = true
    }

    private func translate(_ line: Line, extraLag: Double, arrived: Date) {
        let input = TextTools.applyGlossary(line.source, terms: terms)
        inFlight += 1
        Task { [weak self] in
            guard let self else { return }
            let out = await self.translator.translate(input)
            self.inFlight -= 1
            guard let out, !out.isEmpty,
                  let i = self.current?.lines.firstIndex(where: { $0.id == line.id }) else { return }
            self.current?.lines[i].target = out
            self.current?.lines[i].lag = max(0, extraLag) + Date().timeIntervalSince(arrived)
            self.dirty = true
        }
    }

    /// 老师还没说完就先翻：最多每 0.45 秒一次，而且要多出几个字才再翻。
    private func sendVolatile(force: Bool) {
        guard liveTranslate, translator.state == .ready else { return }
        let text = now.source
        guard TextTools.letterCount(text) >= 2, text != lastVolatileSent else { return }
        let at = Date()
        if !force {
            guard at.timeIntervalSince(lastVolatileAt) >= 0.45,
                  TextTools.worthRetranslating(old: lastVolatileSent, new: text) else { return }
        }
        lastVolatileAt = at
        lastVolatileSent = text
        let gen = volatileGen
        translator.translateVolatile(TextTools.applyGlossary(text, terms: terms)) { [weak self] out in
            guard let self, self.volatileGen == gen, !self.now.source.isEmpty else { return }
            self.now.target = out
        }
    }

    private func startTicker() {
        ticker?.cancel()
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 200_000_000)
                self?.tick()
            }
        }
    }

    private func tick() {
        guard let capture else { return }
        now.elapsed = capture.elapsed
        now.level = levelBox.get()
        now.gainDb = capture.gainDb
        if !now.source.isEmpty, now.source != lastVolatileSent, Date().timeIntervalSince(lastVolatileAt) >= 0.45 {
            sendVolatile(force: true)
        }
        // 每 10 秒自动存一次，App 万一被关掉也不丢字幕
        if dirty, Date().timeIntervalSince(lastSave) > 10, var s = current {
            s.duration = now.elapsed
            store.save(s)
            dirty = false
            lastSave = Date()
        }
    }

    // MARK: 上课中的操作

    func togglePause() {
        guard let capture else { return }
        if phase == .running {
            capture.paused = true
            phase = .paused
            volatileGen += 1
            now.source = ""
            now.target = ""
        } else if phase == .paused {
            capture.paused = false
            phase = .running
        }
    }

    func toggleStar(_ id: UUID) {
        guard let i = current?.lines.firstIndex(where: { $0.id == id }) else { return }
        current?.lines[i].starred.toggle()
        dirty = true
    }

    func stop() async {
        guard isLive else { return }
        phase = .stopping
        ticker?.cancel()
        let cap = capture
        cap?.stop()
        let rec = recognizer.get()
        await rec?.finish()          // 最后几句定稿
        recognizer.set(nil)
        let deadline = Date().addingTimeInterval(8)
        while inFlight > 0 && Date() < deadline {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        if var s = current {
            s.duration = cap?.elapsed ?? now.elapsed
            store.save(s)
            finishedID = s.id
            if s.hasAudio {
                let id = s.id
                let store = self.store
                Task { await store.mergeAudio(id) }
            }
        }
        await teardown()
        phase = .idle
        presented = false
    }

    private func teardown() async {
        ticker?.cancel()
        ticker = nil
        capture?.stop()
        capture = nil
        if let rec = recognizer.get() {
            rec.onUpdate = nil
            rec.onError = nil
            recognizer.set(nil)
            await rec.finish()
        }
        current = nil
        now.source = ""
        now.target = ""
        now.level = 0
        now.elapsed = 0
        inFlight = 0
        UIApplication.shared.isIdleTimerDisabled = false
    }

    static func title(_ course: String) -> String {
        let df = DateFormatter()
        df.locale = Locale(identifier: "zh_CN")
        df.dateFormat = "M月d日 HH:mm"
        let when = df.string(from: Date())
        return course.isEmpty ? "课堂 \(when)" : "\(course) \(when)"
    }
}

/// 首页“上课前检查”：识别包、翻译包、本机 AI 是否就绪。
@MainActor
final class Readiness: ObservableObject {
    enum Item: Equatable {
        case checking
        case ready(String)
        case action(String, String)      // 说明，按钮
        case working(String)
        case unavailable(String)
    }

    @Published var speech: Item = .checking
    @Published var translation: Item = .checking
    @Published var ai: Item = .checking
    private var downloading = false

    var translationNeedsDownload: Bool {
        if case .action = translation { return true }
        return false
    }

    func refresh(_ pair: LanguagePair, translator: TranslationService) async {
        if let why = LocalAI.unavailableReason { ai = .unavailable(why) } else { ai = .ready("课后概括、解释句子可用") }
        if !downloading { speech = await Self.speechState(pair) }
        translation = await Self.translationState(pair, translator)
    }

    static func speechState(_ pair: LanguagePair) async -> Item {
        let locale = Locale(identifier: pair.source)
        #if compiler(>=6.2)
        if #available(iOS 26.0, *), !Prefs.bool(Prefs.legacyEngine, default: false) {
            if let resolved = await AnalyzerRecognizer.resolve(locale) {
                if await AnalyzerRecognizer.isInstalled(resolved) { return .ready("新版离线识别已就绪") }
                return .action("新版离线识别要先下载一次（需 Wi-Fi）", "下载")
            }
        }
        #endif
        guard let r = SFSpeechRecognizer(locale: locale) else { return .unavailable("这台 iPad 不支持识别这种语言") }
        return r.supportsOnDeviceRecognition ? .ready("旧版离线识别可用") : .ready("旧版识别可用（需要联网）")
    }

    static func translationState(_ pair: LanguagePair, _ t: TranslationService) async -> Item {
        if let p = t.pair, p.source == pair.source, p.target == pair.target {
            switch t.state {
            case .preparing: return .working("正在准备翻译…第一次会弹出下载提示")
            case .failed(let m): return .action(m, "重试")
            default: break
            }
        }
        switch await TranslationService.availability(source: pair.source, target: pair.target) {
        case .installed: return .ready("离线翻译已就绪")
        case .supported: return .action("离线翻译语言包要先下载一次（需 Wi-Fi）", "下载")
        case .unsupported: return .unavailable("系统翻译不支持这对语言")
        @unknown default: return .unavailable("系统翻译暂时不可用")
        }
    }

    func downloadSpeech(_ pair: LanguagePair) async {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            downloading = true
            speech = .working("正在下载 0%")
            do {
                try await AnalyzerRecognizer.download(Locale(identifier: pair.source)) { [weak self] p in
                    self?.speech = .working("正在下载 \(Int(p * 100))%")
                }
                speech = .ready("新版离线识别已就绪")
            } catch {
                speech = .action(error.localizedDescription, "重试")
            }
            downloading = false
        }
        #endif
    }

    func downloadTranslation(_ pair: LanguagePair, translator: TranslationService) {
        translation = .working("正在准备翻译…请在弹出的窗口里点“下载”")
        if let p = translator.pair, p.source == pair.source, p.target == pair.target {
            translator.retry()
        } else {
            translator.configure(source: pair.source, target: pair.target)
        }
    }
}
