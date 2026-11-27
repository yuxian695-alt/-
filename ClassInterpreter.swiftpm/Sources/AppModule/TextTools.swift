import Foundation

// 纯文本工具：只依赖 Foundation，可以在任何平台上单独测试（见仓库根目录的 Package.swift）。

public struct Term: Equatable {
    public var source: String
    public var target: String
    public init(source: String, target: String) { self.source = source; self.target = target }
}

public enum TextTools {

    /// "수요=需求" 一行一个；也接受 → -> 和制表符，分号也能分行。
    public static func parseTerms(_ text: String) -> [Term] {
        var out: [Term] = []
        let rows = text.components(separatedBy: CharacterSet(charactersIn: "\n;；"))
        for raw in rows {
            var row = raw.trimmingCharacters(in: .whitespaces)
            if row.isEmpty { continue }
            row = row.replacingOccurrences(of: "->", with: "=").replacingOccurrences(of: "→", with: "=").replacingOccurrences(of: "\t", with: "=")
            let parts = row.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
            guard let first = parts.first, !first.isEmpty else { continue }
            out.append(Term(source: first, target: parts.count > 1 ? parts[1] : ""))
        }
        return out
    }

    /// 翻译前把术语原文换成指定译名（长的先换），系统翻译会原样保留这些中文词。
    public static func applyGlossary(_ text: String, terms: [Term]) -> String {
        var result = text
        let usable = terms.filter { !$0.source.isEmpty && !$0.target.isEmpty }.sorted { $0.source.count > $1.source.count }
        for t in usable {
            result = result.replacingOccurrences(of: t.source, with: t.target, options: [.caseInsensitive])
        }
        return result
    }

    /// 识别结果里最多保留两次连着的重复（“네 네 네 네” → “네 네”）。
    public static func collapseRepeats(_ text: String) -> String {
        let words = text.split(whereSeparator: { $0 == " " }).map(String.init)
        guard words.count > 2 else { return text }
        var out: [String] = []
        var i = 0
        while i < words.count {
            var matched = false
            for n in 1...3 where i + n * 3 <= words.count {
                let unit = Array(words[i..<(i + n)])
                var reps = 1
                while i + (reps + 1) * n <= words.count && Array(words[(i + reps * n)..<(i + (reps + 1) * n)]) == unit { reps += 1 }
                if reps >= 3 {
                    out += unit; out += unit
                    i += reps * n
                    matched = true
                    break
                }
            }
            if !matched { out.append(words[i]); i += 1 }
        }
        return out.joined(separator: " ")
    }

    private static let fillers: Set<String> = ["음", "어", "그", "아", "에", "네", "예", "음음", "어어", "uh", "um"]

    /// 只有语气词、标点，或者空白：不值得单独成一句。
    public static func isFiller(_ text: String) -> Bool {
        let compact = text.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(String.init).joined()
        if compact.isEmpty { return true }
        return fillers.contains(compact.lowercased())
    }

    public static func clean(_ text: String) -> String {
        let spaced = text.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "  ", with: " ")
        return collapseRepeats(spaced.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private static let enders: Set<Character> = [".", "?", "!", "。", "？", "！", "…"]

    /// 一次定稿的话可能有好几句：按句号切开，太短的并到后一句，方便一句一句看。
    public static func splitSentences(_ text: String, minLength: Int = 8) -> [String] {
        var pieces: [String] = []
        var current = ""
        let chars = Array(text)
        for (i, ch) in chars.enumerated() {
            current.append(ch)
            let nextIsSpaceOrEnd = i + 1 >= chars.count || chars[i + 1] == " "
            if enders.contains(ch) && nextIsSpaceOrEnd {
                let piece = current.trimmingCharacters(in: .whitespaces)
                if !piece.isEmpty { pieces.append(piece) }
                current = ""
            }
        }
        let rest = current.trimmingCharacters(in: .whitespaces)
        if !rest.isEmpty { pieces.append(rest) }
        var merged: [String] = []
        var carry = ""
        for p in pieces {
            let joined = carry.isEmpty ? p : carry + " " + p
            if letterCount(joined) < minLength { carry = joined } else { merged.append(joined); carry = "" }
        }
        if !carry.isEmpty {
            if let last = merged.popLast() { merged.append(last + " " + carry) } else { merged.append(carry) }
        }
        return merged
    }

    public static func letterCount(_ text: String) -> Int {
        text.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.count
    }

    /// 临时结果里，已经稳定的开头部分不必重复翻译：只在新增了足够多字的时候才再翻。
    public static func worthRetranslating(old: String, new: String, minNewLetters: Int = 3) -> Bool {
        if new == old { return false }
        if !new.hasPrefix(old) { return true }
        return letterCount(String(new.dropFirst(old.count))) >= minNewLetters
    }

    public static func clock(_ seconds: Double) -> String {
        let s = max(0, Int(seconds.rounded(.down)))
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%02d:%02d", m, sec)
    }

    public static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let s = values.sorted()
        return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
    }

    /// 把一节课的字幕切成本机 AI 一次读得完的几段（按字数）。
    public static func chunks(_ lines: [String], maxChars: Int) -> [String] {
        var out: [String] = []
        var cur = ""
        for l in lines {
            if !cur.isEmpty && cur.count + l.count + 1 > maxChars { out.append(cur); cur = "" }
            cur += (cur.isEmpty ? "" : "\n") + l
        }
        if !cur.isEmpty { out.append(cur) }
        return out
    }
}
