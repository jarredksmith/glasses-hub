import Foundation

public struct StockQuote: Equatable {
    public var symbol: String
    public var name: String
    public var price: Double
    /// The last close before today's session, when the source gives it.
    public var previous: Double?
    public var currency: String
    public var change: Double? { previous.map { price - $0 } }
    public var percent: Double? { previous.flatMap { $0 != 0 ? (price - $0) / $0 * 100 : nil } }
}

public enum Stocks {
    public static let defaults = ["^DJI", "^GSPC", "^IXIC"]

    private static let aliases: [String: String] = [
        "DOW": "^DJI", "DOWJONES": "^DJI", "DJIA": "^DJI", "DJI": "^DJI",
        "S&P": "^GSPC", "S&P500": "^GSPC", "SP500": "^GSPC", "SPX": "^GSPC", "GSPC": "^GSPC",
        "NASDAQ": "^IXIC", "IXIC": "^IXIC", "COMP": "^IXIC", "RUSSELL": "^RUT", "RUSSELL2000": "^RUT", "RUT": "^RUT",
        "VIX": "^VIX", "BITCOIN": "BTC-USD", "BTC": "BTC-USD", "ETHEREUM": "ETH-USD", "ETH": "ETH-USD",
        "GOLD": "GC=F", "OIL": "CL=F",
    ]
    private static let labels: [String: String] = [
        "^DJI": "Dow", "^GSPC": "S&P 500", "^IXIC": "Nasdaq", "^RUT": "Russell 2000", "^VIX": "VIX",
        "BTC-USD": "Bitcoin", "ETH-USD": "Ethereum", "GC=F": "Gold", "CL=F": "Oil",
    ]

    /// Turns what someone typed ("dow", "s&p 500", "aapl") into a ticker symbol. Nil if it can't be one.
    public static func symbol(_ typed: String) -> String? {
        let text = typed.uppercased().filter { !$0.isWhitespace }
        guard !text.isEmpty, text.count <= 12 else { return nil }
        if let known = aliases[text] { return known }
        let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789^.-=")
        return text.allSatisfy { allowed.contains($0) } ? text : nil
    }
    /// Symbols from a typed list separated by commas, spaces or new lines.
    public static func symbols(_ typed: String) -> [String] {
        var out = [String]()
        for part in typed.split(whereSeparator: { $0 == "," || $0 == "\n" || $0 == ";" }) {
            // "s&p 500" is one name; "aapl tsla" is two tickers
            let whole = symbol(String(part))
            let pieces = whole != nil && aliases[String(part).uppercased().filter { !$0.isWhitespace }] != nil
                ? [whole!] : part.split(separator: " ").compactMap { symbol(String($0)) }
            for s in pieces where !out.contains(s) { out.append(s) }
        }
        return out
    }
    public static func label(_ symbol: String) -> String { labels[symbol] ?? symbol }

    /// Yahoo Finance's chart data for one symbol: today's price and the previous close.
    public static func url(symbol: String) -> URL? {
        guard let safe = symbol.addingPercentEncoding(withAllowedCharacters: .alphanumerics) else { return nil }
        return URL(string: "https://query1.finance.yahoo.com/v8/finance/chart/\(safe)?range=1d&interval=1d")
    }

    public static func parse(_ data: Data) -> StockQuote? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = ((json["chart"] as? [String: Any])?["result"] as? [[String: Any]])?.first,
              let meta = result["meta"] as? [String: Any], let symbol = meta["symbol"] as? String,
              let price = (meta["regularMarketPrice"] as? NSNumber)?.doubleValue else { return nil }
        let previous = (meta["previousClose"] as? NSNumber)?.doubleValue ?? (meta["chartPreviousClose"] as? NSNumber)?.doubleValue
        return StockQuote(symbol: symbol, name: meta["shortName"] as? String ?? meta["longName"] as? String ?? symbol,
                          price: price, previous: previous, currency: meta["currency"] as? String ?? "")
    }

    /// A price with thousands separators: two decimals, or none once it's in the tens of thousands.
    public static func money(_ value: Double) -> String {
        let decimals = abs(value) >= 10_000 ? 0 : (abs(value) < 1 ? 4 : 2)
        let text = String(format: "%.\(decimals)f", abs(value))
        let parts = text.split(separator: ".", maxSplits: 1)
        var whole = "", digits = Array(parts.first ?? "")
        while digits.count > 3 { whole = "," + String(digits.suffix(3)) + whole; digits.removeLast(3) }
        whole = String(digits) + whole
        return (value < 0 ? "-" : "") + whole + (parts.count > 1 ? "." + parts[1] : "")
    }

    static func move(_ quote: StockQuote, arrows: Bool) -> String {
        guard let percent = quote.percent else { return "" }
        let size = String(format: "%.2f%%", abs(percent))
        if arrows { return (percent >= 0 ? "↑" : "↓") + size }
        return (percent >= 0 ? "+" : "-") + size
    }

    /// One line for a symbol: "Dow 44,210 ↑0.42%".
    public static func line(_ symbol: String, quote: StockQuote?, arrows: Bool) -> String {
        guard let quote else { return label(symbol) + "  …" }
        return [label(symbol), money(quote.price), move(quote, arrows: arrows)].filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// The markets screen. One symbol gets the screen to itself; more take a line each, a page at a time.
    public static func card(_ symbols: [String], quotes: [String: StockQuote], note: String, page: Int, arrows: Bool, screen: Screen) -> Card {
        guard !symbols.isEmpty else { return Card(["Stocks", "Add symbols in the app,", "under Apps > Stocks."]) }
        if quotes.isEmpty, !note.isEmpty { return Card(["Stocks"] + TextLayout.wrap(note, width: screen.columns, maxLines: max(1, screen.rows - 1))) }
        if symbols.count == 1, let quote = quotes[symbols[0]] {
            var lines = [label(symbols[0]), TextLayout.headline(money(quote.price), screen: screen)]
            if let change = quote.change { lines.append((change >= 0 ? "+" : "") + money(change) + "  " + move(quote, arrows: arrows)) }
            return Card(lines)
        }
        let room = max(1, screen.rows - 1)
        let pages = max(1, Int((Double(symbols.count) / Double(room)).rounded(.up)))
        let at = ((page % pages) + pages) % pages
        let shown = symbols[(at * room)..<min(symbols.count, (at + 1) * room)]
        let title = "Markets" + (pages > 1 ? "  \(at + 1)/\(pages)" : "")
        return Card([title] + shown.map { TextLayout.fit(line($0, quote: quotes[$0], arrows: arrows), width: screen.columns) })
    }
}
