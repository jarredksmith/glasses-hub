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

    /// How wide a character is on the glasses, in units of an average character of ordinary English text.
    /// The glasses draw Latin text in a proportional font ("m" and capitals are wide, "i" and "l" narrow),
    /// so a line's width is the sum of these, not its character count. Double-width characters
    /// (symbols, CJK, the full-width space) take about two units.
    public static func unitWidth(_ ch: Character) -> Double {
        switch ch {
        case " ": return 0.6
        case "i", "l", "j", "'", "|", ".", ",", ":", ";", "!": return 0.52
        case "f", "t", "r", "I": return 0.67
        case "-", "(", ")", "[", "]", "/", "\\", "\"": return 0.72
        case "m", "M": return 1.8
        case "w": return 1.57
        case "W": return 2.04
        case "G", "O", "Q": return 1.7
        case "C", "D", "H", "N", "R", "U": return 1.57
        case "A", "B", "E", "K", "P", "S", "V", "X", "Y": return 1.46
        case "F", "L", "T", "Z": return 1.33
        case "J": return 1.09
        default:
            guard let scalar = ch.unicodeScalars.first else { return 1.2 }
            // Latin, including the accented letters of Vietnamese and other European languages
            if scalar.value < 0x250 || (0x1E00...0x1EFF).contains(scalar.value) { return 1.2 }
            if (0x300...0x36F).contains(scalar.value) { return 0 }           // accents that sit on the letter before
            return 2.17
        }
    }
    /// Moves lines toward the middle of the row by putting full-width blanks in front of them (ordinary
    /// spaces at the start of a line can't be relied on). With `each`, every line is centred on its own;
    /// otherwise the whole block moves together, keeping its left edge straight. Tables, grids and lists
    /// always move as a block, so their columns stay lined up.
    public static func centered(_ lines: [String], width: Int, each: Bool) -> [String] {
        let blank: Character = "\u{3000}"
        let room = Double(max(4, width)) * 0.92                 // a little spare: a line pushed past the edge would wrap
        let step = unitWidth(blank)
        func isBlank(_ line: String) -> Bool { line.allSatisfy { $0 == " " || $0 == blank } }
        func pad(for wide: Double) -> Int { max(0, Int((room - wide) / 2 / step)) }
        func isGridRow(_ line: String) -> Bool {
            guard let first = line.unicodeScalars.first else { return false }
            if first.value == 0x3000 { return true }
            let marks = line.unicodeScalars.filter { (0xFF00...0xFFEF).contains($0.value) || (0x2500...0x259F).contains($0.value) }.count
            return marks >= 3 && marks * 2 >= line.unicodeScalars.count
        }
        let table = lines.filter(isGridRow).count >= 2
        if each && !table {
            return lines.map { isBlank($0) ? $0 : String(repeating: blank, count: pad(for: measure($0))) + $0 }
        }
        let widest = lines.filter { !isBlank($0) }.map(measure).max() ?? 0
        let lead = String(repeating: blank, count: pad(for: widest))
        return lines.map { isBlank($0) ? $0 : lead + $0 }
    }

    /// Pushes a short line to the right-hand edge with full-width blanks in front of it.
    public static func rightAligned(_ line: String, width: Int) -> String {
        let room = Double(max(4, width)) * 0.92
        let blanks = max(0, Int((room - measure(line)) / unitWidth("\u{3000}")))
        return String(repeating: "\u{3000}", count: blanks) + line
    }

    /// The width of a line, in average characters.
    public static func measure(_ text: String) -> Double { text.reduce(0) { $0 + unitWidth($1) } }
    /// How much of a row to fill: a little short of the full width, since the estimate isn't exact and a
    /// line that runs over is wrapped again by the glasses, which pushes the top of the screen out of view.
    private static func limit(_ width: Int) -> Double { Double(max(4, width)) * 0.96 }

    /// Break text into lines that fit a row `width` average characters wide, at spaces where possible.
    /// Keeps paragraph breaks.
    public static func wrap(_ text: String, width: Int) -> [String] {
        let room = limit(width)
        var lines = [String]()
        for paragraph in text.split(omittingEmptySubsequences: false, whereSeparator: { $0.isNewline }) {
            let cleaned = clean(String(paragraph))
            if cleaned.isEmpty { if !(lines.last?.isEmpty ?? true) { lines.append("") }; continue }
            var line = "", used = 0.0
            for word in cleaned.split(separator: " ") {
                let w = measure(String(word))
                let gap = line.isEmpty ? 0 : unitWidth(" ")
                if used + gap + w <= room {
                    if !line.isEmpty { line += " " }
                    line += word; used += gap + w
                    continue
                }
                if !line.isEmpty { lines.append(line); line = ""; used = 0 }
                if w <= room { line = String(word); used = w; continue }
                for ch in word {                                   // one very long word: cut it where the row ends
                    let c = unitWidth(ch)
                    if used + c > room, !line.isEmpty { lines.append(line); line = ""; used = 0 }
                    line.append(ch); used += c
                }
            }
            if !line.isEmpty { lines.append(line) }
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
        while measure(last + "..") > limit(width), !last.isEmpty { last.removeLast() }
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

    /// A screenful with one extra line above it, so the caption page has something to scroll back to.
    /// The glasses show the last `rows` lines, so what the wearer sees is unchanged (short screens stay
    /// centred); but a turn of the crown backwards now scrolls and is reported as such, where a turn
    /// forwards at the bottom is reported as failing. That difference is how the app tells the two apart.
    public static func withScrollRoom(_ lines: [String], rows: Int, marker: String) -> [String] {
        let shown = Array(lines.prefix(rows))
        let free = rows - shown.count
        let blank = "\u{3000}"
        return [marker] + Array(repeating: blank, count: free / 2) + shown + Array(repeating: blank, count: free - free / 2)
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

/// The line of timekeeping a speaker sees while reading from the glasses.
public enum ReaderClock {
    /// What the line shows: nothing, the time of day, time since starting, both, or time left of a target.
    public enum Mode: Int, CaseIterable, Sendable { case off, clock, elapsed, both, countdown, clockCountdown }
        public var usesTimer: Bool { self != .off && self != .clock }
        public var countsDown: Bool { self == .countdown || self == .clockCountdown }

    /// Minutes and seconds, with hours once there are any: "3:05", "1:02:09".
    public static func span(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    public static func line(mode: Mode, now: Date, started: Date, targetMinutes: Int, page: Int, pages: Int, zone: TimeZone = .current) -> String {
        let elapsed = now.timeIntervalSince(started)
        var parts = [String]()
        switch mode {
        case .off: return ""
        case .clock: parts.append(HubClock.time(now, zone: zone))
        case .elapsed: parts.append(span(elapsed))
        case .both: parts.append(HubClock.time(now, zone: zone)); parts.append(span(elapsed))
        case .countdown, .clockCountdown:
            if mode == .clockCountdown { parts.append(HubClock.time(now, zone: zone)) }
            let left = Double(max(1, targetMinutes) * 60) - elapsed
            parts.append(left >= 0 ? span(left) + " left" : "+" + span(-left) + " over")
        }
        if pages > 1 { parts.append("\(page)/\(pages)") }
        return parts.joined(separator: "  ")
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
