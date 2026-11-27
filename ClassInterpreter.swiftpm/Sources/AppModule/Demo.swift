import Foundation

/// 截图用的示例模式：只有带启动参数 `-demo home|live|detail` 时才会出现（平时在 iPad 上运行永远不会触发）。
/// 示例内容只放在内存里，不写进记录、不录音、不识别；里面的中文是手写的示例译文，不是翻译引擎的输出。
enum Demo {
    static var screen: String? {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-demo"), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    static let sessionID = UUID(uuidString: "6F1C2A8E-0D3B-4C55-9E21-5B7A9C0D1E2F")!

    static let lines: [(String, String, Double, Bool)] = [
        ("안녕하세요 여러분, 오늘은 수요와 공급에 대해서 배워 보겠습니다.", "大家好，今天我们来学习供给和需求。", 1.2, false),
        ("지난 시간에 기회비용을 배웠는데, 다들 기억나시죠?", "上节课我们学了机会成本，大家都还记得吧？", 1.4, false),
        ("수요 곡선은 가격과 수요량의 관계를 나타냅니다.", "需求曲线表示价格和需求量之间的关系。", 1.3, false),
        ("일반적으로 가격이 오르면 수요량은 줄어들고, 가격이 내리면 수요량은 늘어납니다.", "一般来说，价格上涨时需求量减少，价格下降时需求量增加。", 1.5, false),
        ("이것을 수요의 법칙이라고 합니다.", "这就叫需求法则。", 1.1, true),
        ("반대로 공급 곡선은 오른쪽 위로 올라가는 모양입니다.", "相反，供给曲线是向右上方倾斜的。", 1.4, false),
        ("두 곡선이 만나는 점에서 시장의 균형 가격이 결정됩니다.", "两条曲线的交点决定了市场的均衡价格。", 1.3, false),
        ("이 부분은 중간고사에 꼭 나오니까 잘 정리해 두세요.", "这部分期中考试一定会考，请好好整理。", 1.2, true)
    ]

    static func session(id: UUID = sessionID, title: String, course: String, started: Date, offset: Double, count: Int) -> ClassSession {
        var s = ClassSession(id: id, title: title, course: course, started: started, sourceLang: "ko-KR", targetLang: "zh-Hans")
        s.engine = "苹果离线识别"
        var t = offset
        for (src, dst, lag, star) in lines.prefix(count) {
            let len = Double(TextTools.letterCount(src)) * 0.16
            s.lines.append(Line(start: t, end: t + len, source: src, target: dst, starred: star, lag: lag))
            t += len + 0.8
        }
        s.duration = t + 30
        return s
    }

    @MainActor
    static func seed(_ store: Store) {
        store.courses = [
            Course(name: "经济学原理", terms: "수요=需求\n공급=供给\n균형 가격=均衡价格\n기회비용=机会成本"),
            Course(name: "宏观经济学", terms: "")
        ]
        let now = Date()
        var main = session(title: "经济学原理 11月27日 10:30", course: "经济学原理",
                           started: now.addingTimeInterval(-3600 * 5), offset: 3912, count: lines.count)
        main.duration = 4520
        main.summary = """
        这节课讲需求和供给的基本关系（示例）。
        - 需求曲线：价格上涨，需求量减少（需求法则）
        - 供给曲线向右上方倾斜
        - 两条曲线的交点决定市场均衡价格
        作业和考试：这部分期中考试一定会考；下周前读完教材第三章
        """
        main.notes = "均衡价格那张图要自己再画一遍。"
        var other = session(id: UUID(), title: "宏观经济学 11月25日 14:00", course: "宏观经济学",
                            started: now.addingTimeInterval(-3600 * 24 * 2), offset: 60, count: 3)
        other.duration = 5340
        store.sessions = [main, other]
    }

    /// 上课界面的示例：老师正在讲下一句
    static func liveSession() -> ClassSession {
        var s = session(id: UUID(), title: "经济学原理 示例", course: "经济学原理", started: Date(), offset: 690, count: lines.count)
        s.duration = 0
        return s
    }
}
