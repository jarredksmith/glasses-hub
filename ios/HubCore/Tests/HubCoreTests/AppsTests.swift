import XCTest
@testable import HubCore

final class LayoutTests: XCTestCase {
    func testCleanAndWrap() {
        XCTAssertEqual(TextLayout.clean("  It\u{2019}s \u{201C}fine\u{201D} \u{2014} really\u{2026} \u{1F600}\n ok "), "It's \"fine\" - really... ok")
        let lines = TextLayout.wrap("The quick brown fox jumps over the lazy dog near the riverbank today", width: 20)
        XCTAssertTrue(lines.allSatisfy { $0.count <= 20 })
        XCTAssertEqual(lines.joined(separator: " "), "The quick brown fox jumps over the lazy dog near the riverbank today")
        XCTAssertEqual(TextLayout.wrap("Supercalifragilisticexpialidocious", width: 10).first, "Supercalif")
        XCTAssertEqual(TextLayout.wrap("one\n\ntwo", width: 10), ["one", "", "two"])
    }
    func testFitAndLimitedWrap() {
        XCTAssertEqual(TextLayout.fit("abcdefghij", width: 6), "abcd..")
        XCTAssertEqual(TextLayout.fit("abc", width: 6), "abc")
        let two = TextLayout.wrap("alpha beta gamma delta epsilon zeta eta theta", width: 12, maxLines: 2)
        XCTAssertEqual(two.count, 2)
        XCTAssertTrue(two[1].hasSuffix(".."))
        XCTAssertTrue(two.allSatisfy { $0.count <= 12 })
    }
    func testWideAndHeadline() {
        XCTAssertEqual(TextLayout.wide("A1 !"), "\u{FF21}\u{FF11}\u{3000}\u{FF01}")
        let screen = Screen(size: .large)
        XCTAssertEqual(TextLayout.headline("KC 24 - BUF 17", screen: screen), TextLayout.wide("KC 24 - BUF 17"))
        XCTAssertEqual(TextLayout.headline("A headline too long for twenty wide cells", screen: screen), "A headline too long for twenty w..")
        XCTAssertEqual(TextLayout.bar(0.5, cells: 10), "[#####-----]")
        XCTAssertEqual(TextLayout.bar(2, cells: 4), "[####]")
    }
    func testPagesAndCards() {
        let pages = TextLayout.pages((1...9).map { "line \($0)" }, rows: 5)
        XCTAssertEqual(pages.count, 3)
        XCTAssertEqual(pages[0].last, "(1/3)")
        XCTAssertEqual(pages[2], ["line 9", "(3/3)"])
        XCTAssertEqual(Card(["a", "b", "c"]).text(rows: 2), "a\nb")
        XCTAssertEqual(Card(["a", "b", "c"], scrolls: true).text(rows: 2), "a\nb\nc")
    }
}

final class ScoreboardTests: XCTestCase {
    static func feed(state: String, detail: String, away: Int, home: Int, situation: Bool = true, date: String = "2026-11-15T18:00Z") -> Data {
        let situationJSON = situation ? """
        ,"situation":{"downDistanceText":"2nd & 7 at KC 43","possession":"12",
          "lastPlay":{"text":"(4:30 - 3rd) Travis Kelce 12 Yd pass from Patrick Mahomes (Harrison Butker Kick)"}}
        """ : ""
        return Data("""
        {"events":[
          {"id":"401","date":"\(date)","competitions":[{
            "competitors":[
              {"homeAway":"home","score":"\(home)","team":{"id":"2","abbreviation":"BUF","shortDisplayName":"Bills"},"records":[{"summary":"7-3"}]},
              {"homeAway":"away","score":"\(away)","team":{"id":"12","abbreviation":"KC","shortDisplayName":"Chiefs"},"records":[{"summary":"8-2"}]}],
            "status":{"period":3,"displayClock":"4:12","type":{"state":"\(state)","shortDetail":"\(detail)"}},
            "broadcasts":[{"market":"national","names":["CBS"]}]\(situationJSON)}]},
          {"id":"402","date":"2026-11-15T21:25Z","competitions":[{
            "competitors":[
              {"homeAway":"home","score":"0","team":{"id":"25","abbreviation":"SF","shortDisplayName":"49ers"}},
              {"homeAway":"away","score":"0","team":{"id":"26","abbreviation":"SEA","shortDisplayName":"Seahawks"}}],
            "status":{"type":{"state":"pre","shortDetail":"11/15 - 4:25 PM EST"}}}]}
        ]}
        """.utf8)
    }
    let now = ISO8601DateFormatter().date(from: "2026-11-15T19:30:00Z")!

    func testParseLiveGame() throws {
        let games = Scoreboard.parse(Self.feed(state: "in", detail: "4:12 - 3rd", away: 24, home: 17), league: .nfl)
        XCTAssertEqual(games.count, 2)
        let g = try XCTUnwrap(Scoreboard.pick(games, teams: ["KC"], now: now))
        XCTAssertEqual(g.state, .live)
        XCTAssertEqual(g.away.abbr, "KC"); XCTAssertEqual(g.away.score, 24); XCTAssertEqual(g.home.score, 17)
        XCTAssertEqual(g.possession, "KC")
        XCTAssertEqual(g.network, "CBS")
        XCTAssertEqual(g.start, ISO8601DateFormatter().date(from: "2026-11-15T18:00:00Z"))
        let card = Scoreboard.card(g, screen: Screen(size: .large), now: now)
        XCTAssertEqual(card.lines[0], "NFL 4:12 - 3rd")
        XCTAssertEqual(card.lines[1], TextLayout.wide("KC 24 - BUF 17"))
        XCTAssertEqual(card.lines[2], "KC ball: 2nd & 7 at KC 43")
        XCTAssertTrue(card.lines[3].hasPrefix("Last: Travis Kelce 12-yd pass"))
        XCTAssertLessThanOrEqual(card.lines.count, 5)
        XCTAssertEqual(Scoreboard.pollInterval(g, now: now), 15)
    }

    func testPickPrefersFollowedTeamThenLiveGames() {
        let games = Scoreboard.parse(Self.feed(state: "in", detail: "4:12 - 3rd", away: 24, home: 17), league: .nfl)
        XCTAssertEqual(Scoreboard.pick(games, teams: ["SEA"], now: now)?.id, "402")
        XCTAssertEqual(Scoreboard.pick(games, teams: [], now: now)?.id, "401")
        XCTAssertEqual(Scoreboard.pick(games, teams: ["DAL"], now: now)?.id, "401")
        XCTAssertNil(Scoreboard.pick([], teams: ["KC"], now: now))
    }

    func testScheduledAndFinalCards() throws {
        let pre = try XCTUnwrap(Scoreboard.parse(Self.feed(state: "pre", detail: "11/15 - 1:00 PM EST", away: 0, home: 0, situation: false), league: .nfl).first)
        XCTAssertNil(pre.away.score)
        let early = ISO8601DateFormatter().date(from: "2026-11-15T17:35:00Z")!
        let card = Scoreboard.card(pre, screen: Screen(size: .small), now: early)
        XCTAssertEqual(card.lines[1], TextLayout.wide("KC at BUF"))
        XCTAssertTrue(card.lines.contains("Kickoff in 25 min"))
        XCTAssertTrue(card.lines.contains("KC 8-2, BUF 7-3"))
        XCTAssertEqual(Scoreboard.pollInterval(pre, now: early), 120)

        let done = try XCTUnwrap(Scoreboard.parse(Self.feed(state: "post", detail: "Final", away: 31, home: 27, situation: false), league: .nfl).first)
        let final = Scoreboard.card(done, screen: Screen(size: .large), now: now)
        XCTAssertEqual(final.lines, ["NFL Final", TextLayout.wide("KC 31 - BUF 27"), "Chiefs now 8-2"])
    }

    func testAlerts() throws {
        func game(_ state: String, _ a: Int, _ h: Int) throws -> Game {
            try XCTUnwrap(Scoreboard.parse(Self.feed(state: state, detail: "x", away: a, home: h), league: .nfl).first)
        }
        let td = Scoreboard.alerts(old: try game("in", 17, 17), new: try game("in", 24, 17))
        XCTAssertEqual(td.count, 1)
        XCTAssertEqual(td[0][0], "TOUCHDOWN KC!")
        XCTAssertEqual(td[0][1], "KC 24 - BUF 17")
        XCTAssertEqual(Scoreboard.alerts(old: try game("in", 17, 17), new: try game("in", 17, 20)).first?.first, "FIELD GOAL BUF!")
        XCTAssertEqual(Scoreboard.alerts(old: try game("pre", 0, 0), new: try game("in", 0, 0)).first?.first, "NFL underway")
        XCTAssertEqual(Scoreboard.alerts(old: try game("in", 24, 17), new: try game("post", 24, 17)).last, ["FINAL", "KC 24 - BUF 17"])
        XCTAssertTrue(Scoreboard.alerts(old: try game("in", 24, 17), new: try game("in", 24, 17)).isEmpty)
        XCTAssertTrue(Scoreboard.alerts(old: nil, new: try game("in", 24, 17)).isEmpty)
    }

    func testGarbageFeedGivesNoGames() {
        XCTAssertTrue(Scoreboard.parse(Data("not json".utf8), league: .nba).isEmpty)
        XCTAssertTrue(Scoreboard.parse(Data("{\"events\":[{\"id\":\"1\"}]}".utf8), league: .nba).isEmpty)
    }
}

final class MiniAppTests: XCTestCase {
    func testTriviaParseAndRound() {
        let data = Data("""
        {"response_code":0,"results":[
          {"category":"Entertainment%3A%20Film","question":"Who%20directed%20%22Jaws%22%3F","correct_answer":"Steven%20Spielberg","incorrect_answers":["A","B","C"]},
          {"category":"Science","question":"What%20is%20H2O%3F","correct_answer":"Water","incorrect_answers":[]}]}
        """.utf8)
        let questions = Trivia.parse(data)
        XCTAssertEqual(questions, [TriviaQuestion(category: "Film", question: "Who directed \"Jaws\"?", answer: "Steven Spielberg"),
                                   TriviaQuestion(category: "Science", question: "What is H2O?", answer: "Water")])
        let screen = Screen(size: .large)
        var round = TriviaRound(questions: questions, now: 0, questionSeconds: 20, answerSeconds: 8)
        XCTAssertEqual(round.card(screen: screen, now: 5).lines, ["Q1 of 2: Film", "Who directed \"Jaws\"?", "Answer in 15s"])
        round.tick(now: 19); XCTAssertEqual(round.phase, .question)
        round.tick(now: 20); XCTAssertEqual(round.phase, .answer)
        XCTAssertEqual(round.card(screen: screen, now: 21).lines, ["Answer 1 of 2", TextLayout.wide("Steven Spielberg")])
        round.tick(now: 28.5); XCTAssertEqual(round.index, 1); XCTAssertEqual(round.phase, .question)
        round.reveal(now: 30); round.next(now: 31)
        XCTAssertEqual(round.phase, .done)
        XCTAssertEqual(round.card(screen: screen, now: 32).lines[1], TextLayout.wide("ROUND OVER"))
        XCTAssertEqual(TriviaRound(questions: [], now: 0).phase, .done)
    }

    func testTriviaWaitsForATapWhenTimersAreOff() {
        var round = TriviaRound(questions: [TriviaQuestion(category: "c", question: "q", answer: "a")], now: 0, questionSeconds: 0, autoAdvance: false)
        round.tick(now: 500); XCTAssertEqual(round.phase, .question)
        round.reveal(now: 501); round.tick(now: 900); XCTAssertEqual(round.phase, .answer)
    }

    func testFacts() {
        XCTAssertEqual(Facts.parseRandom(Data("{\"id\":\"1\",\"text\":\"Bananas are berries.\"}".utf8)), "Bananas are berries.")
        XCTAssertNil(Facts.parseRandom(Data("{}".utf8)))
        let day = Facts.parseOnThisDay(Data("{\"selected\":[{\"text\":\"Apollo 12 launched.\",\"year\":1969},{\"text\":\"\"}]}".utf8))
        XCTAssertEqual(day, ["On this day in 1969: Apollo 12 launched."])
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
        let date = cal.date(from: DateComponents(year: 2026, month: 3, day: 7))!
        XCTAssertTrue(Facts.onThisDayFeed(date, zone: TimeZone(identifier: "UTC")!).absoluteString.hasSuffix("/selected/03/07"))
        let long = Facts.card(String(repeating: "word ", count: 80), screen: Screen(size: .large))
        XCTAssertTrue(long.scrolls)
        XCTAssertFalse(Facts.card("Short one.", screen: Screen(size: .large)).scrolls)
    }

    func testTimer() {
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        var timer = HubTimer(minutes: 10)
        XCTAssertEqual(timer.remaining(now: t0), 600)
        timer.start(now: t0)
        XCTAssertEqual(timer.remaining(now: t0.addingTimeInterval(138)), 462)
        let card = timer.card(screen: Screen(size: .large), now: t0.addingTimeInterval(138))
        XCTAssertEqual(card.lines, ["Timer", TextLayout.wide("07:42"), "[############----] 77%"])
        timer.pause(now: t0.addingTimeInterval(200))
        XCTAssertEqual(timer.remaining(now: t0.addingTimeInterval(9999)), 400)
        XCTAssertFalse(timer.isRunning)
        timer.start(now: t0.addingTimeInterval(300))
        XCTAssertTrue(timer.isDone(now: t0.addingTimeInterval(701)))
        XCTAssertEqual(timer.card(screen: Screen(size: .large), now: t0.addingTimeInterval(701)).lines[0], "TIME'S UP")
        XCTAssertEqual(HubTimer.clock(3725), "1:02:05")
        timer.reset(); XCTAssertEqual(timer.remaining(now: t0), 600)
    }

    func testWeather() throws {
        let data = Data("""
        {"current":{"temperature_2m":71.6,"apparent_temperature":69.2,"weather_code":2,"wind_speed_10m":12.4},
         "daily":{"weather_code":[2,63],"temperature_2m_max":[78.1,64.0],"temperature_2m_min":[55.3,48.8],"precipitation_probability_max":[10,80]}}
        """.utf8)
        let w = try XCTUnwrap(Weather.parse(data, place: "Oklahoma City"))
        XCTAssertEqual(w.temperature, 72); XCTAssertEqual(w.condition, "Partly cloudy"); XCTAssertEqual(w.wind, 12)
        XCTAssertEqual(w.card(screen: Screen(size: .large)).lines,
                       ["Oklahoma City", TextLayout.wide("72° Partly cloudy"), "Feels 69°, wind 12", "High 78, low 55, rain 10%", "Tomorrow 64/49 Rain"])
        XCTAssertEqual(w.summary, "72° Partly cloudy")
        XCTAssertNil(Weather.parse(Data("{}".utf8), place: ""))
        let place = try XCTUnwrap(Weather.parsePlace(Data("{\"results\":[{\"name\":\"Tulsa\",\"latitude\":36.15,\"longitude\":-95.99}]}".utf8)))
        XCTAssertEqual(place.name, "Tulsa")
        XCTAssertTrue(Weather.feed(latitude: 35.4676, longitude: -97.5164).absoluteString.contains("latitude=35.4676"))
        XCTAssertNotNil(Weather.placeLookup("Oklahoma City"))
    }

    func testAgenda() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let items = [AgendaItem(title: "Budget review", start: now.addingTimeInterval(1500), end: now.addingTimeInterval(5100)),
                     AgendaItem(title: "Standup", start: now.addingTimeInterval(-7200), end: now.addingTimeInterval(-5400)),
                     AgendaItem(title: "Conference", start: now.addingTimeInterval(-3600), end: now.addingTimeInterval(80000), allDay: true),
                     AgendaItem(title: "Planning", start: now.addingTimeInterval(-600), end: now.addingTimeInterval(1200))]
        XCTAssertEqual(Agenda.upcoming(items, now: now).map(\.title), ["Planning", "Budget review", "Conference"])
        XCTAssertEqual(Agenda.summary(items, now: now), "Now: Planning")
        XCTAssertEqual(Agenda.summary([items[0]], now: now), "Budget review in 25 min")
        let card = Agenda.card(items, screen: Screen(size: .large), now: now)
        XCTAssertEqual(card.lines[1], "Now: Planning")
        XCTAssertEqual(card.lines.last, "All day: Conference")
        XCTAssertEqual(Agenda.card([], screen: Screen(size: .large), now: now).lines, ["Calendar", "Nothing else today."])
        XCTAssertNil(Agenda.summary([], now: now))
    }

    func testReaderAndNotes() {
        let screen = Screen(size: .large)
        XCTAssertEqual(Reader.parts("Short note.", screen: screen), [Card(["Short note."])])
        let medium = Reader.parts(String(repeating: "Some words to read. ", count: 30), screen: screen)
        XCTAssertEqual(medium.count, 1); XCTAssertTrue(medium[0].scrolls)
        let long = Reader.parts(String(repeating: "Some words to read. ", count: 400), screen: screen)
        XCTAssertGreaterThan(long.count, 3)
        XCTAssertTrue(long.allSatisfy { $0.text(rows: 5).utf8.count <= CaptionWire.maxTextBytes })
        XCTAssertEqual(long[0].lines.last, "(part 1 of \(long.count))")
        XCTAssertTrue(Reader.parts("  \n ", screen: screen).isEmpty)
        XCTAssertEqual(Reader.note(title: "Render done", body: "Explainer video exported", screen: screen).lines, ["Render done", "Explainer video exported"])
    }

    func testDashboardRotatesWhenCrowded() {
        let screen = Screen(size: .large)                           // 5 rows: time, day, 3 lines
        let t = Date(timeIntervalSince1970: 1_800_000_000)
        let few = Dashboard.card(now: t, summaries: ["a", "", "b"], screen: screen)
        XCTAssertEqual(Array(few.lines.suffix(2)), ["a", "b"])
        let many = ["1", "2", "3", "4", "5"]
        let first = Dashboard.card(now: Date(timeIntervalSince1970: 0), summaries: many, screen: screen, rotate: 8)
        let second = Dashboard.card(now: Date(timeIntervalSince1970: 8), summaries: many, screen: screen, rotate: 8)
        XCTAssertEqual(Array(first.lines.suffix(3)), ["1", "2", "3"])
        XCTAssertEqual(Array(second.lines.suffix(2)), ["4", "5"])
        XCTAssertLessThanOrEqual(first.lines.count, 5)
    }

    func testOverlaysShowInTurnThenStepAside() {
        var q = OverlayQueue()
        XCTAssertNil(q.current(now: 0))
        q.push(Card(["first"]), seconds: 10); q.push(Card(["second"]), seconds: 5); q.push(Card([" "]))
        XCTAssertEqual(q.current(now: 100)?.lines, ["first"])
        XCTAssertEqual(q.current(now: 109)?.lines, ["first"])
        XCTAssertEqual(q.current(now: 110)?.lines, ["second"])
        XCTAssertEqual(q.current(now: 114)?.lines, ["second"])
        XCTAssertNil(q.current(now: 116))
        XCTAssertTrue(q.isEmpty)
    }
}
