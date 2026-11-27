import SwiftUI
import UIKit

/// 课后：看字幕、点一句回听、搜索、星标、AI 概括、重译、导出。
struct DetailView: View {
    let id: UUID
    @EnvironmentObject var store: Store
    @EnvironmentObject var translator: TranslationService
    @Environment(\.dismiss) private var dismiss
    @StateObject private var player = Player()
    @AppStorage(Prefs.fontSize) private var fontSize = 26.0
    @State private var query = ""
    @State private var starredOnly = false
    @State private var share: ShareItems?
    @State private var working: String?
    @State private var error: String?
    @State private var explain: (line: Line, text: String)?
    @State private var confirmDelete = false
    @State private var editingTitle = false
    @State private var newTitle = ""

    private var session: ClassSession? { store.sessions.first { $0.id == id } }

    var body: some View {
        Group {
            if let s = session {
                content(s)
            } else {
                Text("这节课的记录已经删除。").foregroundStyle(Theme.muted)
            }
        }
        .background(Theme.bg.ignoresSafeArea())
        .navigationTitle(session?.title ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, prompt: "搜索原文或译文")
        .toolbar { toolbar }
        .sheet(item: $share) { ShareSheet(items: $0.urls) }
        .alert("出错了", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("知道了", role: .cancel) {}
        } message: { Text(error ?? "") }
        .alert("改标题", isPresented: $editingTitle) {
            TextField("标题", text: $newTitle)
            Button("保存") { update { $0.title = newTitle.isEmpty ? $0.title : newTitle } }
            Button("取消", role: .cancel) {}
        }
        .confirmationDialog("删除这节课的字幕和录音？", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("删除", role: .destructive) {
                player.stop()
                if let s = session { store.delete(s) }
                dismiss()
            }
        }
        .task(id: "\(session?.hasAudio == true)-\(store.audioRevision)") { loadAudio() }
        .onDisappear { player.stop() }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarTrailing) {
            Button { starredOnly.toggle() } label: {
                Image(systemName: starredOnly ? "star.fill" : "star")
            }
            .accessibilityLabel("只看星标")
            Menu {
                Button("导出字幕（Markdown）", systemImage: "doc.text") { exportText() }
                Button("导出录音", systemImage: "waveform") { exportAudio() }
                    .disabled(player.isEmpty)
                Button("改标题", systemImage: "pencil") { newTitle = session?.title ?? ""; editingTitle = true }
                Button("用最新术语表全部重译", systemImage: "arrow.triangle.2.circlepath") { Task { await retranslate(all: true) } }
                Button("删除", systemImage: "trash", role: .destructive) { confirmDelete = true }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
        }
    }

    private func content(_ s: ClassSession) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    info(s)
                    summaryCard(s)
                    notesCard(s)
                    if !player.isEmpty { playerBar }
                    let shown = filtered(s)
                    if shown.isEmpty {
                        Text(query.isEmpty ? "没有字幕。" : "没有找到“\(query)”。").foregroundStyle(Theme.muted)
                    }
                    LazyVStack(alignment: .leading, spacing: 16) {
                        ForEach(shown) { line in
                            LineRow(line: line, fontSize: fontSize * 0.8, showSource: true, highlighted: isPlaying(line, in: s))
                                .id(line.id)
                                .contentShape(Rectangle())
                                .onTapGesture { if !player.isEmpty { player.play(from: max(0, line.start - 0.5)) } }
                                .contextMenu { menu(for: line) }
                                .textSelection(.enabled)
                        }
                    }
                    if let e = explain {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("解释：\(e.line.source)").font(.headline).foregroundStyle(Theme.ink)
                                Spacer()
                                Button { explain = nil } label: { Image(systemName: "xmark") }
                            }
                            Text(e.text).foregroundStyle(Theme.ink).textSelection(.enabled)
                        }
                        .panel()
                        .id("explain")
                        .onAppear { withAnimation { proxy.scrollTo("explain") } }
                    }
                }
                .padding(20)
                .frame(maxWidth: 900)
                .frame(maxWidth: .infinity)
            }
        }
    }

    private func info(_ s: ClassSession) -> some View {
        let df = DateFormatter()
        df.locale = Locale(identifier: "zh_CN")
        df.dateFormat = "yyyy年M月d日 HH:mm"
        var parts = [df.string(from: s.started), "时长 \(TextTools.clock(s.duration))", "\(s.lines.count) 句", s.engine]
        if let lag = s.medianLag { parts.append(String(format: "说完到出中文 中位数 %.1f 秒", lag)) }
        let missing = s.lines.filter { $0.target.isEmpty }.count
        return VStack(alignment: .leading, spacing: 8) {
            Text(parts.filter { !$0.isEmpty }.joined(separator: " · ")).font(.footnote).foregroundStyle(Theme.muted)
            if missing > 0 {
                HStack {
                    Text("有 \(missing) 句没翻译出来").font(.callout).foregroundStyle(Theme.warn)
                    Button("重译这些") { Task { await retranslate(all: false) } }.disabled(working != nil)
                }
            }
            if let w = working {
                HStack { ProgressView().controlSize(.small); Text(w).font(.callout).foregroundStyle(Theme.muted) }
            }
        }
    }

    private func summaryCard(_ s: ClassSession) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("课堂概括").font(.headline).foregroundStyle(Theme.ink)
                Spacer()
                Button(s.summary == nil ? "用本机 AI 概括" : "重新概括") { Task { await summarize(s) } }
                    .disabled(working != nil || !LocalAI.isAvailable || s.lines.isEmpty)
            }
            if let sum = s.summary {
                Text(sum).foregroundStyle(Theme.ink).textSelection(.enabled)
            } else if let why = LocalAI.unavailableReason {
                Text(why + "（不影响上课同传）").font(.callout).foregroundStyle(Theme.muted)
            } else {
                Text("点右上角按钮，用 iPad 本机的 Apple 智能整理要点（不联网）。").font(.callout).foregroundStyle(Theme.muted)
            }
        }
        .panel()
    }

    private func notesCard(_ s: ClassSession) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("我的笔记").font(.headline).foregroundStyle(Theme.ink)
            TextEditor(text: Binding(get: { session?.notes ?? "" }, set: { v in update { $0.notes = v } }))
                .frame(minHeight: 80)
                .scrollContentBackground(.hidden)
                .foregroundStyle(Theme.ink)
        }
        .panel()
    }

    private var playerBar: some View {
        HStack(spacing: 14) {
            Button { player.toggle() } label: {
                Image(systemName: player.playing ? "pause.circle.fill" : "play.circle.fill").font(.system(size: 34))
            }
            Text("\(TextTools.clock(player.position)) / \(TextTools.clock(player.duration))")
                .font(.callout.monospacedDigit()).foregroundStyle(Theme.ink)
            Spacer()
            Picker("速度", selection: $player.rate) {
                Text("0.75×").tag(Float(0.75))
                Text("1×").tag(Float(1))
                Text("1.25×").tag(Float(1.25))
                Text("1.5×").tag(Float(1.5))
            }
            .pickerStyle(.segmented)
            .frame(width: 260)
            Text("点任意一句从那里听").font(.caption).foregroundStyle(Theme.muted)
        }
        .panel()
    }

    @ViewBuilder private func menu(for line: Line) -> some View {
        Button(line.starred ? "取消星标" : "加星标", systemImage: "star") { update { s in
            if let i = s.lines.firstIndex(where: { $0.id == line.id }) { s.lines[i].starred.toggle() }
        } }
        Button("复制", systemImage: "doc.on.doc") { UIPasteboard.general.string = "\(line.target)\n\(line.source)" }
        if LocalAI.isAvailable {
            Button("用本机 AI 解释这句", systemImage: "sparkles") { Task { await explainLine(line) } }
        }
        if !player.isEmpty {
            Button("从这句开始听", systemImage: "play") { player.play(from: max(0, line.start - 0.5)) }
        }
    }

    private func filtered(_ s: ClassSession) -> [Line] {
        s.lines.filter { l in
            (!starredOnly || l.starred) &&
            (query.isEmpty || l.source.localizedCaseInsensitiveContains(query) || l.target.localizedCaseInsensitiveContains(query))
        }
    }

    private func isPlaying(_ line: Line, in s: ClassSession) -> Bool {
        guard player.playing else { return false }
        let t = player.position
        guard let i = s.lines.firstIndex(where: { $0.id == line.id }) else { return false }
        let next = i + 1 < s.lines.count ? s.lines[i + 1].start : line.end + 1
        return t >= line.start - 0.5 && t < next - 0.5
    }

    private func loadAudio() {
        guard let s = session, s.hasAudio else { return }
        player.load(store.audioFiles(s.id))
    }

    private func update(_ change: (inout ClassSession) -> Void) {
        guard var s = session else { return }
        change(&s)
        store.save(s)
    }

    private func exportText() {
        guard let s = session else { return }
        share = ShareItems(urls: [store.exportMarkdown(s)])
    }

    private func exportAudio() {
        guard let s = session else { return }
        let files = store.audioFiles(s.id)
        if !files.isEmpty { share = ShareItems(urls: files) }
    }

    private func summarize(_ s: ClassSession) async {
        working = "本机 AI 正在概括（长课要一两分钟）…"
        defer { working = nil }
        let chineseSide = s.targetLang.hasPrefix("zh")
        let lines = s.lines.map { chineseSide ? ($0.target.isEmpty ? $0.source : $0.target) : $0.source }
        do {
            let text = try await LocalAI.summarize(lines)
            update { $0.summary = text }
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func explainLine(_ line: Line) async {
        working = "本机 AI 正在解释…"
        defer { working = nil }
        do {
            let text = try await LocalAI.explain(source: line.source, translation: line.target)
            explain = (line, text)
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func retranslate(all: Bool) async {
        guard let s = session else { return }
        translator.configure(source: s.sourceLang, target: s.targetLang)
        let terms = store.terms(for: s.course)
        let todo = s.lines.filter { all || $0.target.isEmpty }
        guard !todo.isEmpty else { return }
        var failed = 0
        for (n, line) in todo.enumerated() {
            working = "正在重译 \(n + 1)/\(todo.count)…"
            if let out = await translator.translate(TextTools.applyGlossary(line.source, terms: terms)), !out.isEmpty {
                update { s in
                    if let i = s.lines.firstIndex(where: { $0.id == line.id }) { s.lines[i].target = out }
                }
            } else {
                failed += 1
            }
        }
        working = nil
        if failed > 0 { error = "有 \(failed) 句还是没翻译出来。请回首页检查翻译包是否已下载。" }
    }
}
