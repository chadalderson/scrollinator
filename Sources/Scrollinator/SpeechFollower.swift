import AVFoundation
import Speech

/// Hands microphone buffers from the audio thread to the active recognizer, mixed to mono.
final class RecognitionFeed: @unchecked Sendable {
    static let shared = RecognitionFeed()
    typealias Sink = @Sendable (AVAudioPCMBuffer) -> Void

    private let lock = NSLock()
    private var sink: Sink?

    func attach(_ sink: Sink?) {
        lock.lock()
        self.sink = sink
        lock.unlock()
    }

    /// Called from the audio tap.
    func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        let sink = self.sink
        lock.unlock()
        guard let sink else { return }
        let channels = Int(buffer.format.channelCount)
        guard channels > 1 else {
            sink(buffer)
            return
        }
        guard let format = AVAudioFormat(standardFormatWithSampleRate: buffer.format.sampleRate, channels: 1),
              let mono = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: buffer.frameLength),
              let src = buffer.floatChannelData, let dst = mono.floatChannelData?[0] else { return }
        mono.frameLength = buffer.frameLength
        for i in 0..<Int(buffer.frameLength) {
            var sum: Float = 0
            for c in 0..<channels { sum += src[c][i] }
            dst[i] = sum
        }
        sink(mono)
    }
}

/// Runs on-device speech recognition while the prompter follows the speaker, and reports which
/// script word was just spoken. Audio never leaves the Mac. On macOS 26 and later it uses
/// SpeechAnalyzer, which works whether or not Dictation is on; earlier versions use
/// SFSpeechRecognizer, which needs Dictation turned on.
@MainActor
final class SpeechFollower: ObservableObject {
    static let shared = SpeechFollower()

    enum Status: Equatable {
        case off
        /// Downloading the on-device speech model (first use only).
        case preparing
        case denied
        case dictationOff
        case unavailable
        /// Listening, but not currently matched to the script.
        case listening
        /// Recently matched the speaker's words to the script.
        case following
    }

    @Published private(set) var status: Status = .off

    /// Index of the script word just spoken, and how many seconds ago it was spoken.
    var onMatch: ((Int, Double) -> Void)?

    private(set) var aligner = ScriptAligner(text: "")
    private var loadedText: String?
    private var active = false
    private var engine: RecognitionEngine?
    private var lastMatch: CFTimeInterval = 0

    /// The speaker's words matched the script within the last second. Matches arrive in small
    /// bursts, so a short window keeps this steady while reading and lets it drop during an ad-lib.
    var isOnScript: Bool { status == .following && CACurrentMediaTime() - lastMatch < 1 }
    private var staleCheck: Timer?

    func setActive(_ on: Bool, text: String) {
        load(text)
        guard on != active else { return }
        active = on
        if on { start() } else { stop() }
    }

    /// Rebuilds the word list when the script changes, keeping the place in it.
    func load(_ text: String) {
        guard text != loadedText else { return }
        let previous = aligner.position >= 0 ? aligner.words[aligner.position].range.location : -1
        loadedText = text
        aligner = ScriptAligner(text: text)
        aligner.reposition(to: previous < 0 ? -1 : aligner.wordIndex(atCharacter: previous))
    }

    /// The user moved the text themselves; search for the speaker from here.
    func reposition(toWord index: Int) {
        aligner.reposition(to: index)
    }

    private func start() {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized:
            launch()
        case .notDetermined:
            status = .listening
            SFSpeechRecognizer.requestAuthorization { granted in
                Task { @MainActor in
                    guard self.active else { return }
                    if granted == .authorized { self.launch() } else { self.status = .denied }
                }
            }
        default:
            status = .denied
        }
    }

    private func launch() {
        let engine: RecognitionEngine
        if #available(macOS 26, *), SpeechTranscriber.isAvailable {
            engine = AnalyzerEngine()
        } else {
            engine = LegacyEngine()
        }
        engine.onTranscript = { [weak self] text, lag in self?.heard(text, lag: lag) }
        engine.onStatus = { [weak self] status in
            guard let self, self.active else { return }
            self.status = status
        }
        self.engine = engine
        status = .listening
        engine.start(contextualStrings: contextualStrings())

        staleCheck?.invalidate()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.status == .following, CACurrentMediaTime() - self.lastMatch > 6 else { return }
                self.status = .listening
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        staleCheck = timer
    }

    private func stop() {
        staleCheck?.invalidate()
        staleCheck = nil
        engine?.stop()
        engine = nil
        status = .off
    }

    /// Set SCROLLINATOR_DEBUG_SPEECH=1 to log what recognition heard and where it placed the speaker.
    private let debug = ProcessInfo.processInfo.environment["SCROLLINATOR_DEBUG_SPEECH"] != nil

    private func heard(_ transcript: String, lag: Double) {
        guard active else { return }
        let index = aligner.update(recognized: transcript)
        if debug {
            let tail = transcript.split(whereSeparator: \.isWhitespace).suffix(10).joined(separator: " ")
            print("[speech] …\(tail)" + (index.map { " -> word \($0) (\(aligner.words[$0].key))" } ?? ""))
        }
        guard let index else { return }
        lastMatch = CACurrentMediaTime()
        status = .following
        onMatch?(index, lag)
    }

    /// The script's longer words, so names and jargon are recognized.
    private func contextualStrings() -> [String] {
        guard let loadedText else { return [] }
        let text = loadedText as NSString
        var seen = Set<String>(), out: [String] = []
        for token in ScriptAligner.tokens(in: loadedText) where token.key.count >= 6 {
            if seen.insert(token.key).inserted { out.append(text.substring(with: token.range)) }
            if out.count == 100 { break }
        }
        return out
    }
}

@MainActor
private class RecognitionEngine {
    /// Recent recognized text, and how long ago its last word was spoken.
    var onTranscript: ((String, Double) -> Void)?
    var onStatus: ((SpeechFollower.Status) -> Void)?
    func start(contextualStrings: [String]) {}
    func stop() {}
}

// MARK: - macOS 26: SpeechAnalyzer

@available(macOS 26, *)
private final class AnalyzerEngine: RecognitionEngine {
    private var analyzer: SpeechAnalyzer?
    private var input: AsyncStream<AnalyzerInput>.Continuation?
    private var results: Task<Void, Never>?
    private var setup: Task<Void, Never>?
    private var clock: AudioClock?
    /// Finished segments, trimmed to the last few dozen words; the aligner only needs the tail.
    private var finalized = ""

    override func start(contextualStrings: [String]) {
        setup = Task { [weak self] in
            do {
                try await self?.begin(contextualStrings: contextualStrings)
            } catch {
                self?.onStatus?(.unavailable)
            }
        }
    }

    private func begin(contextualStrings: [String]) async throws {
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale.current) else {
            onStatus?(.unavailable)
            return
        }
        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults, .fastResults],
            attributeOptions: [.audioTimeRange]
        )
        if let download = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            onStatus?(.preparing)
            try await download.downloadAndInstall()
            onStatus?(.listening)
        }
        guard !Task.isCancelled,
              let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else { return }

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        if !contextualStrings.isEmpty {
            let context = AnalysisContext()
            context.contextualStrings[.general] = contextualStrings
            try? await analyzer.setContext(context)
        }
        let (stream, input) = AsyncStream<AnalyzerInput>.makeStream()
        let clock = AudioClock()
        results = Task { [weak self] in
            do {
                for try await result in transcriber.results {
                    self?.handle(result)
                }
            } catch {}
        }
        try await analyzer.start(inputSequence: stream)
        guard !Task.isCancelled else { return }
        self.analyzer = analyzer
        self.input = input
        self.clock = clock
        RecognitionFeed.shared.attach(Self.makeSink(input: input, format: format, clock: clock))
    }

    private func handle(_ result: SpeechTranscriber.Result) {
        let text = String(result.text.characters)
        // When was the last recognized word spoken, relative to the audio fed so far?
        var lastEnd: Double?
        for run in result.text.runs {
            if let range = run.audioTimeRange { lastEnd = range.end.seconds }
        }
        let lag = min(max((clock?.seconds ?? 0) - (lastEnd ?? 0), 0), 2)
        if result.isFinal {
            finalized = Self.lastWords(finalized + " " + text, 40)
            onTranscript?(finalized, lag)
        } else {
            onTranscript?(finalized + " " + text, lag)
        }
    }

    override func stop() {
        RecognitionFeed.shared.attach(nil)
        setup?.cancel()
        input?.finish()
        results?.cancel()
        let analyzer = analyzer
        Task { await analyzer?.cancelAndFinishNow() }
        self.analyzer = nil
    }

    private static func lastWords(_ text: String, _ count: Int) -> String {
        text.split(whereSeparator: \.isWhitespace).suffix(count).joined(separator: " ")
    }

    /// Converts mic buffers to the analyzer's format on the audio thread and counts audio time.
    private static func makeSink(
        input: AsyncStream<AnalyzerInput>.Continuation, format: AVAudioFormat, clock: AudioClock
    ) -> RecognitionFeed.Sink {
        let converter = ConverterBox()
        return { buffer in
            guard let out = converter.convert(buffer, to: format) else { return }
            clock.advance(frames: Int(out.frameLength), rate: format.sampleRate)
            input.yield(AnalyzerInput(buffer: out))
        }
    }
}

/// Seconds of audio handed to the analyzer, written on the audio thread and read on the main thread.
private final class AudioClock: @unchecked Sendable {
    private let lock = NSLock()
    private var total: Double = 0

    var seconds: Double {
        lock.lock()
        defer { lock.unlock() }
        return total
    }

    func advance(frames: Int, rate: Double) {
        lock.lock()
        total += Double(frames) / rate
        lock.unlock()
    }
}

/// Streaming sample-rate and format converter, used only from the audio thread.
private final class ConverterBox: @unchecked Sendable {
    private var converter: AVAudioConverter?

    func convert(_ buffer: AVAudioPCMBuffer, to format: AVAudioFormat) -> AVAudioPCMBuffer? {
        if converter == nil || converter?.inputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: format)
        }
        guard let converter else { return nil }
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * format.sampleRate / buffer.format.sampleRate) + 32
        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
        var supplied = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if supplied {
                status.pointee = .noDataNow
                return nil
            }
            supplied = true
            status.pointee = .haveData
            return buffer
        }
        return error == nil && out.frameLength > 0 ? out : nil
    }
}

// MARK: - macOS 14-15: SFSpeechRecognizer

private final class LegacyEngine: RecognitionEngine {
    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var contextualStrings: [String] = []
    private var taskStarted: CFTimeInterval = 0
    private var lastWords: CFTimeInterval = 0
    private var generation = 0
    private var housekeeping: Timer?
    private var running = false

    /// Partial results arrive about this long after the words are spoken.
    private let typicalLag = 0.4
    /// Sessions are restarted during a pause once they run this long, and always at the hard limit,
    /// since recognition sessions are meant to be short.
    private let restartWhenQuietAfter: CFTimeInterval = 25
    private let restartAlwaysAfter: CFTimeInterval = 55

    override func start(contextualStrings: [String]) {
        self.contextualStrings = contextualStrings
        running = true
        let recognizer = SFSpeechRecognizer(locale: Locale.current) ?? SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
        guard let recognizer, recognizer.supportsOnDeviceRecognition else {
            onStatus?(.unavailable)
            return
        }
        self.recognizer = recognizer
        startTask()
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tidy() }
        }
        RunLoop.main.add(timer, forMode: .common)
        housekeeping = timer
    }

    private func startTask() {
        guard running, let recognizer else { return }
        endTask()
        generation += 1
        let current = generation

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = true
        request.addsPunctuation = false
        request.taskHint = .dictation
        request.contextualStrings = contextualStrings
        self.request = request
        taskStarted = CACurrentMediaTime()

        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            let transcript = result?.bestTranscription.formattedString
            let finished = error != nil || (result?.isFinal ?? false)
            let dictationOff = (error as NSError?).map { $0.domain == "kLSRErrorDomain" && $0.code == 201 } ?? false
            Task { @MainActor in
                guard let self, self.generation == current else { return }
                if dictationOff {
                    self.onStatus?(.dictationOff)
                    self.endTask()
                    return
                }
                if let transcript {
                    self.lastWords = CACurrentMediaTime()
                    self.onTranscript?(transcript, self.typicalLag)
                }
                if finished {
                    // The session ended on its own (time limit, audio change); start a fresh one.
                    try? await Task.sleep(for: .milliseconds(300))
                    if self.generation == current { self.startTask() }
                }
            }
        }
        RecognitionFeed.shared.attach { [request] buffer in request.append(buffer) }
    }

    private func endTask() {
        RecognitionFeed.shared.attach(nil)
        request?.endAudio()
        task?.cancel()
        request = nil
        task = nil
    }

    override func stop() {
        running = false
        generation += 1
        housekeeping?.invalidate()
        housekeeping = nil
        endTask()
        recognizer = nil
    }

    private func tidy() {
        guard running, task != nil else { return }
        let now = CACurrentMediaTime()
        let age = now - taskStarted
        let quiet = now - lastWords > 1.2
        if age > restartAlwaysAfter || (age > restartWhenQuietAfter && quiet) { startTask() }
    }
}
