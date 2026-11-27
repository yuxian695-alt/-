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
