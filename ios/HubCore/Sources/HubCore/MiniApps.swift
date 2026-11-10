import Foundation

// MARK: - Trivia host

public struct TriviaQuestion: Equatable, Codable {
    public var category: String
    public var question: String
    public var answer: String
    public init(category: String, question: String, answer: String) {
        self.category = category; self.question = question; self.answer = answer
    }
}

public enum Trivia {
    /// Open Trivia Database, asked for URL-encoded text so no HTML entities need untangling.
    public static func feed(count: Int) -> URL {
        URL(string: "https://opentdb.com/api.php?amount=\(max(1, min(20, count)))&type=multiple&encode=url3986")!
    }
    public static func parse(_ data: Data) -> [TriviaQuestion] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = root["results"] as? [[String: Any]] else { return [] }
        func text(_ value: Any?) -> String { TextLayout.clean(((value as? String) ?? "").removingPercentEncoding ?? "") }
        return results.compactMap { r in
            let q = text(r["question"]), a = text(r["correct_answer"])
            guard !q.isEmpty, !a.isEmpty else { return nil }
            var category = text(r["category"])
            if let colon = category.range(of: ": ") { category = String(category[colon.upperBound...]) }
            return TriviaQuestion(category: category, question: q, answer: a)
        }
    }
}

/// A round of trivia where the wearer is the host: the question shows on the glasses, then its answer.
public struct TriviaRound: Equatable {
    public enum Phase: Equatable { case question, answer, done }
    public var questions: [TriviaQuestion]
    public var index = 0
    public var phase: Phase = .question
    public var phaseStarted: TimeInterval
    /// Seconds before the answer appears on its own. Zero means wait for a tap.
    public var questionSeconds: TimeInterval
    public var answerSeconds: TimeInterval
    /// Move on to the next question without a tap.
    public var autoAdvance: Bool

    public init(questions: [TriviaQuestion], now: TimeInterval, questionSeconds: TimeInterval = 20,
                answerSeconds: TimeInterval = 8, autoAdvance: Bool = true) {
        self.questions = questions; phaseStarted = now
        self.questionSeconds = questionSeconds; self.answerSeconds = answerSeconds; self.autoAdvance = autoAdvance
        if questions.isEmpty { phase = .done }
    }

    public var current: TriviaQuestion? { questions.indices.contains(index) ? questions[index] : nil }

    public mutating func reveal(now: TimeInterval) {
        guard phase == .question else { return }
        phase = .answer; phaseStarted = now
    }
    public mutating func next(now: TimeInterval) {
        guard phase != .done else { return }
        if index + 1 < questions.count { index += 1; phase = .question } else { phase = .done }
        phaseStarted = now
    }
    public mutating func tick(now: TimeInterval) {
        switch phase {
        case .question: if questionSeconds > 0, now - phaseStarted >= questionSeconds { reveal(now: now) }
        case .answer: if autoAdvance, now - phaseStarted >= answerSeconds { next(now: now) }
        case .done: break
        }
    }

    public func card(screen: Screen, now: TimeInterval) -> Card {
        guard let q = current, phase != .done else {
            return Card(["Trivia", TextLayout.headline("ROUND OVER", screen: screen), "\(questions.count) questions asked."])
        }
        let header = "Q\(index + 1) of \(questions.count): \(q.category)"
        switch phase {
        case .question:
            var lines = [TextLayout.fit(header, width: screen.columns)]
            lines += TextLayout.wrap(q.question, width: screen.columns, maxLines: screen.rows - 2)
            if questionSeconds > 0 {
                let left = max(0, Int((questionSeconds - (now - phaseStarted)).rounded(.up)))
                lines.append("Answer in \(left)s")
            }
            return Card(lines)
        case .answer:
            var lines = [TextLayout.fit("Answer \(index + 1) of \(questions.count)", width: screen.columns)]
            if q.answer.count <= screen.wideColumns { lines.append(TextLayout.headline(q.answer, screen: screen)) }
            else { lines += TextLayout.wrap(q.answer, width: screen.columns, maxLines: screen.rows - 1) }
            return Card(lines)
        case .done: return Card([])
        }
    }
}

// MARK: - Odd facts

public enum Facts {
    public static let randomFeed = URL(string: "https://uselessfacts.jsph.pl/api/v2/facts/random?language=en")!
    public static func onThisDayFeed(_ date: Date, zone: TimeZone = .current) -> URL {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = zone
        let c = cal.dateComponents([.month, .day], from: date)
        return URL(string: String(format: "https://api.wikimedia.org/feed/v1/wikipedia/en/onthisday/selected/%02d/%02d", c.month ?? 1, c.day ?? 1))!
    }
    public static func parseRandom(_ data: Data) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = root["text"] as? String else { return nil }
        let fact = TextLayout.clean(text)
        return fact.isEmpty ? nil : fact
    }
    /// "On this day in 1969: ..." for every entry Wikipedia picked for the date.
    public static func parseOnThisDay(_ data: Data) -> [String] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = root["selected"] as? [[String: Any]] else { return [] }
        return list.compactMap { item in
            guard let text = item["text"] as? String, !text.isEmpty else { return nil }
            let year = Envelope.int(item["year"]).map { "On this day in \($0): " } ?? "On this day: "
            return TextLayout.clean(year + text)
        }
    }
    public static func card(_ fact: String, screen: Screen) -> Card {
        let lines = ["Odd fact"] + TextLayout.wrap(fact, width: screen.columns)
        return Card(lines, scrolls: lines.count > screen.rows)
    }
}

// MARK: - Timer

public struct HubTimer: Equatable, Codable {
    public var duration: TimeInterval
    /// Wall-clock time the timer will hit zero, while running.
    public var endsAt: Date?
    /// What was left when it was paused.
    public var pausedRemaining: TimeInterval?
    public var label: String

    public init(minutes: Double, label: String = "Timer") {
        duration = max(1, minutes * 60); self.label = label; pausedRemaining = duration
    }
    public var isRunning: Bool { endsAt != nil }
    public func remaining(now: Date) -> TimeInterval {
        if let endsAt { return max(0, endsAt.timeIntervalSince(now)) }
        return pausedRemaining ?? duration
    }
    public func isDone(now: Date) -> Bool { endsAt != nil && remaining(now: now) <= 0 }
    public mutating func start(now: Date) {
        guard endsAt == nil else { return }
        endsAt = now.addingTimeInterval(pausedRemaining ?? duration); pausedRemaining = nil
    }
    public mutating func pause(now: Date) {
        guard endsAt != nil else { return }
        pausedRemaining = remaining(now: now); endsAt = nil
    }
    public mutating func reset() { endsAt = nil; pausedRemaining = duration }

    public static func clock(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds.rounded(.up)))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, (s / 60) % 60, s % 60) : String(format: "%02d:%02d", s / 60, s % 60)
    }
    public func card(screen: Screen, now: Date) -> Card {
        let left = remaining(now: now)
        let state = isDone(now: now) ? "TIME'S UP" : (isRunning ? label : "\(label) (paused)")
        let fraction = duration > 0 ? left / duration : 0
        return Card([TextLayout.fit(state, width: screen.columns),
                     TextLayout.headline(HubTimer.clock(left), screen: screen),
                     TextLayout.bar(fraction, cells: 16) + " \(Int((fraction * 100).rounded()))%"])
    }
}

// MARK: - Weather

public struct Weather: Equatable {
    public var place: String
    public var temperature: Int
    public var feelsLike: Int
    public var condition: String
    public var wind: Int
    public var high: Int?
    public var low: Int?
    public var rainChance: Int?
    public var tomorrow: String?

    public static func placeLookup(_ name: String) -> URL? {
        var parts = URLComponents(string: "https://geocoding-api.open-meteo.com/v1/search")
        parts?.queryItems = [URLQueryItem(name: "name", value: name), URLQueryItem(name: "count", value: "1"),
                             URLQueryItem(name: "language", value: "en")]
        return parts?.url
    }
    public static func parsePlace(_ data: Data) -> (name: String, latitude: Double, longitude: Double)? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let first = (root["results"] as? [[String: Any]])?.first,
              let lat = first["latitude"] as? Double, let lon = first["longitude"] as? Double else { return nil }
        return (first["name"] as? String ?? "", lat, lon)
    }
    public static func feed(latitude: Double, longitude: Double, celsius: Bool = false) -> URL {
        var parts = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        parts.queryItems = [
            URLQueryItem(name: "latitude", value: String(format: "%.4f", latitude)),
            URLQueryItem(name: "longitude", value: String(format: "%.4f", longitude)),
            URLQueryItem(name: "current", value: "temperature_2m,apparent_temperature,weather_code,wind_speed_10m"),
            URLQueryItem(name: "daily", value: "weather_code,temperature_2m_max,temperature_2m_min,precipitation_probability_max"),
            URLQueryItem(name: "temperature_unit", value: celsius ? "celsius" : "fahrenheit"),
            URLQueryItem(name: "wind_speed_unit", value: celsius ? "kmh" : "mph"),
            URLQueryItem(name: "timezone", value: "auto"), URLQueryItem(name: "forecast_days", value: "2"),
        ]
        return parts.url!
    }
    public static func parse(_ data: Data, place: String) -> Weather? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let current = root["current"] as? [String: Any],
              let temp = current["temperature_2m"] as? Double else { return nil }
        func whole(_ value: Any?) -> Int? { (value as? Double).map { Int($0.rounded()) } }
        func item(_ key: String, _ day: Int) -> Any? {
            guard let list = (root["daily"] as? [String: Any])?[key] as? [Any], list.indices.contains(day) else { return nil }
            return list[day]
        }
        var weather = Weather(place: place, temperature: Int(temp.rounded()),
                              feelsLike: whole(current["apparent_temperature"]) ?? Int(temp.rounded()),
                              condition: describe(Envelope.int(current["weather_code"]) ?? -1),
                              wind: whole(current["wind_speed_10m"]) ?? 0,
                              high: whole(item("temperature_2m_max", 0)), low: whole(item("temperature_2m_min", 0)),
                              rainChance: Envelope.int(item("precipitation_probability_max", 0)), tomorrow: nil)
        if let hi = whole(item("temperature_2m_max", 1)), let lo = whole(item("temperature_2m_min", 1)) {
            weather.tomorrow = "Tomorrow \(hi)/\(lo) \(describe(Envelope.int(item("weather_code", 1)) ?? -1))"
        }
        return weather
    }
    /// WMO weather codes, as Open-Meteo reports them.
    public static func describe(_ code: Int) -> String {
        switch code {
        case 0: return "Clear"; case 1: return "Mostly clear"; case 2: return "Partly cloudy"; case 3: return "Cloudy"
        case 45, 48: return "Fog"; case 51, 53, 55: return "Drizzle"; case 56, 57: return "Freezing drizzle"
        case 61: return "Light rain"; case 63: return "Rain"; case 65: return "Heavy rain"
        case 66, 67: return "Freezing rain"; case 71: return "Light snow"; case 73: return "Snow"
        case 75: return "Heavy snow"; case 77: return "Snow grains"; case 80, 81: return "Showers"
        case 82: return "Heavy showers"; case 85, 86: return "Snow showers"; case 95: return "Thunderstorm"
        case 96, 99: return "Storm with hail"; default: return "Weather"
        }
    }
    public var summary: String { "\(temperature)° \(condition)" + (rainChance.map { $0 >= 30 ? ", rain \($0)%" : "" } ?? "") }
    public func card(screen: Screen) -> Card {
        var lines = [TextLayout.fit(place.isEmpty ? "Weather" : place, width: screen.columns),
                     TextLayout.headline("\(temperature)° \(condition)", screen: screen)]
        lines.append("Feels \(feelsLike)°, wind \(wind)")
        if let high, let low { lines.append("High \(high), low \(low)" + (rainChance.map { ", rain \($0)%" } ?? "")) }
        if let tomorrow { lines.append(TextLayout.fit(tomorrow, width: screen.columns)) }
        return Card(Array(lines.prefix(screen.rows)))
    }
}

// MARK: - Calendar

public struct AgendaItem: Equatable {
    public var title: String
    public var start: Date
    public var end: Date
    public var allDay: Bool
    public var place: String?
    public init(title: String, start: Date, end: Date, allDay: Bool = false, place: String? = nil) {
        self.title = title; self.start = start; self.end = end; self.allDay = allDay; self.place = place
    }
}

public enum Agenda {
    /// Events still ahead (or under way), soonest first; all-day ones last.
    public static func upcoming(_ items: [AgendaItem], now: Date) -> [AgendaItem] {
        items.filter { $0.end > now }.sorted {
            if $0.allDay != $1.allDay { return !$0.allDay }
            return $0.start < $1.start
        }
    }
    public static func line(_ item: AgendaItem, now: Date) -> String {
        if item.allDay { return "All day: \(item.title)" }
        if item.start <= now { return "Now: \(item.title)" }
        return "\(HubClock.time(item.start)) \(item.title)"
    }
    public static func summary(_ items: [AgendaItem], now: Date) -> String? {
        guard let next = upcoming(items, now: now).first(where: { !$0.allDay }) else { return nil }
        if next.start <= now { return "Now: \(next.title)" }
        return "\(next.title) \(HubClock.until(next.start, from: now))"
    }
    public static func card(_ items: [AgendaItem], screen: Screen, now: Date) -> Card {
        let list = upcoming(items, now: now)
        guard !list.isEmpty else { return Card(["Calendar", "Nothing else today."]) }
        var lines = ["Calendar, \(HubClock.day(now))"]
        if let next = list.first, !next.allDay, next.start > now {
            lines.append(TextLayout.fit("Next \(HubClock.until(next.start, from: now))", width: screen.columns))
        }
        for item in list { lines.append(TextLayout.fit(line(item, now: now), width: screen.columns)) }
        return Card(lines, scrolls: lines.count > screen.rows)
    }
}

// MARK: - Reader and messages

public enum Reader {
    /// Longest text sent in one go; more than this is split into parts the phone steps through.
    public static let partBytes = 1500

    /// Fit text to the screen. Short text is a plain card; long text goes up whole (in parts if very long)
    /// and the crown scrolls it.
    public static func parts(_ text: String, screen: Screen) -> [Card] {
        let lines = TextLayout.wrap(text, width: screen.columns)
        guard !lines.isEmpty else { return [] }
        if lines.count <= screen.rows { return [Card(lines)] }
        var parts = [[String]](), current = [String](), bytes = 0
        for line in lines {
            let cost = line.utf8.count + 1
            if bytes + cost > partBytes, !current.isEmpty { parts.append(current); current = []; bytes = 0 }
            current.append(line); bytes += cost
        }
        if !current.isEmpty { parts.append(current) }
        if parts.count == 1 { return [Card(parts[0], scrolls: true)] }
        return parts.enumerated().map { i, body in
            Card(body + ["(part \(i + 1) of \(parts.count))"], scrolls: true)
        }
    }

    /// A short note (from the PC, or typed on the phone) as a card with its title on top.
    public static func note(title: String, body: String, screen: Screen) -> Card {
        var lines = [String]()
        let head = TextLayout.clean(title)
        if !head.isEmpty { lines += TextLayout.wrap(head, width: screen.columns, maxLines: 2) }
        if !TextLayout.clean(body).isEmpty { lines += TextLayout.wrap(body, width: screen.columns) }
        return Card(lines, scrolls: lines.count > screen.rows)
    }
}

// MARK: - Dashboard

public enum Dashboard {
    /// The home screen: time on top, then one line from each thing that has something to say. When there
    /// are more lines than rows, the extras rotate through the last rows every `rotate` seconds.
    public static func card(now: Date, summaries: [String], screen: Screen, rotate: TimeInterval = 8) -> Card {
        var lines = [TextLayout.headline(HubClock.time(now), screen: screen), HubClock.day(now)]
        let room = max(1, screen.rows - lines.count)
        let items = summaries.map { TextLayout.fit($0, width: screen.columns) }.filter { !$0.isEmpty }
        if items.count <= room { lines += items }
        else {
            let pages = Int((Double(items.count) / Double(room)).rounded(.up))
            let page = Int(now.timeIntervalSince1970 / max(2, rotate)) % pages
            lines += items[(page * room)..<min(items.count, (page + 1) * room)]
        }
        return Card(lines)
    }
}

// MARK: - Alerts that briefly take over the screen

public struct OverlayQueue: Equatable {
    public struct Item: Equatable {
        public var card: Card
        public var seconds: TimeInterval
        public var shownAt: TimeInterval?
    }
    public private(set) var items = [Item]()
    public init() {}

    public mutating func push(_ card: Card, seconds: TimeInterval = 10) {
        guard !card.isEmpty else { return }
        items.append(Item(card: card, seconds: seconds, shownAt: nil))
        if items.count > 8 { items.removeFirst(items.count - 8) }
    }
    /// The alert on screen right now, if any. Starts the next one when the current one has had its time.
    public mutating func current(now: TimeInterval) -> Card? {
        while let first = items.first {
            guard let shown = first.shownAt else { items[0].shownAt = now; return first.card }
            if now - shown < first.seconds { return first.card }
            items.removeFirst()
        }
        return nil
    }
    public mutating func clear() { items.removeAll() }
    public var isEmpty: Bool { items.isEmpty }
}
