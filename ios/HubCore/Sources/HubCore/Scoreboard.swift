import Foundation

public enum League: String, CaseIterable, Codable, Identifiable {
    case nfl, ncaaf, nba, wnba, ncaam, mlb, nhl, mls, epl
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .nfl: return "NFL"; case .nba: return "NBA"; case .mlb: return "MLB"; case .nhl: return "NHL"
        case .ncaaf: return "College football"; case .ncaam: return "College basketball"
        case .wnba: return "WNBA"; case .mls: return "MLS"; case .epl: return "Premier League"
        }
    }
    public var short: String {
        switch self { case .ncaaf: return "CFB"; case .ncaam: return "CBB"; default: return rawValue.uppercased() }
    }
    public enum Sport { case football, basketball, baseball, hockey, soccer }
    public var sport: Sport {
        switch self {
        case .nfl, .ncaaf: return .football
        case .nba, .wnba, .ncaam: return .basketball
        case .mlb: return .baseball
        case .nhl: return .hockey
        case .mls, .epl: return .soccer
        }
    }
    var path: String {
        switch self {
        case .nfl: return "football/nfl"; case .ncaaf: return "football/college-football"
        case .nba: return "basketball/nba"; case .wnba: return "basketball/wnba"
        case .ncaam: return "basketball/mens-college-basketball"
        case .mlb: return "baseball/mlb"; case .nhl: return "hockey/nhl"
        case .mls: return "soccer/usa.1"; case .epl: return "soccer/eng.1"
        }
    }
    /// ESPN's public scoreboard feed (the same one the PC app reads).
    public var feed: URL { URL(string: "https://site.api.espn.com/apis/site/v2/sports/\(path)/scoreboard")! }
    /// A team's page in the same feed, which names its next game even when it isn't on today's board.
    public func teamFeed(_ abbreviation: String) -> URL? {
        let safe = abbreviation.lowercased().filter { $0.isLetter || $0.isNumber }
        return safe.isEmpty ? nil : URL(string: "https://site.api.espn.com/apis/site/v2/sports/\(path)/teams/\(safe)")
    }
}

public struct Game: Equatable, Identifiable {
    public enum State: String { case scheduled, live, final }
    public struct Side: Equatable {
        public var abbr: String
        public var name: String
        public var score: Int?
        public var record: String?
        /// Points in each period so far.
        public var periods: [Int] = []
        public var timeouts: Int?
        public init(abbr: String, name: String, score: Int? = nil, record: String? = nil) {
            self.abbr = abbr; self.name = name; self.score = score; self.record = record
        }
    }
    public var id: String
    public var league: League
    public var away: Side
    public var home: Side
    public var state: State
    /// ESPN's short status, like "4:12 - 3rd", "Final/OT" or "11/15 - 12:00 PM EST".
    public var detail: String
    public var period: Int = 0
    public var start: Date?
    /// "2nd & 7 at KC 43"
    public var situation: String?
    public var lastPlay: String?
    /// Abbreviation of the team with the ball, when the feed says.
    public var possession: String?
    public var redZone = false
    public var network: String?

    public func has(_ team: String) -> Bool { away.abbr == team || home.abbr == team }
    public var scoreLine: String { "\(away.abbr) \(away.score.map(String.init) ?? "-") - \(home.abbr) \(home.score.map(String.init) ?? "-")" }
    public var title: String { "\(away.abbr) at \(home.abbr)" }
    /// The lead, in points; positive when the home side is ahead.
    public var margin: Int { (home.score ?? 0) - (away.score ?? 0) }

    /// A status short enough for a table column: "Q3 4:12", "Half", "Final", "Sun 7:20p".
    public func shortStatus(now: Date) -> String {
        switch state {
        case .final: return detail.contains("OT") ? "F/OT" : "Final"
        case .live:
            let d = detail.replacingOccurrences(of: " - ", with: " ")
            return d.count <= 12 ? d : String(d.prefix(12))
        case .scheduled:
            guard let start else { return "Soon" }
            let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = abs(start.timeIntervalSince(now)) < 20 * 3600 ? "h:mma" : "EEE h:mma"
            return f.string(from: start).replacingOccurrences(of: "AM", with: "a").replacingOccurrences(of: "PM", with: "p")
        }
    }
}

public enum Scoreboard {
    private static func number(_ value: Any?) -> Int? {
        if let s = value as? String { return Int(s) }
        if let d = value as? [String: Any] { return number(d["displayValue"]) ?? Envelope.int(d["value"]) }
        return Envelope.int(value)
    }

    static func game(from event: [String: Any], league: League) -> Game? {
        guard let comp = (event["competitions"] as? [[String: Any]])?.first,
              let sides = comp["competitors"] as? [[String: Any]], sides.count == 2 else { return nil }
        var ids = [String: String]()
        func side(_ which: String) -> Game.Side? {
            guard let raw = sides.first(where: { $0["homeAway"] as? String == which }),
                  let team = raw["team"] as? [String: Any],
                  let abbr = team["abbreviation"] as? String else { return nil }
            if let id = team["id"] as? String { ids[id] = abbr }
            var side = Game.Side(abbr: abbr, name: team["shortDisplayName"] as? String ?? abbr, score: number(raw["score"]),
                                 record: (((raw["records"] as? [[String: Any]]) ?? (raw["record"] as? [[String: Any]]))?.first)?["summary"] as? String)
            side.periods = (raw["linescores"] as? [[String: Any]] ?? []).compactMap { number($0["value"]) ?? number($0["displayValue"]) }
            return side
        }
        guard var away = side("away"), var home = side("home") else { return nil }
        let status = (comp["status"] as? [String: Any]) ?? (event["status"] as? [String: Any]) ?? [:]
        let type = status["type"] as? [String: Any] ?? [:]
        let state: Game.State
        switch type["state"] as? String { case "in": state = .live; case "post": state = .final; default: state = .scheduled }
        let dateText = (event["date"] as? String) ?? (comp["date"] as? String) ?? ""
        let short = DateFormatter()
        short.locale = Locale(identifier: "en_US_POSIX"); short.timeZone = TimeZone(identifier: "UTC")
        short.dateFormat = "yyyy-MM-dd'T'HH:mm'Z'"
        let start = ISO8601DateFormatter().date(from: dateText) ?? short.date(from: dateText)
        let situation = comp["situation"] as? [String: Any]
        if state == .scheduled { away.score = nil; home.score = nil; away.periods = []; home.periods = [] }
        if let situation, state == .live {
            away.timeouts = Envelope.int(situation["awayTimeouts"]); home.timeouts = Envelope.int(situation["homeTimeouts"])
        }
        var game = Game(id: event["id"] as? String ?? UUID().uuidString, league: league, away: away, home: home,
                        state: state, detail: type["shortDetail"] as? String ?? "", start: start)
        game.period = Envelope.int(status["period"]) ?? 0
        game.network = ((comp["broadcasts"] as? [[String: Any]])?.first?["names"] as? [String])?.first
            ?? ((comp["broadcasts"] as? [[String: Any]])?.first?["media"] as? [String: Any])?["shortName"] as? String
        if let situation, state == .live {
            game.situation = (situation["downDistanceText"] as? String) ?? (situation["shortDownDistanceText"] as? String)
            game.lastPlay = (situation["lastPlay"] as? [String: Any])?["text"] as? String
            if let id = situation["possession"] as? String { game.possession = ids[id] }
            game.redZone = situation["isRedZone"] as? Bool ?? false
        }
        return game
    }

    public static func parse(_ data: Data, league: League) -> [Game] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let events = root["events"] as? [[String: Any]] else { return [] }
        return events.compactMap { game(from: $0, league: league) }
    }

    /// A team's next game, from its own page. Used when the team isn't on today's scoreboard.
    public static func parseTeamNext(_ data: Data, league: League) -> Game? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let team = root["team"] as? [String: Any],
              let events = team["nextEvent"] as? [[String: Any]] else { return nil }
        return events.compactMap { game(from: $0, league: league) }.first
    }

    /// The game to show: a followed team's live game, else its next one today, else its latest final;
    /// with no followed team in the list, the first live game, else the next to start.
    public static func pick(_ games: [Game], teams: [String], now: Date) -> Game? {
        let mine = games.filter { g in teams.contains { g.has($0) } }
        func best(_ list: [Game]) -> Game? {
            if let live = list.first(where: { $0.state == .live }) { return live }
            let upcoming = list.filter { $0.state == .scheduled }.sorted { ($0.start ?? .distantFuture) < ($1.start ?? .distantFuture) }
            let finals = list.filter { $0.state == .final }.sorted { ($0.start ?? .distantPast) > ($1.start ?? .distantPast) }
            // a game that ended in the last few hours beats one that's a day away
            if let done = finals.first, let began = done.start, now.timeIntervalSince(began) < 8 * 3600,
               (upcoming.first?.start ?? .distantFuture).timeIntervalSince(now) > 3600 { return done }
            return upcoming.first ?? finals.first
        }
        return best(mine) ?? best(games)
    }

    /// Games in the order worth listing: followed teams first, then live, upcoming, finished.
    public static func ordered(_ games: [Game], teams: [String]) -> [Game] {
        func rank(_ g: Game) -> Int {
            let mine = teams.contains { g.has($0) } ? 0 : 10
            switch g.state { case .live: return mine; case .scheduled: return mine + 1; case .final: return mine + 2 }
        }
        return games.enumerated().sorted { a, b in
            let (ra, rb) = (rank(a.element), rank(b.element))
            if ra != rb { return ra < rb }
            if a.element.start != b.element.start { return (a.element.start ?? .distantFuture) < (b.element.start ?? .distantFuture) }
            return a.offset < b.offset
        }.map(\.element)
    }

    // MARK: Cards

    /// The main view of one game.
    public static func card(_ game: Game, screen: Screen, now: Date, stale: Bool = false, glyphs: Glyphs = .plain) -> Card {
        var lines = [String]()
        let w = screen.columns
        let rich = glyphs.style != .plain
        switch game.state {
        case .live:
            let head = "\(game.league.short) \(game.detail)" + (stale ? " (old)" : "")
            lines.append((rich ? glyphs.live + " " : "") + TextLayout.fit(head, width: w - (rich ? 3 : 0)))
            if rich || game.possession != nil {
                // one team per row, the score in a column, a marker on the side with the ball
                for side in [game.away, game.home] {
                    let mark = game.possession == side.abbr ? glyphs.here : ""
                    lines.append(Grid.row([(side.abbr, 5, false), (side.score.map(String.init) ?? "-", 2, true), ("", 1, false)]) + (mark.isEmpty ? "" : glyphs.blank + mark))
                }
            } else {
                lines.append(TextLayout.headline(game.scoreLine, screen: screen))
            }
            if let situation = game.situation, !situation.isEmpty {
                lines.append(TextLayout.fit((game.redZone ? "RED ZONE " : "") + situation, width: w))
            }
            if let play = game.lastPlay, !play.isEmpty, lines.count < screen.rows {
                lines.append(contentsOf: TextLayout.wrap("Last: " + shortPlay(play), width: w, maxLines: max(1, screen.rows - lines.count)))
            }
        case .final:
            lines.append(TextLayout.fit("\(game.league.short) \(game.detail.isEmpty ? "Final" : game.detail)", width: w))
            if rich {
                let won = (game.away.score ?? 0) > (game.home.score ?? 0) ? game.away.abbr : ((game.home.score ?? 0) > (game.away.score ?? 0) ? game.home.abbr : "")
                for side in [game.away, game.home] {
                    lines.append(Grid.row([(side.abbr, 5, false), (side.score.map(String.init) ?? "-", 2, true)]) + (won == side.abbr ? glyphs.blank + glyphs.star : ""))
                }
            } else { lines.append(TextLayout.headline(game.scoreLine, screen: screen)) }
            let winner = (game.away.score ?? 0) >= (game.home.score ?? 0) ? game.away : game.home
            if let record = winner.record { lines.append(TextLayout.fit("\(winner.name) now \(record)", width: w)) }
        case .scheduled:
            lines.append(TextLayout.fit("\(game.league.short) up next", width: w))
            lines.append(TextLayout.headline(game.title, screen: screen))
            if let start = game.start {
                lines.append(TextLayout.fit(HubClock.weekdayTime(start) + (game.network.map { " on \($0)" } ?? ""), width: w))
                if start.timeIntervalSince(now) < 36 * 3600 {
                    let verb = game.league.sport == .football || game.league.sport == .soccer ? "Kickoff" : "Starts"
                    lines.append("\(verb) \(HubClock.until(start, from: now))")
                }
            }
            let records = [game.away, game.home].compactMap { s in s.record.map { "\(s.abbr) \($0)" } }
            if records.count == 2 { lines.append(TextLayout.fit(records.joined(separator: ", "), width: w)) }
        }
        return Card(Array(lines.prefix(screen.rows)))
    }

    /// The box score: points by period in a table. Nil when there's nothing to tabulate (not started,
    /// or a sport like baseball whose line doesn't fit).
    public static func boxCard(_ game: Game, screen: Screen, glyphs: Glyphs = .plain) -> Card? {
        let played = max(game.away.periods.count, game.home.periods.count)
        guard game.state != .scheduled, played > 0, game.league.sport != .baseball else { return nil }
        let regulation: Int
        switch game.league.sport { case .hockey: regulation = 3; case .soccer: regulation = 2; default: regulation = game.league == .ncaam ? 2 : 4 }
        let columns = min(max(regulation, played), (screen.wideColumns - 4 - 3) / 2)
        let first = max(0, played - columns)                       // long overtime: show the latest periods
        func label(_ i: Int) -> String { i < regulation ? String(i + 1) : (i == regulation ? "OT" : "\(i - regulation + 1)O") }
        var lines = [TextLayout.fit("\(game.league.short) \(game.state == .final ? (game.detail.isEmpty ? "Final" : game.detail) : game.detail)", width: screen.columns)]
        lines.append(Grid.row([("", 4, false)] + (first..<(first + columns)).map { (label($0), 2, true) } + [("T", 3, true)]))
        for side in [game.away, game.home] {
            let cells = (first..<(first + columns)).map { i -> (String, Int, Bool) in
                (side.periods.indices.contains(i) ? String(side.periods[i]) : "", 2, true)
            }
            lines.append(Grid.row([(side.abbr, 4, false)] + cells + [(side.score.map(String.init) ?? "-", 3, true)]))
        }
        if let situation = game.situation, !situation.isEmpty, lines.count < screen.rows {
            lines.append(TextLayout.fit((game.possession.map { "\($0): " } ?? "") + situation, width: screen.columns))
        } else if game.state == .final, lines.count < screen.rows {
            let diff = abs(game.margin)
            let winner = game.margin > 0 ? game.home : game.away
            if diff > 0 { lines.append(TextLayout.fit("\(winner.name) by \(diff)", width: screen.columns)) }
        }
        if let a = game.away.timeouts, let h = game.home.timeouts, lines.count < screen.rows {
            lines.append(TextLayout.fit("Timeouts \(game.away.abbr) \(a), \(game.home.abbr) \(h)", width: screen.columns))
        }
        return Card(Array(lines.prefix(screen.rows)))
    }

    /// Every game in a list as a table, split into pages that fit the screen.
    public static func tablePages(_ games: [Game], title: String, screen: Screen, now: Date, glyphs: Glyphs = .plain) -> [Card] {
        guard !games.isEmpty else { return [Card([title, "No games on the schedule."])] }
        let perPage = max(1, screen.rows - 1)
        let statusCells = max(3, screen.wideColumns - 15)
        let pages = stride(from: 0, to: games.count, by: perPage).map { Array(games[$0..<min(games.count, $0 + perPage)]) }
        return pages.enumerated().map { index, page in
            let head = pages.count > 1 ? "\(title)  \(glyphs.pager(index, of: pages.count))" : title
            return Card([head] + page.map { g in
                let lead = g.state == .live ? glyphs.live : (g.state == .final ? glyphs.blank : glyphs.hollow)
                let status = g.shortStatus(now: now)
                let fitted = status.count > statusCells * 2 ? String(status.prefix(statusCells * 2)) : status
                return lead + Grid.row([(g.away.abbr, 4, false), (g.away.score.map(String.init) ?? "", 2, true), ("", 1, false),
                                        (g.home.abbr, 4, false), (g.home.score.map(String.init) ?? "", 2, true), ("", 1, false)]) + fitted
            })
        }
    }

    /// One line for the dashboard.
    public static func summary(_ game: Game, now: Date) -> String {
        switch game.state {
        case .live: return "\(game.scoreLine), \(game.detail)"
        case .final: return "\(game.scoreLine), final"
        case .scheduled: return "\(game.title), \(game.start.map { HubClock.weekdayTime($0) } ?? game.detail)"
        }
    }

    // MARK: Alerts

    /// What's worth interrupting for, comparing the last look at a game with this one.
    public static func alerts(old: Game?, new: Game) -> [[String]] {
        guard let old, old.id == new.id else { return [] }
        var out = [[String]]()
        let sport = new.league.sport
        if old.state == .scheduled, new.state == .live {
            out.append(["\(new.league.short) underway", new.title])
        }
        if new.state == .live || (old.state == .live && new.state == .final) {
            for (before, after) in [(old.away, new.away), (old.home, new.home)] {
                guard let was = before.score, let now = after.score, now > was else { continue }
                let points = now - was
                var lines: [String]
                switch sport {
                case .football:
                    let kind = points >= 6 ? "TOUCHDOWN" : points == 3 ? "FIELD GOAL" : points == 2 ? "SAFETY" : "SCORE"
                    lines = ["\(kind) \(after.abbr)!", new.scoreLine]
                case .hockey, .soccer: lines = ["GOAL \(after.abbr)!", new.scoreLine]
                case .baseball: lines = ["\(after.abbr) scores \(points)", new.scoreLine]
                case .basketball: continue                    // far too often; see lead changes below
                }
                if let play = new.lastPlay, !play.isEmpty { lines.append(shortPlay(play)) }
                out.append(lines)
            }
        }
        if sport == .basketball, new.state == .live {
            // the end of each period, and the lead changing hands late in a game
            if new.period > old.period, old.period > 0 {
                out.append(["End of \(ordinal(old.period))", new.scoreLine])
            } else if new.period >= 4, old.margin != 0, new.margin != 0, (old.margin > 0) != (new.margin > 0) {
                let leader = new.margin > 0 ? new.home.abbr : new.away.abbr
                out.append(["\(leader) takes the lead", new.scoreLine, new.detail])
            }
        }
        if sport == .football, new.state == .live, new.redZone, !old.redZone, let team = new.possession {
            out.append(["\(team) in the red zone", new.scoreLine])
        }
        if old.state == .live, new.state == .final {
            out.append(["FINAL", new.scoreLine])
        }
        return out
    }

    static func ordinal(_ n: Int) -> String {
        switch n { case 1: return "1st"; case 2: return "2nd"; case 3: return "3rd"; default: return "\(n)th" }
    }

    /// How long to wait before asking the feed again.
    public static func pollInterval(_ game: Game?, now: Date) -> TimeInterval {
        guard let game else { return 600 }
        switch game.state {
        case .live: return 15
        case .final: return 600
        case .scheduled:
            guard let start = game.start else { return 300 }
            let wait = start.timeIntervalSince(now)
            return wait < 600 ? 30 : wait < 3600 ? 120 : 600
        }
    }

    /// "(12:41 - 2nd) Tyquan Thornton 2 Yd pass from Patrick Mahomes (Harrison Butker Kick)" reads long on
    /// two lines; trim the clock prefix and spell yards the short way.
    static func shortPlay(_ text: String) -> String {
        var s = TextLayout.clean(text)
        if s.hasPrefix("("), let end = s.firstIndex(of: ")"), s.distance(from: s.startIndex, to: end) < 20 {
            s = String(s[s.index(after: end)...]).trimmingCharacters(in: .whitespaces)
        }
        for (a, b) in [(" Yds ", "-yd "), (" Yd ", "-yd "), (" yards ", "-yd "), (" yard ", "-yd ")] {
            s = s.replacingOccurrences(of: a, with: b)
        }
        return s
    }
}
