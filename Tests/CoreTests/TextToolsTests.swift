import XCTest
@testable import Core

final class TextToolsTests: XCTestCase {

    func testParseTerms() {
        let t = TextTools.parseTerms("수요=需求\n공급 -> 供给；한계효용→边际效用\nGDP\t国内生产总值\n\n  \n오직원문")
        XCTAssertEqual(t, [
            Term(source: "수요", target: "需求"),
            Term(source: "공급", target: "供给"),
            Term(source: "한계효용", target: "边际效用"),
            Term(source: "GDP", target: "国内生产总值"),
            Term(source: "오직원문", target: "")
        ])
    }

    func testGlossaryLongestFirstAndCaseInsensitive() {
        let terms = [Term(source: "효용", target: "效用"), Term(source: "한계효용", target: "边际效用"), Term(source: "gdp", target: "国内生产总值")]
        XCTAssertEqual(TextTools.applyGlossary("한계효용은 감소한다", terms: terms), "边际效用은 감소한다")
        XCTAssertEqual(TextTools.applyGlossary("GDP가 늘었다", terms: terms), "国内生产总值가 늘었다")
        XCTAssertEqual(TextTools.applyGlossary("효용", terms: [Term(source: "효용", target: "")]), "효용")
    }

    func testCollapseRepeats() {
        XCTAssertEqual(TextTools.collapseRepeats("네 네 네 네 알겠습니다"), "네 네 알겠습니다")
        XCTAssertEqual(TextTools.collapseRepeats("그래서 이제 그래서 이제 그래서 이제 시작"), "그래서 이제 그래서 이제 시작")
        XCTAssertEqual(TextTools.collapseRepeats("오늘 수업은 여기까지"), "오늘 수업은 여기까지")
    }

    func testFiller() {
        XCTAssertTrue(TextTools.isFiller("음..."))
        XCTAssertTrue(TextTools.isFiller(" 네. "))
        XCTAssertTrue(TextTools.isFiller("。"))
        XCTAssertFalse(TextTools.isFiller("네, 시작합시다"))
    }

    func testSplitSentences() {
        let s = TextTools.splitSentences("오늘은 수요와 공급을 배웁니다. 네. 가격이 오르면 수요는 줄어듭니다! 맞죠?")
        // 太短的“네.”并到后一句，句尾太短的“맞죠?”并到前一句
        XCTAssertEqual(s, ["오늘은 수요와 공급을 배웁니다.", "네. 가격이 오르면 수요는 줄어듭니다! 맞죠?"])
        XCTAssertEqual(TextTools.splitSentences("3.5퍼센트 올랐습니다"), ["3.5퍼센트 올랐습니다"])
        XCTAssertEqual(TextTools.splitSentences("짧다."), ["짧다."])
    }

    func testWorthRetranslating() {
        XCTAssertFalse(TextTools.worthRetranslating(old: "가격이", new: "가격이"))
        XCTAssertFalse(TextTools.worthRetranslating(old: "가격이", new: "가격이 오"))
        XCTAssertTrue(TextTools.worthRetranslating(old: "가격이", new: "가격이 오르면"))
        XCTAssertTrue(TextTools.worthRetranslating(old: "가격이", new: "가격은"))
    }

    func testClockMedianChunks() {
        XCTAssertEqual(TextTools.clock(65.9), "01:05")
        XCTAssertEqual(TextTools.clock(3725), "1:02:05")
        XCTAssertEqual(TextTools.clock(-3), "00:00")
        XCTAssertEqual(TextTools.median([3, 1, 2]), 2)
        XCTAssertEqual(TextTools.median([4, 1, 2, 3]), 2.5)
        XCTAssertNil(TextTools.median([]))
        XCTAssertEqual(TextTools.chunks(["aaaa", "bbbb", "cc"], maxChars: 9), ["aaaa\nbbbb", "cc"])
        XCTAssertEqual(TextTools.chunks([], maxChars: 9), [])
    }
}

final class SoftCommitTests: XCTestCase {

    func testLastSentenceEnd() {
        let t = "오늘은 수요와 공급을 배웁니다 지난 시간에 기회비용을"
        let n = TextTools.lastSentenceEnd(t)
        XCTAssertEqual(n.map { String(t.prefix($0)) }, "오늘은 수요와 공급을 배웁니다")
        // 最后一个词可能还没说完（“배웁니다만…”），不能切
        XCTAssertNil(TextTools.lastSentenceEnd("오늘은 수요와 공급을 배웁니다"))
        let p = "가격이 오르면 수요는 줄어듭니다. 그리고"
        XCTAssertEqual(TextTools.lastSentenceEnd(p).map { String(p.prefix($0)) }, "가격이 오르면 수요는 줄어듭니다.")
        XCTAssertNil(TextTools.lastSentenceEnd("3.5퍼센트 올랐 습니"))
        let z = "今天我们学习供求关系。价格上涨"
        XCTAssertEqual(TextTools.lastSentenceEnd(z).map { String(z.prefix($0)) }, "今天我们学习供求关系。")
        // 太短的不切
        XCTAssertNil(TextTools.lastSentenceEnd("네 그렇죠 그래서"))
    }

    func testDropAligned() {
        XCTAssertEqual(TextTools.dropAligned("안녕하세요 여러분 오늘은 수요", prefix: "안녕하세요 여러분"), "오늘은 수요")
        // 定稿加了标点、空格不一样，也能对齐
        XCTAssertEqual(TextTools.dropAligned("안녕하세요, 여러분. 오늘은 수요와 공급", prefix: "안녕하세요 여러분"), "오늘은 수요와 공급")
        // 切在词中间：丢掉半截词
        XCTAssertEqual(TextTools.dropAligned("안녕하세요 여러분들 오늘은", prefix: "안녕하세요 여러분"), "오늘은")
        XCTAssertEqual(TextTools.dropAligned("abc", prefix: ""), "abc")
        XCTAssertEqual(TextTools.dropAligned("짧다", prefix: "훨씬 더 긴 앞부분"), "")
    }

    func testCommitsStableSentenceWhileTeacherKeepsTalking() {
        var s = SoftCommitter(stableFor: 1.0)
        XCTAssertNil(s.volatile("오늘은 수요와", at: 0).commit)
        XCTAssertNil(s.volatile("오늘은 수요와 공급을 배웁니다", at: 0.5).commit)
        XCTAssertNil(s.volatile("오늘은 수요와 공급을 배웁니다 지난", at: 1.0).commit)
        let r = s.volatile("오늘은 수요와 공급을 배웁니다 지난 시간에", at: 1.6)
        XCTAssertEqual(r.commit, "오늘은 수요와 공급을 배웁니다")
        XCTAssertEqual(r.rest, "지난 시간에")
        // 接下来的临时结果只显示还没定下来的部分
        XCTAssertEqual(s.volatile("오늘은 수요와 공급을 배웁니다 지난 시간에 기회비용을", at: 2.0).rest, "지난 시간에 기회비용을")
        // 引擎终于定稿：已经切走的那句不重复
        XCTAssertEqual(s.final("오늘은 수요와 공급을 배웁니다. 지난 시간에 기회비용을 배웠죠."), "지난 시간에 기회비용을 배웠죠.")
        XCTAssertEqual(s.committed, "")
    }

    func testDoesNotCommitWhileTextIsStillChanging() {
        var s = SoftCommitter(stableFor: 1.0)
        _ = s.volatile("가격이 오르면 수량은 줄어듭니다 그", at: 0)
        // 1 秒后开头被引擎改了：改过的部分不算稳定
        let r = s.volatile("가격이 오르면 수요량은 줄어듭니다 그리고", at: 1.2)
        XCTAssertNil(r.commit)
    }
}
