import Foundation
import SwiftUI
import Translation

/// 苹果系统翻译：完全在 iPad 本机，第一次下载语言包以后不用联网，也不花钱。
///
/// SwiftUI 的 `.translationTask` 交给我们一个 TranslationSession，`serve` 用一个循环一直为它干活：
/// 定稿的句子先翻（排队、一句不丢），“正在说”的临时结果只翻最新的那一版（旧的直接丢掉，保证不越积越慢）。
@MainActor
final class TranslationService: ObservableObject {
    enum State: Equatable {
        case idle, preparing, ready
        case failed(String)
    }

    @Published var config: TranslationSession.Configuration?
    @Published private(set) var state: State = .idle
    private(set) var pair: (source: String, target: String)?

    private struct Job { let id: UUID; let text: String; let cont: CheckedContinuation<String?, Never> }
    private var finals: [Job] = []
    private var volatile: (text: String, done: (String) -> Void)?
    private var generation = 0

    /// 例如 ko-KR → zh-Hans。同一对语言重复调用不会重新准备。
    func configure(source: String, target: String) {
        if let pair, pair.source == source, pair.target == target, config != nil {
            if case .failed = state { retry() }
            return
        }
        drain()         // 换了语言：还没翻的旧句子不能用新语言去翻
        pair = (source, target)
        state = .preparing
        config = TranslationSession.Configuration(source: Self.language(source), target: Self.language(target))
    }

    /// 再准备一次（例如刚才取消了下载）。
    func retry() {
        guard config != nil else { return }
        state = .preparing
        config?.invalidate()
    }

    static func language(_ code: String) -> Locale.Language {
        switch code {
        case "zh-CN", "zh-Hans", "zh": return Locale.Language(identifier: "zh-Hans")
        case "zh-TW", "zh-Hant": return Locale.Language(identifier: "zh-Hant")
        case "en-US": return Locale.Language(identifier: "en-US")
        case "en-GB": return Locale.Language(identifier: "en-GB")
        default: return Locale.Language(identifier: String(code.split(separator: "-").first ?? Substring(code)))
        }
    }

    /// 这对语言在本机的情况：已下载 / 可下载 / 不支持。
    static func availability(source: String, target: String) async -> LanguageAvailability.Status {
        await LanguageAvailability().status(from: language(source), to: language(target))
    }

    /// 翻译一句定稿的话。翻不出来（例如语言包没下载）返回 nil，课后可以在记录里重译。
    func translate(_ text: String) async -> String? {
        if case .failed = state { return nil }
        guard config != nil else { return nil }
        let id = UUID()
        return await withCheckedContinuation { (c: CheckedContinuation<String?, Never>) in
            finals.append(Job(id: id, text: text, cont: c))
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                self?.expire(id)
            }
        }
    }

    /// 翻译“正在说”的临时结果：只保留最新一版，翻完在主线程回调。
    func translateVolatile(_ text: String, done: @escaping (String) -> Void) {
        guard state == .ready else { return }
        volatile = (text, done)
    }

    func dropVolatile() { volatile = nil }

    private func expire(_ id: UUID) {
        if let i = finals.firstIndex(where: { $0.id == id }) {
            finals.remove(at: i).cont.resume(returning: nil)
        }
    }

    private func drain() {
        let jobs = finals
        finals.removeAll()
        volatile = nil
        for j in jobs { j.cont.resume(returning: nil) }
    }

    /// 由 RootView 的 `.translationTask` 调用；换语言或重试时系统会取消旧的、再调一次新的。
    func serve(_ session: TranslationSession) async {
        generation += 1
        let me = generation
        state = .preparing
        do {
            // 语言包没下载时，系统会弹出下载提示（只需要一次，之后完全离线）
            try await session.prepareTranslation()
        } catch {
            if generation == me {
                state = .failed(Self.describe(error))
                drain()
            }
            return
        }
        guard generation == me else { return }
        state = .ready
        while !Task.isCancelled && generation == me {
            if !finals.isEmpty {
                let job = finals.removeFirst()
                let out = try? await session.translate(job.text)
                job.cont.resume(returning: out?.targetText)
                continue
            }
            if let v = volatile {
                volatile = nil
                if let out = try? await session.translate(v.text), generation == me {
                    v.done(out.targetText)
                }
                continue
            }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        if generation == me {
            state = .idle
            drain()
        }
    }

    static func describe(_ error: Error) -> String {
        let text = error.localizedDescription
        if text.contains("cancel") || text.contains("取消") { return "没有下载翻译语言包（刚才取消了）。" }
        return text
    }
}
