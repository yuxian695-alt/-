// swift-tools-version: 5.9
// 这个文件只给 GitHub 自动测试用：单独测试 App 里不依赖 iPad 的纯逻辑（切句、术语表、自动增益……）。
// 装到 iPad 上的是 ClassInterpreter.swiftpm，和这里无关。
import PackageDescription

let package = Package(
    name: "ClassInterpreterCore",
    platforms: [.macOS(.v13), .iOS(.v17)],
    products: [.library(name: "Core", targets: ["Core"])],
    targets: [
        .target(name: "Core",
                path: "ClassInterpreter.swiftpm/Sources/AppModule",
                sources: ["TextTools.swift", "GainControl.swift"]),
        .testTarget(name: "CoreTests", dependencies: ["Core"], path: "Tests/CoreTests")
    ]
)
