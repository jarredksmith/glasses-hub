import Foundation

// The RayNeo iO wire format, as far as Glasses Hub needs it.
//
// Layout of one packet (all multi-byte numbers big-endian):
//   AA 55 | length (2) | sequence (2) | type (1) | business (1) | payload | CRC-16/XMODEM (2)
// `length` counts sequence, type, business and payload, so a whole packet is length + 6 bytes.
// The CRC covers the same bytes that `length` counts.
//
// Sources: the owner's own Bluetooth captures, and the public protocol notes in Turbo-IO and OpenRayneo.
// This file is an independent implementation of that format; no third-party code is included.

public enum CRC16 {
    /// CRC-16/XMODEM: polynomial 0x1021, start value 0.
    public static func xmodem<S: Sequence>(_ bytes: S) -> UInt16 where S.Element == UInt8 {
        var crc: UInt16 = 0
        for byte in bytes {
            crc ^= UInt16(byte) << 8
            for _ in 0..<8 { crc = (crc & 0x8000) != 0 ? (crc << 1) ^ 0x1021 : crc << 1 }
        }
        return crc
    }
}

public struct GlassesFrame: Equatable {
    public var sequence: UInt16
    /// Low five bits of the type byte. Zero for every packet Glasses Hub sends.
    public var flags: UInt8
    /// Bytes of slice information announced by the top three bits of the type byte (zero for whole packets).
    public var sliceBytes: Int
    public var business: UInt8
    public var payload: Data

    public init(sequence: UInt16, business: UInt8, payload: Data, flags: UInt8 = 0, sliceBytes: Int = 0) {
        self.sequence = sequence; self.business = business; self.payload = payload
        self.flags = flags; self.sliceBytes = sliceBytes
    }

    /// A whole, unsliced packet: the only kind Glasses Hub reads the payload of.
    public var isPlain: Bool { flags == 0 && sliceBytes == 0 }

    /// Bytes to put on the wire. Only plain packets are ever encoded.
    public func encoded() -> Data {
        let length = payload.count + 4          // sequence (2) + type + business + payload
        var out = Data([0xAA, 0x55, UInt8(length >> 8), UInt8(length & 0xFF),
                        UInt8(sequence >> 8), UInt8(sequence & 0xFF), 0x00, business])
        out.append(payload)
        let crc = CRC16.xmodem(out.dropFirst(4))
        out.append(UInt8(crc >> 8)); out.append(UInt8(crc & 0xFF))
        return out
    }
}

/// Turns the stream of Bluetooth notifications back into packets. Notifications can split a packet
/// anywhere or carry several at once; bad or oversized data is skipped, never guessed at.
public struct FrameStreamDecoder {
    private var buffer = [UInt8]()
    public let maxFrameBytes: Int
    public private(set) var dropped = 0

    public init(maxFrameBytes: Int = 8192) { self.maxFrameBytes = maxFrameBytes }

    public mutating func append(_ data: Data) -> [GlassesFrame] {
        buffer.append(contentsOf: data)
        var frames = [GlassesFrame]()
        while true {
            // find the AA 55 marker
            var start = 0
            while start + 1 < buffer.count, !(buffer[start] == 0xAA && buffer[start + 1] == 0x55) { start += 1 }
            if start > 0 {
                if start + 1 >= buffer.count {
                    // no marker; keep a trailing AA in case 55 comes next
                    let keep = buffer.last == 0xAA ? 1 : 0
                    dropped += buffer.count - keep
                    buffer.removeFirst(buffer.count - keep)
                    break
                }
                dropped += start
                buffer.removeFirst(start)
            }
            guard buffer.count >= 4 else { break }
            let total = (Int(buffer[2]) << 8 | Int(buffer[3])) + 6
            guard total >= 10, total <= maxFrameBytes else { dropped += 2; buffer.removeFirst(2); continue }
            guard buffer.count >= total else { break }
            let crc = UInt16(buffer[total - 2]) << 8 | UInt16(buffer[total - 1])
            guard CRC16.xmodem(buffer[4..<(total - 2)]) == crc else { dropped += 2; buffer.removeFirst(2); continue }
            let type = buffer[6]
            let flags = type & 0x1F, slice = Int(type >> 5)
            let address = (flags & 0x02) != 0 ? 1 : 0
            let businessAt = 7 + address + slice
            if businessAt < total - 2 {
                frames.append(GlassesFrame(sequence: UInt16(buffer[4]) << 8 | UInt16(buffer[5]),
                                           business: buffer[businessAt],
                                           payload: Data(buffer[(businessAt + 1)..<(total - 2)]),
                                           flags: flags, sliceBytes: slice))
            }
            buffer.removeFirst(total)
        }
        if buffer.count > maxFrameBytes * 2 { dropped += buffer.count; buffer.removeAll() }
        return frames
    }
}

/// The message inside a packet: a tiny Protobuf wrapper around a JSON string.
///   field 1 = version (always 1), field 2 = message type, field 3 = JSON text, field 4 = binary data
public struct Envelope {
    public var type: UInt32
    public var json: [String: Any]
    public var dataBytes: Int

    public static func encode(type: UInt32, json: [String: Any]) -> Data {
        let body = (try? JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])) ?? Data("{}".utf8)
        var out = Data([0x08, 0x01, 0x10])
        putVarint(UInt64(type), into: &out)
        out.append(0x1A); putVarint(UInt64(body.count), into: &out); out.append(body)
        return out
    }

    public init?(_ payload: Data) {
        let a = [UInt8](payload)
        var i = 0
        var version: UInt64?, type: UInt64?, body: [UInt8]?, binary = 0
        func varint() -> UInt64? {
            var n: UInt64 = 0, shift: UInt64 = 0
            while i < a.count, shift < 64 {
                let b = a[i]; i += 1
                n |= UInt64(b & 0x7F) << shift
                if b < 0x80 { return n }
                shift += 7
            }
            return nil
        }
        while i < a.count {
            guard let key = varint() else { return nil }
            switch key & 7 {
            case 0:
                guard let v = varint() else { return nil }
                if key >> 3 == 1 { version = v } else if key >> 3 == 2 { type = v }
            case 1: i += 8
            case 5: i += 4
            case 2:
                guard let n = varint(), n <= UInt64(a.count - i) else { return nil }
                let slice = Array(a[i..<(i + Int(n))]); i += Int(n)
                if key >> 3 == 3 { body = slice } else if key >> 3 == 4 { binary = slice.count }
            default: return nil
            }
            if i > a.count { return nil }
        }
        guard version == 1, let type, type <= UInt64(UInt32.max) else { return nil }
        self.type = UInt32(type)
        self.dataBytes = binary
        if let body, !body.isEmpty {
            guard let object = try? JSONSerialization.jsonObject(with: Data(body)) as? [String: Any] else { return nil }
            json = object
        } else { json = [:] }
    }

    private static func putVarint(_ value: UInt64, into data: inout Data) {
        var n = value
        while n >= 0x80 { data.append(UInt8(n & 0x7F) | 0x80); n >>= 7 }
        data.append(UInt8(n))
    }

    public func int(_ key: String) -> Int? { Envelope.int(json[key]) }
    public static func int(_ value: Any?) -> Int? {
        if let n = value as? Int { return n }
        if let n = value as? Double, n.rounded() == n, abs(n) < 1e15 { return Int(n) }
        if let n = value as? NSNumber { return n.intValue }
        return nil
    }
}

/// The glasses' Live Captions page, used as a text screen.
///
/// A session is: configure (7) -> the glasses may answer (8) -> text (5), each one replacing the last ->
/// stop (3). `force` is always false, so Glasses Hub never takes the screen away from something else, and
/// the layout is `temporary`, so the wearer's own caption settings are left alone.
public enum CaptionWire {
    public static let business: UInt8 = 19
    public static let configureType: UInt32 = 7
    public static let acknowledgeType: UInt32 = 8
    public static let textType: UInt32 = 5
    public static let stopType: UInt32 = 3
    /// Longest text Glasses Hub will send in one screen.
    public static let maxTextBytes = 3800

    public static func newSessionID() -> String {
        (0..<16).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
    }

    public static func configure(sid: String, fontSize: Int, maxLines: Int) -> Data {
        Envelope.encode(type: configureType, json: [
            "sid": sid, "force": false, "scope": "temporary",
            "config": ["font_size": fontSize, "content_width": 100, "max_lines": maxLines,
                       "position": "center", "is_display": true, "straight_view": "original"] as [String: Any],
        ])
    }

    /// `status` 0 marks the text as still changing, which is what makes the next one replace it in place.
    /// `finished` marks it as done instead, an experiment for long text: the page may then stop jumping
    /// back to the end while the wearer scrolls.
    /// `translationMode` is an experiment: 0 sends plain text as usual; 1, 2 or 3 send the same text as
    /// both the original and its "translation" under that mode number. The official app's translation
    /// captions let the crown swap original and translation, so a click may then do something the
    /// glasses report every time.
    public static func text(sid: String, frame: String, finished: Bool = false, translationMode: Int = 0) -> Data {
        var content: [String: Any] = ["source_transcript": frame]
        if translationMode > 0 { content["target_translation"] = frame }
        return Envelope.encode(type: textType, json: [
            "sid": sid, "mode": translationMode > 0 ? translationMode : 3, "status": finished ? 1 : 0, "content": content,
        ])
    }

    public static func stop(sid: String) -> Data {
        Envelope.encode(type: stopType, json: ["sid": sid, "reason_code": 10, "text": ""])
    }
}

/// Things the glasses announce about themselves, read from their usage reports (channel 15, type 76).
/// The reports aren't meant as a control channel, but on firmware 1.0.6.11 they arrive within about a
/// second of the action, which is fast enough to turn pages with.
public struct GlassesReport: Equatable {
    public enum Action: Equatable {
        /// The crown was turned forward at the bottom of the page: the glasses report a scroll that failed.
        case crownTurn
        /// The crown was turned back and the page scrolled up, to this many lines above the bottom.
        case crownBack(depth: Int)
        /// One click of the crown.
        case crownClick
        /// The wearer tilted their head up far enough to wake the screen.
        case headRaise
        /// The wearer held the crown and the glasses left the caption page.
        case holdExit
    }
    public var action: Action?
    public var battery: Int?

    public static let business: UInt8 = 15

    public init?(_ frame: GlassesFrame) {
        guard frame.business == GlassesReport.business, frame.isPlain, let message = Envelope(frame.payload),
              message.json["cmd"] as? String == "analytics_log" else { return nil }
        func dict(_ value: Any?) -> [String: Any]? {
            if let d = value as? [String: Any] { return d }
            // some firmware packs the inner part as JSON inside a string
            if let s = value as? String, let d = try? JSONSerialization.jsonObject(with: Data(s.utf8)) as? [String: Any] { return d }
            return nil
        }
        guard let data = dict(dict(message.json["payload"])?["data"]), let extras = dict(data["extras"]) else { return nil }
        if extras["action_type"] as? String == "scroll" {
            let depth = Envelope.int(extras["history_depth"]) ?? 0
            action = extras["action_result"] as? String == "success" && depth > 0 ? .crownBack(depth: depth) : .crownTurn
        }
        // A look up while the caption page is showing, reported every time (as "fail" with plain
        // captions, "success" with translation captions).
        else if extras["action_type"] as? String == "raise_head" { action = .headRaise }
        else if extras["event_name"] as? String == "KEY_PRESS" { action = .crownClick }
        else if extras["exit_type"] as? String == "crown_long_press" { action = .holdExit }
        else if extras["trigger_source"] as? String == "raise_head", extras["screen_state"] as? String == "screen_on" { action = .headRaise }
        battery = Envelope.int(extras["battery_level"]) ?? Envelope.int(extras["bat"])
        if let level = battery, !(0...100).contains(level) { battery = nil }
        if action == nil, battery == nil { return nil }
    }
}
