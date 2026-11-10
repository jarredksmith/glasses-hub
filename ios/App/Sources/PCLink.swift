import Foundation
import UIKit

struct PCNote: Identifiable, Codable, Equatable {
    var id = UUID()
    var title: String
    var body: String
    var source: String
    var time: Date
}

struct PCPlugin: Identifiable, Equatable {
    struct Button: Identifiable, Equatable { var id: String; var label: String }
    var id: String
    var name: String
    var on: Bool
    var state: String
    var actions: [Button]
}

/// The link to Glasses Hub on the PC. Same pairing code and relay as the web app; the PC sees this app
/// as a phone that takes notes over the relay, so nothing on the PC needs to change.
///
/// Notes arrive while this app is running (in front, or behind with the display on). They don't arrive
/// while it's closed; that would need Apple push, which the PC doesn't speak yet.
@MainActor
final class PCLink: ObservableObject {
    @Published private(set) var connected = false
    @Published private(set) var paired: Bool
    @Published private(set) var pcName: String
    @Published private(set) var plugins: [PCPlugin] = []
    @Published private(set) var quietHours = false
    /// True when the PC has an Apple push key and this app's address, so notes arrive even when it's closed.
    @Published private(set) var reachesWhenClosed = false
    @Published private(set) var message = ""
    @Published private(set) var notes: [PCNote] = []
    @Published var code: String

    var onNote: ((PCNote) -> Void)?

    private let defaults = UserDefaults.standard
    private let relay = "https://ntfy.sh"
    private var keys: PairingKeys?
    private var listener: Task<Void, Never>?
    private var heartbeat: Task<Void, Never>?
    private var tokenObserver: NSObjectProtocol?
    private var seen = Set<String>()
    private let deviceID: String

    init() {
        code = defaults.string(forKey: "pc.code") ?? ""
        paired = defaults.bool(forKey: "pc.paired")
        pcName = defaults.string(forKey: "pc.name") ?? ""
        if let saved = defaults.string(forKey: "pc.device") { deviceID = saved }
        else {
            deviceID = (0..<9).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
            defaults.set(deviceID, forKey: "pc.device")
        }
        tokenObserver = NotificationCenter.default.addObserver(forName: PushDelegate.changed, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.keys != nil else { return }
                await self.send("hello", self.helloFields)        // tell the PC the new push address
            }
        }
        if let data = defaults.data(forKey: "pc.notes"), let saved = try? JSONDecoder().decode([PCNote].self, from: data) { notes = saved }
    }

    var hasCode: Bool { PairingKeys.normalize(code).count == 16 }

    // MARK: Pairing

    func pair() async {
        guard let made = PairingKeys(code: code) else {
            message = "The code has 16 letters and numbers, like ABCD-EFGH-JKLM-NPQR."; return
        }
        code = PairingKeys.pretty(code)
        defaults.set(code, forKey: "pc.code")
        keys = made; paired = false; message = "Connecting to your PC…"
        startListening()
        try? await Task.sleep(nanoseconds: 1_200_000_000)        // give the listener a moment to be on the channel
        await send("hello", helloFields)
        var answered = false
        for _ in 0..<40 where !answered {                        // up to 20 seconds
            try? await Task.sleep(nanoseconds: 500_000_000)
            answered = paired
        }
        message = answered ? "" : "Your PC didn't answer. Check that Glasses Hub is running there and the code matches."
    }

    func forget() {
        Task { await send("forget") }
        stopListening()
        keys = nil; paired = false; pcName = ""; plugins = []; code = ""; reachesWhenClosed = false
        for key in ["pc.code", "pc.paired", "pc.name"] { defaults.removeObject(forKey: key) }
    }

    /// Start (or restart) listening if there's a saved pairing. Safe to call often.
    func resume() {
        guard listener == nil, paired, let made = PairingKeys(code: code) else { return }
        keys = made
        startListening()
        Task { await send("hello", helloFields) }
    }

    /// The app is about to stop running in the background. Tell the PC, so it switches to Apple push.
    func pause() {
        guard listener != nil else { return }
        stopListening()
        Task { await send("live", ["on": false]) }
    }

    private func stopListening() {
        listener?.cancel(); listener = nil
        heartbeat?.cancel(); heartbeat = nil
        connected = false
    }

    func toggle(_ plugin: PCPlugin, on: Bool) { Task { await send("toggle", ["plugin": plugin.id, "on": on]) } }
    func run(_ action: PCPlugin.Button, of plugin: PCPlugin) { Task { await send("action", ["plugin": plugin.id, "action": action.id]) } }
    func sendTest() { Task { await send("test") } }
    func refresh() { Task { await send("status") } }
    func clearNotes() { notes = []; defaults.removeObject(forKey: "pc.notes") }

    private var helloFields: [String: Any] {
        // Wide limits: the PC sends each note whole and this app lays it out for the glasses itself.
        var fields: [String: Any] = ["name": UIDevice.current.name + " (app)", "widths": ["title": 120, "body": 1500],
                                     "hasPush": false, "live": listener != nil]
        if let token = defaults.string(forKey: PushDelegate.tokenKey),
           let team = Bundle.main.object(forInfoDictionaryKey: "HubTeamID") as? String, !team.isEmpty,
           let topic = Bundle.main.bundleIdentifier {
            fields["apns"] = ["token": token, "team": team, "topic": topic]
        }
        return fields
    }

    // MARK: Relay

    @discardableResult
    private func send(_ command: String, _ extra: [String: Any] = [:]) async -> Bool {
        guard let keys else { return false }
        var object = extra
        object["cmd"] = command; object["id"] = deviceID; object["t"] = Date().timeIntervalSince1970
        guard let body = keys.seal(object), let url = URL(string: "\(relay)/\(keys.up)") else { return false }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"; request.httpBody = Data(body.utf8); request.timeoutInterval = 15
        request.setValue("text/plain", forHTTPHeaderField: "Content-Type")
        for attempt in 0..<3 {
            if let (_, response) = try? await URLSession.shared.data(for: request),
               (response as? HTTPURLResponse)?.statusCode == 200 { return true }
            try? await Task.sleep(nanoseconds: UInt64(1_500_000_000 * (attempt + 1)))
        }
        return false
    }

    private func startListening() {
        stopListening()
        guard let keys else { return }
        let channel = keys.down
        // While this app is running it takes notes over the relay and shows them itself. The PC is told
        // every 45 seconds; when the word stops coming, it falls back to Apple push.
        heartbeat = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 45_000_000_000)
                guard !Task.isCancelled, let self else { return }
                await self.send("live", ["on": true])
            }
        }
        listener = Task { @MainActor [weak self] in
            var since = String(Int(Date().timeIntervalSince1970))
            var wait: UInt64 = 2
            while !Task.isCancelled {
                guard let self, let url = URL(string: "\(self.relay)/\(channel)/json?since=\(since)") else { return }
                var request = URLRequest(url: url)
                request.timeoutInterval = 120                 // the relay sends a keep-alive line well inside this
                do {
                    let (bytes, response) = try await URLSession.shared.bytes(for: request)
                    guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
                    self.connected = true; wait = 2
                    for try await line in bytes.lines {
                        guard let event = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                              event["event"] as? String == "message", let id = event["id"] as? String else { continue }
                        since = id
                        guard !self.seen.contains(id), let text = event["message"] as? String else { continue }
                        self.seen.insert(id)
                        if let message = keys.open(text) { self.handle(message) }
                    }
                } catch {}
                guard !Task.isCancelled else { return }
                self.connected = false
                try? await Task.sleep(nanoseconds: wait * 1_000_000_000)
                wait = min(30, wait * 2)
            }
        }
    }

    private func handle(_ message: [String: Any]) {
        if let to = message["to"] as? String, to != deviceID { return }                 // for another phone
        if Date().timeIntervalSince1970 - ((message["t"] as? Double) ?? 0) > 120 { return }   // stale
        switch message["type"] as? String {
        case "welcome", "status":
            if let name = message["pc"] as? String { pcName = name; defaults.set(name, forKey: "pc.name") }
            quietHours = message["quiet"] as? Bool ?? false
            reachesWhenClosed = message["apns"] as? Bool ?? false
            plugins = (message["plugins"] as? [[String: Any]] ?? []).compactMap { p in
                guard let id = p["id"] as? String else { return nil }
                let actions = (p["actions"] as? [[String: Any]] ?? []).compactMap { a -> PCPlugin.Button? in
                    guard let aid = a["id"] as? String else { return nil }
                    return PCPlugin.Button(id: aid, label: a["label"] as? String ?? aid)
                }
                return PCPlugin(id: id, name: p["name"] as? String ?? id, on: p["on"] as? Bool ?? false,
                                state: p["state"] as? String ?? "", actions: actions)
            }
            paired = true; defaults.set(true, forKey: "pc.paired")
        case "toast":
            if let text = message["text"] as? String { self.message = text }
        case "note":
            let note = PCNote(title: message["title"] as? String ?? "", body: message["body"] as? String ?? "",
                              source: message["source"] as? String ?? "hub", time: Date())
            notes.insert(note, at: 0)
            if notes.count > 60 { notes.removeLast(notes.count - 60) }
            if let data = try? JSONEncoder().encode(notes) { defaults.set(data, forKey: "pc.notes") }
            onNote?(note)
        default: break
        }
    }
}
