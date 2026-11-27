import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage(Prefs.fontSize) private var fontSize = 26.0
    @AppStorage(Prefs.showSource) private var showSource = true
    @AppStorage(Prefs.liveTranslate) private var liveTranslate = true
    @AppStorage(Prefs.autoGain) private var autoGain = true
    @AppStorage(Prefs.startGain) private var startGain = 12.0
    @AppStorage(Prefs.record) private var record = true
    @AppStorage(Prefs.legacyEngine) private var legacyEngine = false

    var body: some View {
        NavigationStack {
            Form {
                Section("字幕") {
                    VStack(alignment: .leading) {
                        Text("字号 \(Int(fontSize))")
                        Slider(value: $fontSize, in: 16...48, step: 1)
                    }
                    Toggle("同时显示原文", isOn: $showSource)
                    Toggle("老师没说完就先翻（边说边译）", isOn: $liveTranslate)
                }
                Section {
                    Toggle("自动增益（离老师远时自动放大）", isOn: $autoGain)
                    if autoGain {
                        VStack(alignment: .leading) {
                            Text("起始放大 \(Int(startGain)) dB")
                            Slider(value: $startGain, in: 0...36, step: 1)
                        }
                    }
                    Toggle("上课同时录音（课后点句子回听）", isOn: $record)
                } header: {
                    Text("声音")
                } footer: {
                    Text("录音只存在这台 iPad 上，每 5 分钟存一段，App 万一被关掉也最多丢几分钟。")
                }
                Section {
                    Toggle("使用旧版识别引擎", isOn: $legacyEngine)
                } header: {
                    Text("识别引擎")
                } footer: {
                    Text("默认用 iPadOS 26 起的新版离线识别（为讲座这类长语音设计，更准）。只有新版出问题时才需要打开这个开关。")
                }
                Section("隐私") {
                    Text("识别、翻译、概括都在 iPad 本机完成；这个 App 不连接任何服务器，不需要账号，也不收费。")
                        .font(.callout)
                }
            }
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } }
            }
        }
    }
}

/// 课程和术语表：术语原文会提示给识别引擎，翻译前也会换成你指定的中文。
struct CoursesView: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    @State private var newName = ""

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        TextField("新课程名，例如 宏观经济学", text: $newName)
                        Button("添加") { add() }.disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
                Section {
                    ForEach(store.courses) { c in
                        NavigationLink(c.name) { CourseEditor(id: c.id) }
                    }
                    .onDelete { idx in
                        store.courses.remove(atOffsets: idx)
                        store.saveCourses()
                    }
                } footer: {
                    Text("每门课一张术语表。上课前选好课程，专业词更容易识别对、翻译对。")
                }
            }
            .navigationTitle("课程和术语")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } }
            }
        }
    }

    private func add() {
        let name = newName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, !store.courses.contains(where: { $0.name == name }) else { return }
        store.courses.append(Course(name: name))
        store.saveCourses()
        newName = ""
    }
}

struct CourseEditor: View {
    let id: UUID
    @EnvironmentObject var store: Store

    private var index: Int? { store.courses.firstIndex { $0.id == id } }

    var body: some View {
        Form {
            if let i = index {
                Section("术语表（一行一个：原文=中文）") {
                    TextEditor(text: Binding(
                        get: { store.courses[i].terms },
                        set: { store.courses[i].terms = $0; store.saveCourses() }))
                        .font(.body.monospaced())
                        .frame(minHeight: 260)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                }
                Section("示例") {
                    Text("수요=需求\n공급=供给\n한계효용=边际效用\nGDP=国内生产总值")
                        .font(.callout.monospaced())
                        .foregroundStyle(Theme.muted)
                        .textSelection(.enabled)
                }
                Section("已识别 \(TextTools.parseTerms(store.courses[i].terms).count) 条") {
                    ForEach(Array(TextTools.parseTerms(store.courses[i].terms).prefix(50).enumerated()), id: \.offset) { _, t in
                        HStack {
                            Text(t.source)
                            Spacer()
                            Text(t.target.isEmpty ? "（只提示识别）" : t.target).foregroundStyle(Theme.muted)
                        }
                    }
                }
            }
        }
        .navigationTitle(index.map { store.courses[$0].name } ?? "")
    }
}
