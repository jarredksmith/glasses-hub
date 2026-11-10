import Foundation

/// How adventurous the screen may be with characters.
///
/// The glasses' font is undocumented. Plain letters, digits and their double-width forms are known to
/// work. Symbols here are limited to the old GB2312 set (stars, circles, squares, triangles, arrows,
/// box lines), which a Chinese-market display font almost certainly carries. Block shading is one step
/// less certain, so it's its own level. The app's test cards show every character used, so anything that
/// comes out as an empty box can be turned off by dropping a level.
public enum GlyphStyle: String, CaseIterable, Codable, Identifiable {
    case plain, symbols, blocks
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .plain: return "Plain text only"
        case .symbols: return "Symbols and lines"
        case .blocks: return "Symbols plus shaded bars"
        }
    }
}

public struct Glyphs: Equatable {
    public var style: GlyphStyle
    public init(_ style: GlyphStyle = .plain) { self.style = style }
    public static let plain = Glyphs(.plain)

    private var rich: Bool { style != .plain }
    private func pick(_ fancy: String, _ simple: String) -> String { rich ? fancy : simple }

    /// Each of these is one double-width cell in both styles, so tables stay aligned.
    public var live: String { pick("●", "＊") }
    public var bullet: String { pick("◆", "－") }
    public var hollow: String { pick("○", "ｏ") }
    public var star: String { pick("★", "＊") }
    public var next: String { pick("→", "＞") }
    public var here: String { pick("◀", "＜") }
    public var up: String { pick("↑", "＋") }
    public var down: String { pick("↓", "－") }
    public var note: String { pick("※", "！") }
    public var full: String { pick("■", "＃") }
    public var empty: String { pick("□", "－") }
    public var rule: String { pick("─", "－") }
    public var bar: String { pick("│", "｜") }
    public var blank: String { "\u{3000}" }

    /// A progress bar of double-width cells: ■■■■□□□□
    public func meter(_ fraction: Double, cells: Int) -> String {
        let cells = max(1, cells)
        let filled = max(0, min(cells, Int((fraction * Double(cells)).rounded())))
        return String(repeating: full, count: filled) + String(repeating: empty, count: cells - filled)
    }

    /// A row of dots showing position in a set: ○○●○○. Falls back to "3/5" when there are too many.
    public func pager(_ index: Int, of count: Int, maxCells: Int = 8) -> String {
        guard count > 1 else { return "" }
        guard count <= maxCells else { return "\(index + 1)/\(count)" }
        return (0..<count).map { $0 == index ? live : hollow }.joined()
    }

    /// A tiny chart, one cell per value. Needs the shaded blocks; nil otherwise.
    public func spark(_ values: [Double]) -> String? {
        guard style == .blocks, let low = values.min(), let high = values.max(), !values.isEmpty else { return nil }
        let steps = Array("▁▂▃▄▅▆▇█")
        return String(values.map { v in
            high - low < 0.0001 ? steps[3] : steps[min(7, Int(((v - low) / (high - low)) * 7.999))]
        })
    }

    /// One cell that stands for the weather. Symbols when allowed, a double-width letter otherwise.
    public func weather(_ code: Int) -> String {
        let kind: (String, String)
        switch code {
        case 0, 1: kind = ("○", "Ｓ")              // sun
        case 2: kind = ("◎", "Ｐ")                 // partly cloudy
        case 3: kind = ("●", "Ｃ")                 // cloud
        case 45, 48: kind = ("≡", "Ｆ")            // fog
        case 51...67, 80...82: kind = ("∴", "Ｒ")  // rain
        case 71...77, 85, 86: kind = ("※", "Ｎ")   // snow
        case 95...99: kind = ("▲", "Ｔ")           // thunder
        default: kind = ("？", "？")
        }
        return pick(kind.0, kind.1)
    }
    /// The key for those cells, to show once on a weather card.
    public var weatherLegend: String {
        rich ? "○sun ◎part ●cloud ∴rain ※snow" : "S sun P part C cloud R rain N snow"
    }

    /// Every character this style can put on screen, grouped, for the on-glasses test cards.
    public static let testPages: [[String]] = [
        ["Symbols test 1 of 3", "Stars ★ ☆  Dots ● ○ ◎", "Squares ■ □ ◆ ◇", "Triangles ▲ △  Note ※ §", "Arrows → ← ↑ ↓ ◀"],
        ["Symbols test 2 of 3", "Lines ─ │ ┌ ┐ └ ┘ ├ ┤ ┬ ┴ ┼", "┌──┬──┐", "│12│34│", "└──┴──┘"],
        ["Symbols test 3 of 3", "Weather ○ ◎ ● ≡ ∴ ※ ▲", "Blocks ▁▂▃▄▅▆▇█", "Shade ░ ▒ ▓  Math ± × ÷ ≈ ≤ ≥ ∞", "Degrees ° ℃  Misc № ‰ 〓"],
    ]
}

/// Tables that line up. The glasses' ordinary letters vary in width, but double-width characters are all
/// one size, and two ordinary digits take the space of one of them. So a table cell is built from
/// double-width letters and either one double-width digit or a pair of ordinary ones.
public enum Grid {
    static let space: Character = "\u{3000}"

    /// Text in table form: letters and symbols double-width, digits paired where there are two together.
    public static func mono(_ text: String) -> String {
        var out = ""
        var digits = [Character]()
        func flush() {
            var run = digits[...]
            if run.count % 2 == 1, let first = run.first { out += TextLayout.wide(String(first)); run = run.dropFirst() }
            out += String(run)
            digits.removeAll()
        }
        for ch in text {
            if ch.isASCII, ch.isNumber { digits.append(ch) } else { flush(); out += TextLayout.wide(String(ch)) }
        }
        flush()
        return out
    }

    /// Width of table text, in double-width cells. A pair of ordinary characters counts as one.
    public static func cells(_ text: String) -> Int {
        var halves = 0
        for scalar in text.unicodeScalars { halves += (32...126).contains(scalar.value) || scalar.value == 0xB0 ? 1 : 2 }
        return (halves + 1) / 2
    }

    /// One table cell, exactly `width` cells wide. Text that's too long is cut.
    public static func cell(_ text: String, _ width: Int, right: Bool = false) -> String {
        var body = mono(text)
        while cells(body) > width, !body.isEmpty { body.removeLast() }
        let pad = String(repeating: space, count: max(0, width - cells(body)))
        return right ? pad + body : body + pad
    }

    /// A row from (text, width, right-aligned) cells, with trailing blanks removed to save bytes.
    public static func row(_ parts: [(String, Int, Bool)]) -> String {
        var line = parts.map { cell($0.0, $0.1, right: $0.2) }.joined()
        while line.last == space { line.removeLast() }
        return line
    }
}
