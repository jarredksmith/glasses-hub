import Foundation

public struct MailMessage: Equatable, Identifiable {
    public var id: String
    public var from: String
    public var subject: String
    public var date: Date?
    public var preview: String
    public var body: String
    public var unread: Bool
}

/// Reading Gmail through Google's own API. The app asks for read-only access; it can't send, delete
/// or change anything.
public enum Mail {
    public static let scope = "https://www.googleapis.com/auth/gmail.readonly"

    public static func listURL(query: String, max: Int = 15) -> URL? {
        var parts = URLComponents(string: "https://gmail.googleapis.com/gmail/v1/users/me/messages")
        parts?.queryItems = [URLQueryItem(name: "maxResults", value: String(max)), URLQueryItem(name: "q", value: query)]
        return parts?.url
    }
    public static func messageURL(_ id: String) -> URL? {
        let safe = id.filter { $0.isLetter || $0.isNumber }
        return safe.isEmpty ? nil : URL(string: "https://gmail.googleapis.com/gmail/v1/users/me/messages/\(safe)?format=full")
    }

    public static func parseList(_ data: Data) -> [String] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = root["messages"] as? [[String: Any]] else { return [] }
        return list.compactMap { $0["id"] as? String }
    }

    static func decode(_ base64url: String) -> String? {
        var s = base64url.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        s += String(repeating: "=", count: (4 - s.count % 4) % 4)
        return Data(base64Encoded: s).map { String(decoding: $0, as: UTF8.self) }
    }

    public static func parseMessage(_ data: Data) -> MailMessage? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = root["id"] as? String, let payload = root["payload"] as? [String: Any] else { return nil }
        var headers = [String: String]()
        for h in payload["headers"] as? [[String: Any]] ?? [] {
            if let name = h["name"] as? String, let value = h["value"] as? String, headers[name.lowercased()] == nil { headers[name.lowercased()] = value }
        }
        // the plain-text part if there is one, else the HTML part with its tags removed
        var plain: String?, html: String?
        func walk(_ part: [String: Any]) {
            let type = (part["mimeType"] as? String ?? "").lowercased()
            if let text = ((part["body"] as? [String: Any])?["data"] as? String).flatMap(decode), !text.isEmpty {
                if type == "text/plain", plain == nil { plain = text }
                if type == "text/html", html == nil { html = text }
            }
            for child in part["parts"] as? [[String: Any]] ?? [] { walk(child) }
        }
        walk(payload)
        var body = ""
        if let plain, plain.trimmingCharacters(in: .whitespacesAndNewlines).count > 20 { body = tidy(plain) }
        else if let html { body = fromHTML(html) }
        else if let plain { body = tidy(plain) }
        let stamp = (root["internalDate"] as? String).flatMap { Double($0) }.map { Date(timeIntervalSince1970: $0 / 1000) }
        return MailMessage(id: id, from: sender(headers["from"] ?? ""), subject: TextLayout.clean(headers["subject"] ?? "(no subject)"),
                           date: stamp, preview: TextLayout.clean(News.decodeEntities(root["snippet"] as? String ?? "")),
                           body: body, unread: (root["labelIds"] as? [String] ?? []).contains("UNREAD"))
    }

    /// "Pat Lee <pat@example.com>" -> "Pat Lee"; a bare address stays as it is.
    static func sender(_ raw: String) -> String {
        let value = TextLayout.clean(raw)
        if let open = value.firstIndex(of: "<") {
            let name = value[..<open].trimmingCharacters(in: CharacterSet(charactersIn: " \""))
            if !name.isEmpty { return name }
            return value[value.index(after: open)...].trimmingCharacters(in: CharacterSet(charactersIn: " >"))
        }
        return value
    }

    /// Plain text with quoted replies, long links and runs of blank lines taken out.
    static func tidy(_ text: String) -> String {
        var out = [String](), blank = false
        for raw in text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix(">") { continue }
            if line.hasPrefix("On "), line.hasSuffix("wrote:") { break }          // the rest is the message being replied to
            if line.isEmpty { if !blank, !out.isEmpty { out.append("") }; blank = true; continue }
            blank = false
            let words = line.split(separator: " ").map { w -> String in
                (w.hasPrefix("http://") || w.hasPrefix("https://") || w.hasPrefix("<http")) && w.count > 30 ? "[link]" : String(w)
            }
            out.append(words.joined(separator: " "))
        }
        while out.last == "" { out.removeLast() }
        return out.joined(separator: "\n")
    }

    static func fromHTML(_ html: String) -> String {
        let story = News.articleText(html: html)
        if story.count > 80 { return story }
        // marketing mail is mostly tables, not paragraphs: fall back to all of its text
        var page = html
        for tag in ["script", "style", "head"] {
            if let regex = try? NSRegularExpression(pattern: "<\(tag)\\b[^>]*>.*?</\(tag)>", options: [.caseInsensitive, .dotMatchesLineSeparators]) {
                page = regex.stringByReplacingMatches(in: page, range: NSRange(page.startIndex..., in: page), withTemplate: " ")
            }
        }
        return News.plain(page)
    }

    // MARK: Cards

    public static func listCard(_ message: MailMessage, index: Int, count: Int, screen: Screen, now: Date, glyphs: Glyphs = .plain) -> Card {
        let rich = glyphs.style != .plain
        let mark = message.unread ? (rich ? glyphs.live + " " : "* ") : (rich ? glyphs.hollow + " " : "")
        var lines = [mark + TextLayout.fit("Inbox \(index + 1)/\(count)  \(News.age(message.date, now: now))", width: screen.columns - 3)]
        lines.append(TextLayout.fit(message.from, width: screen.columns))
        lines += TextLayout.wrap(message.subject, width: screen.columns, maxLines: 2)
        if lines.count < screen.rows, !message.preview.isEmpty {
            lines += TextLayout.wrap(message.preview, width: screen.columns, maxLines: screen.rows - lines.count)
        }
        return Card(Array(lines.prefix(screen.rows)))
    }

    public static func readCard(_ message: MailMessage, screen: Screen) -> Card {
        var lines = [TextLayout.fit("From " + message.from, width: screen.columns)]
        lines += TextLayout.wrap(message.subject, width: screen.columns)
        lines.append("")
        lines += TextLayout.wrap(message.body.isEmpty ? message.preview : message.body, width: screen.columns)
        lines.append("- end -")
        return Card(lines, scrolls: true)
    }
}

extension Agenda {
    /// One event on its own: what, when, where, and its notes.
    public static func detailCard(_ item: AgendaItem, index: Int, count: Int, screen: Screen, now: Date, glyphs: Glyphs = .plain) -> Card {
        let day = Calendar.current.isDate(item.start, inSameDayAs: now) ? "Today" : HubClock.day(item.start)
        var lines = [(glyphs.style != .plain ? glyphs.bullet + " " : "") + "Event \(index + 1)/\(count)  \(day)"]
        lines += TextLayout.wrap(item.title, width: screen.columns, maxLines: 2)
        lines.append(item.allDay ? "All day" : "\(HubClock.time(item.start)) - \(HubClock.time(item.end))" + (item.start > now ? "  (\(HubClock.until(item.start, from: now)))" : (item.end > now ? "  (now)" : "")))
        if let place = item.place, !TextLayout.clean(place).isEmpty { lines += TextLayout.wrap("At " + place, width: screen.columns, maxLines: 2) }
        if let notes = item.notes, !notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { lines += [""] + TextLayout.wrap(Mail.tidy(notes), width: screen.columns) }
        return Card(lines, scrolls: lines.count > screen.rows)
    }
}

/// The on-glasses list of apps, with a marker on the one a click would open.
public enum AppMenu {
    public static func card(titles: [String], selected: Int, screen: Screen, glyphs: Glyphs = .plain) -> Card {
        guard !titles.isEmpty else { return Card(["Apps"]) }
        let room = max(1, screen.rows - 1)
        let start = max(0, min(titles.count - room, selected - room / 2))
        var lines = ["Apps  (turn: next, click: open)"]
        for i in start..<min(titles.count, start + room) {
            lines.append((i == selected ? glyphs.next : glyphs.blank) + " " + titles[i])
        }
        return Card(lines)
    }
    /// Shown after the last item of a list, so there's a way out to the menu.
    public static func endCard(of what: String) -> Card {
        Card(["End of \(what)", "Turn: back to the start", "Double click: apps menu"])
    }
}
