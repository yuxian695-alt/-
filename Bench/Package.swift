// swift-tools-version: 5.9
// 在 GitHub 的 Mac 上跑：用苹果同一套离线识别（SpeechAnalyzer）听一段韩语合成讲课，测延迟和错字率。
import PackageDescription

let package = Package(
    name: "Bench",
    platforms: [.macOS("26.0")],
    targets: [.executableTarget(name: "bench", path: "Sources/bench")]
)
