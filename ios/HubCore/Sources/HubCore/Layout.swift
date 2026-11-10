import Foundation

/// The two text sizes the caption page offers. Rows and grid widths were measured by the OpenRayneo
/// project on stock firmware; `columns` (ordinary text per row) is a safe starting point the wearer can
/// tune, because the glasses' Latin letters aren't all the same width.
public enum TextSize: String, CaseIterable, Codable {
    case small, large
    public var fontSize: Int { self == .small ? 1 : 2 }
    public var rows: Int { self == .small ? 7 : 5 }
    /// Double-width ("full-width") characters that fit on a row.
    public var wideColumns: Int { self == .small ? 26 : 20 }
    public var defaultColumns: Int { self == .small ? 44 : 34 }
    public var title: String { self == .small ? "Small (7 lines)" : "Large (5 lines)" }
}

public struct Screen: Equatable {
    public var rows: Int
    /// Ordinary characters per row before the glasses wrap the line themselves.
    public var columns: Int
    /// Double-width characters per row.
    public var wideColumns: Int

    public init(rows: Int, columns: Int, wideColumns: Int) {
        self.rows = max(1, rows); self.columns = max(12, columns); self.wideColumns = max(6, wideColumns)
    }
    public init(size: TextSize, columns: Int? = nil) {
        self.init(rows: size.rows, columns: columns ?? size.defaultColumns, wideColumns: size.wideColumns)
    }
}

/// What an app wants on the glasses: a few lines, already fitted to the screen.
public struct Card: Equatable {
    public var lines: [String]
    /// More lines than the page shows; sent whole so the crown can scroll it.
    public var scrolls: Bool

    public init(_ lines: [String], scrolls: Bool = false) { self.lines = lines; self.scrolls = scrolls }

    public func text(rows: Int) -> String {
        (scrolls ? lines : Array(lines.prefix(rows))).joined(separator: "\n")
    }
    public var isEmpty: Bool { lines.allSatisfy { $0.trimmingCharacters(in: .whitespaces).isEmpty } }
}

public enum TextLayout {
    private static let replacements: [Character: String] = [
        "\u{2018}": "'", "\u{2019}": "'", "\u{201C}": "\"", "\u{201D}": "\"", "\u{2013}": "-", "\u{2014}": "-",
        "\u{2026}": "...", "\u{00A0}": " ", "\u{2022}": "-", "\u{00D7}": "x", "\u{2212}": "-", "\u{00B0}": "°",
        "\t": " ",
    ]

    /// One tidy line: plain punctuation, single spaces, no control characters or emoji.
    public static func clean(_ text: String) -> String {
        var out = ""
        var lastWasSpace = true
        for ch in text {
            if let swap = replacements[ch] { for c in swap { append(c, to: &out, lastWasSpace: &lastWasSpace) }; continue }
            if ch.isNewline { append(" ", to: &out, lastWasSpace: &lastWasSpace); continue }
            guard let scalar = ch.unicodeScalars.first else { continue }
            if scalar.value < 32 || scalar.value == 127 { continue }
            // emoji and other picture characters: the glasses' font has no shapes for them
            if scalar.value >= 0x1F000 || ((0x2600...0x27BF).contains(scalar.value) && scalar.value != 0x2605 && scalar.value != 0x2606) || (0xFE00...0xFE0F).contains(scalar.value) { continue }
            append(ch, to: &out, lastWasSpace: &lastWasSpace)
        }
        while out.last == " " { out.removeLast() }
        return out
    }
    private static func append(_ ch: Character, to out: inout String, lastWasSpace: inout Bool) {
        if ch == " " { if lastWasSpace { return }; lastWasSpace = true } else { lastWasSpace = false }
        out.append(ch)
    }

    /// Break text into lines of at most `width` characters, at spaces where possible. Keeps paragraph breaks.
    public static func wrap(_ text: String, width: Int) -> [String] {
        let width = max(4, width)
        var lines = [String]()
        for paragraph in text.split(omittingEmptySubsequences: false, whereSeparator: { $0.isNewline }) {
            var rest = Substring(clean(String(paragraph)))
            if rest.isEmpty { if !(lines.last?.isEmpty ?? true) { lines.append("") }; continue }
            while rest.count > width {
                let window = rest.prefix(width + 1)
                var cut = window.lastIndex(of: " ").map { window.distance(from: window.startIndex, to: $0) } ?? -1
                if cut < width / 2 { cut = width }          // one very long word: hard cut
                lines.append(String(rest.prefix(cut)).trimmingCharacters(in: .whitespaces))
                rest = rest.dropFirst(cut)
                while rest.first == " " { rest = rest.dropFirst() }
            }
            if !rest.isEmpty { lines.append(String(rest)) }
        }
        while lines.last == "" { lines.removeLast() }
        return lines
    }

    /// Cut a line to `width`, ending in ".." when something was lost.
    public static func fit(_ text: String, width: Int) -> String {
        let line = clean(text)
        guard line.count > width else { return line }
        guard width > 2 else { return String(line.prefix(width)) }
        return String(line.prefix(width - 2)).trimmingCharacters(in: .whitespaces) + ".."
    }

    /// Wrap to at most `maxLines` lines; the last one ends in ".." if text was left over.
    public static func wrap(_ text: String, width: Int, maxLines: Int) -> [String] {
        let all = wrap(text, width: width)
        guard all.count > maxLines, maxLines > 0 else { return all }
        var kept = Array(all.prefix(maxLines))
        var last = kept[maxLines - 1]
        while last.count + 2 > width, !last.isEmpty { last.removeLast() }
        kept[maxLines - 1] = last.trimmingCharacters(in: .whitespaces) + ".."
        return kept
    }

    /// "[#####-----]"
    public static func bar(_ fraction: Double, cells: Int = 10) -> String {
        let filled = max(0, min(cells, Int((fraction * Double(cells)).rounded())))
        return "[" + String(repeating: "#", count: filled) + String(repeating: "-", count: cells - filled) + "]"
    }

    /// Printable ASCII as double-width characters. They're twice as wide on the glasses, so a short line
    /// (a score, a clock) reads as a headline, and they are all the same width, so columns line up.
    public static func wide(_ text: String) -> String {
        String(String.UnicodeScalarView(text.unicodeScalars.map { scalar in
            if scalar.value == 32 { return Unicode.Scalar(0x3000)! }
            if (33...126).contains(scalar.value) { return Unicode.Scalar(scalar.value + 0xFEE0)! }
            return scalar
        }))
    }

    /// A headline: double-width when it fits the row, ordinary text when it doesn't.
    public static func headline(_ text: String, screen: Screen) -> String {
        let line = clean(text)
        let ascii = line.unicodeScalars.allSatisfy { (32...126).contains($0.value) || $0.value == 0xB0 }
        return ascii && line.count <= screen.wideColumns ? wide(line) : fit(line, width: screen.columns)
    }

    /// Split lines into pages of `rows`, each page ending "(2/5)" style when there is more than one.
    public static func pages(_ lines: [String], rows: Int) -> [[String]] {
        guard lines.count > rows, rows > 1 else { return [lines] }
        let body = rows - 1
        let count = Int((Double(lines.count) / Double(body)).rounded(.up))
        return (0..<count).map { page in
            Array(lines[(page * body)..<min(lines.count, (page + 1) * body)]) + ["(\(page + 1)/\(count))"]
        }
    }
}

public enum HubClock {
    public static func time(_ date: Date, zone: TimeZone = .current) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = zone
        f.dateFormat = "h:mm a"
        return f.string(from: date)
    }
    public static func day(_ date: Date, zone: TimeZone = .current) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = zone
        f.dateFormat = "EEE MMM d"
        return f.string(from: date)
    }
    public static func weekdayTime(_ date: Date, zone: TimeZone = .current) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = zone
        f.dateFormat = "EEE h:mm a"
        return f.string(from: date)
    }
    /// "in 25 min", "in 2 hr", "now"
    public static func until(_ date: Date, from now: Date) -> String {
        let minutes = Int((date.timeIntervalSince(now) / 60).rounded())
        if minutes <= 0 { return "now" }
        if minutes < 90 { return "in \(minutes) min" }
        let hours = Int((Double(minutes) / 60).rounded())
        return hours < 36 ? "in \(hours) hr" : "in \(Int((Double(hours) / 24).rounded())) days"
    }
}
