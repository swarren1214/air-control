import AVFoundation
import Foundation
import Observation
import QuartzCore
import Speech

/// Hands audio buffers from the realtime audio thread to the current recognition request.
final class AudioTapSink: @unchecked Sendable {
    private let lock = NSLock()
    private var _request: SFSpeechAudioBufferRecognitionRequest?
    var onLevel: ((Float) -> Void)?

    var request: SFSpeechAudioBufferRecognitionRequest? {
        get { lock.lock(); defer { lock.unlock() }; return _request }
        set { lock.lock(); _request = newValue; lock.unlock() }
    }
}

/// One finished utterance.
struct VoiceInput {
    /// Lowercased words, punctuation stripped, wake phrase removed.
    var text: String
    /// As recognized, with capitals and punctuation (wake phrase removed). Used for typing.
    var raw: String
    var wake: Bool
    /// When it was spoken (CACurrentMediaTime), for the lip-movement check.
    var span: ClosedRange<TimeInterval>
}

/// Always-on, on-device listening. Normally gated by "Hey Mac"; in open-mic mode (your hand is
/// up and you're looking at the screen, or you're dictating) speech is taken without it.
@Observable
final class VoiceController {
    enum Phase: Equatable {
        case off
        case unavailable(String)
        case idle
        case awake
        case processing
    }

    private(set) var phase: Phase = .off
    private(set) var transcript = ""
    private(set) var heardWake = false
    private(set) var openMic = false
    /// Dictation: every phrase is typed; commits on shorter pauses with full punctuation.
    private(set) var dictating = false
    private(set) var levels: [Float] = Array(repeating: 0, count: 24)
    private(set) var lastHeard = ""
    /// The full running transcript, for live captions.
    private(set) var live = ""
    private(set) var liveUpdated: TimeInterval = 0

    @ObservationIgnored var onInput: ((VoiceInput) -> Void)?
    /// Apple's voice processing on the mic: noise suppression and echo cancellation.
    @ObservationIgnored var noiseReduction = true

    /// "Hey Mac" plus the ways the recognizer commonly hears it. All start with a greeting, so "mac"
    /// on its own ("open the Mac App Store") never wakes it.
    static let wakePhrases = ["hey mac", "hey mack", "hey mak", "hey max", "hay mac", "hey mach", "hey mack s",
                              "a mac", "hey mac s"]
    static let hints = ["hey mac", "click", "double click", "right click", "scroll down", "scroll up", "open",
                        "switch to", "close window", "new tab", "go back", "copy", "paste", "undo", "type",
                        "press return", "mission control", "start dictation", "stop dictation"]
    /// One- or two-word commands that commit almost immediately in open-mic mode.
    static let quickCommands: Set<String> = ["click", "double click", "right click", "copy", "paste", "cut", "undo",
                                             "redo", "go back", "back", "forward", "reload", "refresh", "escape",
                                             "enter", "return", "scroll down", "scroll up", "new tab", "close tab",
                                             "close window", "save", "select all", "mission control", "show desktop"]
    /// Recognition reports words roughly this long after they're spoken.
    static let recognitionLag: TimeInterval = 0.7

    private let engine = AVAudioEngine()
    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private let sink = AudioTapSink()
    @ObservationIgnored private var task: SFSpeechRecognitionTask?
    @ObservationIgnored private var silenceTimer: Timer?
    @ObservationIgnored private var wakeTimer: Timer?
    @ObservationIgnored private var processingReset: DispatchWorkItem?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var wantsRunning = false
    /// Words (normalized) and characters (formatted) of the running transcript already used.
    /// Recognition keeps one long transcript per task; restarting after each command would leave
    /// it deaf for a second, so we move these markers instead.
    @ObservationIgnored private var baseline = 0
    @ObservationIgnored private var rawBaseline = 0
    @ObservationIgnored private var currentWordCount = 0
    @ObservationIgnored private var formatted = ""
    @ObservationIgnored private var candidates: [String] = []
    @ObservationIgnored private var spanStart: TimeInterval?
    @ObservationIgnored private var spanEnd: TimeInterval = 0
    @ObservationIgnored private var spanText = ""

    // MARK: Modes

    func setOpenMic(_ on: Bool) {
        guard on != openMic else { return }
        openMic = on
        if phase == .awake, heardWake { return }   // a "Hey Mac" command in progress carries on
        silenceTimer?.invalidate()
        markUsed()
        if phase == .awake { phase = .idle }
    }

    func setDictating(_ on: Bool) {
        guard on != dictating else { return }
        dictating = on
        silenceTimer?.invalidate()
        markUsed()
        if phase == .awake { phase = .idle }
    }

    // MARK: Lifecycle

    func start() {
        wantsRunning = true
        SFSpeechRecognizer.requestAuthorization { status in
            DispatchQueue.main.async {
                guard status == .authorized else {
                    self.phase = .unavailable("Speech recognition permission off")
                    return
                }
                AVCaptureDevice.requestAccess(for: .audio) { granted in
                    DispatchQueue.main.async {
                        if granted { self.beginAudio() } else { self.phase = .unavailable("Microphone permission off") }
                    }
                }
            }
        }
    }

    func stop() {
        wantsRunning = false
        silenceTimer?.invalidate()
        wakeTimer?.invalidate()
        generation += 1
        task?.cancel()
        task = nil
        sink.request?.endAudio()
        sink.request = nil
        if engine.isRunning { engine.stop() }
        engine.inputNode.removeTap(onBus: 0)
        phase = .off
        transcript = ""
        live = ""
    }

    private func beginAudio() {
        guard wantsRunning else { return }
        guard let recognizer, recognizer.isAvailable else {
            phase = .unavailable("Speech recognition unavailable")
            return
        }
        guard recognizer.supportsOnDeviceRecognition else {
            phase = .unavailable("On-device speech not installed — add English in Keyboard → Dictation")
            return
        }

        let input = engine.inputNode
        // Must be set before reading the format: voice processing changes it.
        if input.isVoiceProcessingEnabled != noiseReduction {
            try? input.setVoiceProcessingEnabled(noiseReduction)
        }
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            phase = .unavailable("No microphone")
            return
        }
        input.removeTap(onBus: 0)

        let sink = self.sink
        sink.onLevel = { [weak self] level in
            DispatchQueue.main.async { self?.push(level: level) }
        }
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            sink.request?.append(buffer)
            guard let data = buffer.floatChannelData?[0] else { return }
            let n = Int(buffer.frameLength)
            guard n > 0 else { return }
            var sum: Float = 0
            for i in 0..<n { sum += data[i] * data[i] }
            sink.onLevel?(min(1, (sum / Float(n)).squareRoot() * 18))
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            phase = .unavailable("Microphone failed to start")
            return
        }
        startRecognition()
    }

    // MARK: Recognition loop

    private func startRecognition() {
        guard wantsRunning, let recognizer else { return }
        task?.cancel()
        generation += 1
        let gen = generation

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = true
        request.contextualStrings = Self.hints
        request.addsPunctuation = true
        sink.request = request

        phase = .idle
        transcript = ""
        heardWake = false
        baseline = 0
        rawBaseline = 0
        currentWordCount = 0
        formatted = ""
        candidates = []
        spanStart = nil
        spanText = ""

        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            let text = result?.bestTranscription.formattedString
            let alternatives = (result?.transcriptions ?? []).dropFirst().prefix(4).map(\.formattedString)
            let isFinal = result?.isFinal ?? false
            let failed = error != nil
            DispatchQueue.main.async {
                self?.handle(text: text, alternatives: Array(alternatives), isFinal: isFinal, failed: failed, generation: gen)
            }
        }
    }

    private func restart(after delay: TimeInterval = 0.15) {
        silenceTimer?.invalidate()
        wakeTimer?.invalidate()
        generation += 1
        sink.request?.endAudio()
        sink.request = nil
        task?.cancel()
        task = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.startRecognition()
        }
    }

    private func handle(text: String?, alternatives: [String], isFinal: Bool, failed: Bool, generation gen: Int) {
        guard gen == generation, wantsRunning else { return }

        if let text {
            formatted = text
            if rawBaseline > text.count { rawBaseline = text.count }
            let all = Self.normalize(text).split(separator: " ")
            currentWordCount = all.count
            if baseline > all.count { baseline = all.count }   // the recognizer revised earlier words
            var fresh = all.dropFirst(baseline).joined(separator: " ")
            let freshAlternatives = alternatives.map {
                Self.normalize($0).split(separator: " ").dropFirst(baseline).joined(separator: " ")
            }
            // The wake phrase is easy to miss in the top guess; accept it from any reading.
            if Self.command(after: fresh) == nil,
               let alt = freshAlternatives.first(where: { Self.command(after: $0) != nil }) {
                fresh = alt
            }
            if text != live {
                live = text
                liveUpdated = CACurrentMediaTime()
            }
            if !fresh.isEmpty {
                if fresh != spanText {
                    spanText = fresh
                    let now = CACurrentMediaTime()
                    if spanStart == nil { spanStart = now }
                    spanEnd = now
                }
                lastHeard = fresh
            }

            if let command = Self.command(after: fresh) {
                heardWake = true
                if phase != .awake {
                    phase = .awake
                    armWakeTimeout()
                }
                candidates = freshAlternatives.compactMap { Self.command(after: $0) }.filter { !$0.isEmpty }
                if command != transcript {
                    transcript = command
                    if !command.isEmpty { armSilence(1.1) }
                }
            } else if (openMic || dictating), !heardWake {
                candidates = freshAlternatives.filter { !$0.isEmpty }
                if !fresh.isEmpty, fresh != transcript {
                    if phase != .awake { phase = .awake }
                    transcript = fresh
                    if dictating {
                        armSilence(0.9)
                    } else {
                        armSilence(Self.quickCommands.contains(fresh) ? 0.4 : 1.2)
                    }
                }
            }
        }

        if failed || isFinal {
            // The task ended (long silence, an error, or its ~1 minute limit): use what we have,
            // then start a fresh one. This is the only place recognition restarts.
            if phase == .awake, !transcript.isEmpty { commit() }
            restart(after: failed ? 0.5 : 0.1)
        }
    }

    private func armSilence(_ delay: TimeInterval) {
        silenceTimer?.invalidate()
        silenceTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            self?.commit()
        }
    }

    private func armWakeTimeout() {
        wakeTimer?.invalidate()
        wakeTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: false) { [weak self] _ in
            guard let self, self.phase == .awake, self.transcript.isEmpty else { return }
            self.markUsed()
            self.phase = .idle
        }
    }

    private func commit() {
        silenceTimer?.invalidate()
        wakeTimer?.invalidate()
        let best = transcript.trimmingCharacters(in: .whitespaces)
        guard phase == .awake, !best.isEmpty else { return }
        // If the top guess isn't a command but another reading is ("click sand" vs "click send"
        // is rare, but "pace" vs "paste" isn't), use that one. Dictation always takes the top guess.
        var command = best
        if !dictating, MacCommandParser.parse(best) == .unknown,
           let alt = candidates.first(where: { MacCommandParser.parse($0) != .unknown }) {
            command = alt
        }
        let wake = heardWake
        var raw = String(formatted.dropFirst(rawBaseline)).trimmingCharacters(in: .whitespacesAndNewlines)
        if wake { raw = Self.rawAfterWake(raw) }
        let end = spanEnd
        let start = min(spanStart ?? end, end) - Self.recognitionLag
        markUsed()
        phase = .processing
        onInput?(VoiceInput(text: command, raw: raw, wake: wake, span: start...end))
        processingReset?.cancel()
        let reset = DispatchWorkItem { [weak self] in
            if self?.phase == .processing { self?.phase = .idle }
        }
        processingReset = reset
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: reset)
    }

    /// Marks everything heard so far as used, without stopping recognition.
    private func markUsed() {
        silenceTimer?.invalidate()
        wakeTimer?.invalidate()
        baseline = currentWordCount
        rawBaseline = formatted.count
        spanStart = nil
        spanText = ""
        transcript = ""
        candidates = []
        heardWake = false
        if phase == .awake { phase = .idle }
    }

    private func push(level: Float) {
        guard phase == .awake || phase == .processing else { return }
        levels.removeFirst()
        levels.append(level)
    }

    static func normalize(_ text: String) -> String {
        let cleaned = String(text.lowercased().map { $0.isLetter || $0.isNumber ? $0 : " " })
        return cleaned.split(separator: " ").joined(separator: " ")
    }

    /// The words after the last wake phrase, or nil if no wake phrase was heard.
    static func command(after text: String) -> String? {
        let normalized = normalize(text)
        var best: Range<String.Index>?
        for phrase in wakePhrases {
            if let r = normalized.range(of: phrase, options: .backwards) {
                if let b = best, b.lowerBound >= r.lowerBound { continue }
                best = r
            }
        }
        guard let r = best else { return nil }
        return String(normalized[r.upperBound...]).trimmingCharacters(in: .whitespaces)
    }

    /// "Hey Mac, type Hello there." → "type Hello there."
    /// Finds the first greeting followed by a wake word, so a "Mac" later in the command
    /// ("type I love my Mac") isn't mistaken for the wake phrase.
    static func rawAfterWake(_ raw: String) -> String {
        let pattern = #"(?i)\b(hey|hay|a)[\s,.!]+(mac|mack|mak|max|mach)('?s)?\b"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: raw, range: NSRange(raw.startIndex..., in: raw)),
              let r = Range(match.range, in: raw) else { return raw }
        return String(raw[r.upperBound...]).trimmingCharacters(in: CharacterSet(charactersIn: " ,.!?:;-"))
    }
}
