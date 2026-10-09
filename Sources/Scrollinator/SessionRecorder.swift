import AppKit
import AVFoundation
#if canImport(CLame)
import CLame
#endif

/// Writes a session's audio to a file. `append` runs on the audio thread, `finish` on the main thread.
protocol RecordingWriter: AnyObject, Sendable {
    var url: URL { get }
    func append(_ buffer: AVAudioPCMBuffer)
    /// Closes the file and returns the recorded length in seconds.
    @discardableResult func finish() -> TimeInterval
}

/// Hands microphone buffers from the audio thread to the active writer.
final class RecordingFeed: @unchecked Sendable {
    static let shared = RecordingFeed()

    private let lock = NSLock()
    private var writer: RecordingWriter?

    func attach(_ writer: RecordingWriter?) {
        lock.lock()
        self.writer = writer
        lock.unlock()
    }

    /// Called from the audio tap.
    func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        let writer = self.writer
        lock.unlock()
        writer?.append(buffer)
    }
}

/// Averages a buffer's channels into `mono`: an interface's stereo mix of one mic keeps its level
/// without clipping. Returns the frame count.
private func mixToMono(_ buffer: AVAudioPCMBuffer, into mono: inout [Float]) -> Int {
    guard let channels = buffer.floatChannelData else { return 0 }
    let n = Int(buffer.frameLength), count = Int(buffer.format.channelCount)
    guard n > 0, count > 0 else { return 0 }
    if mono.count < n { mono = [Float](repeating: 0, count: n) }
    for i in 0..<n {
        var sum: Float = 0
        for c in 0..<count { sum += channels[c][i] }
        mono[i] = sum / Float(count)
    }
    return n
}

#if canImport(CLame)
/// Encodes audio to a mono 128 kbps MP3 as it arrives, so an interrupted session still leaves
/// a playable file. Used outside the App Store, where the LGPL LAME encoder is fine to ship.
final class Mp3Writer: RecordingWriter, @unchecked Sendable {
    let url: URL

    private let lock = NSLock()
    private let handle: FileHandle
    private var lame: lame_t?
    private var sampleRate: Double = 0
    private var mono: [Float] = []
    private var encoded: [UInt8] = []
    private var frames = 0
    private var finished = false

    init(url: URL) throws {
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw CocoaError(.fileWriteNoPermission, userInfo: [NSFilePathErrorKey: url.path])
        }
        self.url = url
        handle = try FileHandle(forWritingTo: url)
    }

    deinit {
        if let lame { lame_close(lame) }
    }

    var duration: TimeInterval {
        lock.lock()
        defer { lock.unlock() }
        return sampleRate > 0 ? Double(frames) / sampleRate : 0
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        defer { lock.unlock() }
        guard !finished else { return }
        let rate = buffer.format.sampleRate
        if lame == nil {
            start(sampleRate: rate)
        }
        // An MP3 can't change sample rate midway; skip audio from a device switch that does.
        guard let lame, rate == sampleRate else { return }

        let n = mixToMono(buffer, into: &mono)
        guard n > 0 else { return }
        let capacity = n * 5 / 4 + 7200
        if encoded.count < capacity { encoded = [UInt8](repeating: 0, count: capacity) }
        let bytes = lame_encode_buffer_ieee_float(lame, mono, mono, Int32(n), &encoded, Int32(capacity))
        if bytes > 0 { write(Int(bytes)) }
        frames += n
    }

    /// Flushes the encoder and closes the file. Returns the recorded length in seconds.
    @discardableResult
    func finish() -> TimeInterval {
        lock.lock()
        defer { lock.unlock() }
        guard !finished else { return 0 }
        finished = true
        if let lame {
            if encoded.count < 7200 { encoded = [UInt8](repeating: 0, count: 7200) }
            let bytes = lame_encode_flush(lame, &encoded, Int32(encoded.count))
            if bytes > 0 { write(Int(bytes)) }
        }
        try? handle.close()
        return sampleRate > 0 ? Double(frames) / sampleRate : 0
    }

    private func start(sampleRate rate: Double) {
        guard let encoder = lame_init() else { return }
        lame_set_in_samplerate(encoder, Int32(rate))
        // Keep the mic's rate when MP3 supports it; otherwise LAME picks the closest.
        if [32000.0, 44100, 48000].contains(rate) { lame_set_out_samplerate(encoder, Int32(rate)) }
        lame_set_num_channels(encoder, 1)
        lame_set_mode(encoder, MONO)
        lame_set_brate(encoder, 128)
        lame_set_quality(encoder, 2)
        guard lame_init_params(encoder) >= 0 else {
            lame_close(encoder)
            return
        }
        lame = encoder
        sampleRate = rate
    }

    private func write(_ count: Int) {
        try? handle.write(contentsOf: encoded[0..<count])
    }
}
#endif

/// Encodes audio to a mono 128 kbps AAC (.m4a) file with Apple's built-in encoder.
/// Used by the App Store build. The file is finalized when the session ends.
final class M4aWriter: RecordingWriter, @unchecked Sendable {
    let url: URL

    private let lock = NSLock()
    private var file: AVAudioFile?
    private var format: AVAudioFormat?
    private var mono: [Float] = []
    private var frames = 0
    private var finished = false

    init(url: URL) {
        self.url = url
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        defer { lock.unlock() }
        guard !finished else { return }
        let rate = buffer.format.sampleRate
        if file == nil { start(sampleRate: rate) }
        // A file can't change sample rate midway; skip audio from a device switch that does.
        guard let file, let format, rate == format.sampleRate else { return }
        let n = mixToMono(buffer, into: &mono)
        guard n > 0, let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(n)),
              let dst = out.floatChannelData?[0] else { return }
        out.frameLength = AVAudioFrameCount(n)
        mono.withUnsafeBufferPointer { dst.update(from: $0.baseAddress!, count: n) }
        do {
            try file.write(from: out)
            frames += n
        } catch {}
    }

    @discardableResult
    func finish() -> TimeInterval {
        lock.lock()
        defer { lock.unlock() }
        guard !finished else { return 0 }
        finished = true
        if #available(macOS 15, *) { file?.close() }
        file = nil   // Releasing the file finalizes it on earlier versions.
        return format.map { Double(frames) / $0.sampleRate } ?? 0
    }

    private func start(sampleRate rate: Double) {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1) else { return }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: rate,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 128_000,
        ]
        file = try? AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        self.format = format
    }
}

/// Records the microphone for the length of a prompter session when recording is turned on.
@MainActor
final class SessionRecorder: ObservableObject {
    static let shared = SessionRecorder()

    @Published private(set) var startedAt: Date?
    @Published private(set) var lastSaved: URL?
    @Published private(set) var lastError: String?

    private var writer: RecordingWriter?
    private var scopedFolder: URL?
    private let voice = VoiceDetector.shared

    var isRecording: Bool { writer != nil }

    #if canImport(CLame)
    static let fileExtension = "mp3"
    private static func makeWriter(_ url: URL) throws -> RecordingWriter { try Mp3Writer(url: url) }
    #else
    static let fileExtension = "m4a"
    private static func makeWriter(_ url: URL) throws -> RecordingWriter { M4aWriter(url: url) }
    #endif

    /// ~/Music/Scrollinator Recordings. In the App Store sandbox the usual home-folder APIs point
    /// inside the app's container, so this asks for the real home folder; the music-folder
    /// entitlement allows writing there.
    static var defaultFolder: URL {
        let home = getpwuid(getuid()).map { URL(fileURLWithPath: String(cString: $0.pointee.pw_dir), isDirectory: true) }
            ?? FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent("Music/Scrollinator Recordings", isDirectory: true)
    }

    /// The recordings folder, opened with the sandbox access its bookmark grants.
    /// Call `endFolderAccess` when done writing.
    static func beginFolderAccess() -> (url: URL, scoped: Bool) {
        if let bookmark = Pref.recordingFolderBookmark {
            var stale = false
            if let url = try? URL(resolvingBookmarkData: bookmark, options: .withSecurityScope, bookmarkDataIsStale: &stale) {
                let scoped = url.startAccessingSecurityScopedResource()
                if stale { Pref.setRecordingFolder(url) }
                return (url, scoped)
            }
        }
        return (Pref.recordingFolder, false)
    }

    func start(title: String) {
        stop()
        let (folder, scoped) = Self.beginFolderAccess()
        if scoped { scopedFolder = folder }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            guard FileManager.default.isWritableFile(atPath: folder.path) else {
                throw CocoaError(.fileWriteNoPermission, userInfo: [NSFilePathErrorKey: folder.path])
            }
            let writer = try Self.makeWriter(Self.uniqueURL(in: folder, title: title))
            self.writer = writer
            startedAt = Date()
            lastError = nil
            RecordingFeed.shared.attach(writer)
            voice.acquire("recorder")
        } catch {
            lastError = "Couldn't save recordings in \(folder.path). Choose another folder in Settings."
            endFolderAccess()
        }
    }

    /// Opens the recordings folder in Finder, creating it first.
    static func revealFolder() {
        let (folder, scoped) = beginFolderAccess()
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(folder)
        if scoped { folder.stopAccessingSecurityScopedResource() }
    }

    private func endFolderAccess() {
        scopedFolder?.stopAccessingSecurityScopedResource()
        scopedFolder = nil
    }

    enum Outcome {
        case saved(URL)
        /// Under a second of audio, so nothing was kept.
        case tooShort
    }

    /// Stops and finishes the file. Returns nil if nothing was recording.
    @discardableResult
    func stop() -> Outcome? {
        guard let writer else { return nil }
        RecordingFeed.shared.attach(nil)
        voice.release("recorder")
        self.writer = nil
        startedAt = nil
        let seconds = writer.finish()
        defer { endFolderAccess() }
        if seconds < 1 {
            // Nothing worth keeping (no audio arrived, or the prompter was closed right away).
            try? FileManager.default.removeItem(at: writer.url)
            if voice.permissionDenied { lastError = "Nothing was recorded: microphone access is off." }
            return .tooShort
        }
        lastSaved = writer.url
        return .saved(writer.url)
    }

    /// "Welcome 2026-10-09 at 08.41.mp3" (or .m4a), numbered if that name is taken.
    private static func uniqueURL(in folder: URL, title: String) -> URL {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm"
        let safeTitle = title.components(separatedBy: CharacterSet(charactersIn: "/:\\\n"))
            .joined(separator: "-").trimmingCharacters(in: .whitespaces)
        let base = "\(safeTitle.isEmpty ? "Recording" : safeTitle) \(formatter.string(from: Date()))"
        var url = folder.appendingPathComponent("\(base).\(fileExtension)")
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent("\(base) \(n).\(fileExtension)")
            n += 1
        }
        return url
    }
}
