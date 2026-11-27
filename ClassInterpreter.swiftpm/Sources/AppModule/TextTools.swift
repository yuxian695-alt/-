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

    // MARK: 老师一直讲不停时，自己先按句子切

    private static func isLetter(_ ch: Character) -> Bool {
        ch.unicodeScalars.contains { CharacterSet.alphanumerics.contains($0) }
    }

    private static let koreanEnds: [String] = ["다", "요", "죠", "까"]

    /// 一段还在说的话里，最后一个“这句话说完了”的位置（第几个字符之后）。前面那段至少 minLetters 个字。
    /// 看句号问号，也看韩语句尾（…다 / …요 / …죠 / …까 后面已经接着说下一个词）。
    /// limit：只在前 limit 个字符里找（后面的字用来判断句尾那个词是不是已经说完了）。
    public static func lastSentenceEnd(_ text: String, minLetters: Int = 10, limit: Int? = nil) -> Int? {
        let chars = Array(text)
        let limit = limit ?? chars.count
        var best: Int?
        var letters = 0
        var wordStart = 0
        for (i, ch) in chars.enumerated() {
            if isLetter(ch) { letters += 1 }
            let next: Character? = i + 1 < chars.count ? chars[i + 1] : nil
            var boundary = false
            if enders.contains(ch) {
                // “3.5” 这种数字里的点不算；后面是空格、结尾或中日韩文字才算
                if let n = next { boundary = n == " " || (!n.isASCII && isLetter(n)) } else { boundary = true }
            } else if next == " ", i - wordStart >= 1 {
                let word = String(chars[wordStart...i])
                boundary = koreanEnds.contains { word.hasSuffix($0) }
            }
            if boundary && letters >= minLetters && i + 1 <= limit { best = i + 1 }
            if ch == " " { wordStart = i + 1 }
        }
        return best
    }

    /// 实在找不到句尾时，在最后一个空格处切（前面至少 minLetters 个字）。
    public static func lastWordBreak(_ text: String, minLetters: Int) -> Int? {
        let chars = Array(text)
        var best: Int?
        var letters = 0
        for (i, ch) in chars.enumerated() {
            if isLetter(ch) { letters += 1 }
            if ch == " " && letters >= minLetters { best = i }
        }
        return best
    }

    public static func commonPrefix(_ a: String, _ b: String) -> String {
        var out = ""
        for (x, y) in zip(a, b) {
            guard x == y else { break }
            out.append(x)
        }
        return out
    }

    /// 去掉开头已经处理过的那部分（按字数对齐，不怕标点和空格变了），返回剩下的。
    public static func dropAligned(_ text: String, prefix: String) -> String {
        if prefix.isEmpty { return text }
        let need = letterCount(prefix)
        let chars = Array(text)
        var seen = 0
        var i = 0
        while i < chars.count && seen < need {
            if isLetter(chars[i]) { seen += 1 }
            i += 1
        }
        // 切在一个词中间时，丢掉这个词剩下的半截（宁可少半个词，也不重复）
        if i > 0 && i < chars.count && isLetter(chars[i - 1]) && isLetter(chars[i]) {
            while i < chars.count && chars[i] != " " { i += 1 }
        }
        while i < chars.count && !isLetter(chars[i]) { i += 1 }
        return String(chars[i...])
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

/// 识别引擎有时要等老师停很久才“定稿”。这里看“正在说”的文字：开头那部分已经 1 秒没变、
/// 而且到了句尾，就先把它当成一句定下来去翻译，不用干等。引擎真正定稿时，再把已经切走的部分去掉。
public struct SoftCommitter {
    public private(set) var committed = ""
    private var history: [(at: Double, text: String)] = []
    public var stableFor: Double

    public init(stableFor: Double = 1.0) { self.stableFor = stableFor }

    /// 收到一版临时结果（t 是秒）。返回这次要先定下来的一句（可能没有）和剩下还在说的部分。
    public mutating func volatile(_ text: String, at t: Double) -> (commit: String?, rest: String) {
        var rest = TextTools.dropAligned(text, prefix: committed)
        history.append((t, rest))
        history.removeAll { t - $0.at > 5 }
        guard let old = history.last(where: { t - $0.at >= stableFor }) else { return (nil, rest) }
        let stable = TextTools.commonPrefix(rest, old.text).count
        var cut = TextTools.lastSentenceEnd(rest, minLetters: 10, limit: stable)
        if cut == nil && TextTools.letterCount(rest) >= 70 { cut = TextTools.lastWordBreak(String(rest.prefix(stable)), minLetters: 40) }
        guard let n = cut else { return (nil, rest) }
        let piece = String(rest.prefix(n)).trimmingCharacters(in: .whitespaces)
        guard TextTools.letterCount(piece) > 0 else { return (nil, rest) }
        committed = committed.isEmpty ? piece : committed + " " + piece
        rest = TextTools.dropAligned(rest, prefix: piece)
        history = history.map { (at: $0.at, text: TextTools.dropAligned($0.text, prefix: piece)) }
        return (piece, rest)
    }

    /// 收到定稿：去掉已经先切走的部分，返回剩下的，然后从头开始。
    public mutating func final(_ text: String) -> String {
        let rest = TextTools.dropAligned(text, prefix: committed)
        committed = ""
        history = []
        return rest
    }
}
