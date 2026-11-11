import AVFoundation
import HubCore

/// Sound for the tools: the metronome's clicks through the phone, and the tuner listening on its microphone.
@MainActor
final class ToolSound {
    private let clicks = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let mic = AVAudioEngine()
    private var wired = false
    private(set) var metronomeOn = false
    private(set) var listening = false
    /// The pitch heard, about ten times a second; nil when there's no clear note.
    var onPitch: ((Double?) -> Void)?

    private func activate(recording: Bool) {
        let session = AVAudioSession.sharedInstance()
        if recording {
            try? session.setCategory(.playAndRecord, mode: .measurement, options: [.mixWithOthers, .defaultToSpeaker])
        } else {
            try? session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
        }
        try? session.setActive(true, options: [])
    }

    // MARK: Metronome

    func startMetronome(bpm: Int, beats: Int) {
        let rate = 44_100.0
        guard let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1) else { return }
        let samples = Metronome.bar(bpm: bpm, beats: beats, sampleRate: rate)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = buffer.floatChannelData else { return }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        for i in 0..<samples.count { channel[0][i] = samples[i] }
        if !wired {
            clicks.attach(player)
            clicks.connect(player, to: clicks.mainMixerNode, format: format)
            wired = true
        }
        activate(recording: listening)
        if !clicks.isRunning { try? clicks.start() }
        guard clicks.isRunning else { metronomeOn = false; return }
        player.stop()
        player.scheduleBuffer(buffer, at: nil, options: [.loops], completionHandler: nil)
        player.play()
        metronomeOn = true
    }

    func stopMetronome() {
        guard metronomeOn else { return }
        player.stop()
        clicks.stop()
        metronomeOn = false
    }

    // MARK: Tuner

    /// Asks for the microphone if needed and starts listening. False when it isn't allowed or can't start.
    func startListening() async -> Bool {
        if listening { return true }
        let allowed = await withCheckedContinuation { (done: CheckedContinuation<Bool, Never>) in
            AVAudioApplication.requestRecordPermission { done.resume(returning: $0) }
        }
        guard allowed else { return false }
        activate(recording: true)
        let input = mic.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { return false }
        input.removeTap(onBus: 0)
        ToolSound.tap(input, format: format) { [weak self] hz in
            Task { @MainActor in self?.onPitch?(hz) }
        }
        do { try mic.start() } catch { input.removeTap(onBus: 0); return false }
        listening = true
        return true
    }

    func stopListening() {
        guard listening else { return }
        mic.inputNode.removeTap(onBus: 0)
        mic.stop()
        listening = false
        activate(recording: false)
    }

    /// Installed from outside the main actor: the tap runs on the audio thread.
    nonisolated private static func tap(_ input: AVAudioInputNode, format: AVAudioFormat, report: @escaping @Sendable (Double?) -> Void) {
        let rate = format.sampleRate
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in
            guard let data = buffer.floatChannelData else { return }
            let count = Int(buffer.frameLength)
            guard count >= 1024 else { return }
            let samples = Array(UnsafeBufferPointer(start: data[0], count: count))
            report(Pitch.detect(samples, sampleRate: rate))
        }
    }
}
