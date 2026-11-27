import SwiftUI

/// 上课全屏界面：上面是状态条，中间是一句一句的双语字幕，下面大字显示老师正在说的话。
struct LiveView: View {
    @EnvironmentObject var live: LiveController
    @AppStorage(Prefs.fontSize) private var fontSize = 26.0
    @AppStorage(Prefs.showSource) private var showSource = true
    @State private var confirmStop = false

    var body: some View {
        VStack(spacing: 0) {
            TopBar(now: live.now, confirmStop: $confirmStop, fontSize: $fontSize)
            if let notice = live.notice {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.warn)
                    Text(notice).font(.callout).foregroundStyle(Theme.ink)
                    Spacer()
                    Button { live.notice = nil } label: { Image(systemName: "xmark") }
                }
                .padding(.horizontal, 16).padding(.vertical, 8)
                .background(Theme.warn.opacity(0.15))
            }
            switch live.phase {
            case .starting:
                Spacer()
                ProgressView(live.status.isEmpty ? "正在准备…" : live.status)
                    .foregroundStyle(Theme.ink)
                Spacer()
            case .stopping:
                Spacer()
                ProgressView("正在保存最后几句…").foregroundStyle(Theme.ink)
                Spacer()
            default:
                LinesView(lines: live.current?.lines ?? [], fontSize: fontSize, showSource: showSource) { id in
                    live.toggleStar(id)
                }
                NowPanel(now: live.now, fontSize: fontSize, showSource: showSource, paused: live.phase == .paused)
            }
        }
        .background(Theme.bg.ignoresSafeArea())
        .confirmationDialog("下课了吗？", isPresented: $confirmStop, titleVisibility: .visible) {
            Button("结束并保存", role: .destructive) { Task { await live.stop() } }
            Button("继续上课", role: .cancel) {}
        }
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
    }
}

private struct TopBar: View {
    @EnvironmentObject var live: LiveController
    @ObservedObject var now: LiveNow
    @Binding var confirmStop: Bool
    @Binding var fontSize: Double

    var body: some View {
        HStack(spacing: 14) {
            Circle()
                .fill(live.phase == .paused ? Theme.muted : Theme.rec)
                .frame(width: 12, height: 12)
            Text(TextTools.clock(now.elapsed))
                .font(.title3.monospacedDigit().weight(.semibold))
                .foregroundStyle(Theme.ink)
            VStack(alignment: .leading, spacing: 2) {
                Text(live.current?.course.isEmpty == false ? live.current!.course : "未分类")
                    .font(.callout.weight(.semibold)).foregroundStyle(Theme.ink)
                Text(engineLine).font(.caption).foregroundStyle(Theme.muted)
            }
            Spacer()
            LevelMeter(level: now.level)
                .frame(width: 90, height: 8)
                .accessibilityLabel("音量")
            Text(String(format: "+%.0f dB", now.gainDb)).font(.caption.monospacedDigit()).foregroundStyle(Theme.muted)
            Button { fontSize = max(16, fontSize - 2) } label: { Image(systemName: "textformat.size.smaller") }
            Button { fontSize = min(48, fontSize + 2) } label: { Image(systemName: "textformat.size.larger") }
            Button { live.togglePause() } label: {
                Label(live.phase == .paused ? "继续" : "暂停", systemImage: live.phase == .paused ? "play.fill" : "pause.fill")
            }
            .buttonStyle(.bordered)
            .disabled(!live.isLive)
            Button { confirmStop = true } label: { Label("结束", systemImage: "stop.fill") }
                .buttonStyle(.borderedProminent)
                .tint(Theme.rec)
                .disabled(!live.isLive)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Theme.panel)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }
    }

    private var engineLine: String {
        var parts: [String] = []
        if let s = live.current {
            parts.append(LanguagePair.all.first { $0.source == s.sourceLang && $0.target == s.targetLang }?.label ?? s.sourceLang)
            parts.append(s.engine)
            if let lag = s.medianLag { parts.append(String(format: "延迟 %.1f 秒", lag)) }
        }
        return parts.joined(separator: " · ")
    }
}

private struct LevelMeter: View {
    let level: Float
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.line)
                Capsule()
                    .fill(level > 0.9 ? Theme.warn : Theme.ok)
                    .frame(width: g.size.width * CGFloat(min(1, max(0.02, sqrt(Double(level))))))
            }
        }
        .animation(.linear(duration: 0.15), value: level)
    }
}

private struct LinesView: View {
    let lines: [Line]
    let fontSize: Double
    let showSource: Bool
    let onTap: (UUID) -> Void
    @State private var follow = true

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    if lines.isEmpty {
                        Text("在听了。老师开口后，字幕会出现在这里。")
                            .font(.title3).foregroundStyle(Theme.muted)
                            .padding(.top, 40)
                    }
                    ForEach(lines) { line in
                        LineRow(line: line, fontSize: fontSize, showSource: showSource)
                            .id(line.id)
                            .contentShape(Rectangle())
                            .onTapGesture { onTap(line.id) }
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 16)
            }
            .onScrollPhaseChange { _, phase in
                if phase == .interacting { follow = false }
            }
            .onScrollGeometryChange(for: Bool.self) { geo in
                geo.contentOffset.y + geo.containerSize.height >= geo.contentSize.height - 60
            } action: { _, atBottom in
                if atBottom { follow = true }
            }
            .onChange(of: lines.count) { _, _ in
                if follow { withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("bottom", anchor: .bottom) } }
            }
            .onChange(of: lines.last?.target) { _, _ in
                if follow { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .overlay(alignment: .bottomTrailing) {
                if !follow {
                    Button {
                        follow = true
                        withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
                    } label: {
                        Label("回到最新", systemImage: "arrow.down")
                    }
                    .buttonStyle(.borderedProminent)
                    .padding(16)
                }
            }
        }
    }
}

struct LineRow: View {
    let line: Line
    let fontSize: Double
    let showSource: Bool
    var highlighted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(TextTools.clock(line.start)).font(.caption.monospacedDigit()).foregroundStyle(Theme.muted)
                if line.starred { Image(systemName: "star.fill").font(.caption).foregroundStyle(Theme.accent) }
            }
            Text(line.target.isEmpty ? "…" : line.target)
                .font(.system(size: fontSize, weight: .semibold))
                .foregroundStyle(highlighted ? Theme.accentSoft : Theme.ink)
                .fixedSize(horizontal: false, vertical: true)
            if showSource {
                Text(line.source)
                    .font(.system(size: max(14, fontSize * 0.62)))
                    .foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, line.starred ? 10 : 0)
        .overlay(alignment: .leading) {
            if line.starred { Rectangle().fill(Theme.accent).frame(width: 3) }
        }
    }
}

private struct NowPanel: View {
    @ObservedObject var now: LiveNow
    let fontSize: Double
    let showSource: Bool
    let paused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Circle().fill(paused ? Theme.muted : Theme.accent).frame(width: 8, height: 8)
                Text(paused ? "已暂停" : "正在说").font(.caption.weight(.semibold)).foregroundStyle(Theme.accent)
            }
            Text(now.target.isEmpty ? (now.source.isEmpty ? " " : "…") : now.target)
                .font(.system(size: fontSize * 1.1, weight: .bold))
                .foregroundStyle(Theme.accentSoft)
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)
            if showSource {
                Text(now.source.isEmpty ? " " : now.source)
                    .font(.system(size: max(14, fontSize * 0.66)))
                    .foregroundStyle(Theme.muted)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
        .frame(minHeight: fontSize * 3.6, alignment: .top)
        .background(Theme.panel)
        .overlay(alignment: .top) { Rectangle().fill(Theme.line).frame(height: 1) }
    }
}
