import Foundation

public enum League: String, CaseIterable, Codable, Identifiable {
    case nfl, nba, mlb, nhl, ncaaf, ncaam
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .nfl: return "NFL"; case .nba: return "NBA"; case .mlb: return "MLB"; case .nhl: return "NHL"
        case .ncaaf: return "College football"; case .ncaam: return "College basketball"
        }
    }
    public var short: String {
        switch self { case .ncaaf: return "CFB"; case .ncaam: return "CBB"; default: return rawValue.uppercased() }
    }
    /// ESPN's public scoreboard feed (the same one the PC app reads).
    public var feed: URL {
        let path: String
        switch self {
        case .nfl: path = "football/nfl"; case .nba: path = "basketball/nba"; case .mlb: path = "baseball/mlb"
        case .nhl: path = "hockey/nhl"; case .ncaaf: path = "football/college-football"
        case .ncaam: path = "basketball/mens-college-basketball"
        }
        return URL(string: "https://site.api.espn.com/apis/site/v2/sports/\(path)/scoreboard")!
    }
}

public struct Game: Equatable, Identifiable {
    public enum State: String { case scheduled, live, final }
    public struct Side: Equatable {
        public var abbr: String
        public var name: String
        public var score: Int?
        public var record: String?
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
    public var start: Date?
    /// "2nd & 7 at KC 43"
    public var situation: String?
    public var lastPlay: String?
    /// Abbreviation of the team with the ball, when the feed says.
    public var possession: String?
    public var network: String?

    public func has(_ team: String) -> Bool { away.abbr == team || home.abbr == team }
    public var scoreLine: String { "\(away.abbr) \(away.score.map(String.init) ?? "-") - \(home.abbr) \(home.score.map(String.init) ?? "-")" }
}

public enum Scoreboard {
    public static func parse(_ data: Data, league: League) -> [Game] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let events = root["events"] as? [[String: Any]] else { return [] }
        let iso = ISO8601DateFormatter()
        let isoShort = DateFormatter()
        isoShort.locale = Locale(identifier: "en_US_POSIX"); isoShort.timeZone = TimeZone(identifier: "UTC")
        isoShort.dateFormat = "yyyy-MM-dd'T'HH:mm'Z'"
        return events.compactMap { event in
            guard let comp = (event["competitions"] as? [[String: Any]])?.first,
                  let sides = comp["competitors"] as? [[String: Any]], sides.count == 2 else { return nil }
            var ids = [String: String]()
            func side(_ which: String) -> Game.Side? {
                guard let raw = sides.first(where: { $0["homeAway"] as? String == which }),
                      let team = raw["team"] as? [String: Any],
                      let abbr = team["abbreviation"] as? String else { return nil }
                if let id = team["id"] as? String { ids[id] = abbr }
                let record = ((raw["records"] as? [[String: Any]])?.first)?["summary"] as? String
                return Game.Side(abbr: abbr, name: team["shortDisplayName"] as? String ?? abbr,
                                 score: (raw["score"] as? String).flatMap { Int($0) }, record: record)
            }
            guard let away = side("away"), let home = side("home") else { return nil }
            let status = (comp["status"] as? [String: Any]) ?? (event["status"] as? [String: Any]) ?? [:]
            let type = status["type"] as? [String: Any] ?? [:]
            let state: Game.State
            switch type["state"] as? String { case "in": state = .live; case "post": state = .final; default: state = .scheduled }
            let dateText = event["date"] as? String ?? ""
            let start = iso.date(from: dateText) ?? isoShort.date(from: dateText)
            let situation = comp["situation"] as? [String: Any]
            let network = ((comp["broadcasts"] as? [[String: Any]])?.first?["names"] as? [String])?.first
            var game = Game(id: event["id"] as? String ?? UUID().uuidString, league: league, away: away, home: home,
                            state: state, detail: type["shortDetail"] as? String ?? "", start: start,
                            situation: nil, lastPlay: nil, possession: nil, network: network)
            if state == .scheduled { game.away.score = nil; game.home.score = nil }
            if let situation, state == .live {
                game.situation = (situation["downDistanceText"] as? String) ?? (situation["shortDownDistanceText"] as? String)
                game.lastPlay = (situation["lastPlay"] as? [String: Any])?["text"] as? String
                if let id = situation["possession"] as? String { game.possession = ids[id] }
            }
            return game
        }
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

    public static func card(_ game: Game, screen: Screen, now: Date, stale: Bool = false) -> Card {
        var lines = [String]()
        let w = screen.columns
        switch game.state {
        case .live:
            lines.append(TextLayout.fit("\(game.league.short) \(game.detail)" + (stale ? " (old)" : ""), width: w))
            lines.append(TextLayout.headline(game.scoreLine, screen: screen))
            if let situation = game.situation, !situation.isEmpty {
                let ball = game.possession.map { "\($0) ball: " } ?? ""
                lines.append(TextLayout.fit(ball + situation, width: w))
            }
            if let play = game.lastPlay, !play.isEmpty {
                lines.append(contentsOf: TextLayout.wrap("Last: " + shortPlay(play), width: w, maxLines: max(1, screen.rows - lines.count)))
            }
        case .final:
            lines.append(TextLayout.fit("\(game.league.short) \(game.detail.isEmpty ? "Final" : game.detail)", width: w))
            lines.append(TextLayout.headline(game.scoreLine, screen: screen))
            let winner = (game.away.score ?? 0) >= (game.home.score ?? 0) ? game.away : game.home
            if let record = winner.record { lines.append(TextLayout.fit("\(winner.name) now \(record)", width: w)) }
        case .scheduled:
            lines.append(TextLayout.fit("\(game.league.short) up next", width: w))
            lines.append(TextLayout.headline("\(game.away.abbr) at \(game.home.abbr)", screen: screen))
            if let start = game.start {
                let when = HubClock.weekdayTime(start)
                lines.append(TextLayout.fit(when + (game.network.map { " on \($0)" } ?? ""), width: w))
                if start.timeIntervalSince(now) < 36 * 3600 {
                    let verb = (game.league == .nfl || game.league == .ncaaf) ? "Kickoff" : "Starts"
                    lines.append("\(verb) \(HubClock.until(start, from: now))")
                }
            }
            let records = [game.away, game.home].compactMap { s in s.record.map { "\(s.abbr) \($0)" } }
            if records.count == 2 { lines.append(TextLayout.fit(records.joined(separator: ", "), width: w)) }
        }
        return Card(Array(lines.prefix(screen.rows)))
    }

    /// One line for the dashboard.
    public static func summary(_ game: Game, now: Date) -> String {
        switch game.state {
        case .live: return "\(game.scoreLine), \(game.detail)"
        case .final: return "\(game.scoreLine), final"
        case .scheduled:
            let when = game.start.map { HubClock.weekdayTime($0) } ?? game.detail
            return "\(game.away.abbr) at \(game.home.abbr), \(when)"
        }
    }

    /// What's worth interrupting for, comparing the last look at a game with this one.
    public static func alerts(old: Game?, new: Game) -> [[String]] {
        guard let old, old.id == new.id else { return [] }
        var out = [[String]]()
        if old.state == .scheduled, new.state == .live {
            out.append(["\(new.league.short) underway", "\(new.away.abbr) at \(new.home.abbr)"])
        }
        if new.state == .live || (old.state == .live && new.state == .final) {
            for (before, after) in [(old.away, new.away), (old.home, new.home)] {
                guard let was = before.score, let now = after.score, now > was else { continue }
                // every score in football; other sports score too often to interrupt for
                guard new.league == .nfl || new.league == .ncaaf else { continue }
                let points = now - was
                let kind = points >= 6 ? "TOUCHDOWN" : points == 3 ? "FIELD GOAL" : points == 2 ? "SAFETY" : "SCORE"
                var lines = ["\(kind) \(after.abbr)!", new.scoreLine]
                if let play = new.lastPlay, !play.isEmpty { lines.append(shortPlay(play)) }
                out.append(lines)
            }
        }
        if old.state == .live, new.state == .final {
            out.append(["FINAL", new.scoreLine])
        }
        return out
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
