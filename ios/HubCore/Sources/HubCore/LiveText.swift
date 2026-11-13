import Foundation

/// Text handed to Glasses Hub by another app (a translator, a script, a shortcut) to show on the glasses.
public struct LiveText: Equatable {
    public private(set) var text = ""
    /// Whether the text is a running stream (lines added one after another) or one piece put up whole.
    public private(set) var streaming = false
    /// How much text is kept when appending; older text falls off the front.
    public static let limit = 4000

    public init() {}

    /// Replace what's showing, or add to the end of it (on a new line).
    public mutating func show(_ incoming: String, append: Bool) {
        let cleaned = incoming.replacingOccurrences(of: "\r\n", with: "\n")
        if append, !text.isEmpty { text += "\n" + cleaned } else { text = cleaned }
        streaming = append
        if text.count > LiveText.limit { text = String(text.suffix(LiveText.limit)) }
    }
    public mutating func clear() { text = ""; streaming = false }

    /// How many screens a whole piece of text takes (always 1 for a stream).
    public func pageCount(screen: Screen) -> Int {
        streaming ? 1 : max(1, TextLayout.pages(TextLayout.wrap(text, width: screen.columns), rows: screen.rows).count)
    }

    /// A stream shows its newest lines, like captions, with the latest at the bottom. A whole piece of
    /// text (a note) shows from its first line, and pages if it's longer than the screen.
    public func card(screen: Screen, page: Int = 0) -> Card {
        let lines = TextLayout.wrap(text, width: screen.columns)
        guard !lines.isEmpty else { return Card(["Live text", "Waiting for text from", "another app."]) }
        if streaming { return Card(Array(lines.suffix(screen.rows))) }
        let pages = TextLayout.pages(lines, rows: screen.rows)
        return Card(pages[max(0, min(pages.count - 1, page))])
    }
}

/// A request to the local API, parsed from the bytes another app sent.
public struct LocalRequest: Equatable, Sendable {
    public var method: String
    public var path: String
    public var query: [String: String]
    public var body: Data
    public var contentType: String

    /// Nil while more bytes are still expected (or the bytes aren't an HTTP request at all).
    public static func parse(_ data: Data) -> LocalRequest? {
        guard let split = data.range(of: Data("\r\n\r\n".utf8)),
              let head = String(data: data[data.startIndex..<split.lowerBound], encoding: .utf8) else { return nil }
        let lines = head.components(separatedBy: "\r\n")
        let first = lines[0].split(separator: " ")
        guard first.count >= 2 else { return nil }
        var headers = [String: String]()
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let body = data[split.upperBound...]
        if let length = headers["content-length"].flatMap({ Int($0) }), body.count < length { return nil }
        let target = String(first[1])
        let parts = target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        return LocalRequest(method: String(first[0]).uppercased(), path: String(parts.first ?? "/"),
                            query: parts.count > 1 ? LocalRequest.fields(String(parts[1])) : [:],
                            body: Data(body), contentType: headers["content-type"]?.lowercased() ?? "")
    }

    /// "a=1&b=two+words" as a dictionary.
    public static func fields(_ encoded: String) -> [String: String] {
        var out = [String: String]()
        for pair in encoded.split(separator: "&") {
            let bits = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let key = String(bits[0]).removingPercentEncoding ?? String(bits[0])
            let raw = bits.count > 1 ? String(bits[1]).replacingOccurrences(of: "+", with: " ") : ""
            out[key] = raw.removingPercentEncoding ?? raw
        }
        return out
    }

    /// The text to show and whether to append it, from the query, a JSON body, a form body or a plain body.
    public var textAndAppend: (text: String?, append: Bool) {
        func truthy(_ value: String?) -> Bool { ["1", "true", "yes"].contains((value ?? "").lowercased()) }
        var text = query["text"], append = truthy(query["append"])
        if !body.isEmpty {
            if contentType.contains("json"), let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
                if let t = object["text"] as? String { text = t }
                if let a = object["append"] as? Bool { append = a }
            } else if contentType.contains("x-www-form-urlencoded"), let form = String(data: body, encoding: .utf8) {
                let f = LocalRequest.fields(form)
                if let t = f["text"] { text = t }
                if f["append"] != nil { append = truthy(f["append"]) }
            } else if text == nil, let plain = String(data: body, encoding: .utf8) {
                text = plain
            }
        }
        return (text, append)
    }

    public static func response(status: Int = 200, json: [String: Any]) -> Data {
        let body = (try? JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])) ?? Data("{}".utf8)
        let reason = status == 200 ? "OK" : status == 404 ? "Not Found" : "Bad Request"
        let head = "HTTP/1.1 \(status) \(reason)\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nAccess-Control-Allow-Origin: *\r\nAccess-Control-Allow-Methods: GET, POST, OPTIONS\r\nAccess-Control-Allow-Headers: *\r\nConnection: close\r\n\r\n"
        return Data(head.utf8) + body
    }
}

/// A running caption built from a streaming speech service's messages (Soniox's real-time API):
/// text that's settled, followed by the words still being worked out.
public struct CloudCaption: Equatable {
    public private(set) var settled = ""
    public private(set) var pending = ""
    private var lastSpeaker = ""
    /// Put "S1:", "S2:" in front of each change of speaker (when the service labels speakers).
    public var labelSpeakers = false
    public static let limit = 3000

    public enum Event: Equatable { case updated, finished, failed(String) }

    public init(labelSpeakers: Bool = false) { self.labelSpeakers = labelSpeakers }

    public var text: String { (settled + pending).trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Takes one message from the service. Each carries newly settled words (sent once) and the
    /// current tentative words (which replace the previous tentative ones).
    public mutating func take(_ data: Data) -> Event? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let message = object["error_message"] as? String { return .failed(message) }
        var tentative = "", speaker = lastSpeaker
        for case let token as [String: Any] in object["tokens"] as? [Any] ?? [] {
            guard let piece = token["text"] as? String, !piece.isEmpty else { continue }
            if piece.hasPrefix("<"), piece.hasSuffix(">") { continue }                 // markers such as <end>
            // With translation on, the words to show are the translated ones (or ones that were already
            // in the target language); the original-language words are skipped.
            if (token["translation_status"] as? String) == "original" { continue }
            let final = token["is_final"] as? Bool ?? false
            var add = piece
            if labelSpeakers, let who = token["speaker"].flatMap({ "\($0)" }), !who.isEmpty, who != (final ? lastSpeaker : speaker) {
                add = "\nS\(who): " + piece.trimmingCharacters(in: .whitespaces)
                if final { lastSpeaker = who }
                speaker = who
            }
            if final { settled += add } else { tentative += add }
        }
        pending = tentative
        if settled.count > CloudCaption.limit { settled = String(settled.suffix(CloudCaption.limit)) }
        if object["finished"] as? Bool == true { return .finished }
        return .updated
    }

    /// The newest lines that fit, like captions.
    public func lines(screen: Screen) -> [String] {
        Array(TextLayout.wrap(text, width: screen.columns).suffix(screen.rows))
    }
}
