import SwiftUI
import UIKit

@main
struct ClassInterpreterApp: App {
    @StateObject private var store: Store
    @StateObject private var translator: TranslationService
    @StateObject private var live: LiveController

    init() {
        let store = Store()
        let translator = TranslationService()
        _store = StateObject(wrappedValue: store)
        _translator = StateObject(wrappedValue: translator)
        _live = StateObject(wrappedValue: LiveController(store: store, translator: translator))
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
                .environmentObject(translator)
                .environmentObject(live)
                .preferredColorScheme(.dark)
                .tint(Theme.accent)
        }
    }
}

struct RootView: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var translator: TranslationService
    @EnvironmentObject var live: LiveController

    var body: some View {
        HomeView()
            .fullScreenCover(isPresented: $live.presented) {
                LiveView()
                    .environmentObject(store)
                    .environmentObject(translator)
                    .environmentObject(live)
                    .preferredColorScheme(.dark)
                    .tint(Theme.accent)
                    .interactiveDismissDisabled()
            }
            // 整个 App 只有这一个翻译会话；第一次用某对语言时，系统会在这里弹出下载提示
            .translationTask(translator.config) { session in
                await translator.serve(session)
            }
            .task { await store.repairAudio() }
    }
}

/// 系统的“分享”面板：存到“文件”、AirDrop 到电脑、发微信都从这里走。
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

/// 让一组文件地址可以用 .sheet(item:) 弹出分享
struct ShareItems: Identifiable {
    let id = UUID()
    let urls: [URL]
}

extension View {
    func panel() -> some View {
        self.padding(16)
            .background(Theme.panel, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Theme.line, lineWidth: 1))
    }
}
