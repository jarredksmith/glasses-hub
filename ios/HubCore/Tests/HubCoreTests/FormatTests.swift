import XCTest
@testable import HubCore

final class GridTests: XCTestCase {
    func testMonoPairsDigitsAndWidensEverythingElse() {
        XCTAssertEqual(Grid.mono("KC 7"), "ＫＣ\u{3000}７")
        XCTAssertEqual(Grid.mono("24"), "24")                       // a pair of digits fills one cell
        XCTAssertEqual(Grid.mono("104"), "１04")
        XCTAssertEqual(Grid.cells("ＫＣ"), 2); XCTAssertEqual(Grid.cells("24"), 1); XCTAssertEqual(Grid.cells("１04"), 2)
    }
    func testCellsAndRowsAlign() {
        XCTAssertEqual(Grid.cell("7", 2, right: true), "\u{3000}７")
        XCTAssertEqual(Grid.cell("24", 2, right: true), "\u{3000}24")
        XCTAssertEqual(Grid.cell("BUF", 4), "ＢＵＦ\u{3000}")
        XCTAssertEqual(Grid.cells(Grid.cell("TOOLONGNAME", 4)), 4)
        let a = Grid.row([("KC", 4, false), ("7", 2, true), ("x", 1, false)])
        let b = Grid.row([("BUF", 4, false), ("24", 2, true), ("x", 1, false)])
        XCTAssertEqual(Grid.cells(a), Grid.cells(b))
        XCTAssertEqual(Grid.row([("A", 2, false), ("", 3, false)]), "Ａ")   // trailing blanks trimmed
    }
    func testGlyphLevels() {
        XCTAssertEqual(Glyphs(.symbols).meter(0.5, cells: 4), "■■□□")
        XCTAssertEqual(Glyphs.plain.meter(0.5, cells: 4), "＃＃－－")
        XCTAssertEqual(Glyphs(.symbols).pager(1, of: 3), "○●○")
        XCTAssertEqual(Glyphs(.symbols).pager(11, of: 30), "12/30")
        XCTAssertEqual(Glyphs(.symbols).pager(0, of: 1), "")
        XCTAssertNil(Glyphs(.symbols).spark([1, 2, 3]))
        XCTAssertEqual(Glyphs(.blocks).spark([0, 5, 10]), "▁▄█")
        XCTAssertEqual(Glyphs(.symbols).weather(63), "∴"); XCTAssertEqual(Glyphs.plain.weather(63), "Ｒ")
        // every symbol is a single character, so it fills exactly one cell
        for g in [Glyphs.plain, Glyphs(.symbols)] {
            for s in [g.live, g.bullet, g.hollow, g.star, g.next, g.here, g.full, g.empty, g.rule, g.bar, g.weather(0), g.weather(71)] {
                XCTAssertEqual(s.count, 1); XCTAssertEqual(Grid.cells(s), 1)
            }
        }
        XCTAssertEqual(TextLayout.clean("★ ok ☆"), "★ ok ☆")     // stars survive cleaning; emoji don't
    }
    func testEveryTestPageFitsTheSmallestScreen() {
        for page in Glyphs.testPages { XCTAssertLessThanOrEqual(page.count, 5) }
    }
}

final class SportsTests: XCTestCase {
    static func event(league: String = "nfl", state: String, period: Int, away: (String, Int, [Int]), home: (String, Int, [Int]), extra: String = "") -> Data {
        func side(_ which: String, _ s: (String, Int, [Int]), _ id: String) -> String {
            let lines = s.2.map { "{\"value\":\($0).0}" }.joined(separator: ",")
            return "{\"homeAway\":\"\(which)\",\"score\":\"\(s.1)\",\"team\":{\"id\":\"\(id)\",\"abbreviation\":\"\(s.0)\",\"shortDisplayName\":\"\(s.0)s\"},\"linescores\":[\(lines)]}"
        }
        return Data("""
        {"events":[{"id":"9","date":"2026-11-15T18:00Z","competitions":[{"competitors":[\(side("home", home, "2")),\(side("away", away, "1"))],
        "status":{"period":\(period),"type":{"state":"\(state)","shortDetail":"4:12 - 3rd"}}\(extra)}]}]}
        """.utf8)
    }
    func game(_ data: Data, _ league: League = .nfl) throws -> Game { try XCTUnwrap(Scoreboard.parse(data, league: league).first) }

    func testBoxScoreTable() throws {
        let g = try game(Self.event(state: "in", period: 3, away: ("KC", 24, [7, 10, 7]), home: ("BUF", 17, [3, 7, 7]),
                                    extra: ",\"situation\":{\"downDistanceText\":\"2nd & 7 at KC 43\",\"possession\":\"1\",\"isRedZone\":false,\"homeTimeouts\":2,\"awayTimeouts\":3}"))
        XCTAssertEqual(g.away.periods, [7, 10, 7]); XCTAssertEqual(g.home.timeouts, 2)
        let card = try XCTUnwrap(Scoreboard.boxCard(g, screen: Screen(size: .small)))
        XCTAssertEqual(card.lines[0], "NFL 4:12 - 3rd")
        XCTAssertEqual(card.lines[1], "\u{3000}\u{3000}\u{3000}\u{3000}\u{3000}１\u{3000}２\u{3000}３\u{3000}４\u{3000}\u{3000}Ｔ")
        XCTAssertEqual(card.lines[2], "ＫＣ\u{3000}\u{3000}\u{3000}７\u{3000}10\u{3000}７\u{3000}\u{3000}\u{3000}\u{3000}24")
        XCTAssertEqual(Grid.cells(card.lines[2]), Grid.cells(card.lines[3]))       // columns line up
        XCTAssertEqual(card.lines[4], "KC: 2nd & 7 at KC 43")
        XCTAssertEqual(card.lines[5], "Timeouts KC 3, BUF 2")
        let pre = try game(Self.event(state: "pre", period: 0, away: ("KC", 0, []), home: ("BUF", 0, [])))
        XCTAssertNil(Scoreboard.boxCard(pre, screen: Screen(size: .small)))
        let ot = try game(Self.event(league: "nba", state: "post", period: 6, away: ("OKC", 130, [30, 25, 28, 27, 10, 10]), home: ("DAL", 128, [28, 27, 30, 25, 10, 8])), .nba)
        let wide = try XCTUnwrap(Scoreboard.boxCard(ot, screen: Screen(size: .large)))
        XCTAssertTrue(wide.lines.allSatisfy { Grid.cells($0) <= 20 || $0.unicodeScalars.allSatisfy { $0.value < 128 } })
        XCTAssertTrue(wide.lines[1].hasSuffix("Ｔ"))
        XCTAssertEqual(wide.lines.last, "OKCs by 2")
    }

    func testRichGameCardMarksTheWinner() throws {
        let g = try game(Self.event(state: "post", period: 4, away: ("KC", 31, [7, 7, 7, 10]), home: ("BUF", 27, [7, 7, 7, 6])))
        let card = Scoreboard.card(g, screen: Screen(size: .large), now: Date(), glyphs: Glyphs(.symbols))
        XCTAssertTrue(card.lines[1].hasSuffix("★")); XCTAssertFalse(card.lines[2].contains("★"))
        let live = try game(Self.event(state: "in", period: 3, away: ("KC", 24, []), home: ("BUF", 17, [])))
        XCTAssertTrue(Scoreboard.card(live, screen: Screen(size: .large), now: Date(), glyphs: Glyphs(.symbols)).lines[0].hasPrefix("● NFL"))
    }

    func testLeagueTablePages() throws {
        var games = [Game]()
        for i in 0..<9 {
            var g = try game(Self.event(state: i < 3 ? "in" : (i < 6 ? "pre" : "post"), period: 2, away: ("AW\(i)", 10 + i, []), home: ("HM\(i)", 7, [])))
            g.id = "g\(i)"; games.append(g)
        }
        let now = ISO8601DateFormatter().date(from: "2026-11-15T12:00:00Z")!
        let pages = Scoreboard.tablePages(games, title: "NFL", screen: Screen(size: .large), now: now, glyphs: Glyphs(.symbols))
        XCTAssertEqual(pages.count, 3)                              // 4 games a page on the 5-line screen
        XCTAssertEqual(pages[0].lines[0], "NFL  ●○○")
        XCTAssertTrue(pages[0].lines[1].hasPrefix("●ＡＷ０"))        // live games get a filled dot
        XCTAssertTrue(pages[0].lines[1].hasSuffix("4:12 3rd"))
        XCTAssertTrue(pages[1].lines[1].hasPrefix("○"))
        XCTAssertEqual(pages.flatMap(\.lines).count, 9 + 3)
        XCTAssertEqual(Scoreboard.tablePages([], title: "NBA", screen: Screen(size: .large), now: now)[0].lines[1], "No games on the schedule.")
        XCTAssertEqual(Scoreboard.ordered(games.reversed(), teams: ["AW7"]).first?.id, "g7")
        XCTAssertEqual(Scoreboard.ordered(games.reversed(), teams: []).first?.state, .live)
    }

    func testAlertsBySport() throws {
        func nhl(_ a: Int, _ h: Int) throws -> Game { try game(Self.event(state: "in", period: 2, away: ("OKC", a, []), home: ("DAL", h, [])), .nhl) }
        XCTAssertEqual(Scoreboard.alerts(old: try nhl(1, 1), new: try nhl(2, 1)).first?.first, "GOAL OKC!")
        func nba(_ p: Int, _ a: Int, _ h: Int) throws -> Game { try game(Self.event(state: "in", period: p, away: ("OKC", a, []), home: ("DAL", h, [])), .nba) }
        XCTAssertTrue(Scoreboard.alerts(old: try nba(2, 40, 38), new: try nba(2, 43, 38)).isEmpty)          // baskets don't interrupt
        XCTAssertEqual(Scoreboard.alerts(old: try nba(2, 55, 50), new: try nba(3, 55, 50)).first?.first, "End of 2nd")
        XCTAssertEqual(Scoreboard.alerts(old: try nba(4, 98, 99), new: try nba(4, 100, 99)).first?.first, "OKC takes the lead")
        XCTAssertTrue(Scoreboard.alerts(old: try nba(2, 40, 41), new: try nba(2, 42, 41)).isEmpty)          // early lead changes don't
        let before = try game(Self.event(state: "in", period: 3, away: ("KC", 24, []), home: ("BUF", 17, []), extra: ",\"situation\":{\"possession\":\"1\",\"isRedZone\":false}"))
        let after = try game(Self.event(state: "in", period: 3, away: ("KC", 24, []), home: ("BUF", 17, []), extra: ",\"situation\":{\"possession\":\"1\",\"isRedZone\":true}"))
        XCTAssertEqual(Scoreboard.alerts(old: before, new: after).first?.first, "KC in the red zone")
    }

    func testTeamNextGameAndShortStatus() throws {
        let data = Data("""
        {"team":{"abbreviation":"OKC","nextEvent":[{"id":"77","date":"2026-11-12T01:00Z","competitions":[{"competitors":[
          {"homeAway":"home","score":{"value":0.0,"displayValue":"0"},"team":{"id":"25","abbreviation":"OKC","shortDisplayName":"Thunder"},"record":[{"summary":"9-1"}]},
          {"homeAway":"away","team":{"id":"6","abbreviation":"DAL","shortDisplayName":"Mavericks"}}],
          "status":{"type":{"state":"pre","shortDetail":"11/11 - 8:00 PM EST"}},"broadcasts":[{"media":{"shortName":"ESPN"}}]}]}]}}
        """.utf8)
        let g = try XCTUnwrap(Scoreboard.parseTeamNext(data, league: .nba))
        XCTAssertEqual(g.title, "DAL at OKC"); XCTAssertEqual(g.home.record, "9-1"); XCTAssertEqual(g.network, "ESPN")
        XCTAssertNil(g.home.score)
        XCTAssertNil(Scoreboard.parseTeamNext(Data("{}".utf8), league: .nba))
        XCTAssertTrue(League.nba.teamFeed("OKC")!.absoluteString.hasSuffix("/basketball/nba/teams/okc"))
        XCTAssertNil(League.nba.teamFeed("  "))
        var done = g; done.state = .final; done.detail = "Final/OT"
        XCTAssertEqual(done.shortStatus(now: Date()), "F/OT")
        XCTAssertEqual(League.allCases.count, 9)
    }
}

final class ViewsTests: XCTestCase {
    static let weatherJSON = Data("""
    {"current":{"temperature_2m":71.6,"apparent_temperature":69.2,"weather_code":2,"wind_speed_10m":12.4},
     "hourly":{"time":["2026-11-10T16:00","2026-11-10T17:00","2026-11-10T18:00","2026-11-10T19:00","2026-11-10T20:00","2026-11-10T21:00","2026-11-10T22:00","2026-11-10T23:00","2026-11-11T00:00","2026-11-11T01:00","2026-11-11T02:00","2026-11-11T03:00","2026-11-11T04:00"],
       "temperature_2m":[72,71,70,68,66,64,62,60,58,57,56,55,54],"precipitation_probability":[0,0,5,5,10,20,40,60,80,80,70,60,50],
       "weather_code":[2,2,1,0,0,3,61,63,63,63,61,3,3]},
     "daily":{"time":["2026-11-10","2026-11-11","2026-11-12","2026-11-13","2026-11-14"],"weather_code":[2,63,3,0,71],
       "temperature_2m_max":[78.1,64.0,58,61,39],"temperature_2m_min":[55.3,48.8,40,38,28],"precipitation_probability_max":[10,80,20,0,60]}}
    """.utf8)

    func testHourlyTable() throws {
        let w = try XCTUnwrap(Weather.parse(Self.weatherJSON, place: "Oklahoma City"))
        XCTAssertEqual(w.hours.count, 13); XCTAssertEqual(w.hours[0].label, "4p"); XCTAssertEqual(w.hours[8].label, "12a")
        let card = try XCTUnwrap(w.hoursCard(screen: Screen(size: .large), glyphs: Glyphs(.symbols)))
        XCTAssertEqual(card.lines[0], "Oklahoma City 72° Partly cloudy")
        XCTAssertEqual(card.lines[1], "Ｎｏｗ\u{3000}７ｐ\u{3000}\u{3000}10ｐ\u{3000}\u{3000}１ａ\u{3000}\u{3000}４ａ")
        XCTAssertEqual(card.lines[2], "72\u{3000}\u{3000}\u{3000}68\u{3000}\u{3000}\u{3000}62\u{3000}\u{3000}\u{3000}57\u{3000}\u{3000}\u{3000}54")
        XCTAssertEqual(card.lines[3], "◎\u{3000}\u{3000}\u{3000}○\u{3000}\u{3000}\u{3000}∴\u{3000}\u{3000}\u{3000}∴\u{3000}\u{3000}\u{3000}●")
        XCTAssertTrue(card.lines[4].hasSuffix(" %rain"))
        XCTAssertEqual(card.lines.count, 5)
        XCTAssertNil(Weather.parse(Data("{\"current\":{\"temperature_2m\":70}}".utf8), place: "x")?.hoursCard(screen: Screen(size: .large)))
    }

    func testWeekTable() throws {
        let w = try XCTUnwrap(Weather.parse(Self.weatherJSON, place: "Oklahoma City"))
        let card = try XCTUnwrap(w.weekCard(screen: Screen(size: .small), glyphs: Glyphs(.symbols)))
        XCTAssertEqual(card.lines.count, 6)
        XCTAssertEqual(card.lines[1], "Ｎｏｗ\u{3000}◎\u{3000}\u{3000}78／55")
        XCTAssertEqual(card.lines[2], "Ｗｅｄ\u{3000}∴\u{3000}\u{3000}64／49\u{3000}∴80")
        XCTAssertEqual(w.weekCard(screen: Screen(size: .large))?.lines.count, 5)
        XCTAssertEqual(w.card(screen: Screen(size: .large)).lines[1], TextLayout.wide("72° Partly cloudy"))    // the plain card still works
    }

    func testMonthGrid() {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
        let nov10 = cal.date(from: DateComponents(year: 2026, month: 11, day: 10, hour: 12))!     // November 2026 starts on a Sunday
        let card = Agenda.monthCard(now: nov10, screen: Screen(size: .small), glyphs: Glyphs(.symbols), busyDays: [12], calendar: cal)
        XCTAssertEqual(card.lines[0], "November 2026")
        XCTAssertEqual(card.lines[1], "Ｓ\u{3000}Ｍ\u{3000}Ｔ\u{3000}Ｗ\u{3000}Ｔ\u{3000}Ｆ\u{3000}Ｓ")
        XCTAssertEqual(card.lines[2], "１\u{3000}２\u{3000}３\u{3000}４\u{3000}５\u{3000}６\u{3000}７")
        XCTAssertEqual(card.lines[3], "８\u{3000}９\u{3000}10◀11\u{3000}12·13\u{3000}14")                 // today and a busy day
        XCTAssertEqual(card.lines.count, 7)
        let small = Agenda.monthCard(now: nov10, screen: Screen(size: .large), calendar: cal)
        XCTAssertEqual(small.lines.count, 5)
        XCTAssertTrue(small.lines.contains { $0.contains("10＜") })                                      // the week with today stays in view
        let aug = cal.date(from: DateComponents(year: 2026, month: 8, day: 30))!                        // six weeks: Aug 2026 starts on a Saturday
        let six = Agenda.monthCard(now: aug, screen: Screen(size: .small), calendar: cal)
        XCTAssertEqual(six.lines.count, 7); XCTAssertTrue(six.lines[0].hasPrefix("Ｓ"))                   // title dropped to make room
    }

    func testAgendaMarkers() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let items = [AgendaItem(title: "Planning", start: now.addingTimeInterval(-600), end: now.addingTimeInterval(1200)),
                     AgendaItem(title: "Budget review", start: now.addingTimeInterval(1500), end: now.addingTimeInterval(5100)),
                     AgendaItem(title: "Dinner", start: now.addingTimeInterval(9000), end: now.addingTimeInterval(12000))]
        let lines = Agenda.listCard(items, screen: Screen(size: .small), now: now, glyphs: Glyphs(.symbols)).lines
        XCTAssertEqual(lines[1], "● Now: Planning")
        XCTAssertTrue(lines[2].hasPrefix("→ ")); XCTAssertTrue(lines[2].hasSuffix("(in 25 min)"))
        XCTAssertTrue(lines[3].hasPrefix("○ "))
        XCTAssertEqual(Agenda.listCard(items, screen: Screen(size: .small), now: now, glyphs: .plain), Agenda.card(items, screen: Screen(size: .small), now: now))
    }

    func testAutoPagerTurnsPagesAndHolds() {
        let card = Card((1...11).map { "line \($0)" }, scrolls: true)
        var pager = AutoPager()
        XCTAssertEqual(pager.page(of: card, rows: 5, now: 0, seconds: 10, loops: false).lines, ["line 1", "line 2", "line 3", "line 4", "(1/3)"])
        XCTAssertEqual(pager.count, 3)
        XCTAssertEqual(pager.page(of: card, rows: 5, now: 9, seconds: 10, loops: false).lines.last, "(1/3)")
        XCTAssertEqual(pager.page(of: card, rows: 5, now: 10, seconds: 10, loops: false).lines.last, "(2/3)")
        XCTAssertFalse(pager.page(of: card, rows: 5, now: 11, seconds: 10, loops: false).scrolls)       // never relies on the crown
        pager.paused = true
        XCTAssertEqual(pager.page(of: card, rows: 5, now: 99, seconds: 10, loops: false).lines.last, "(2/3)")
        pager.paused = false; pager.step(1, now: 100)
        XCTAssertEqual(pager.page(of: card, rows: 5, now: 200, seconds: 10, loops: false).lines, ["line 9", "line 10", "line 11", "(3/3)"])   // holds on the last page
        XCTAssertEqual(pager.page(of: card, rows: 5, now: 300, seconds: 10, loops: true).lines.last, "(1/3)")                              // or starts over
        pager.step(-5, now: 301); XCTAssertEqual(pager.index, 0)
        let other = Card((1...8).map { "other \($0)" })
        pager.step(1, now: 302)
        XCTAssertEqual(pager.page(of: other, rows: 5, now: 303, seconds: 10, loops: false).lines.first, "other 1")     // new text starts at the top
        XCTAssertEqual(pager.page(of: Card(["short"]), rows: 5, now: 304, seconds: 10, loops: false).lines, ["short"])
        XCTAssertEqual(pager.count, 1)
    }

    func testScrollingTextCanBeSentAsFinished() throws {
        var s = CaptionSession(sequenceStart: 1)
        s.finishScrollingText = true
        _ = s.start(now: 0); _ = s.subscribed(now: 0); _ = s.writeFinished(ok: true, now: 0)
        func status(_ actions: [CaptionSession.Action]) -> Int? {
            for case .write(let data, _) in actions {
                var d = FrameStreamDecoder()
                if let f = d.append(data).first { return Envelope(f.payload)?.int("status") }
            }
            return nil
        }
        s.show("long", scrolls: true); XCTAssertEqual(status(s.tick(now: 2)), 1)
        _ = s.writeFinished(ok: true, now: 2.1)
        s.show("short"); XCTAssertEqual(status(s.tick(now: 4)), 0)
    }
}

final class NewsTests: XCTestCase {
    func testRSS() {
        let rss = Data("""
        <?xml version="1.0"?><rss version="2.0" xmlns:content="http://purl.org/rss/1.0/modules/content/"><channel><title>Example</title><link>https://example.com</link>
        <item><title><![CDATA[Rover finds &amp; maps an ancient riverbed]]></title><link>https://example.com/a</link>
          <description>&lt;p&gt;The rover&#8217;s cameras traced a channel &lt;b&gt;nine miles&lt;/b&gt; long.&lt;/p&gt;</description><pubDate>Tue, 10 Nov 2026 22:10:00 GMT</pubDate></item>
        <item><title>Second story</title><link>https://example.com/b</link><description>Short.</description><pubDate>Tue, 10 Nov 2026 20:00:00 +0000</pubDate></item>
        <item><title></title><link>https://example.com/c</link></item>
        </channel></rss>
        """.utf8)
        let items = News.parseFeed(rss, source: "Example")
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items[0].title, "Rover finds & maps an ancient riverbed")
        XCTAssertEqual(items[0].summary, "The rover's cameras traced a channel nine miles long.")
        XCTAssertEqual(items[0].link?.absoluteString, "https://example.com/a")
        XCTAssertEqual(items[0].date, ISO8601DateFormatter().date(from: "2026-11-10T22:10:00Z"))
        XCTAssertEqual(items[1].date, ISO8601DateFormatter().date(from: "2026-11-10T20:00:00Z"))
    }

    func testAtom() {
        let atom = Data("""
        <feed xmlns="http://www.w3.org/2005/Atom"><title>Site</title><link href="https://site.example/"/>
        <entry><title type="html">A &quot;quoted&quot; headline</title><link rel="alternate" href="https://site.example/x"/><link rel="enclosure" href="https://site.example/x.jpg"/>
          <updated>2026-11-10T21:00:00Z</updated><summary type="html">&lt;p&gt;Summary text here.&lt;/p&gt;</summary></entry></feed>
        """.utf8)
        let items = News.parseFeed(atom, source: "Site")
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].title, "A \"quoted\" headline")
        XCTAssertEqual(items[0].link?.absoluteString, "https://site.example/x")
        XCTAssertEqual(items[0].summary, "Summary text here.")
        XCTAssertNotNil(items[0].date)
        XCTAssertTrue(News.parseFeed(Data("not xml".utf8), source: "x").isEmpty)
    }

    func testArticleExtraction() {
        let html = """
        <html><head><style>p{color:red}</style><script>var p = "<p>not this, it is inside a script tag and long enough to count otherwise.</p>";</script></head>
        <body><nav><p>Home News Sport Weather and other menu words that go on for a while here.</p></nav>
        <article><h1>Headline</h1><p class="byline">By A Writer</p>
        <p>The first paragraph of the story says what happened, where, and to whom, in one long sentence.</p>
        <figure><p>A caption that describes the photograph above in more than sixty characters of text.</p></figure>
        <p>The second paragraph adds a quote: &ldquo;It was&nbsp;remarkable,&rdquo; she said, and <a href="/x">a link</a> to more.</p>
        <p>The first paragraph of the story says what happened, where, and to whom, in one long sentence.</p>
        <p>Share</p></article>
        <footer><p>Copyright notice and a long list of links to terms, privacy and cookies pages.</p></footer></body></html>
        """ + String(repeating: " ", count: 10)
        let text = News.articleText(html: html)
        XCTAssertEqual(text.components(separatedBy: "\n\n"), [
            "The first paragraph of the story says what happened, where, and to whom, in one long sentence.",
            "The second paragraph adds a quote: \"It was remarkable,\" she said, and a link to more.",
        ])
        XCTAssertEqual(News.articleText(html: "<div>no paragraphs</div>"), "")
        XCTAssertEqual(News.decodeEntities("a &amp; b &#x2014; c &bogus; d &"), "a & b \u{2014} c &bogus; d &")
    }

    func testCardsAndMerging() {
        let now = ISO8601DateFormatter().date(from: "2026-11-10T23:10:00Z")!
        let a = NewsItem(title: "Rover finds and maps an ancient riverbed on a distant plain", summary: "The rover's cameras traced a channel nine miles long.",
                         link: URL(string: "https://example.com/a"), source: "Example", date: now.addingTimeInterval(-7200))
        let card = News.headlineCard(a, index: 2, count: 12, screen: Screen(size: .small), now: now, glyphs: Glyphs(.symbols))
        XCTAssertEqual(card.lines[0], "◆ Example 2h 3/12")
        XCTAssertEqual(card.lines[1], "Rover finds and maps an ancient riverbed on")
        XCTAssertTrue(card.lines.contains("────────"))
        XCTAssertLessThanOrEqual(card.lines.count, 7)
        XCTAssertEqual(News.headlineCard(a, index: 0, count: 1, screen: Screen(size: .large), now: now).lines[0], "Example 2h")
        XCTAssertEqual(News.age(now.addingTimeInterval(-90), now: now), "1m"); XCTAssertEqual(News.age(nil, now: now), "")
        let article = News.articleCard(a, text: "One.\n\nTwo.", screen: Screen(size: .small))
        XCTAssertEqual(Array(article.lines.suffix(5)), ["One.", "", "Two.", "", "- end -"])
        var b = a; b.source = "Other"; b.date = now
        var c = a; c.title = "Something else"; c.date = now.addingTimeInterval(-60)
        XCTAssertEqual(News.merged([[a], [b, c]]).map(\.title), ["Something else", a.title])       // duplicates dropped, newest first
        XCTAssertGreaterThanOrEqual(NewsSource.builtIn.count, 4)
    }
}

final class MailTests: XCTestCase {
    static func b64(_ s: String) -> String {
        Data(s.utf8).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    func testParsePlainTextMessage() throws {
        let text = "Hi Jarred,\r\n\r\nThe deck is ready. See https://example.com/a/very/long/link/that/goes/on/and/on for the file.\r\n\r\n\r\nThanks\r\n\r\nOn Tue, Nov 10, 2026 at 3:00 PM Someone <s@example.com> wrote:\r\n> old text\r\n"
        let json = """
        {"id":"abc123","labelIds":["INBOX","UNREAD"],"snippet":"Hi Jarred, The deck is ready &amp; waiting","internalDate":"1794350000000",
         "payload":{"mimeType":"multipart/alternative","headers":[{"name":"From","value":"\\"Pat Lee\\" <pat@example.com>"},{"name":"Subject","value":"Deck for Thursday"}],
           "parts":[{"mimeType":"text/plain","body":{"data":"\(Self.b64(text))"}},{"mimeType":"text/html","body":{"data":"\(Self.b64("<p>ignored</p>"))"}}]}}
        """
        let m = try XCTUnwrap(Mail.parseMessage(Data(json.utf8)))
        XCTAssertEqual(m.from, "Pat Lee"); XCTAssertEqual(m.subject, "Deck for Thursday"); XCTAssertTrue(m.unread)
        XCTAssertEqual(m.preview, "Hi Jarred, The deck is ready & waiting")
        XCTAssertEqual(m.body, "Hi Jarred,\n\nThe deck is ready. See [link] for the file.\n\nThanks")      // quoted reply and long link gone
        XCTAssertEqual(m.date, Date(timeIntervalSince1970: 1_794_350_000))
        let card = Mail.listCard(m, index: 0, count: 12, screen: Screen(size: .small), now: Date(timeIntervalSince1970: 1_794_357_200), glyphs: Glyphs(.symbols))
        XCTAssertEqual(Array(card.lines.prefix(3)), ["● Inbox 1/12 2h", "Pat Lee", "Deck for Thursday"])
        let read = Mail.readCard(m, screen: Screen(size: .small))
        XCTAssertEqual(read.lines.first, "From Pat Lee"); XCTAssertEqual(read.lines.last, "- end -")
    }
    func testParseHTMLOnlyMessageAndLists() throws {
        let html = "<html><head><style>x{}</style></head><body><table><tr><td>Your order has shipped</td><td>Track it today</td></tr></table></body></html>"
        let json = "{\"id\":\"z9\",\"snippet\":\"\",\"payload\":{\"mimeType\":\"text/html\",\"headers\":[{\"name\":\"from\",\"value\":\"orders@shop.example\"}],\"body\":{\"data\":\"\(Self.b64(html))\"}}}"
        let m = try XCTUnwrap(Mail.parseMessage(Data(json.utf8)))
        XCTAssertEqual(m.from, "orders@shop.example"); XCTAssertEqual(m.subject, "(no subject)"); XCTAssertFalse(m.unread)
        XCTAssertEqual(m.body, "Your order has shipped Track it today")
        XCTAssertEqual(Mail.parseList(Data("{\"messages\":[{\"id\":\"a\",\"threadId\":\"t\"},{\"id\":\"b\"}],\"resultSizeEstimate\":2}".utf8)), ["a", "b"])
        XCTAssertTrue(Mail.parseList(Data("{\"resultSizeEstimate\":0}".utf8)).isEmpty)
        XCTAssertNil(Mail.parseMessage(Data("{}".utf8)))
        XCTAssertEqual(Mail.sender("<solo@example.com>"), "solo@example.com")
        XCTAssertTrue(Mail.listURL(query: "in:inbox")!.absoluteString.contains("q=in:inbox"))
        XCTAssertEqual(Mail.messageURL("../x?")?.path.hasSuffix("/messages/x"), true)
    }
    func testEventDetailAndMenu() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let item = AgendaItem(title: "Budget review", start: now.addingTimeInterval(1500), end: now.addingTimeInterval(5100), place: "Room 4", notes: "Bring the Q4 numbers.\n\n> quoted")
        let card = Agenda.detailCard(item, index: 1, count: 6, screen: Screen(size: .small), now: now, glyphs: Glyphs(.symbols))
        XCTAssertTrue(card.lines[0].hasPrefix("◆ Event 2/6"))
        XCTAssertEqual(card.lines[1], "Budget review")
        XCTAssertTrue(card.lines[2].hasSuffix("(in 25 min)"))
        XCTAssertEqual(Array(card.lines.suffix(3)), ["At Room 4", "", "Bring the Q4 numbers."])
        let menu = AppMenu.card(titles: (1...10).map { "App \($0)" }, selected: 7, screen: Screen(size: .large), glyphs: Glyphs(.symbols))
        XCTAssertEqual(menu.lines.count, 5)
        XCTAssertTrue(menu.lines.contains("→ App 8"))
        XCTAssertEqual(AppMenu.card(titles: ["A", "B"], selected: 0, screen: Screen(size: .large)).lines[1], "＞ A")
        XCTAssertEqual(AppMenu.endCard(of: "headlines").lines.count, 3)
    }
}

final class ToolsTests: XCTestCase {
    private func tone(_ hz: Double, rate: Double = 44100, count: Int = 4096) -> [Float] {
        var out = [Float]()
        for i in 0..<count {
            let t = Double(i) / rate
            let value: Double = 0.5 * sin(2 * Double.pi * hz * t) + 0.2 * sin(4 * Double.pi * hz * t)
            out.append(Float(value))
        }
        return out
    }
    func testPitch() {
        for hz in [82.41, 110.0, 196.0, 329.63, 440.0, 880.0] {
            let found = Pitch.detect(tone(hz), sampleRate: 44100)
            XCTAssertNotNil(found)
            XCTAssertEqual(found ?? 0, hz, accuracy: hz * 0.01)
        }
        XCTAssertNil(Pitch.detect([Float](repeating: 0, count: 4096), sampleRate: 44100))
        let a = TunerReading(hz: 440)
        XCTAssertEqual(a?.note, "A"); XCTAssertEqual(a?.octave, 4); XCTAssertEqual(a?.cents, 0)
        let e = TunerReading(hz: 82.41)
        XCTAssertEqual(e?.note, "E"); XCTAssertEqual(e?.octave, 2)
        let flat = TunerReading(hz: 435)
        XCTAssertEqual(flat?.note, "A"); XCTAssertEqual(flat?.cents, -20)
        let card = Tuner.card(flat, listening: true, screen: Screen(rows: 7, columns: 28, wideColumns: 14))
        XCTAssertTrue(card.lines[3].hasPrefix("Flat 20"))
        XCTAssertLessThanOrEqual(card.lines[2].count, 28)
    }
    func testMetronome() {
        let bar = Metronome.bar(bpm: 120, beats: 4, sampleRate: 44100)
        XCTAssertEqual(bar.count, 22050 * 4)
        XCTAssertNotEqual(bar[1], 0); XCTAssertEqual(bar[22049], 0, accuracy: 0.001)
        XCTAssertEqual(Metronome.bar(bpm: 999, beats: 1, sampleRate: 44100).count, 11025)
        XCTAssertEqual(Metronome.tempoName(120), "Allegro")
        let screen = Screen(rows: 7, columns: 28, wideColumns: 14)
        XCTAssertEqual(Metronome.card(bpm: 100, beats: 4, running: true, beat: 2, screen: screen).lines, ["100 BPM   3", "○○●○"])
        XCTAssertEqual(Metronome.card(bpm: 100, beats: 4, running: false, beat: 2, screen: screen).lines.first, "Metronome")
    }
    func testPicker() {
        XCTAssertEqual(Picker.options(from: "Pizza, Tacos\n  Sushi \n"), ["Pizza", "Tacos", "Sushi"])
        XCTAssertEqual(Picker.roll(.coin, using: { _ in 1 }).text, "Tails")
        XCTAssertEqual(Picker.roll(.twoD6, using: { _ in 5 }).text, "12")
        XCTAssertEqual(Picker.roll(.list, options: ["a", "b"], using: { _ in 1 }).text, "b")
        XCTAssertEqual(Picker.face(5), ["●\u{3000}●", "\u{3000}●\u{3000}", "●\u{3000}●"])
        XCTAssertTrue(Picker.face(1).allSatisfy { $0.count == 3 })
        let screen = Screen(rows: 7, columns: 28, wideColumns: 14)
        XCTAssertEqual(Picker.card(mode: .twoD6, result: Picker.roll(.twoD6, using: { _ in 0 }), rolling: false, screen: screen).lines.last, "Total 2")
    }
    func testSpeedRead() {
        let words = SpeedRead.words(of: "The quick brown fox. Jumps over\nthe lazy dog")
        XCTAssertEqual(words.count, 9)
        XCTAssertEqual(SpeedRead.chunk(words, at: 0, size: 2, width: 28).text, "The quick")
        XCTAssertEqual(SpeedRead.chunk(words, at: 2, size: 3, width: 28).text, "brown fox.")       // stops at the sentence end
        XCTAssertEqual(SpeedRead.chunk(words, at: 0, size: 3, width: 6).count, 1)
        XCTAssertEqual(SpeedRead.interval(wpm: 200, chunk: 2), 0.6, accuracy: 0.001)
        XCTAssertEqual(SpeedRead.interval(wpm: 400, chunk: 1), 0.3, accuracy: 0.001)
        let screen = Screen(rows: 7, columns: 28, wideColumns: 14)
        let card = SpeedRead.card(words: words, index: 0, size: 2, playing: true, wpm: 200, screen: screen)
        XCTAssertEqual(card.lines.count, 7)
        XCTAssertTrue(card.lines[3].contains("The quick"))
    }
}

