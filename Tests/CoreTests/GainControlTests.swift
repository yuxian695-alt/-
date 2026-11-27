import XCTest
@testable import Core

final class GainControlTests: XCTestCase {
    private let n = 4096
    private var rng = SystemRandomNumberGenerator()

    private func block(amplitude: Float, tone: Bool, phase: inout Float) -> [Float] {
        (0..<n).map { _ in
            if tone {
                phase += 2 * .pi * 220 / 48000
                return amplitude * sinf(phase)
            }
            return Float.random(in: -amplitude...amplitude, using: &rng)
        }
    }

    private func run(_ g: GainControl, _ buf: inout [Float]) -> Float {
        buf.withUnsafeMutableBufferPointer { p in g.process([p.baseAddress!], frames: n) }
    }

    /// 网页版真机实测：iPad 放桌上，老师讲话只有 -60 dB 左右。几十秒内应该自动放大到接近上限。
    func testQuietSpeechGetsBoosted() {
        let g = GainControl(startDb: 0)
        var phase: Float = 0
        for i in 0..<400 {
            let speaking = (i / 6) % 2 == 0      // 讲 0.5 秒，停 0.5 秒
            var buf = block(amplitude: speaking ? 0.002 : 0.0001, tone: speaking, phase: &phase)
            _ = run(g, &buf)
        }
        XCTAssertGreaterThan(g.db, 25, "安静的讲话应该被放大，实际 \(g.db) dB")
        XCTAssertLessThanOrEqual(g.db, g.maxDb)
    }

    /// 没人讲话、只有平稳底噪时，不能把噪音越放越大。
    func testSteadyNoiseIsLeftAlone() {
        let g = GainControl(startDb: 6)
        var phase: Float = 0
        for _ in 0..<400 {
            var buf = block(amplitude: 0.001, tone: false, phase: &phase)
            _ = run(g, &buf)
        }
        XCTAssertEqual(g.db, 6, accuracy: 0.001)
    }

    /// 突然大声：当场压住，不破音。
    func testLimiterPreventsClipping() {
        let g = GainControl(startDb: 30)
        var phase: Float = 0
        var buf = block(amplitude: 0.5, tone: true, phase: &phase)
        let peak = run(g, &buf)
        XCTAssertLessThanOrEqual(peak, 0.951)
        XCTAssertLessThanOrEqual(buf.map { abs($0) }.max() ?? 0, 0.951)
    }

    func testLevel() {
        var ones = [Float](repeating: 1, count: 100)
        XCTAssertEqual(GainControl.level(&ones, 100), 0, accuracy: 0.01)
        var zeros = [Float](repeating: 0, count: 100)
        XCTAssertLessThan(GainControl.level(&zeros, 100), -100)
    }
}
