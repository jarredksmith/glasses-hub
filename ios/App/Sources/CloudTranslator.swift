import AVFoundation
import Foundation
import Security

/// Streams the phone's microphone to Soniox's real-time API and hands back its messages, which carry
/// the translation as it forms. Needs the user's own Soniox API key and an internet connection; the
/// audio goes to Soniox's servers.
@MainActor
final class CloudTranslator {
    private let engine = AVAudioEngine()
    private var socket: URLSessionWebSocketTask?
    private var run = 0
    private(set) var running = false
    /// One message from the service, as received.
    var onMessage: ((Data) -> Void)?
    /// The stream ended without being asked to, with the reason.
    var onDropped: ((String) -> Void)?

    /// Starts listening and translating. Returns what went wrong, or nil.
    func start(key: String, from: String, to: String, speakers: Bool) async -> String? {
        stop()
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "Add your Soniox API key in the app, under Apps > Live translate." }
        let micAllowed = await withCheckedContinuation { (done: CheckedContinuation<Bool, Never>) in
            AVAudioApplication.requestRecordPermission { done.resume(returning: $0) }
        }
        guard micAllowed else { return "Allow the microphone for Glasses Hub in the iPhone's Settings." }
        guard let url = URL(string: "wss://stt-rt.soniox.com/transcribe-websocket") else { return "Bad address." }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(trimmed)", forHTTPHeaderField: "Authorization")
        let task = URLSession.shared.webSocketTask(with: request)
        task.resume()
        let config: [String: Any] = [
            "model": "stt-rt-v6", "audio_format": "s16le", "num_channels": 1, "sample_rate": 16000,
            "language_hints": [from], "enable_endpoint_detection": true, "enable_speaker_diarization": speakers,
            "translation": ["type": "one_way", "target_language": to],
        ]
        guard let body = try? JSONSerialization.data(withJSONObject: config), let text = String(data: body, encoding: .utf8) else { return "Couldn't build the request." }
        do { try await task.send(.string(text)) }
        catch { task.cancel(with: .goingAway, reason: nil); return "Couldn't reach Soniox. Check your connection and your API key." }

        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playAndRecord, mode: .default, options: [.mixWithOthers, .defaultToSpeaker])
        try? session.setActive(true, options: [])
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0,
              let wire = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true),
              let converter = AVAudioConverter(from: format, to: wire) else {
            task.cancel(with: .goingAway, reason: nil); return "The microphone isn't available."
        }
        input.removeTap(onBus: 0)
        CloudTranslator.tap(input, format: format, pump: AudioPump(converter: converter, format: wire, task: task))
        do { try engine.start() } catch { input.removeTap(onBus: 0); task.cancel(with: .goingAway, reason: nil); return "Couldn't start the microphone." }

        socket = task
        running = true
        run += 1
        let mine = run
        CloudTranslator.listen(task) { [weak self] data, failure in
            Task { @MainActor in self?.received(data, failure, run: mine) }
        }
        return nil
    }

    func stop() {
        guard running || socket != nil else { return }
        running = false
        run += 1
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        socket?.send(.string("")) { _ in }                      // an empty text frame ends the stream politely
        socket?.cancel(with: .normalClosure, reason: nil)
        socket = nil
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [.mixWithOthers])
    }

    private func received(_ data: Data?, _ failure: String?, run mine: Int) {
        guard mine == run, running else { return }
        if let data { onMessage?(data) }
        if let failure { stop(); onDropped?(failure) }
    }

    // Set up outside the main actor: these run on the audio thread and the network's queue.

    nonisolated private static func tap(_ input: AVAudioInputNode, format: AVAudioFormat, pump: AudioPump) {
        input.installTap(onBus: 0, bufferSize: 2048, format: format) { buffer, _ in pump.push(buffer) }
    }

    nonisolated private static func listen(_ task: URLSessionWebSocketTask, report: @escaping @Sendable (Data?, String?) -> Void) {
        task.receive { result in
            switch result {
            case .success(.string(let text)): report(Data(text.utf8), nil); listen(task, report: report)
            case .success(.data(let data)): report(data, nil); listen(task, report: report)
            case .success: listen(task, report: report)
            case .failure: report(nil, "The connection to Soniox dropped.")
            }
        }
    }
}

/// Converts microphone audio to what the service wants (16 kHz, 16-bit, mono) and sends it.
private final class AudioPump: @unchecked Sendable {
    private let converter: AVAudioConverter
    private let format: AVAudioFormat
    private let task: URLSessionWebSocketTask

    init(converter: AVAudioConverter, format: AVAudioFormat, task: URLSessionWebSocketTask) {
        self.converter = converter; self.format = format; self.task = task
    }

    func push(_ buffer: AVAudioPCMBuffer) {
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return }
        var fed = false
        var problem: NSError?
        let status = converter.convert(to: out, error: &problem) { _, state in
            if fed { state.pointee = .noDataNow; return nil }
            fed = true
            state.pointee = .haveData
            return buffer
        }
        guard status != .error, out.frameLength > 0, let samples = out.int16ChannelData else { return }
        let data = Data(bytes: samples[0], count: Int(out.frameLength) * MemoryLayout<Int16>.size)
        task.send(.data(data)) { _ in }
    }
}

/// Small secrets (API keys) kept in the iPhone's Keychain.
enum Secrets {
    private static func query(_ name: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "com.jarredsmith.glasseshub.keys", kSecAttrAccount as String: name]
    }
    static func get(_ name: String) -> String {
        var q = query(name)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }
    static func set(_ name: String, _ value: String) {
        SecItemDelete(query(name) as CFDictionary)
        guard !value.isEmpty else { return }
        var q = query(name)
        q[kSecValueData as String] = Data(value.utf8)
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(q as CFDictionary, nil)
    }
}
