// Tracking test: does "Follow my words" stay on the speaker at every prompter size?
//
// Run it with Tests/Tracking/run.sh. Steps:
//   prepare <dir>          macOS text-to-speech reads the practice script one sentence at a time,
//                          at speeds from 140 to 220 wpm with uneven pauses, plus an off-script ad-lib
//   record  <dir> <name>   stream that audio in real time through the app's real speech recognition
//                          and script matcher; save which word was recognized when, and when the
//                          voice counted as speaking ("in-order" reads straight through; "hard" adds an
//                          ad-lib, a re-read and a skip)
//   replay  <dir> <name>   replay the recording through the app's real PrompterView layout, WordLayout,
//                          PaceFollower and ScrollMotion at many widths, heights and font sizes, and
//                          with size changes mid-read; report how far the reading line strays from
//                          the speaker, and PASS or FAIL
//
// Recording once and replaying many times keeps recognition identical across sizes, so differences
// come from layout and scrolling alone.
import AppKit
import AVFoundation

let fs = 48000.0
let script = Script.practice.body
let args = CommandLine.arguments
let dir = args.count > 2 ? args[2] : "."
let traceName = args.count > 3 ? args[3] : "in-order"

struct Sentence: Codable { let file: String; let text: String; let pause: Double }
struct Event: Codable { let t: Double; let word: Int; let lag: Double }
struct Segment: Codable { let start: Double; let end: Double; let first: Int; let count: Int }
struct Trace: Codable { var events: [Event]; var speaking: [Bool]; var bufferSeconds: Double; var truth: [Segment]; var duration: Double }

let adlib = "Actually, before I go on, let me quickly mention how great the coffee was this morning, so thank you to whoever brought it."

func url(_ name: String) -> URL { URL(fileURLWithPath: dir).appendingPathComponent(name) }

// MARK: Prepare

func sentences(of text: String) -> [String] {
    text.components(separatedBy: "\n\n").flatMap { paragraph -> [String] in
        var out: [String] = [], current = ""
        for ch in paragraph.replacingOccurrences(of: "\n", with: " ") {
            current.append(ch)
            if ".!?".contains(ch) {
                out.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            }
        }
        let rest = current.trimmingCharacters(in: .whitespaces)
        if !rest.isEmpty { out.append(rest) }
        return out.filter { !$0.isEmpty }
    }
}

func say(_ text: String, rate: Int, to file: String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/say")
    p.arguments = ["-r", String(rate), "-o", url(file).path, "--file-format=WAVE", "--data-format=LEF32@48000", text]
    try! p.run()
    p.waitUntilExit()
}

func prepare() {
    try! FileManager.default.createDirectory(at: url("audio"), withIntermediateDirectories: true)
    let rates = [150, 175, 200, 220, 185, 160, 140, 170, 205, 215, 180, 150, 165, 195]
    let pauses = [0.4, 0.9, 0.3, 1.2, 0.5, 0.7, 0.35, 1.0, 0.45, 0.6, 0.8, 0.3, 0.5, 0.4]
    var list: [Sentence] = []
    for (i, text) in sentences(of: script).enumerated() {
        let file = String(format: "audio/s%02d.wav", i)
        say(text, rate: rates[i % rates.count], to: file)
        list.append(Sentence(file: file, text: text, pause: pauses[i % pauses.count]))
    }
    say(adlib, rate: 180, to: "audio/adlib.wav")
    try! JSONEncoder().encode(list).write(to: url("sentences.json"))
    print("prepared \(list.count) sentences")
}

// MARK: Record

/// Sentence numbers to read; "A" is the ad-lib. The hard run ad-libs after "I cannot let that happen.",
/// re-reads "Read these words out loud." through "I do not get tired.", and skips "Try going faster."
/// and "I will keep up."
func order(_ count: Int) -> [String] {
    let all = (0..<count).map(String.init)
    guard traceName == "hard" else { return all }
    return Array(all[0...12]) + ["A"] + Array(all[13...18]) + Array(all[13...16]) + Array(all[21...])
}

@MainActor final class Recorder {
    var audio: [Float] = []
    var truth: [Segment] = []
    let analyzer = VoiceAnalyzer(sampleRate: 48000, channels: 1)
    var floorDB: Float = 0, firstBuffer = true, recent: [(Double, Bool)] = [], lastLoud = -9.0
    var speaking: [Bool] = []
    var events: [Event] = []
    var fed = 0, startTime = 0.0

    init() {
        let list = try! JSONDecoder().decode([Sentence].self, from: Data(contentsOf: url("sentences.json")))
        var firstWord: [Int] = [], total = 0
        for s in list { firstWord.append(total); total += ScriptAligner.tokens(in: s.text).count }
        precondition(total == ScriptAligner(text: script).words.count, "sentences don't add up to the script")
        var lastSpoken = -1
        audio += [Float](repeating: 0, count: Int(fs))
        for item in order(list.count) {
            let isAdlib = item == "A"
            let file = isAdlib ? "audio/adlib.wav" : list[Int(item)!].file
            let f = try! AVAudioFile(forReading: url(file))
            let b = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: AVAudioFrameCount(f.length))!
            try! f.read(into: b)
            let x = UnsafeBufferPointer(start: b.floatChannelData![0], count: Int(b.frameLength))
            let a = x.firstIndex { abs($0) > 0.01 } ?? 0, z = x.lastIndex { abs($0) > 0.01 } ?? x.count - 1
            let start = Double(audio.count) / fs
            audio += x[a...z]
            if isAdlib {
                truth.append(Segment(start: start, end: Double(audio.count) / fs, first: lastSpoken + 1, count: 0))
            } else {
                let n = ScriptAligner.tokens(in: list[Int(item)!].text).count
                truth.append(Segment(start: start, end: Double(audio.count) / fs, first: firstWord[Int(item)!], count: n))
                lastSpoken = firstWord[Int(item)!] + n - 1
            }
            audio += [Float](repeating: 0, count: Int((isAdlib ? 0.6 : list[Int(item)!].pause) * fs))
        }
        audio += [Float](repeating: 0, count: Int(2 * fs))
        for i in audio.indices { audio[i] += Float.random(in: -0.0005...0.0005) }   // room hiss
        print(String(format: "recording \"%@\": %.0f s of audio in real time…", traceName, Double(audio.count) / fs))
    }

    func start() {
        let follower = SpeechFollower.shared
        follower.onMatch = { [unowned self] word, lag in events.append(Event(t: CACurrentMediaTime() - startTime, word: word, lag: lag)) }
        follower.setActive(true, text: script)
        follower.reposition(toWord: -1)
        Task { @MainActor in
            while follower.status == .off || follower.status == .preparing { try? await Task.sleep(for: .milliseconds(100)) }
            guard follower.status == .listening || follower.status == .following else {
                print("speech recognition unavailable: \(follower.status)"); exit(1)
            }
            try? await Task.sleep(for: .seconds(1))
            startTime = CACurrentMediaTime()
            let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [unowned self] _ in MainActor.assumeIsolated { tick() } }
            RunLoop.main.add(timer, forMode: .common)
        }
    }

    func tick() {
        let t = CACurrentMediaTime() - startTime
        let format = AVAudioFormat(standardFormatWithSampleRate: fs, channels: 1)!
        while fed + 1024 <= audio.count && Double(fed + 1024) / fs <= t {
            let b = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1024)!
            b.frameLength = 1024
            for k in 0..<1024 { b.floatChannelData![0][k] = audio[fed + k] }
            RecognitionFeed.shared.append(b)
            // VoiceDetector's speech decision, on the same audio.
            let reading = analyzer.analyze(UnsafePointer(b.floatChannelData!), channels: 1, frames: 1024)
            let bt = Double(fed) / fs, dt = 1024 / fs
            if firstBuffer { floorDB = reading.db; firstBuffer = false } else {
                floorDB = reading.db < floorDB ? reading.db : floorDB + 1.5 * Float(dt)
            }
            floorDB = max(floorDB, -75)
            recent.append((bt, reading.db >= floorDB + VoiceDetector.margin(for: 0.5) && reading.voiced))
            recent.removeAll { bt - $0.0 > 0.3 }
            if Double(recent.filter(\.1).count) / Double(recent.count) >= 0.4 { lastLoud = bt }
            speaking.append(bt - lastLoud < 0.5)
            fed += 1024
        }
        if fed + 1024 > audio.count {
            let trace = Trace(events: events, speaking: speaking, bufferSeconds: 1024 / fs, truth: truth, duration: Double(audio.count) / fs)
            try! JSONEncoder().encode(trace).write(to: url("\(traceName).json"))
            print("recorded \(events.count) recognitions")
            exit(0)
        }
    }
}

// MARK: Replay

struct Change { let at: Double; var width: CGFloat? = nil; var height: CGFloat? = nil; var font: CGFloat? = nil }
struct Config { let name: String; let width: CGFloat; let height: CGFloat; let font: CGFloat; var changes: [Change] = [] }
struct Result { let mean: Double; let p90: Int; let worst: Int; let final: Int; let backMoves: Int; let biggestBack: Double }

/// Mirrors PrompterController: the same styled text, word map, anchoring and per-frame motion.
@MainActor func replay(_ trace: Trace, _ config: Config, wordsPerMinute: Double = 162) -> Result {
    let words = ScriptAligner(text: script).words
    let view = PrompterView(frame: NSRect(x: 0, y: 0, width: config.width, height: config.height))
    var font = config.font
    func setText() {
        let (text, lineHeight) = PrompterController.styledText(script, fontSize: font, color: .white)
        view.setText(text, accent: .white, lineHeight: lineHeight)
        view.layoutSubtreeIfNeeded()
    }
    setText()
    var maxOffset: CGFloat = 0
    var layout = WordLayout(ends: [], maxOffset: 0)
    var offset: CGFloat = 0, velocity: CGFloat = 0, pacer = PaceFollower()
    func layoutChanged() {   // PrompterController.layoutChanged()
        maxOffset = max(0, view.textHeight - view.lineHeight)
        let reading = offset > 0.5 ? layout.word(atOffset: offset) : nil
        layout = WordLayout(ends: words.map { view.followOffset(forCharacterAt: NSMaxRange($0.range) - 1) ?? 0 }, maxOffset: maxOffset)
        offset = min(max(reading.map { layout.offset(atWord: $0) } ?? 0, 0), maxOffset)
    }
    layoutChanged()

    let wordsPerSecond = wordsPerMinute / 60, dt = 1.0 / 60
    var pending = config.changes.sorted { $0.at < $1.at }, nextEvent = 0
    var errors: [Int] = [], backMoves = 0, movingBack = false, backFrom = 0.0, biggestBack = 0.0
    var t = 0.0
    while t < trace.duration {
        while let change = pending.first, change.at <= t {
            pending.removeFirst()
            if let f = change.font { font = f; setText() }
            if change.width != nil || change.height != nil {
                view.setFrameSize(NSSize(width: change.width ?? view.frame.width, height: change.height ?? view.frame.height))
                view.layoutSubtreeIfNeeded()
            }
            layoutChanged()
        }
        while nextEvent < trace.events.count && trace.events[nextEvent].t <= t {
            let e = trace.events[nextEvent]
            nextEvent += 1
            pacer.anchor(word: e.word, lag: e.lag, setPace: wordsPerSecond)   // PrompterController.spoke
        }
        let before = offset
        _ = ScrollMotion.step(
            offset: &offset, velocity: &velocity, pacer: &pacer, dt: dt, running: true,
            speaking: trace.speaking[min(Int(t / trace.bufferSeconds), trace.speaking.count - 1)], following: true,
            wordsPerSecond: wordsPerSecond, layout: layout, lineHeight: view.lineHeight, maxOffset: maxOffset
        )
        let back = offset < before - 0.01
        if back && !movingBack { backMoves += 1; backFrom = layout.word(atOffset: before) }
        if back { biggestBack = max(biggestBack, backFrom - layout.word(atOffset: offset)) }
        movingBack = back

        // The speaker's last word against the word at the reading line, ten times a second,
        // once past the first line (both sit at the top there).
        if Int((t * 60).rounded()) % 6 == 0 {
            var speaker = -1
            for s in trace.truth {
                if t >= s.end { speaker = s.first + s.count - 1 }
                else if t >= s.start { speaker = s.first + Int(Double(s.count) * (t - s.start) / (s.end - s.start)) - 1; break }
            }
            let firstLine = layout.ends.lastIndex { $0 <= 0 } ?? 0
            let shown = layout.ends.lastIndex { $0 <= offset + 0.5 } ?? -1
            if speaker > firstLine { errors.append(shown - speaker) }
        }
        t += dt
    }
    let sorted = errors.map(abs).sorted()
    return Result(mean: Double(sorted.reduce(0, +)) / Double(max(sorted.count, 1)),
                  p90: sorted.isEmpty ? 0 : sorted[Int(Double(sorted.count) * 0.9)],
                  worst: sorted.last ?? 0, final: errors.last ?? 0, backMoves: backMoves, biggestBack: biggestBack)
}

@MainActor func replayAll() -> Bool {
    let trace = try! JSONDecoder().decode(Trace.self, from: Data(contentsOf: url("\(traceName).json")))
    let hard = traceName == "hard"
    var failures: [String] = []
    func run(_ c: Config) {
        let r = replay(trace, c)
        // In-order reading must stay close; the hard run includes a 38-word re-read and a 27-word
        // skip, which can't be known until recognition hears them, so it is judged more loosely.
        let ok = abs(r.final) <= 1 && (hard ? r.mean <= 6 && r.p90 <= 20 : r.mean <= 2 && r.worst <= 15)
        if !ok { failures.append(c.name) }
        print(c.name.padding(toLength: 34, withPad: " ", startingAt: 0)
              + String(format: "mean %4.1f  p90 %3d  worst %3d  end %+2d  back %3d (largest %4.1f words)  %@",
                       r.mean, r.p90, r.worst, r.final, r.backMoves, r.biggestBack, ok ? "ok" : "FAIL"))
    }
    print("== \(traceName): \(trace.events.count) recognitions over \(Int(trace.duration)) s; error in words, + = text ahead")
    for (w, h) in [(300.0, 120.0), (460, 190), (700, 220), (943, 265), (1400, 400)] {
        for f in [16.0, 23, 30, 48, 72] {
            run(Config(name: String(format: "%4.0f x %3.0f, %2.0f pt", w, h, f), width: w, height: h, font: f))
        }
    }
    run(Config(name: "font 23 -> 40 mid-read", width: 943, height: 265, font: 23, changes: [Change(at: 30, font: 40)]))
    run(Config(name: "font 40 -> 23 mid-read", width: 943, height: 265, font: 40, changes: [Change(at: 30, font: 23)]))
    run(Config(name: "font 30 -> 60 -> 20 mid-read", width: 700, height: 220, font: 30,
               changes: [Change(at: 30, font: 60), Change(at: 45, font: 20)]))
    run(Config(name: "widen 460 -> 943 mid-read", width: 460, height: 190, font: 30, changes: [Change(at: 30, width: 943)]))
    run(Config(name: "narrow 943 -> 360 mid-read", width: 943, height: 265, font: 23, changes: [Change(at: 30, width: 360)]))
    run(Config(name: "taller 190 -> 400 mid-read", width: 460, height: 190, font: 30, changes: [Change(at: 30, height: 400)]))
    if hard {
        // During the ad-lib, recognition must not place the speaker anywhere new.
        let adlib = trace.truth.first { $0.count == 0 }!
        let stray = trace.events.filter { $0.t > adlib.start + 0.3 && $0.t < adlib.end && $0.word > adlib.first }
        print("matches to new script words during the ad-lib: \(stray.count)  \(stray.isEmpty ? "ok" : "FAIL")")
        if !stray.isEmpty { failures.append("ad-lib false match") }
    }
    print(failures.isEmpty ? "PASS" : "FAIL: " + failures.joined(separator: ", "))
    return failures.isEmpty
}

MainActor.assumeIsolated {
    _ = NSApplication.shared
    switch args.count > 1 ? args[1] : "" {
    case "prepare":
        prepare()
        exit(0)
    case "record":
        let recorder = Recorder()
        recorder.start()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 600))
        print("timed out")
        exit(1)
    case "replay":
        exit(replayAll() ? 0 : 1)
    default:
        print("usage: tracking prepare|record|replay <dir> [in-order|hard]")
        exit(2)
    }
}
