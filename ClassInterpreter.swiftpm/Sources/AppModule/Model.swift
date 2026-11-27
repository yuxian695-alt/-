import Foundation
import SwiftUI
import AVFoundation

struct Line: Identifiable, Codable, Equatable {
    var id = UUID()
    var start: Double            // 这节课开始后的秒数
    var end: Double
    var source: String
    var target: String = ""
    var starred = false
    /// 老师说完这句到中文出现用了多少秒（实测）
    var lag: Double? = nil
}

struct Course: Identifiable, Codable, Equatable, Hashable {
    var id = UUID()
    var name: String
    var terms: String = ""
}

struct ClassSession: Identifiable, Codable, Equatable {
    var id = UUID()
    var title: String
    var course: String
    var started: Date
    var duration: Double = 0
    var sourceLang: String
    var targetLang: String
    var engine: String = ""
    var lines: [Line] = []
    var hasAudio = false
    var summary: String? = nil
    var notes: String = ""

    var medianLag: Double? { TextTools.median(lines.compactMap { $0.lag }) }
}

struct LanguagePair: Hashable, Identifiable {
    let source: String      // 识别用的地区代码，例如 ko-KR
    let target: String      // 翻译目标，例如 zh-Hans
    let label: String
    var id: String { source + ">" + target }
    var sourceLanguage: String { String(source.split(separator: "-").first ?? Substring(source)) }

    static let all: [LanguagePair] = [
        LanguagePair(source: "ko-KR", target: "zh-Hans", label: "韩语 → 中文"),
        LanguagePair(source: "en-US", target: "zh-Hans", label: "英语 → 中文"),
        LanguagePair(source: "ja-JP", target: "zh-Hans", label: "日语 → 中文"),
        LanguagePair(source: "zh-CN", target: "ko", label: "中文 → 韩语")
    ]
    static func find(_ id: String) -> LanguagePair { all.first { $0.id == id } ?? all[0] }
}

/// 课堂记录、录音和课程都只存在 iPad 本机，不上传。需要带走时用记录页的“导出”。
@MainActor
final class Store: ObservableObject {
    @Published var sessions: [ClassSession] = []
    @Published var courses: [Course] = []
    /// 录音合并完成时加一，回听界面据此重新载入
    @Published private(set) var audioRevision = 0

    let root: URL
    var sessionsDir: URL { root.appendingPathComponent("课堂记录", isDirectory: true) }
    var audioDir: URL { root.appendingPathComponent("录音", isDirectory: true) }
    var exportDir: URL { root.appendingPathComponent("导出", isDirectory: true) }
    private var coursesURL: URL { root.appendingPathComponent("courses.json") }

    init() {
        root = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        for d in [sessionsDir, audioDir, exportDir] {
            try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        }
        load()
    }

    /// 下课后合并好的整节录音
    func audioURL(_ id: UUID) -> URL { audioDir.appendingPathComponent(id.uuidString + ".m4a") }
    /// 上课时每 5 分钟一段的录音放在这里
    func segmentFolder(_ id: UUID) -> URL { audioDir.appendingPathComponent(id.uuidString, isDirectory: true) }

    private func segments(_ id: UUID) -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(at: segmentFolder(id), includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "m4a" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// 回听和导出用：有合并好的就用整段，没有就用分段。
    func audioFiles(_ id: UUID) -> [URL] {
        let whole = audioURL(id)
        if FileManager.default.fileExists(atPath: whole.path) { return [whole] }
        return segments(id)
    }

    /// 把分段录音合并成一个 m4a；合并成功并核对时长后才删掉分段。
    func mergeAudio(_ id: UUID) async {
        let parts = segments(id)
        guard !parts.isEmpty else { return }
        let out = audioURL(id)
        let tmp = audioDir.appendingPathComponent(id.uuidString + ".merging.m4a")
        do {
            let expected = try await Self.merge(parts, to: tmp)
            let got = try await AVURLAsset(url: tmp).load(.duration).seconds
            guard got > 0, got >= expected * 0.97 else { try? FileManager.default.removeItem(at: tmp); return }
            try? FileManager.default.removeItem(at: out)
            try FileManager.default.moveItem(at: tmp, to: out)
            try? FileManager.default.removeItem(at: segmentFolder(id))
            audioRevision += 1
        } catch {
            try? FileManager.default.removeItem(at: tmp)
        }
    }

    /// 上次没来得及合并的录音（例如上课时 App 被关掉）：打开 App 时补上。
    func repairAudio() async {
        for s in sessions where s.hasAudio && !FileManager.default.fileExists(atPath: audioURL(s.id).path) {
            await mergeAudio(s.id)
        }
    }

    nonisolated private static func merge(_ parts: [URL], to out: URL) async throws -> Double {
        let comp = AVMutableComposition()
        guard let track = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw CaptureError.converter
        }
        var cursor = CMTime.zero
        for url in parts {
            let asset = AVURLAsset(url: url)
            // 最后一段如果没写完整（App 被关掉）就读不出来，跳过它
            guard let src = try? await asset.loadTracks(withMediaType: .audio).first,
                  let duration = try? await asset.load(.duration), duration.seconds > 0 else { continue }
            try track.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: src, at: cursor)
            cursor = cursor + duration
        }
        guard cursor.seconds > 0, let export = AVAssetExportSession(asset: comp, presetName: AVAssetExportPresetAppleM4A) else {
            throw CaptureError.converter
        }
        try? FileManager.default.removeItem(at: out)
        try await export.export(to: out, as: .m4a)
        return cursor.seconds
    }
    private func url(_ id: UUID) -> URL { sessionsDir.appendingPathComponent(id.uuidString + ".json") }

    func load() {
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        let files = (try? FileManager.default.contentsOfDirectory(at: sessionsDir, includingPropertiesForKeys: nil)) ?? []
        sessions = files.filter { $0.pathExtension == "json" }
            .compactMap { try? dec.decode(ClassSession.self, from: Data(contentsOf: $0)) }
            .sorted { $0.started > $1.started }
        if let data = try? Data(contentsOf: coursesURL), let list = try? JSONDecoder().decode([Course].self, from: data) { courses = list }
    }

    func save(_ s: ClassSession) {
        if let i = sessions.firstIndex(where: { $0.id == s.id }) { sessions[i] = s } else { sessions.insert(s, at: 0) }
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        if let data = try? enc.encode(s) { try? data.write(to: url(s.id), options: .atomic) }
    }

    func delete(_ s: ClassSession) {
        sessions.removeAll { $0.id == s.id }
        try? FileManager.default.removeItem(at: url(s.id))
        try? FileManager.default.removeItem(at: audioURL(s.id))
        try? FileManager.default.removeItem(at: segmentFolder(s.id))
    }

    func saveCourses() {
        if let data = try? JSONEncoder().encode(courses) { try? data.write(to: coursesURL, options: .atomic) }
    }

    func terms(for course: String) -> [Term] {
        TextTools.parseTerms(courses.first { $0.name == course }?.terms ?? "")
    }

    /// 导出成 Markdown 文件（双语字幕 + 概括），返回文件地址，给“分享”用。
    func exportMarkdown(_ s: ClassSession) -> URL {
        var out = ["# \(s.title)", ""]
        let df = DateFormatter(); df.locale = Locale(identifier: "zh_CN"); df.dateFormat = "yyyy年M月d日 HH:mm"
        out.append("\(df.string(from: s.started)) · 时长 \(TextTools.clock(s.duration)) · \(s.course.isEmpty ? "未分类" : s.course)")
        out.append("")
        if let sum = s.summary, !sum.isEmpty { out += ["## 课堂概括", "", sum, ""] }
        if !s.notes.isEmpty { out += ["## 我的笔记", "", s.notes, ""] }
        out += ["## 双语字幕", ""]
        for l in s.lines {
            out.append("**[\(TextTools.clock(l.start))]\(l.starred ? " ★" : "")** \(l.target.isEmpty ? "（未翻译）" : l.target)")
            out.append("> \(l.source)")
            out.append("")
        }
        let safe = s.title.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        let file = exportDir.appendingPathComponent(safe + ".md")
        try? out.joined(separator: "\n").write(to: file, atomically: true, encoding: .utf8)
        return file
    }
}

/// 设置项（@AppStorage 和 UserDefaults 共用这些名字）
enum Prefs {
    static let pair = "pair"
    static let course = "course"
    static let fontSize = "fontSize"
    static let showSource = "showSource"
    static let autoGain = "autoGain"
    static let startGain = "startGain"
    static let record = "record"
    static let legacyEngine = "legacyEngine"
    static let liveTranslate = "liveTranslate"

    static func bool(_ key: String, default value: Bool) -> Bool {
        UserDefaults.standard.object(forKey: key) == nil ? value : UserDefaults.standard.bool(forKey: key)
    }
    static func double(_ key: String, default value: Double) -> Double {
        UserDefaults.standard.object(forKey: key) == nil ? value : UserDefaults.standard.double(forKey: key)
    }
}

enum Theme {
    static let bg = Color(red: 0.055, green: 0.055, blue: 0.06)
    static let panel = Color(red: 0.16, green: 0.14, blue: 0.11).opacity(0.7)
    static let line = Color(red: 1.0, green: 0.8, blue: 0.55).opacity(0.14)
    static let accent = Color(red: 1.0, green: 0.698, blue: 0.247)          // #FFB23F 琥珀金
    static let accentSoft = Color(red: 1.0, green: 0.816, blue: 0.541)      // #FFD08A
    static let ink = Color(red: 0.957, green: 0.937, blue: 0.902)           // #F4EFE6
    static let muted = Color(red: 0.70, green: 0.67, blue: 0.62)
    static let ok = Color(red: 0.608, green: 0.890, blue: 0.541)            // #9BE38A
    static let warn = Color(red: 1.0, green: 0.541, blue: 0.361)            // #FF8A5C
    static let rec = Color(red: 1.0, green: 0.357, blue: 0.29)              // #FF5B4A
}
