import Foundation
import AVFoundation
import UserNotifications
import EventKit
import CryptoKit
import HubCore

/// Keeps the app running while the phone is locked, so the glasses keep updating from a pocket.
///
/// iOS only lets an app keep working in the background for a few reasons; playing audio is one. This
/// plays a loop of silence (mixed with whatever else is playing, so music and calls are unaffected).
/// It's only on while the display is on, and only if the setting allows it.
@MainActor
final class KeepAwake {
    private var player: AVAudioPlayer?
    private var observer: NSObjectProtocol?
    var isOn: Bool { player != nil }

    func set(_ on: Bool) {
        if on, player == nil {
            guard let made = try? AVAudioPlayer(data: KeepAwake.silence()) else { return }
            made.numberOfLoops = -1; made.volume = 0.01
            player = made
            activate()
            made.prepareToPlay(); made.play()
            observer = NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
                guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                      AVAudioSession.InterruptionType(rawValue: raw) == .ended else { return }
                Task { @MainActor in self?.resume() }       // a call or Siri ended: pick the silence back up
            }
        } else if !on, let playing = player {
            playing.stop(); player = nil
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil
            try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
        }
    }

    /// Called every so often in case the system paused playback without telling us.
    func resume() {
        guard let player, !player.isPlaying else { return }
        activate(); player.play()
    }

    private func activate() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
        try? session.setActive(true, options: [])
    }

    /// One second of 16-bit mono silence as a WAV file.
    private static func silence() -> Data {
        let rate: UInt32 = 8000, bytes = rate * 2
        var d = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        d.append(contentsOf: Array("RIFF".utf8)); u32(36 + bytes)
        d.append(contentsOf: Array("WAVEfmt ".utf8)); u32(16); u16(1); u16(1); u32(rate); u32(rate * 2); u16(2); u16(16)
        d.append(contentsOf: Array("data".utf8)); u32(bytes)
        d.append(Data(count: Int(bytes)))
        return d
    }
}

/// Ordinary iPhone notifications. The RayNeo app mirrors these to the glasses, which is how Glasses Hub
/// reaches them when its own display isn't on.
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()

    func setUp() { UNUserNotificationCenter.current().delegate = self }

    func askPermission() async -> Bool {
        (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])) ?? false
    }

    func post(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title.isEmpty ? "Glasses Hub" : title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    // Show notifications even while the app is in front; otherwise they'd never reach the glasses.
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }
}

/// Fetches for the apps. Each returns nil (or empty) on any failure; callers keep what they had.
enum Feeds {
    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config)
    }()

    static func data(_ url: URL) async -> Data? {
        var request = URLRequest(url: url)
        request.setValue("GlassesHub/2.0 (personal iPhone app)", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return data
    }

    static func games(_ leagues: [League]) async -> [Game]? {
        var all = [Game](), anyWorked = false
        for league in leagues {
            guard let data = await data(league.feed) else { continue }
            anyWorked = true
            all += Scoreboard.parse(data, league: league)
        }
        return anyWorked ? all : nil
    }

    static func nextGame(team: String, league: League) async -> Game? {
        guard let url = league.teamFeed(team), let data = await data(url) else { return nil }
        return Scoreboard.parseTeamNext(data, league: league)
    }

    static func news(_ source: NewsSource) async -> [NewsItem] {
        guard let url = URL(string: source.url), let data = await data(url) else { return [] }
        return News.parseFeed(data, source: source.name)
    }

    /// The readable text of a story's page, or "" if it can't be had.
    static func article(_ url: URL) async -> String {
        guard let data = await data(url), data.count < 4_000_000 else { return "" }
        let html = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
        let text = News.articleText(html: html)
        return text.utf8.count > 60_000 ? String(text.prefix(60_000)) : text
    }

    static func trivia(count: Int) async -> [TriviaQuestion] {
        guard let data = await data(Trivia.feed(count: count)) else { return [] }
        return Trivia.parse(data)
    }

    static func fact(onThisDay: Bool) async -> String? {
        if onThisDay, let data = await data(Facts.onThisDayFeed(Date())), let pick = Facts.parseOnThisDay(data).randomElement() { return pick }
        guard let data = await data(Facts.randomFeed) else { return nil }
        return Facts.parseRandom(data)
    }

    static func place(_ name: String) async -> (name: String, latitude: Double, longitude: Double)? {
        guard let url = Weather.placeLookup(name), let data = await data(url) else { return nil }
        return Weather.parsePlace(data)
    }

    static func weather(place: String, latitude: Double, longitude: Double, celsius: Bool) async -> Weather? {
        guard let data = await data(Weather.feed(latitude: latitude, longitude: longitude, celsius: celsius)) else { return nil }
        return Weather.parse(data, place: place)
    }
}

/// Today's events from the iPhone's calendars. Read-only.
@MainActor
final class CalendarReader {
    private let store = EKEventStore()
    var allowed: Bool { EKEventStore.authorizationStatus(for: .event) == .fullAccess }

    func askPermission() async -> Bool {
        (try? await store.requestFullAccessToEvents()) ?? false
    }

    func today(now: Date = Date()) -> [AgendaItem] {
        guard allowed else { return [] }
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: now)
        guard let end = calendar.date(byAdding: .day, value: 1, to: start) else { return [] }
        let events = store.events(matching: store.predicateForEvents(withStart: start, end: end, calendars: nil))
        return events.map {
            AgendaItem(title: $0.title ?? "Event", start: $0.startDate, end: $0.endDate, allDay: $0.isAllDay,
                       place: $0.location)
        }
    }
}

/// The pairing scheme shared with Glasses Hub on the PC (see desktop/core.py): the 16-character code
/// gives two relay channel names and an AES-256-GCM key. The relay only ever sees scrambled text.
struct PairingKeys {
    static let alphabet = "23456789ABCDEFGHJKLMNPQRSTUVWXYZ"
    let down: String        // PC -> phone
    let up: String          // phone -> PC
    private let key: SymmetricKey

    static func normalize(_ code: String) -> String { String(code.uppercased().filter { alphabet.contains($0) }) }
    static func pretty(_ code: String) -> String {
        let c = Array(normalize(code))
        return stride(from: 0, to: c.count, by: 4).map { String(c[$0..<min(c.count, $0 + 4)]) }.joined(separator: "-")
    }

    init?(code: String) {
        let c = PairingKeys.normalize(code)
        guard c.count == 16 else { return nil }
        let channel = SHA256.hash(data: Data(("glasseshub-channel:" + c).utf8)).map { String(format: "%02x", $0) }.joined().prefix(24)
        down = "gh-\(channel)"; up = "gh-\(channel)-up"
        key = SymmetricKey(data: Data(SHA256.hash(data: Data(("glasseshub-key:" + c).utf8))))
    }

    /// base64(nonce + ciphertext + tag), the same layout the PC and the web app use.
    func seal(_ object: [String: Any]) -> String? {
        guard let plain = try? JSONSerialization.data(withJSONObject: object),
              let box = try? AES.GCM.seal(plain, using: key), let combined = box.combined else { return nil }
        return combined.base64EncodedString()
    }

    func open(_ text: String) -> [String: Any]? {
        guard let raw = Data(base64Encoded: text), let box = try? AES.GCM.SealedBox(combined: raw),
              let plain = try? AES.GCM.open(box, using: key) else { return nil }
        return try? JSONSerialization.jsonObject(with: plain) as? [String: Any]
    }
}
