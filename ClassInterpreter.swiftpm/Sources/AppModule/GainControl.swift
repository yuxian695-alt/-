import Foundation

/// 自动增益：iPad 放在桌上离老师远，声音常常很小（网页版第一次真机实测讲话只有 -67 dB）。
/// 按最近约 30 秒里“有人讲话”的音量慢慢调到 -24 dB 左右；突然的大声当场压住不破音；
/// 没人讲话（音量没有起伏）时不动，免得把安静教室的底噪越放越大。和网页版 core.js 的 Level 同一套规则。
public final class GainControl {
    public private(set) var db: Float
    public let maxDb: Float
    public let targetDb: Float
    private var ring: [Float] = []
    private var counter = 0
    private var heard = 0
    private var lastGain: Float

    public init(startDb: Float = 0, maxDb: Float = 36, targetDb: Float = -24) {
        self.maxDb = maxDb
        self.targetDb = targetDb
        self.db = min(maxDb, max(0, startDb))
        self.lastGain = powf(10, self.db / 20)
    }

    /// 一块声音的能量（dBFS）。
    public static func level(_ x: UnsafePointer<Float>, _ n: Int) -> Float {
        guard n > 0 else { return -120 }
        var e: Float = 0
        for i in 0..<n { e += x[i] * x[i] }
        return 10 * log10f(e / Float(n) + 1e-12)
    }

    func measure(_ x: UnsafePointer<Float>, _ n: Int) {
        let d = GainControl.level(x, n)
        if d < -100 { return }                       // 麦克风被系统静音
        ring.append(d)
        if ring.count > 350 { ring.removeFirst(ring.count - 350) }
        counter += 1
        if counter % 5 != 0 || ring.count < 10 { return }
        let s = ring.sorted()
        func q(_ p: Float) -> Float { s[min(s.count - 1, Int(p * Float(s.count)))] }
        let floor = q(0.1), mid = q(0.5)
        if q(0.95) - floor < 6 { return }            // 没有起伏：没人讲话
        let line = min(floor + 6, mid)
        let speech = s.filter { $0 > line }
        if speech.count < 5 { return }
        let want = min(maxDb, max(0, targetDb - speech[speech.count / 2]))
        let step: Float = heard < 10 ? 0.6 : (want < db ? 0.3 : 0.12)
        heard += 1
        db += step * (want - db)
    }

    /// 原地放大第一个声道并同样处理其余声道；返回放大后的峰值（0...1），给音量条用。
    @discardableResult
    public func process(_ channels: [UnsafeMutablePointer<Float>], frames n: Int) -> Float {
        guard let first = channels.first, n > 0 else { return 0 }
        measure(UnsafePointer(first), n)
        var g = powf(10, db / 20)
        var peak: Float = 0
        for i in 0..<n { peak = max(peak, abs(first[i])) }
        if peak * g > 0.95 { g = max(0.5, 0.95 / peak) }
        let from = min(lastGain, peak > 0 ? max(0.5, 0.95 / peak) : lastGain)
        let ramp = min(160, n)
        for ch in channels {
            for i in 0..<n {
                let gi = i < ramp ? from + (g - from) * Float(i) / Float(ramp) : g
                var v = ch[i] * gi
                if v > 1 { v = 1 } else if v < -1 { v = -1 }
                ch[i] = v
            }
        }
        lastGain = g
        return min(1, peak * g)
    }
}
