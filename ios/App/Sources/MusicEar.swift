import AVFoundation
import HubCore

/// Listens through the phone's microphone for the guitar and drum trainers.
@MainActor
final class MusicEar {
    enum Mode { case chords, drums }
    private let mic = AVAudioEngine()
    private(set) var listening = false
    /// The notes sounding, a few times a second (chords mode).
    var onChroma: (([Double], Double) -> Void)?
    /// A drum hit (drums mode).
    var onHit: ((DrumHit) -> Void)?

    /// Asks for the microphone if needed and starts listening. Returns what went wrong, or nil.
    func start(_ mode: Mode) async -> String? {
        stop()
        let allowed = await withCheckedContinuation { (done: CheckedContinuation<Bool, Never>) in
            AVAudioApplication.requestRecordPermission { done.resume(returning: $0) }
        }
        guard allowed else { return "Allow the microphone for Glasses Hub in the iPhone's Settings." }
        let session = AVAudioSession.sharedInstance()
        // measurement mode turns off the phone's automatic levelling, which would flatten drum hits
        try? session.setCategory(.playAndRecord, mode: .measurement, options: [.mixWithOthers, .defaultToSpeaker])
        try? session.setActive(true, options: [])
        let input = mic.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { return "The microphone isn't available." }
        input.removeTap(onBus: 0)
        let listener = Listener(mode: mode, sampleRate: format.sampleRate)
        MusicEar.tap(input, format: format, listener: listener,
                     chroma: { [weak self] chroma, level in Task { @MainActor in self?.onChroma?(chroma, level) } },
                     hit: { [weak self] hit in Task { @MainActor in self?.onHit?(hit) } })
        do { try mic.start() } catch { input.removeTap(onBus: 0); return "Couldn't start the microphone." }
        listening = true
        return nil
    }

    func stop() {
        guard listening else { return }
        mic.inputNode.removeTap(onBus: 0)
        mic.stop()
        listening = false
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [.mixWithOthers])
    }

    /// Installed from outside the main actor: the tap runs on the audio thread.
    nonisolated private static func tap(_ input: AVAudioInputNode, format: AVAudioFormat, listener: Listener,
                                        chroma: @escaping @Sendable ([Double], Double) -> Void, hit: @escaping @Sendable (DrumHit) -> Void) {
        let size: AVAudioFrameCount = listener.mode == .drums ? 512 : 4096
        input.installTap(onBus: 0, bufferSize: size, format: format) { buffer, _ in
            guard let data = buffer.floatChannelData else { return }
            let count = Int(buffer.frameLength)
            guard count > 0 else { return }
            listener.take(Array(UnsafeBufferPointer(start: data[0], count: count)), chroma: chroma, hit: hit)
        }
    }
}

/// The audio thread's working state. Only the tap touches it.
private final class Listener: @unchecked Sendable {
    let mode: MusicEar.Mode
    private let sampleRate: Double
    private var ear: DrumEar
    private var recent = [Float]()

    init(mode: MusicEar.Mode, sampleRate: Double) {
        self.mode = mode; self.sampleRate = sampleRate; ear = DrumEar(sampleRate: sampleRate)
    }

    func take(_ samples: [Float], chroma: (([Double], Double) -> Void), hit: ((DrumHit) -> Void)) {
        switch mode {
        case .drums:
            for found in ear.process(samples) { hit(found) }
        case .chords:
            // a longer stretch of sound tells low notes apart better than one buffer does
            recent += samples
            if recent.count > 8192 { recent.removeFirst(recent.count - 8192) }
            guard recent.count >= 4096 else { return }
            let heard = Chroma.compute(recent, sampleRate: sampleRate)
            chroma(heard.chroma, heard.level)
        }
    }
}
