import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// 课后用 iPad 本机的 Apple 智能模型做概括、解释句子。完全离线、不花钱；
/// 设备或系统没开 Apple 智能时，这些按钮会说明原因并保持不可用，不影响上课同传。
enum LocalAI {
    enum Failure: LocalizedError {
        case unavailable(String), empty
        var errorDescription: String? {
            switch self {
            case .unavailable(let why): return why
            case .empty: return "这节课还没有字幕。"
            }
        }
    }

    /// nil 表示可以用；否则是不能用的原因。
    static var unavailableReason: String? {
        #if canImport(FoundationModels) && compiler(>=6.2)
        if #available(iOS 26.0, *) {
            switch SystemLanguageModel.default.availability {
            case .available:
                return nil
            case .unavailable(let reason):
                switch reason {
                case .deviceNotEligible: return "这台 iPad 不支持 Apple 智能。"
                case .appleIntelligenceNotEnabled: return "请到 设置 → Apple 智能与 Siri 打开 Apple 智能。"
                case .modelNotReady: return "Apple 智能模型还在下载，请连上 Wi-Fi 稍后再试。"
                @unknown default: return "Apple 智能暂时不可用。"
                }
            @unknown default:
                return "Apple 智能暂时不可用。"
            }
        }
        #endif
        return "需要 iPadOS 26 以上的 Apple 智能。"
    }

    static var isAvailable: Bool { unavailableReason == nil }

    private static let summaryRules = """
    你是认真负责的大学助教。下面是一节课的同传字幕（可能有识别错字）。
    请用简体中文整理：先写一句话说明这节课讲什么，再列出 3 到 8 条要点（每条一行，以“- ”开头），
    最后列出老师强调的作业、考试、截止时间（没有就写“无”）。不要编造字幕里没有的内容。
    """

    /// 按段概括，再把各段合成一份。字幕优先用中文那一侧。
    static func summarize(_ lines: [String]) async throws -> String {
        let usable = lines.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard !usable.isEmpty else { throw Failure.empty }
        if let why = unavailableReason { throw Failure.unavailable(why) }
        #if canImport(FoundationModels) && compiler(>=6.2)
        if #available(iOS 26.0, *) {
            let parts = TextTools.chunks(usable, maxChars: 1400)
            if parts.count == 1 { return try await ask(summaryRules, parts[0]) }
            var partial: [String] = []
            for (i, p) in parts.enumerated() {
                let s = try await ask("""
                你是认真负责的大学助教。下面是一节课第 \(i + 1)/\(parts.count) 段的同传字幕（可能有识别错字）。
                用简体中文列出这一段的要点，最多 6 条，每条一行，以“- ”开头。不要编造。
                """, p)
                partial.append(s)
            }
            let merged = TextTools.chunks(partial, maxChars: 2400).first ?? partial.joined(separator: "\n")
            return try await ask(summaryRules + "\n下面给你的已经是分段要点，请合并去重。", merged)
        }
        #endif
        throw Failure.unavailable("需要 iPadOS 26 以上的 Apple 智能。")
    }

    /// 解释一句话：生词、语法、老师的语气。
    static func explain(source: String, translation: String) async throws -> String {
        if let why = unavailableReason { throw Failure.unavailable(why) }
        #if canImport(FoundationModels) && compiler(>=6.2)
        if #available(iOS 26.0, *) {
            return try await ask("""
            你是耐心的语言老师，学生是中国留学生。用简体中文简短解释这句课堂原话：
            1) 关键生词和意思；2) 句子结构或语法点；3) 老师的语气（例如是在强调、提醒还是举例）。
            控制在 150 字以内。
            """, "原话：\(source)\n参考译文：\(translation)")
        }
        #endif
        throw Failure.unavailable("需要 iPadOS 26 以上的 Apple 智能。")
    }

    #if canImport(FoundationModels) && compiler(>=6.2)
    @available(iOS 26.0, *)
    private static func ask(_ instructions: String, _ text: String) async throws -> String {
        let session = LanguageModelSession(instructions: instructions)
        let response = try await session.respond(to: text)
        return response.content.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    #endif
}
