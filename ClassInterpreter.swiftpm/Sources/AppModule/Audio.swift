import AVFoundation

enum CaptureError: LocalizedError {
    case noPermission, noUsageText, noInput, converter
    var errorDescription: String? {
        switch self {
        case .noPermission: return "没有麦克风权限。请到 设置 → 隐私与安全性 → 麦克风，打开“课堂同传”。"
        case .noUsageText: return "这份工程缺少麦克风权限说明，系统不允许录音。请重新下载最新版本再运行。"
        case .noInput: return "找不到麦克风。请拔掉外接设备后再试。"
        case .converter: return "声音格式转换失败。"
        }
    }
}

/// 把麦克风的声音转成识别引擎或录音文件要的格式（和苹果官方示例同一种写法）。
final class BufferConverter {
    private var converter: AVAudioConverter?

    func convert(_ buffer: AVAudioPCMBuffer, to format: AVAudioFormat) throws -> AVAudioPCMBuffer {
        if buffer.format == format { return buffer }
        if converter == nil || converter?.inputFormat != buffer.format || converter?.outputFormat != format {
            converter = AVAudioConverter(from: buffer.format, to: format)
            converter?.primeMethod = .none
        }
        guard let converter else { throw CaptureError.converter }
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 16
        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { throw CaptureError.converter }
        var error: NSError?
        var consumed = false
        let status = converter.convert(to: out, error: &error) { _, inputStatus in
            if consumed { inputStatus.pointee = .noDataNow; return nil }
            consumed = true
            inputStatus.pointee = .haveData
            return buffer
        }
        if status == .error { throw error ?? CaptureError.converter }
        return out
    }
}

/// 麦克风采集：自动增益 → 交给识别引擎 → 同时存成录音（课后回听、传到电脑精翻）。
///
/// 录音每 5 分钟切成一个 m4a 小文件：就算上课中途 App 被系统关掉或 iPad 没电，
/// 也最多丢最后几分钟；下课后自动合并成一个文件。
final class AudioCapture {
    static let segmentSeconds: Double = 300

    private let engine = AVAudioEngine()
    private let gain: GainControl
    private let fileConverter = BufferConverter()
    private let lock = NSLock()
    private var observers: [NSObjectProtocol] = []

    // 下面几个只在 lock 里读写
    private var file: AVAudioFile?
    private var folder: URL?
    private var segment = 0
    private var segmentElapsed: Double = 0
    private var seconds: Double = 0
    private var isPaused = false
    private var useAutoGain = true

    /// 在音频线程上调用
    var onBuffer: ((AVAudioPCMBuffer) -> Void)?
    /// 在音频线程上调用：0...1
    var onLevel: ((Float) -> Void)?
    /// 采集出错或被打断（例如来电）后，在主线程上调用
    var onInterrupted: ((String) -> Void)?

    init(startGainDb: Float, autoGain: Bool) {
        gain = GainControl(startDb: startGainDb)
        useAutoGain = autoGain
    }

    var gainDb: Float { lock.lock(); defer { lock.unlock() }; return useAutoGain ? gain.db : 0 }

    var paused: Bool {
        get { lock.lock(); defer { lock.unlock() }; return isPaused }
        set { lock.lock(); isPaused = newValue; lock.unlock() }
    }

    /// 已经采集（不含暂停）的秒数，线程安全
    var elapsed: Double { lock.lock(); defer { lock.unlock() }; return seconds }

    /// 缺少麦克风权限说明时系统会直接让 App 崩溃，所以先检查，缺了就报错而不是去申请。
    static func requestPermission() async throws -> Bool {
        guard Bundle.main.object(forInfoDictionaryKey: "NSMicrophoneUsageDescription") != nil else {
            throw CaptureError.noUsageText
        }
        return await AVAudioApplication.requestRecordPermission()
    }

    private static let fileSettings: [String: Any] = [
        AVFormatIDKey: kAudioFormatMPEG4AAC,
        AVSampleRateKey: 16000.0,
        AVNumberOfChannelsKey: 1,
        AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue
    ]

    static func segmentURL(_ folder: URL, _ index: Int) -> URL {
        folder.appendingPathComponent(String(format: "part-%03d.m4a", index))
    }

    func start(recordTo folder: URL?) throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .default, options: [])
        try session.setActive(true)
        if let folder {
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            lock.lock()
            self.folder = folder
            openSegment(0)
            lock.unlock()
        }
        try installTap()
        engine.prepare()
        try engine.start()
        observe()
    }

    /// 只在 lock 里调用
    private func openSegment(_ index: Int) {
        guard let folder else { return }
        file = nil      // 关掉上一段（写好文件尾）
        segment = index
        segmentElapsed = 0
        file = try? AVAudioFile(forWriting: Self.segmentURL(folder, index), settings: Self.fileSettings,
                                commonFormat: .pcmFormatFloat32, interleaved: false)
    }

    private func installTap() throws {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw CaptureError.noInput }
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            self?.handle(buffer)
        }
    }

    private func handle(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        let skip = isPaused
        let agc = useAutoGain
        lock.unlock()
        if skip || buffer.frameLength == 0 { return }
        let n = Int(buffer.frameLength)
        let duration = Double(n) / buffer.format.sampleRate
        var peak: Float = 0
        if let data = buffer.floatChannelData {
            let channels = (0..<Int(buffer.format.channelCount)).map { data[$0] }
            if agc {
                peak = gain.process(channels, frames: n)
            } else {
                for i in 0..<n { peak = max(peak, abs(channels[0][i])) }
            }
        }
        onLevel?(peak)
        onBuffer?(buffer)

        lock.lock()
        seconds += duration
        if let file, let converted = try? fileConverter.convert(buffer, to: file.processingFormat) {
            try? file.write(from: converted)
            segmentElapsed += duration
            if segmentElapsed >= Self.segmentSeconds { openSegment(segment + 1) }
        }
        lock.unlock()
    }

    private func observe() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            guard let self, let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
            if type == .ended {
                self.restart()
            } else {
                self.onInterrupted?("被系统打断（例如来电或 Siri），结束后会自动接着听。")
            }
        })
        observers.append(center.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            self?.restart()
        })
    }

    /// 来电结束、插拔耳机后：重新接上麦克风。
    private func restart() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        do {
            try AVAudioSession.sharedInstance().setCategory(.record, mode: .default, options: [])
            try AVAudioSession.sharedInstance().setActive(true)
            try installTap()
            engine.prepare()
            try engine.start()
        } catch {
            onInterrupted?("麦克风重新连接失败：\(error.localizedDescription)。请点“暂停”再“继续”。")
        }
    }

    func stop() {
        for o in observers { NotificationCenter.default.removeObserver(o) }
        observers.removeAll()
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        lock.lock()
        file = nil
        folder = nil
        lock.unlock()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}

/// 课后回听：点一句字幕就从那里开始放。录音可能是一个合并好的文件，也可能是几段 5 分钟的小文件。
@MainActor
final class Player: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published private(set) var playing = false
    @Published private(set) var position: Double = 0
    @Published var rate: Float = 1 { didSet { player?.rate = rate } }

    private struct Part { let url: URL; let start: Double; let duration: Double }
    private var parts: [Part] = []
    private var player: AVAudioPlayer?
    private var index = 0
    private var ticker: Task<Void, Never>?

    var duration: Double { parts.last.map { $0.start + $0.duration } ?? 0 }
    var isEmpty: Bool { parts.isEmpty }

    func load(_ urls: [URL]) {
        stop()
        var t = 0.0
        parts = []
        for u in urls {
            if let p = try? AVAudioPlayer(contentsOf: u), p.duration > 0 {
                parts.append(Part(url: u, start: t, duration: p.duration))
                t += p.duration
            }
        }
    }

    func play(from time: Double) {
        guard !parts.isEmpty else { return }
        let i = parts.lastIndex { $0.start <= time + 0.01 } ?? 0
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio, options: [])
        try? AVAudioSession.sharedInstance().setActive(true)
        begin(i, at: max(0, time - parts[i].start))
    }

    func toggle() {
        if playing { pause() } else if let p = player { p.play(); playing = true; tick() } else { play(from: position) }
    }

    func pause() {
        player?.pause()
        playing = false
        ticker?.cancel()
    }

    func stop() {
        player?.stop()
        player = nil
        playing = false
        ticker?.cancel()
    }

    private func begin(_ i: Int, at offset: Double) {
        player?.stop()
        guard i < parts.count, let p = try? AVAudioPlayer(contentsOf: parts[i].url) else { stop(); return }
        p.delegate = self
        p.enableRate = true
        p.rate = rate
        p.currentTime = min(offset, max(0, p.duration - 0.05))
        p.prepareToPlay()
        p.play()
        player = p
        index = i
        playing = true
        tick()
    }

    private func tick() {
        ticker?.cancel()
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if let p = self.player, self.index < self.parts.count {
                    self.position = self.parts[self.index].start + p.currentTime
                }
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
        }
    }

    private func next() {
        if index + 1 < parts.count { begin(index + 1, at: 0) } else { stop(); position = 0 }
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in self.next() }
    }
}
