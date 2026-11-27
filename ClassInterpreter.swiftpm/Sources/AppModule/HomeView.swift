import SwiftUI

struct HomeView: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var translator: TranslationService
    @EnvironmentObject var live: LiveController
    @StateObject private var readiness = Readiness()
    @AppStorage(Prefs.pair) private var pairID = LanguagePair.all[0].id
    @AppStorage(Prefs.course) private var course = ""
    @State private var path: [UUID] = []
    @State private var showSettings = false
    @State private var showCourses = false
    @State private var askDownload = false

    private var pair: LanguagePair { LanguagePair.find(pairID) }

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header
                    startCard
                    checkCard
                    recent
                }
                .padding(20)
                .frame(maxWidth: 820)
                .frame(maxWidth: .infinity)
            }
            .background(Theme.bg.ignoresSafeArea())
            .navigationTitle("课堂同传")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showSettings = true } label: { Image(systemName: "gearshape") }
                        .accessibilityLabel("设置")
                }
            }
            .navigationDestination(for: UUID.self) { id in DetailView(id: id) }
            .sheet(isPresented: $showSettings) { SettingsView() }
            .sheet(isPresented: $showCourses) { CoursesView() }
        }
        .task(id: pairID) { await readiness.refresh(pair, translator: translator) }
        .onChange(of: translator.state) { _, _ in
            Task { await readiness.refresh(pair, translator: translator) }
        }
        .onChange(of: live.finishedID) { _, id in
            if let id { path = [id]; live.finishedID = nil }
        }
        .alert("没能开始", isPresented: Binding(get: { live.startError != nil }, set: { if !$0 { live.startError = nil } })) {
            Button("知道了", role: .cancel) {}
        } message: {
            Text(live.startError ?? "")
        }
        .confirmationDialog("翻译语言包还没下载", isPresented: $askDownload, titleVisibility: .visible) {
            Button("先下载翻译包（需 Wi-Fi，只要一次）") { readiness.downloadTranslation(pair, translator: translator) }
            Button("先开始，只出原文") { begin() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("下载好以后，上课完全不用联网。")
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("课堂同传")
                .font(.system(size: 34, weight: .bold))
                .foregroundStyle(Theme.ink)
            Text("iPad 本机识别 + 本机翻译 · 上课不用联网 · 永久免费 · 声音和文字不离开这台 iPad")
                .font(.subheadline)
                .foregroundStyle(Theme.muted)
        }
    }

    private var startCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Picker("语言", selection: $pairID) {
                    ForEach(LanguagePair.all) { p in Text(p.label).tag(p.id) }
                }
                .pickerStyle(.menu)
                Picker("课程", selection: $course) {
                    Text("未分类").tag("")
                    ForEach(store.courses) { c in Text(c.name).tag(c.name) }
                }
                .pickerStyle(.menu)
                Spacer()
                Button("课程和术语") { showCourses = true }
                    .font(.callout)
            }
            Button {
                if readiness.translationNeedsDownload { askDownload = true } else { begin() }
            } label: {
                HStack {
                    Image(systemName: "mic.fill")
                    Text("开始上课").font(.title2.weight(.bold))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 18)
                .background(Theme.accent, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .foregroundStyle(Color.black)
            }
            .disabled(live.phase != .idle)
            Text("把 iPad 放在离老师近一点的地方。上课时屏幕会一直亮着；点字幕可以加星标，下课点“结束”自动保存。")
                .font(.footnote)
                .foregroundStyle(Theme.muted)
        }
        .panel()
    }

    private var checkCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("上课前检查").font(.headline).foregroundStyle(Theme.ink)
            CheckRow(title: "语音识别", item: readiness.speech) {
                Task { await readiness.downloadSpeech(pair) }
            }
            CheckRow(title: "翻译", item: readiness.translation) {
                readiness.downloadTranslation(pair, translator: translator)
            }
            CheckRow(title: "课后 AI 概括", item: readiness.ai, action: nil)
        }
        .panel()
    }

    @ViewBuilder private var recent: some View {
        if !store.sessions.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("课堂记录").font(.headline).foregroundStyle(Theme.ink)
                ForEach(store.sessions) { s in
                    NavigationLink(value: s.id) { SessionRow(session: s) }
                        .buttonStyle(.plain)
                }
            }
        }
    }

    private func begin() {
        let p = pair, c = course
        Task { await live.start(pair: p, course: c) }
    }
}

struct CheckRow: View {
    let title: String
    let item: Readiness.Item
    let action: (() -> Void)?

    var body: some View {
        HStack(spacing: 10) {
            icon.frame(width: 22)
            Text(title).foregroundStyle(Theme.ink).frame(width: 110, alignment: .leading)
            Text(detail).font(.callout).foregroundStyle(Theme.muted)
            Spacer()
            if case .action(_, let label) = item, let action {
                Button(label, action: action).buttonStyle(.borderedProminent)
            }
        }
    }

    private var detail: String {
        switch item {
        case .checking: return "检查中…"
        case .ready(let s), .working(let s), .unavailable(let s): return s
        case .action(let s, _): return s
        }
    }

    @ViewBuilder private var icon: some View {
        switch item {
        case .checking, .working: ProgressView().controlSize(.small)
        case .ready: Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.ok)
        case .action: Image(systemName: "arrow.down.circle.fill").foregroundStyle(Theme.accent)
        case .unavailable: Image(systemName: "minus.circle").foregroundStyle(Theme.muted)
        }
    }
}

struct SessionRow: View {
    let session: ClassSession

    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text(session.title).font(.body.weight(.semibold)).foregroundStyle(Theme.ink)
                Text(subtitle).font(.caption).foregroundStyle(Theme.muted)
                if let first = session.lines.first(where: { !$0.target.isEmpty }) {
                    Text(first.target).font(.callout).foregroundStyle(Theme.muted).lineLimit(1)
                }
            }
            Spacer()
            Image(systemName: "chevron.right").foregroundStyle(Theme.muted)
        }
        .padding(14)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var subtitle: String {
        var parts = [TextTools.clock(session.duration), "\(session.lines.count) 句"]
        if let lag = session.medianLag { parts.append(String(format: "延迟中位数 %.1f 秒", lag)) }
        if session.summary != nil { parts.append("已概括") }
        return parts.joined(separator: " · ")
    }
}
