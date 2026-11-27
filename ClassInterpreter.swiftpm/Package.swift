// swift-tools-version: 5.9

// 小霸王学习机 · 课堂同传（iPad 本机版）
// 用 iPad 上的 Swift Playgrounds 打开这个文件夹，点“运行”即可安装到 iPad。
// 听写和翻译都用 iPad 自带的离线引擎，不需要服务器、密钥或电脑。

import PackageDescription
import AppleProductTypes

let package = Package(
    name: "ClassInterpreter",
    platforms: [
        .iOS("18.0")
    ],
    products: [
        .iOSApplication(
            name: "课堂同传",
            targets: ["AppModule"],
            bundleIdentifier: "app.xiaobawang.classinterpreter",
            displayVersion: "1.0",
            bundleVersion: "1",
            appIcon: .placeholder(icon: .mic),
            accentColor: .presetColor(.orange),
            supportedDeviceFamilies: [
                .pad,
                .phone
            ],
            supportedInterfaceOrientations: [
                .portrait,
                .landscapeRight,
                .landscapeLeft,
                .portraitUpsideDown(.when(deviceFamilies: [.pad]))
            ],
            capabilities: [
                .microphone(purposeString: "上课时听老师讲话，在 iPad 本机实时识别并翻译。声音不会上传。")
            ],
            appCategory: .education,
            additionalInfoPlistContentFilePath: "AppInfo.plist"
        )
    ],
    targets: [
        .executableTarget(
            name: "AppModule",
            path: "Sources/AppModule"
        )
    ]
)
