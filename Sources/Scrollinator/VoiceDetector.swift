import AVFoundation
import QuartzCore

/// Listens to the default microphone and reports a smoothed input level plus whether the user is speaking.
/// Shared by the prompter and the settings meter; the engine runs only while someone holds it.
@MainActor
final class VoiceDetector: ObservableObject {
    static let shared = VoiceDetector()

    /// 0...1, fast attack / slow release, for the settings meter.
    @Published private(set) var level: Float = 0
    @Published private(set) var isSpeaking = false
    /// 0...1 on the same scale as `level`: input above this counts as speech.
    @Published private(set) var threshold: Float = 0
    @Published private(set) var permissionDenied = false
    @Published private(set) var errorMessage: String?

    /// How long text keeps moving after the voice drops below the threshold, so it doesn't stutter between words.
    private let hangover: CFTimeInterval = 0.5

    private var engine = AVAudioEngine()
    private var users = Set<String>()
    private var running = false
    private var lastLoud: CFTimeInterval = 0
    private var peak: Float = 0
    private var lastSample: CFTimeInterval = 0
    /// Background noise estimate in dBFS. It drops straight to quieter input and creeps up slowly,
    /// so the gaps between words keep it pinned to the room rather than to the voice.
    private var noiseFloor: Float = -60
    private let floorRise: Float = 1.5   // dB per second
    private static let floorMinimum: Float = -75
    /// Speech keeps the input loud and voiced for much of a short window; a key click or tap is a brief spike.
    private let sustainWindow: CFTimeInterval = 0.3
    private let sustainRatio = 0.4
    private var recent: [(time: CFTimeInterval, loud: Bool)] = []

    /// Level map: -80 dBFS (silence) ... -10 dBFS (loud speech) onto 0...1.
    static func normalized(_ db: Float) -> Float {
        min(max((db + 80) / 70, 0), 1)
    }
    private var configObserver: NSObjectProtocol?

    /// How many dB above the noise floor input must be to count as speech. Higher sensitivity → smaller margin.
    static func margin(for sensitivity: Double) -> Float {
        Float(22 - 14 * sensitivity)
    }

    /// Loudest unsmoothed reading since the last call, relative to the speech threshold:
    /// 0 at the room's noise, about 1 for loud speech. Drives the prompter's waveform.
    func takePeak() -> Float {
        defer { peak = 0 }
        guard running else { return 0 }
        return min(max((peak - threshold + 0.1) / 0.45, 0), 1)
    }

    func acquire(_ user: String) {
        users.insert(user)
        if !running { start() }
    }

    func release(_ user: String) {
        users.remove(user)
        if users.isEmpty { teardown() }
    }

    private func start() {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            startEngine()
        case .notDetermined:
            Task {
                let granted = await AVCaptureDevice.requestAccess(for: .audio)
                if granted {
                    if !self.users.isEmpty { self.startEngine() }
                } else {
                    self.permissionDenied = true
                }
            }
        default:
            permissionDenied = true
        }
    }

    private func startEngine() {
        guard !running else { return }
        permissionDenied = false

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            errorMessage = "No microphone input found."
            return
        }

        let analyzer = VoiceAnalyzer(sampleRate: format.sampleRate, channels: Int(format.channelCount))
        input.installTap(onBus: 0, bufferSize: 1024, format: format, block: Self.makeTap(analyzer) { [weak self] value in
            Task { @MainActor in self?.ingest(value) }
        })

        do {
            try engine.start()
            running = true
            errorMessage = nil
        } catch {
            input.removeTap(onBus: 0)
            errorMessage = "Couldn't start the microphone: \(error.localizedDescription)"
            return
        }

        // Plugging in headphones or switching inputs invalidates the engine; rebuild it.
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.rebuild() }
        }
    }

    private func rebuild() {
        teardown()
        engine = AVAudioEngine()
        if !users.isEmpty { startEngine() }
    }

    private func teardown() {
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
        configObserver = nil
        if running {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        running = false
        lastSample = 0
        recent.removeAll()
        level = 0
        isSpeaking = false
    }

    private func ingest(_ reading: VoiceAnalyzer.Reading) {
        let db = reading.db
        let now = CACurrentMediaTime()
        if lastSample == 0 {
            noiseFloor = db
        } else {
            let dt = Float(min(now - lastSample, 0.2))
            noiseFloor = db < noiseFloor ? db : noiseFloor + floorRise * dt
        }
        noiseFloor = max(noiseFloor, Self.floorMinimum)
        lastSample = now

        let thresholdDB = noiseFloor + Self.margin(for: Pref.micSensitivity)
        threshold = Self.normalized(thresholdDB)
        let value = Self.normalized(db)
        level = value > level ? value : level * 0.8 + value * 0.2
        peak = max(peak, value)
        recent.append((now, db >= thresholdDB && reading.voiced))
        recent.removeAll { now - $0.time > sustainWindow }
        let loudShare = Double(recent.filter(\.loud).count) / Double(recent.count)
        if loudShare >= sustainRatio { lastLoud = now }
        let speaking = now - lastLoud < hangover
        if speaking != isSpeaking { isSpeaking = speaking }
    }

    /// Built outside the main actor because the tap runs on the audio thread.
    nonisolated private static func makeTap(
        _ analyzer: VoiceAnalyzer, _ sink: @escaping @Sendable (VoiceAnalyzer.Reading) -> Void
    ) -> AVAudioNodeTapBlock {
        return { buffer, _ in
            guard let channels = buffer.floatChannelData else { return }
            let n = Int(buffer.frameLength)
            guard n > 0 else { return }
            // Interfaces often put the mic on one channel only, so loudness uses the loudest one.
            sink(analyzer.analyze(channels, channels: Int(buffer.format.channelCount), frames: n))
            RecognitionFeed.shared.append(buffer)
            RecordingFeed.shared.append(buffer)
        }
    }
}

/// Turns each mic buffer into a loudness reading plus whether it sounds like a voice.
/// Loudness uses only the voice range (about 150 Hz to 1.2 kHz), so key clicks shrink to brief blips.
/// "Voiced" means the sound repeats at a speaking pitch (70-400 Hz): vowels do, while clicks, taps
/// and hiss don't. Used only from the audio thread, one buffer at a time.
final class VoiceAnalyzer: @unchecked Sendable {
    struct Reading: Sendable {
        var db: Float
        var voiced: Bool
    }

    private struct Biquad {
        var b0: Float, b1: Float, b2: Float, a1: Float, a2: Float
        var x1: Float = 0, x2: Float = 0, y1: Float = 0, y2: Float = 0

        /// RBJ cookbook Butterworth (Q = 0.707) high- or low-pass.
        init(highPass: Bool, frequency: Double, sampleRate: Double) {
            let w0 = 2 * Double.pi * frequency / sampleRate
            let cosw = cos(w0), alpha = sin(w0) / (2 * 0.7071)
            let a0 = 1 + alpha
            let b = highPass ? (1 + cosw) / 2 : (1 - cosw) / 2
            b0 = Float(b / a0)
            b1 = Float((highPass ? -2 * b : 2 * b) / a0)
            b2 = b0
            a1 = Float(-2 * cosw / a0)
            a2 = Float((1 - alpha) / a0)
        }

        mutating func process(_ x: Float) -> Float {
            let y = b0 * x + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
            x2 = x1; x1 = x; y2 = y1; y1 = y
            return y
        }
    }

    /// Normalized autocorrelation at the best speaking-pitch lag must reach this to count as voiced.
    static let voicedCorrelation: Float = 0.6

    let channelCount: Int
    private var bands: [[Biquad]]
    // Pitch runs on a mono mix, low-passed hard and decimated to about 8 kHz.
    private var pitchFilters: [Biquad]
    private let step: Int
    private var phase = 0
    private var history: [Float] = []
    private let window: Int
    private let minLag: Int
    private let maxLag: Int

    init(sampleRate: Double, channels: Int) {
        channelCount = channels
        bands = Array(repeating: [
            Biquad(highPass: true, frequency: 150, sampleRate: sampleRate),
            Biquad(highPass: false, frequency: 1200, sampleRate: sampleRate),
        ], count: channels)
        pitchFilters = [
            Biquad(highPass: true, frequency: 60, sampleRate: sampleRate),
            Biquad(highPass: false, frequency: 900, sampleRate: sampleRate),
            Biquad(highPass: false, frequency: 900, sampleRate: sampleRate),
        ]
        step = max(1, Int((sampleRate / 8000).rounded()))
        let rate = sampleRate / Double(step)
        window = Int(rate * 0.032)
        minLag = Int(rate / 400)
        maxLag = Int(rate / 70)
    }

    func analyze(_ channels: UnsafePointer<UnsafeMutablePointer<Float>>, channels count: Int, frames n: Int) -> Reading {
        let used = min(count, channelCount)
        var loudest: Float = 0
        for c in 0..<used {
            let samples = channels[c]
            var sum: Float = 0
            for i in 0..<n {
                let y = bands[c][1].process(bands[c][0].process(samples[i]))
                sum += y * y
            }
            loudest = max(loudest, (sum / Float(n)).squareRoot())
        }

        for i in 0..<n {
            var x: Float = 0
            for c in 0..<used { x += channels[c][i] }
            for f in pitchFilters.indices { x = pitchFilters[f].process(x) }
            phase += 1
            if phase == step {
                phase = 0
                history.append(x)
            }
        }
        let needed = window + maxLag
        if history.count > needed { history.removeFirst(history.count - needed) }

        return Reading(db: 20 * log10(max(loudest, 1e-7)), voiced: pitchCorrelation() >= Self.voicedCorrelation)
    }

    /// Best normalized autocorrelation over lags that match a 70-400 Hz voice. Returns 0 unless neighboring
    /// samples move together, i.e. the energy sits low like a voice rather than in a high key ring.
    private func pitchCorrelation() -> Float {
        guard history.count == window + maxLag else { return 0 }
        return history.withUnsafeBufferPointer { x in
            var e0: Float = 0, adjacent: Float = 0
            for i in 0..<window {
                e0 += x[i] * x[i]
                adjacent += x[i] * x[i + 1]
            }
            guard e0 > 0, adjacent / e0 >= 0.5 else { return 0 }
            var eL: Float = 0
            for i in minLag..<(minLag + window) { eL += x[i] * x[i] }
            var best: Float = 0
            for lag in minLag...maxLag {
                if lag > minLag {
                    eL += x[lag + window - 1] * x[lag + window - 1] - x[lag - 1] * x[lag - 1]
                }
                var dot: Float = 0
                for i in 0..<window { dot += x[i] * x[i + lag] }
                if eL > 0 { best = max(best, dot / (e0 * eL).squareRoot()) }
            }
            return best
        }
    }
}
