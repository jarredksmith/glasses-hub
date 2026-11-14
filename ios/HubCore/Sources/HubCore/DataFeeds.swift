import Foundation

/// Where a data feed's number comes from.
public enum FeedKind: String, Codable, CaseIterable, Sendable {
    case nightscout, homeAssistant, custom
    public var title: String {
        switch self { case .nightscout: return "Nightscout"; case .homeAssistant: return "Home Assistant"; case .custom: return "Any web address" }
    }
}

/// One value fetched from the wearer's own source and shown on the glasses.
public struct DataFeed: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var kind: FeedKind
    /// The site (Nightscout, Home Assistant) or the whole address (custom).
    public var address: String
    /// Home Assistant: the entity. Custom: the JSON field to show, as a dotted path.
    public var item: String
    /// Custom: text after the value. Nightscout: "mmol" for mmol/L.
    public var unit: String
    public var minutes: Int
    public var onDashboard: Bool

    public init(id: UUID = UUID(), name: String = "", kind: FeedKind, address: String = "", item: String = "", unit: String = "", minutes: Int = 5, onDashboard: Bool = true) {
        self.id = id; self.name = name; self.kind = kind; self.address = address; self.item = item
        self.unit = unit; self.minutes = minutes; self.onDashboard = onDashboard
    }

    public var title: String {
        let own = name.trimmingCharacters(in: .whitespaces)
        if !own.isEmpty { return own }
        switch kind { case .nightscout: return "Glucose"; case .homeAssistant: return item.isEmpty ? "Home" : item; case .custom: return "Feed" }
    }

    /// The address with a scheme and no trailing slash.
    var base: String {
        var text = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return "" }
        if !text.lowercased().hasPrefix("http://"), !text.lowercased().hasPrefix("https://") { text = "https://" + text }
        while text.hasSuffix("/") { text.removeLast() }
        return text
    }

    /// What to ask for, or nil while the feed isn't filled in yet.
    public func request(token: String) -> (url: URL, headers: [String: String])? {
        let token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !base.isEmpty else { return nil }
        switch kind {
        case .nightscout:
            var text = base + "/api/v1/entries.json?count=1"
            if !token.isEmpty, let safe = token.addingPercentEncoding(withAllowedCharacters: .alphanumerics) { text += "&token=" + safe }
            guard let url = URL(string: text) else { return nil }
            return (url, ["Accept": "application/json"])
        case .homeAssistant:
            let entity = item.trimmingCharacters(in: .whitespaces)
            guard !entity.isEmpty, !token.isEmpty, let safe = entity.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
                  let url = URL(string: base + "/api/states/" + safe) else { return nil }
            return (url, ["Authorization": "Bearer " + token, "Accept": "application/json"])
        case .custom:
            guard let url = URL(string: base) else { return nil }
            return (url, token.isEmpty ? [:] : ["Authorization": "Bearer " + token])
        }
    }
}

/// What a feed last said.
public struct FeedReading: Equatable, Sendable {
    public var value: String
    /// Nightscout's direction of travel ("Flat", "SingleUp" and so on).
    public var trend: String?
    /// When the source took the reading, if it says.
    public var at: Date?
    public var fetched: Date
    public init(value: String, trend: String? = nil, at: Date? = nil, fetched: Date) {
        self.value = value; self.trend = trend; self.at = at; self.fetched = fetched
    }
}

public enum FeedParser {
    /// Turns a feed's answer into a reading. Nil when the answer doesn't hold what the feed asks for.
    public static func read(_ feed: DataFeed, data: Data, now: Date) -> FeedReading? {
        let json = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        switch feed.kind {
        case .nightscout:
            guard let entry = (json as? [[String: Any]])?.first else { return nil }
            guard let level = number(entry["sgv"]) ?? number(entry["mbg"]) else { return nil }
            let value = feed.unit == "mmol" ? String(format: "%.1f", level / 18.018) : String(Int(level.rounded()))
            let at = number(entry["date"]).map { Date(timeIntervalSince1970: $0 / 1000) }
            return FeedReading(value: value, trend: entry["direction"] as? String, at: at, fetched: now)
        case .homeAssistant:
            guard let state = json as? [String: Any], let value = text(state["state"]) else { return nil }
            let unit = (state["attributes"] as? [String: Any])?["unit_of_measurement"] as? String ?? ""
            return FeedReading(value: unit.isEmpty ? value : value + " " + unit, fetched: now)
        case .custom:
            let path = feed.item.trimmingCharacters(in: .whitespaces)
            var value: String?
            if path.isEmpty {
                value = json.flatMap(text) ?? String(data: data, encoding: .utf8)?
                    .split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty }
            } else if let json {
                value = text(walk(json, path: path))
            }
            guard var shown = value, !shown.isEmpty else { return nil }
            if shown.count > 60 { shown = String(shown.prefix(58)) + ".." }
            let unit = feed.unit.trimmingCharacters(in: .whitespaces)
            return FeedReading(value: unit.isEmpty ? shown : shown + " " + unit, fetched: now)
        }
    }

    /// Follows a dotted path through JSON: names for objects, numbers for lists ("data.0.price").
    static func walk(_ json: Any, path: String) -> Any? {
        var here: Any? = json
        for part in path.split(separator: ".") {
            if let list = here as? [Any], let index = Int(part) { here = list.indices.contains(index) ? list[index] : nil }
            else if let object = here as? [String: Any] { here = object[String(part)] }
            else { return nil }
        }
        return here
    }

    static func number(_ value: Any?) -> Double? {
        if let text = value as? String { return Double(text) }
        return (value as? NSNumber)?.doubleValue
    }

    /// A single value as text; nil for lists, objects and nothing.
    static func text(_ value: Any?) -> String? {
        if let text = value as? String { return text.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard let number = value as? NSNumber else { return nil }
        let double = number.doubleValue
        if double == double.rounded(), abs(double) < 1e15 { return String(Int(double)) }
        var text = String(format: "%.2f", double)
        while text.hasSuffix("0") { text.removeLast() }
        return text
    }

    /// Nightscout's direction, as arrows the glasses have or as words.
    public static func trend(_ direction: String?, arrows: Bool) -> String {
        switch direction ?? "" {
        case "DoubleUp", "TripleUp": return arrows ? "↑↑" : "rising fast"
        case "SingleUp": return arrows ? "↑" : "rising"
        case "FortyFiveUp": return arrows ? "↑ slow" : "rising slowly"
        case "Flat": return arrows ? "→" : "steady"
        case "FortyFiveDown": return arrows ? "↓ slow" : "falling slowly"
        case "SingleDown": return arrows ? "↓" : "falling"
        case "DoubleDown", "TripleDown": return arrows ? "↓↓" : "falling fast"
        default: return ""
        }
    }

    /// How old a reading is, when that's worth saying: "4m", "2h", or nothing for a fresh one.
    public static func age(_ reading: FeedReading, feed: DataFeed, now: Date) -> String {
        let stamp = reading.at ?? reading.fetched
        let minutes = Int(now.timeIntervalSince(stamp) / 60)
        // a source that stamps its readings always shows the age; others only once a refresh was missed
        if reading.at == nil, minutes < max(2, feed.minutes * 2) { return "" }
        if minutes < 1 { return "now" }
        return minutes < 90 ? "\(minutes)m ago" : "\(minutes / 60)h ago"
    }

    /// One line for a feed: "Glucose 112 → 3m ago".
    public static func line(_ feed: DataFeed, reading: FeedReading?, note: String = "", now: Date, arrows: Bool) -> String {
        guard let reading else { return feed.title + ": " + (note.isEmpty ? "waiting" : note) }
        var parts = [feed.title, reading.value]
        let trend = FeedParser.trend(reading.trend, arrows: arrows)
        if !trend.isEmpty { parts.append(trend) }
        let age = FeedParser.age(reading, feed: feed, now: now)
        if !age.isEmpty { parts.append(arrows || trend.isEmpty ? age : "(" + age + ")") }
        return parts.joined(separator: " ")
    }

    /// The feeds' own screen. One feed gets the screen to itself; several take a line each.
    public static func card(_ feeds: [DataFeed], readings: [UUID: FeedReading], notes: [UUID: String], now: Date, screen: Screen, arrows: Bool, turn: Int) -> Card {
        guard !feeds.isEmpty else { return Card(["Data feeds", "Add one in the app,", "under Apps > Data feeds."]) }
        if feeds.count == 1, let feed = feeds.first {
            guard let reading = readings[feed.id] else { return Card([feed.title] + TextLayout.wrap(notes[feed.id] ?? "Waiting for the first reading.", width: screen.columns)) }
            let trend = FeedParser.trend(reading.trend, arrows: arrows)
            var lines = [feed.title, TextLayout.headline(trend.isEmpty ? reading.value : reading.value + " " + trend, screen: screen)]
            let age = FeedParser.age(reading, feed: feed, now: now)
            if !age.isEmpty { lines.append(age) }
            if let note = notes[feed.id], !note.isEmpty { lines += TextLayout.wrap(note, width: screen.columns) }
            return Card(Array(lines.prefix(screen.rows)))
        }
        let lines = feeds.map { TextLayout.fit(line($0, reading: readings[$0.id], note: notes[$0.id] ?? "", now: now, arrows: arrows), width: screen.columns) }
        let room = max(1, screen.rows - 1)
        let pages = max(1, Int((Double(lines.count) / Double(room)).rounded(.up)))
        let page = ((turn % pages) + pages) % pages
        return Card(["Data feeds"] + lines[(page * room)..<min(lines.count, (page + 1) * room)])
    }
}
