import AVFoundation
import Speech

/// Listens on the phone's microphone and turns speech into text, a phrase at a time.
///
/// Apple's recogniser hands back one growing transcript and only calls it finished after about a minute,
/// so this cuts phrases itself: when the text stops changing for a moment (a pause), or gets long, the
/// phrase is reported as final and a fresh recognition starts.
@MainActor
final class SpeechListener {
    private let engine = AVAudioEngine()
    private let box = RequestBox()
    private var recognizer: SFSpeechRecognizer?
    private var task: SFSpeechRecognitionTask?
    private var generation = 0
    private var text = ""
    private var changedAt = Date()
    private var restartAt: Date?
    private(set) var running = false

    /// The phrase so far, as it grows.
    var onPartial: ((String) -> Void)?
    /// A finished phrase.
    var onFinal: ((String) -> Void)?

    /// Starts listening in the given language ("es-ES"). Returns what went wrong, or nil.
    func start(locale: String) async -> String? {
        stop()
        let micAllowed = await withCheckedContinuation { (done: CheckedContinuation<Bool, Never>) in
            AVAudioApplication.requestRecordPermission { done.resume(returning: $0) }
        }
        guard micAllowed else { return "Allow the microphone for Glasses Hub in the iPhone's Settings." }
        let speechAllowed = await withCheckedContinuation { (done: CheckedContinuation<Bool, Never>) in
            SFSpeechRecognizer.requestAuthorization { done.resume(returning: $0 == .authorized) }
        }
        guard speechAllowed else { return "Allow Speech Recognition for Glasses Hub in the iPhone's Settings." }
        guard let made = SFSpeechRecognizer(locale: Locale(identifier: locale)), made.isAvailable else {
            return "The iPhone can't recognise speech in that language right now."
        }
        recognizer = made
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playAndRecord, mode: .default, options: [.mixWithOthers, .defaultToSpeaker])
        try? session.setActive(true, options: [])
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { return "The microphone isn't available." }
        input.removeTap(onBus: 0)
        SpeechListener.tap(input, format: format, into: box)
        do { try engine.start() } catch { input.removeTap(onBus: 0); return "Couldn't start the microphone." }
        running = true
        begin()
        return nil
    }

    func stop() {
        guard running else { return }
        running = false
        generation += 1
        task?.cancel(); task = nil
        box.set(nil)
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        text = ""; restartAt = nil
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [.mixWithOthers])
    }

    /// Call a few times a second: ends a phrase after a pause and restarts recognition when it stops.
    func tick() {
        guard running else { return }
        let now = Date()
        if let at = restartAt, now >= at { restartAt = nil; begin(); return }
        guard !text.isEmpty else { return }
        if now.timeIntervalSince(changedAt) > 1.1 || text.count > 180 { finishPhrase() }
    }

    private func finishPhrase() {
        let phrase = text
        text = ""
        if !phrase.isEmpty { onFinal?(phrase) }
        begin()
    }

    /// A fresh recognition: everything heard from now on is a new phrase.
    private func begin() {
        guard running, let recognizer else { return }
        generation += 1
        let mine = generation
        task?.cancel()
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }
        box.set(request)
        text = ""; changedAt = Date()
        task = SpeechListener.recognise(recognizer, request) { [weak self] heard, finished, failed in
            Task { @MainActor in self?.heard(heard, finished: finished, failed: failed, generation: mine) }
        }
    }

    private func heard(_ heard: String?, finished: Bool, failed: Bool, generation mine: Int) {
        guard running, mine == generation else { return }
        if let heard, heard != text {
            text = heard; changedAt = Date()
            onPartial?(heard)
        }
        if finished { finishPhrase() }
        else if failed {                                    // usually "no speech heard": quietly start again
            let phrase = text; text = ""
            if !phrase.isEmpty { onFinal?(phrase) }
            restartAt = Date().addingTimeInterval(0.3)
        }
    }

    // These run on the audio and recognition threads, so they're set up outside the main actor.

    nonisolated private static func tap(_ input: AVAudioInputNode, format: AVAudioFormat, into box: RequestBox) {
        input.installTap(onBus: 0, bufferSize: 2048, format: format) { buffer, _ in box.append(buffer) }
    }

    nonisolated private static func recognise(_ recognizer: SFSpeechRecognizer, _ request: SFSpeechAudioBufferRecognitionRequest,
                                              report: @escaping @Sendable (String?, Bool, Bool) -> Void) -> SFSpeechRecognitionTask {
        recognizer.recognitionTask(with: request) { result, error in
            report(result?.bestTranscription.formattedString, result?.isFinal ?? false, error != nil)
        }
    }
}

/// The recognition request the microphone is currently feeding, shared with the audio thread.
private final class RequestBox: @unchecked Sendable {
    private let lock = NSLock()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    func set(_ new: SFSpeechAudioBufferRecognitionRequest?) {
        lock.lock(); let old = request; request = new; lock.unlock()
        old?.endAudio()
    }
    func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock(); let current = request; lock.unlock()
        current?.append(buffer)
    }
}
