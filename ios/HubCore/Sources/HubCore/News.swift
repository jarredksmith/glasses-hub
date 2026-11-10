import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

public struct NewsItem: Equatable, Identifiable {
    public var title: String
    public var summary: String
    public var link: URL?
    public var source: String
    public var date: Date?
    public var id: String { (link?.absoluteString ?? "") + "|" + title }
}

public struct NewsSource: Equatable, Identifiable, Codable {
    public var name: String
    public var url: String
    public var id: String { url }
    public init(name: String, url: String) { self.name = name; self.url = url }

    /// Public feeds that publishers offer for exactly this: reading their headlines somewhere else.
    public static let builtIn: [NewsSource] = [
        NewsSource(name: "BBC News", url: "https://feeds.bbci.co.uk/news/rss.xml"),
        NewsSource(name: "NPR", url: "https://feeds.npr.org/1001/rss.xml"),
        NewsSource(name: "BBC Tech", url: "https://feeds.bbci.co.uk/news/technology/rss.xml"),
        NewsSource(name: "The Verge", url: "https://www.theverge.com/rss/index.xml"),
        NewsSource(name: "ESPN", url: "https://www.espn.com/espn/rss/news"),
        NewsSource(name: "NASA", url: "https://www.nasa.gov/feed/"),
    ]
}

public enum News {
    // MARK: Feeds (RSS and Atom)

    public static func parseFeed(_ data: Data, source: String) -> [NewsItem] {
        let reader = FeedReader(source: source)
        let parser = XMLParser(data: data)
        parser.delegate = reader
        parser.parse()
        return reader.items
    }

    private final class FeedReader: NSObject, XMLParserDelegate {
        let source: String
        var items = [NewsItem]()
        private var inItem = false
        private var text = ""
        private var fields = [String: String]()
        private var link: String?
        init(source: String) { self.source = source }

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
            let tag = name.lowercased()
            if tag == "item" || tag == "entry" { inItem = true; fields = [:]; link = nil }
            if inItem, tag == "link", let href = attributes["href"], (attributes["rel"] ?? "alternate") == "alternate" { link = href }
            text = ""
        }
        func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }
        func parser(_ parser: XMLParser, foundCDATA block: Data) { text += String(data: block, encoding: .utf8) ?? "" }
        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            let tag = name.lowercased()
            guard inItem else { return }
            if tag == "item" || tag == "entry" {
                inItem = false
                let title = News.plain(fields["title"] ?? "")
                guard !title.isEmpty else { return }
                let body = fields["content:encoded"] ?? fields["description"] ?? fields["summary"] ?? fields["content"] ?? ""
                let stamp = fields["pubdate"] ?? fields["published"] ?? fields["updated"] ?? fields["dc:date"] ?? ""
                items.append(NewsItem(title: title, summary: News.plain(body),
                                      link: (link ?? fields["link"]).flatMap { URL(string: $0.trimmingCharacters(in: .whitespacesAndNewlines)) },
                                      source: source, date: News.date(stamp)))
            } else if fields[tag] == nil || tag == "content:encoded" {
                fields[tag] = text.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
    }

    static func date(_ text: String) -> Date? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        if let iso = ISO8601DateFormatter().date(from: value) { return iso }
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX")
        for format in ["EEE, dd MMM yyyy HH:mm:ss Z", "EEE, dd MMM yyyy HH:mm:ss zzz", "EEE, dd MMM yyyy HH:mm Z", "yyyy-MM-dd'T'HH:mm:ss.SSSZ"] {
            f.dateFormat = format
            if let made = f.date(from: value) { return made }
        }
        return nil
    }

    // MARK: Text out of HTML

    private static let entities: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " ", "mdash": "-", "ndash": "-",
        "hellip": "...", "rsquo": "'", "lsquo": "'", "rdquo": "\"", "ldquo": "\"", "copy": "(c)", "deg": "°",
    ]

    static func decodeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        var out = "", rest = Substring(text)
        while let amp = rest.firstIndex(of: "&") {
            out += rest[..<amp]
            let after = rest[rest.index(after: amp)...]
            if let semi = after.firstIndex(of: ";"), after.distance(from: after.startIndex, to: semi) <= 8 {
                let name = String(after[..<semi])
                var swap: String?
                if name.hasPrefix("#x") || name.hasPrefix("#X") { swap = UInt32(name.dropFirst(2), radix: 16).flatMap(Unicode.Scalar.init).map { String(Character($0)) } }
                else if name.hasPrefix("#") { swap = UInt32(name.dropFirst()).flatMap(Unicode.Scalar.init).map { String(Character($0)) } }
                else { swap = entities[name] }
                if let swap { out += swap; rest = after[after.index(after: semi)...]; continue }
            }
            out += "&"; rest = after
        }
        return out + rest
    }

    private static func replacing(_ pattern: String, in text: String, with template: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else { return text }
        return regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: template)
    }

    /// One line of plain text from a snippet of HTML.
    public static func plain(_ html: String) -> String {
        TextLayout.clean(decodeEntities(replacing("<[^>]+>", in: html, with: " ")))
    }

    /// The readable paragraphs of an article page, in order, separated by blank lines. This is a small
    /// reader view: it keeps <p> text from the article body and drops scripts, menus and captions.
    public static func articleText(html: String) -> String {
        var page = html
        for tag in ["script", "style", "noscript", "svg", "figure", "nav", "header", "footer", "aside", "form", "button"] {
            page = replacing("<\(tag)\\b[^>]*>.*?</\(tag)>", in: page, with: " ")
        }
        var body = page
        if let regex = try? NSRegularExpression(pattern: "<article\\b[^>]*>(.*?)</article>", options: [.caseInsensitive, .dotMatchesLineSeparators]) {
            let found = regex.matches(in: page, range: NSRange(page.startIndex..., in: page)).compactMap { Range($0.range(at: 1), in: page).map { String(page[$0]) } }
            if let largest = found.max(by: { $0.count < $1.count }), largest.count > 400 { body = largest }
        }
        guard let paragraph = try? NSRegularExpression(pattern: "<p\\b[^>]*>(.*?)</p>", options: [.caseInsensitive, .dotMatchesLineSeparators]) else { return "" }
        var seen = Set<String>()
        let paragraphs = paragraph.matches(in: body, range: NSRange(body.startIndex..., in: body)).compactMap { match -> String? in
            guard let range = Range(match.range(at: 1), in: body) else { return nil }
            let text = plain(String(body[range]))
            // short scraps are bylines, captions and buttons, not the story
            guard text.count >= 60 || (text.count >= 25 && text.hasSuffix(".")), seen.insert(text).inserted else { return nil }
            return text
        }
        return paragraphs.joined(separator: "\n\n")
    }

    // MARK: Cards

    public static func age(_ date: Date?, now: Date) -> String {
        guard let date else { return "" }
        let minutes = Int(now.timeIntervalSince(date) / 60)
        if minutes < 1 { return "now" }
        if minutes < 60 { return "\(minutes)m" }
        if minutes < 48 * 60 { return "\(minutes / 60)h" }
        return "\(minutes / (24 * 60))d"
    }

    /// One headline: where it's from and how old, the headline, then as much of the summary as fits.
    public static func headlineCard(_ item: NewsItem, index: Int, count: Int, screen: Screen, now: Date, glyphs: Glyphs = .plain) -> Card {
        let rich = glyphs.style != .plain
        let when = age(item.date, now: now)
        let position = count > 1 ? "  \(index + 1)/\(count)" : ""
        var lines = [(rich ? glyphs.bullet + " " : "") + TextLayout.fit(item.source + (when.isEmpty ? "" : "  " + when) + position, width: screen.columns - (rich ? 3 : 0))]
        lines += TextLayout.wrap(item.title, width: screen.columns, maxLines: max(2, screen.rows - 2))
        let room = screen.rows - lines.count
        if room > 0, !item.summary.isEmpty, item.summary != item.title {
            if rich, room > 1 { lines.append(String(repeating: glyphs.rule, count: min(8, screen.wideColumns))) }
            lines += TextLayout.wrap(item.summary, width: screen.columns, maxLines: screen.rows - lines.count)
        }
        return Card(Array(lines.prefix(screen.rows)))
    }

    /// A whole story as lines, headline first, for paging.
    public static func articleCard(_ item: NewsItem, text: String, screen: Screen) -> Card {
        let body = text.isEmpty ? item.summary : text
        let lines = TextLayout.wrap(item.title, width: screen.columns) + [""] + TextLayout.wrap(body, width: screen.columns) + ["", "- end -"]
        return Card(lines, scrolls: true)
    }

    /// Newest first, the same story from two feeds listed once.
    public static func merged(_ lists: [[NewsItem]], limit: Int = 40) -> [NewsItem] {
        var seen = Set<String>()
        let all = lists.flatMap { $0 }.filter { seen.insert($0.title.lowercased()).inserted }
        return Array(all.sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }.prefix(limit))
    }
}
