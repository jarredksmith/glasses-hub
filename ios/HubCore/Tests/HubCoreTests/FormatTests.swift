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
        XCTAssertEqual(card.lines[1], "Rover finds and maps an ancient riverbed")
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
        let large = Screen(size: .large)
        let hinted = AppMenu.card(titles: (1...10).map { "App \($0)" }, selected: 7, screen: large, hint: "Look up: open")
        XCTAssertEqual(hinted.lines.count, large.rows)
        XCTAssertEqual(hinted.lines.last, "Look up: open")
        XCTAssertTrue(hinted.lines.contains { $0.hasSuffix("App 8") })
        XCTAssertEqual(AppMenu.hint(select: "Look up", columns: 40), "Turn: move, Look up: open")
        XCTAssertEqual(AppMenu.hint(select: "Look up", columns: 16), "Look up: open")
        XCTAssertNil(AppMenu.hint(select: nil, columns: 40))
        XCTAssertEqual(AppMenu.practiceCard(done: [true, false, false, false]).lines[1], "[x] Turn crown forward")
        XCTAssertEqual(AppMenu.practiceCard(done: [true, true, true, true]).lines.count, 3)
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

final class LiveTextTests: XCTestCase {
    func testLiveText() {
        var live = LiveText()
        let screen = Screen(rows: 3, columns: 30, wideColumns: 15)
        XCTAssertEqual(live.card(screen: screen).lines.first, "Live text")
        live.show("A: xin chào", append: false)
        live.show("B: 你好", append: true)
        XCTAssertEqual(live.card(screen: screen).lines, ["A: xin chào", "B: 你好"])
        live.show("zero", append: false)
        for word in ["one", "two", "three", "four"] { live.show(word, append: true) }
        XCTAssertEqual(live.card(screen: screen).lines, ["two", "three", "four"])                  // a stream: newest at the bottom
        live.show("Ask: who owns it\nline two\nline three\nline four", append: false)
        XCTAssertEqual(live.card(screen: screen).lines, ["Ask: who owns it", "line two", "(1/2)"])   // a note: starts at the top
        XCTAssertEqual(live.card(screen: screen, page: 1).lines, ["line three", "line four", "(2/2)"])
        XCTAssertEqual(live.pageCount(screen: screen), 2)
        live.clear()
        XCTAssertEqual(live.text, "")
        XCTAssertLessThan(TextLayout.measure("Tiếng Việt"), TextLayout.measure("你好你好你好"))
    }
    func testLocalRequests() {
        let get = LocalRequest.parse(Data("GET /show?text=Hello%20there&append=1 HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n".utf8))
        XCTAssertEqual(get?.path, "/show")
        XCTAssertEqual(get?.textAndAppend.text, "Hello there")
        XCTAssertEqual(get?.textAndAppend.append, true)
        let json = #"{"text":"Xin chào","append":false}"#
        let post = "POST /show HTTP/1.1\r\nContent-Type: application/json\r\nContent-Length: \(json.utf8.count)\r\n\r\n" + json
        XCTAssertEqual(LocalRequest.parse(Data(post.utf8))?.textAndAppend.text, "Xin chào")
        XCTAssertNil(LocalRequest.parse(Data(post.utf8).dropLast(4)))                             // body not all here yet
        let plain = "POST /show HTTP/1.1\r\nContent-Type: text/plain\r\nContent-Length: 5\r\n\r\nhello"
        XCTAssertEqual(LocalRequest.parse(Data(plain.utf8))?.textAndAppend.text, "hello")
        XCTAssertEqual(LocalRequest.fields("a=1&b=two+words")["b"], "two words")
        let reply = String(data: LocalRequest.response(json: ["ok": true]), encoding: .utf8) ?? ""
        XCTAssertTrue(reply.hasPrefix("HTTP/1.1 200 OK"))
        XCTAssertTrue(reply.hasSuffix(#"{"ok":true}"#))
    }

    func testCloudCaption() {
        var caption = CloudCaption()
        let first = #"{"tokens":[{"text":"Hola","is_final":true,"translation_status":"original","language":"es"},{"text":"Hello","is_final":true,"translation_status":"translation","language":"en"},{"text":" every","is_final":false,"translation_status":"translation"}],"final_audio_proc_ms":100,"total_audio_proc_ms":300}"#
        XCTAssertEqual(caption.take(Data(first.utf8)), .updated)
        XCTAssertEqual(caption.text, "Hello every")
        let second = #"{"tokens":[{"text":" everyone","is_final":true,"translation_status":"translation"},{"text":"<end>","is_final":true},{"text":" how","is_final":false,"translation_status":"translation"}]}"#
        XCTAssertEqual(caption.take(Data(second.utf8)), .updated)
        XCTAssertEqual(caption.text, "Hello everyone how")                                   // tentative words are replaced, not added
        XCTAssertEqual(caption.take(Data(#"{"tokens":[],"finished":true}"#.utf8)), .finished)
        XCTAssertEqual(caption.take(Data(#"{"tokens":[],"error_code":401,"error_message":"Invalid API key"}"#.utf8)), .failed("Invalid API key"))
        var labelled = CloudCaption(labelSpeakers: true)
        _ = labelled.take(Data(#"{"tokens":[{"text":"Hi","is_final":true,"speaker":"1","translation_status":"translation"},{"text":" there","is_final":true,"speaker":"1","translation_status":"translation"},{"text":" Yes","is_final":true,"speaker":"2","translation_status":"translation"}]}"#.utf8))
        XCTAssertEqual(labelled.text, "S1: Hi there\nS2: Yes")
        XCTAssertEqual(labelled.lines(screen: Screen(rows: 1, columns: 30, wideColumns: 15)), ["S2: Yes"])
    }
}

final class DataFeedTests: XCTestCase {
    func testNightscout() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var feed = DataFeed(kind: .nightscout, address: "my.site.example/")
        let request = feed.request(token: "abc-123")
        XCTAssertEqual(request?.url.absoluteString, "https://my.site.example/api/v1/entries.json?count=1&token=abc%2D123")
        let stamp = Int((now.timeIntervalSince1970 - 240) * 1000)
        let body = Data(#"[{"sgv":112,"direction":"Flat","date":\#(stamp)}]"#.utf8)
        let reading = FeedParser.read(feed, data: body, now: now)
        XCTAssertEqual(reading?.value, "112")
        XCTAssertEqual(FeedParser.line(feed, reading: reading, now: now, arrows: true), "Glucose 112 → 4m ago")
        XCTAssertEqual(FeedParser.line(feed, reading: reading, now: now, arrows: false), "Glucose 112 steady (4m ago)")
        feed.unit = "mmol"
        XCTAssertEqual(FeedParser.read(feed, data: body, now: now)?.value, "6.2")
        XCTAssertNil(FeedParser.read(feed, data: Data("[]".utf8), now: now))
        XCTAssertEqual(FeedParser.line(feed, reading: nil, note: "No answer", now: now, arrows: true), "Glucose: No answer")
    }
    func testSpeedReadSize() {
        XCTAssertEqual(SpeedRead.size(wpm: 200, chunk: 2), 2)
        XCTAssertEqual(SpeedRead.size(wpm: 600, chunk: 1), 3)
        XCTAssertEqual(SpeedRead.size(wpm: 900, chunk: 2), 5)
        XCTAssertEqual(SpeedRead.interval(wpm: 900, chunk: 5), 60.0 * 5 / 900, accuracy: 0.001)
    }
    func testHomeAssistantAndCustom() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let home = DataFeed(name: "Porch", kind: .homeAssistant, address: "http://homeassistant.local:8123", item: "sensor.porch_temp")
        XCTAssertNil(home.request(token: ""))
        XCTAssertEqual(home.request(token: "t")?.url.absoluteString, "http://homeassistant.local:8123/api/states/sensor.porch_temp")
        XCTAssertEqual(home.request(token: "t")?.headers["Authorization"], "Bearer t")
        let state = Data(#"{"state":"71.4","attributes":{"unit_of_measurement":"°F"}}"#.utf8)
        XCTAssertEqual(FeedParser.read(home, data: state, now: now)?.value, "71.4 °F")
        XCTAssertEqual(FeedParser.line(home, reading: FeedParser.read(home, data: state, now: now), now: now, arrows: true), "Porch 71.4 °F")

        var custom = DataFeed(name: "BTC", kind: .custom, address: "https://example.com/p", item: "data.0.price", unit: "USD")
        let json = Data(#"{"data":[{"price":64250.5}]}"#.utf8)
        XCTAssertEqual(FeedParser.read(custom, data: json, now: now)?.value, "64250.5 USD")
        custom.item = ""; custom.unit = ""
        XCTAssertEqual(FeedParser.read(custom, data: Data("\n  All systems go \nmore".utf8), now: now)?.value, "All systems go")
        XCTAssertEqual(FeedParser.read(custom, data: Data("42".utf8), now: now)?.value, "42")
        custom.item = "missing.field"
        XCTAssertNil(FeedParser.read(custom, data: json, now: now))

        let old = FeedReading(value: "5", fetched: now.addingTimeInterval(-3600))
        XCTAssertEqual(FeedParser.age(old, feed: custom, now: now), "60m ago")
        let card = FeedParser.card([home, custom], readings: [home.id: FeedReading(value: "71 °F", fetched: now)], notes: [:], now: now, screen: Screen(size: .large), arrows: true, turn: 0)
        XCTAssertEqual(card.lines, ["Data feeds", "Porch 71 °F", "BTC: waiting"])
    }
}

struct StepGenerator: RandomNumberGenerator {
    var values: [UInt64]; var at = 0
    mutating func next() -> UInt64 { defer { at += 1 }; return values[at % values.count] }
}

final class GamesTests: XCTestCase {
    func testWordGame() {
        XCTAssertGreaterThan(WordGame.words.count, 200)
        XCTAssertEqual(Set(WordGame.words).count, WordGame.words.count)
        XCTAssertTrue(WordGame.words.allSatisfy { $0.count >= 4 && $0.count <= 8 && $0.allSatisfy { $0.isLetter && $0.isUppercase } })
        XCTAssertEqual(WordGame.daily(day: 20000), WordGame.daily(day: 20000))
        XCTAssertNotEqual(WordGame.daily(day: 20000), WordGame.daily(day: 20001))
        var game = WordGame(word: "apple", day: 1)
        XCTAssertEqual(game.shown, "_ _ _ _ _")
        game.guess()                                   // E
        XCTAssertEqual(game.shown, "_ _ _ _ E")
        XCTAssertEqual(game.cursor, "F")
        game.move(-1)                                  // E is used, so back lands on D
        XCTAssertEqual(game.cursor, "D")
        game.guess()
        XCTAssertEqual(game.misses, 1)
        for letter in ["A", "P", "L"] { game.cursor = letter; game.guess() }
        XCTAssertTrue(game.solved)
        XCTAssertEqual(game.card(streak: 3, screen: Screen(size: .large)).lines[2], "Got it with 1 miss. Streak 3.")
        var losing = WordGame(word: "APPLE")
        for letter in ["Z", "X", "Q", "J", "K", "V"] { losing.cursor = letter; losing.guess() }
        XCTAssertTrue(losing.lost)
        XCTAssertEqual(losing.card(streak: 0, screen: Screen(size: .large)).lines[1], "It was APPLE")
        let playing = WordGame(word: "APPLE").card(streak: 0, screen: Screen(size: .large))
        XCTAssertEqual(playing.lines[2], "D  [ E ]  F")
        XCTAssertLessThanOrEqual(playing.lines.count, Screen(size: .large).rows)
    }
    func testBlackjack() {
        XCTAssertEqual(Blackjack.total([1, 13]).value, 21)
        XCTAssertTrue(Blackjack.total([1, 6]).soft)
        XCTAssertEqual(Blackjack.total([1, 6, 10]).value, 17)
        XCTAssertEqual(Blackjack.total([1, 1, 9]).value, 21)
        var game = Blackjack()
        game.player = [10, 9]; game.dealer = [10, 7]; game.playing = true
        var rng = SystemRandomNumberGenerator()
        game.stand(using: &rng)
        XCTAssertEqual(game.chips, 110)
        XCTAssertEqual(game.result, "You win. +10")
        game.player = [10, 6]; game.dealer = [10, 10]; game.playing = true; game.stake = 10
        game.stand(using: &rng)
        XCTAssertEqual(game.chips, 100)
        game.player = [5, 6]; game.dealer = [10, 10]; game.playing = true
        XCTAssertTrue(game.canDouble)
        game.double(using: &rng)
        XCTAssertFalse(game.playing)
        XCTAssertEqual(game.stake, 20)
        XCTAssertTrue(game.chips == 120 || game.chips == 80 || game.chips == 100)
        for _ in 0..<300 {
            game.deal(using: &rng)
            while game.playing { if Blackjack.total(game.player).value < 15 { game.hit(using: &rng) } else { game.stand(using: &rng) } }
            XCTAssertFalse(game.result.isEmpty)
            XCTAssertLessThanOrEqual(game.card(screen: Screen(size: .large)).lines.count, 5)
        }
    }
    func testTwentyQuestions() {
        var game = TwentyQuestions()
        game.start()
        XCTAssertEqual(game.messages().count, 1)
        game.take(reply: "Is it alive?\n")
        XCTAssertEqual(game.phase, .asking)
        XCTAssertTrue(game.answer(.no))
        XCTAssertEqual(game.messages().map { $0["role"] ?? "" }, ["user", "assistant", "user"])
        game.take(reply: "GUESS: a bicycle.")
        XCTAssertEqual(game.phase, .guessing)
        XCTAssertEqual(game.card(screen: Screen(size: .large)).lines[1], "Is it a bicycle?")
        XCTAssertFalse(game.answer(.yes))
        XCTAssertEqual(game.phase, .aiWon)
        var long = TwentyQuestions(); long.start()
        for turn in 1...20 {
            long.take(reply: "Question \(turn)?")
            let more = long.answer(.unsure)
            XCTAssertEqual(more, turn < 20)
            if turn == 19 { XCTAssertTrue(long.messages().last?["content"]?.contains("last turn") ?? false) }
        }
        XCTAssertEqual(long.phase, .playerWon)
    }
}

final class NearbyTests: XCTestCase {
    func testGeo() {
        XCTAssertEqual(Geo.distance(35.0, -97.0, 35.0, -97.0), 0, accuracy: 0.001)
        XCTAssertEqual(Geo.distance(35.0, -97.0, 36.0, -97.0), 111_195, accuracy: 300)
        XCTAssertEqual(Geo.compass(Geo.bearing(35, -97, 36, -97)), "N")
        XCTAssertEqual(Geo.compass(Geo.bearing(35, -97, 35, -96)), "E")
        XCTAssertEqual(Geo.compass(Geo.bearing(35, -97, 34, -98)), "SW")
        XCTAssertEqual(Geo.length(100, metric: false), "350 ft")
        XCTAssertEqual(Geo.length(3218.7, metric: false), "2.0 mi")
        XCTAssertEqual(Geo.length(404, metric: true), "400 m")
    }
    func testPlanes() {
        let body = Data(#"{"ac":[{"hex":"a1","flight":"UAL123  ","t":"B738","r":"N12345","alt_baro":34025,"gs":451.3,"track":92.0,"baro_rate":0,"lat":35.10,"lon":-97.0},{"hex":"b2","flight":"N5GA","alt_baro":"ground","lat":35.0,"lon":-97.0},{"hex":"c3","r":"N77","alt_baro":2500,"gs":110,"track":270,"baro_rate":-640,"lat":35.01,"lon":-97.0}],"total":3}"#.utf8)
        let planes = Planes.parse(body, latitude: 35.0, longitude: -97.0) ?? []
        XCTAssertEqual(planes.map(\.name), ["N77", "UAL123"])
        XCTAssertNil(Planes.parse(Data("oops".utf8), latitude: 0, longitude: 0))
        let route = Planes.route(Data(#"{"response":{"flightroute":{"callsign":"UAL123","airline":{"name":"United Airlines"},"origin":{"iata_code":"DEN","municipality":"Denver"},"destination":{"iata_code":"ORD","municipality":"Chicago"}}}}"#.utf8))
        XCTAssertEqual(route, PlaneRoute(from: "Denver", to: "Chicago", airline: "United Airlines"))
        XCTAssertNil(Planes.route(Data(#"{"response":"unknown callsign"}"#.utf8)))
        let screen = Screen(size: .large)
        let card = Planes.card(planes, index: 1, routes: ["UAL123": route!], note: "", metric: false, arrows: true, screen: screen)
        XCTAssertEqual(card.lines, ["UAL123 B738 2/2", "Denver → Chicago", "United Airlines", "34000 ft 519 mph", "6.9 mi N, heading E"])
        XCTAssertEqual(Planes.card(planes, index: 0, routes: [:], note: "", metric: false, arrows: false, screen: screen).lines[1], "2500 ft 127 mph descending")
        XCTAssertEqual(Planes.url(latitude: 35.46756, longitude: -97.51643)?.absoluteString, "https://api.adsb.lol/v2/lat/35.4676/lon/-97.5164/dist/15")
        XCTAssertEqual(Planes.routeURL(callsign: "UAL 123")?.absoluteString, "https://api.adsbdb.com/v0/callsign/UAL123")
    }
    func testTour() {
        let body = Data(#"{"batchcomplete":"","query":{"pages":{"11":{"pageid":11,"title":"Far Museum","extract":"A museum.\nIt is far.","coordinates":[{"lat":35.01,"lon":-97.0}]},"7":{"pageid":7,"title":"Near Fountain","extract":"A fountain.","coordinates":[{"lat":35.001,"lon":-97.0}]},"9":{"pageid":9,"title":"No place"}}}}"#.utf8)
        let places = Tour.parse(body, latitude: 35.0, longitude: -97.0) ?? []
        XCTAssertEqual(places.map(\.title), ["Near Fountain", "Far Museum"])
        XCTAssertEqual(places[1].summary, "A museum. It is far.")
        XCTAssertEqual(Tour.parse(Data(#"{"batchcomplete":""}"#.utf8), latitude: 0, longitude: 0), [])
        XCTAssertNil(Tour.parse(Data("x".utf8), latitude: 0, longitude: 0))
        XCTAssertEqual(Tour.moved(places, latitude: 35.011, longitude: -97.0).first?.title, "Far Museum")
        let card = Tour.listCard(places, index: 0, note: "", metric: false, screen: Screen(size: .large))
        XCTAssertEqual(card.lines, ["Nearby  1/2", "Near Fountain", "350 ft N", "Look up: read"])
        let url = Tour.url(latitude: 35.0, longitude: -97.0)?.absoluteString ?? ""
        XCTAssertTrue(url.contains("generator=geosearch") && url.contains("ggscoord=35.00000%7C-97.00000"))
    }
}

final class MusicTests: XCTestCase {
    /// A strummed chord: each note with a few overtones, like a string.
    func strum(_ midi: [Int], rate: Double = 44_100, count: Int = 8192) -> [Float] {
        var out = [Float](repeating: 0, count: count)
        for note in midi {
            let f = 440 * pow(2, Double(note - 69) / 12)
            for i in 0..<count {
                let w: Double = 2 * Double.pi * f * Double(i) / rate
                let one: Double = sin(w), two: Double = 0.5 * sin(2 * w), three: Double = 0.25 * sin(3 * w)
                out[i] += Float(0.1 * (one + two + three))
            }
        }
        return out
    }
    func testChordNamesAndCharts() {
        XCTAssertEqual(ChordChart.notes(of: "G"), [7, 11, 2])
        XCTAssertEqual(ChordChart.notes(of: "Em"), [4, 7, 11])
        XCTAssertEqual(ChordChart.notes(of: "F#m7"), [6, 9, 1, 4])
        XCTAssertEqual(ChordChart.notes(of: "Bb"), [10, 2, 5])
        XCTAssertEqual(ChordChart.notes(of: "D/F#"), ChordChart.notes(of: "D"))
        XCTAssertNil(ChordChart.notes(of: "Hello"))
        XCTAssertNil(ChordChart.notes(of: "Am I"))
        let steps = ChordChart.parse("[G]Amazing grace, how [C]sweet the [G]sound\nThat saved a wretch like [D]me")
        XCTAssertEqual(steps.map(\.chord), ["G", "C", "G", "D"])
        XCTAssertEqual(steps[2].lyric, "sound / That saved a wretch like")
        let over = ChordChart.parse("G      C\nAmazing grace\nD\nme")
        XCTAssertEqual(over.map(\.chord), ["G", "C", "D"])
        XCTAssertEqual(over[0].lyric, "Amazing grace")
        for song in ChordChart.songs {
            let parsed = ChordChart.parse(song.chart)
            XCTAssertGreaterThan(parsed.count, 5, song.title)
            XCTAssertTrue(parsed.allSatisfy { ChordChart.notes(of: $0.chord) != nil })
        }
    }
    func testFollowingChords() {
        let g = strum([43, 47, 50, 55, 59, 67]), c = strum([48, 52, 55, 60, 64]), d = strum([50, 57, 62, 66]), em = strum([40, 47, 52, 55, 59, 64])
        let heardG = Chroma.compute(g, sampleRate: 44_100)
        XCTAssertGreaterThan(Chroma.score(heardG.chroma, notes: ChordChart.notes(of: "G")!), Chroma.score(heardG.chroma, notes: ChordChart.notes(of: "C")!) + 0.2)
        XCTAssertGreaterThan(heardG.level, 0.05)
        var follower = ChordFollower(steps: ChordChart.parse("[G]one [C]two [D]three [Em]four [G]five"))
        func play(_ sound: [Float], times: Int = 3) -> Int {
            var moves = 0
            for _ in 0..<times { let h = Chroma.compute(sound, sampleRate: 44_100); if follower.hear(chroma: h.chroma, level: h.level) { moves += 1 } }
            return moves
        }
        XCTAssertEqual(play(g), 0)                      // still on the first chord
        XCTAssertEqual(play(c), 1)
        XCTAssertEqual(follower.index, 1)
        XCTAssertEqual(play(c), 0)                      // holding C doesn't run ahead
        XCTAssertEqual(play(d), 1)
        XCTAssertEqual(play(em), 1)
        XCTAssertEqual(play(g), 1)
        XCTAssertTrue(follower.finished)
        XCTAssertEqual(play([Float](repeating: 0, count: 8192)), 0)
        let card = ChordFollower(steps: ChordChart.parse(ChordChart.songs[0].chart)).card(title: "x", listening: true, screen: Screen(size: .large))
        XCTAssertEqual(card.lines[0], "Ｇ\u{3000}３２０００３")
        XCTAssertEqual(card.lines[1], "then C x32010")
        XCTAssertLessThanOrEqual(card.lines.count, 5)
        let grace = ChordFollower(steps: ChordChart.parse(ChordChart.songs[0].chart))
        XCTAssertTrue(grace.card(title: "x", listening: true, style: .name, screen: Screen(size: .large)).lines[0].hasSuffix("then C"))
        let tab = grace.card(title: "x", listening: true, style: .tab, screen: Screen(size: .small)).lines
        XCTAssertEqual(tab.count, 7)
        XCTAssertEqual(tab[1], "ｅ｜３－－０")
        XCTAssertEqual(tab[5], "Ａ｜２－－３")
        XCTAssertEqual(tab[6], "Ｅ｜３－－ｘ")
        XCTAssertLessThanOrEqual(grace.card(title: "x", listening: true, style: .tab, screen: Screen(size: .large)).lines.count, 5)   // no room: falls back
    }
    func testChordShapes() {
        XCTAssertEqual(ChordChart.shape(of: "G"), [3, 2, 0, 0, 0, 3])
        XCTAssertEqual(ChordChart.shape(of: "C/G"), [-1, 3, 2, 0, 1, 0])
        XCTAssertEqual(ChordChart.shape(of: "Amin"), [-1, 0, 2, 2, 1, 0])
        XCTAssertEqual(ChordChart.shape(of: "G#"), [4, 6, 6, 5, 4, 4])            // E shape at the fourth fret
        XCTAssertEqual(ChordChart.shape(of: "C#"), [-1, 4, 6, 6, 6, 4])           // A shape: the E shape would sit at the ninth
        XCTAssertEqual(ChordChart.shape(of: "Bbm"), [6, 8, 8, 6, 6, 6])
        XCTAssertNil(ChordChart.shape(of: "Cdim7"))
        XCTAssertEqual(ChordChart.frets("x(10)(12)(12)(11)(10)"), [-1, 10, 12, 12, 11, 10])
        XCTAssertNil(ChordChart.frets("3200"))
        let own = ChordChart.parse("[G:3x0003]Amazing [Cdim7:x3424x]grace [D]now")
        XCTAssertEqual(own.map(\.chord), ["G", "Cdim7", "D"])
        XCTAssertEqual(own[0].frets, [3, -1, 0, 0, 0, 3])
        XCTAssertEqual(own[1].frets, [-1, 3, 4, 2, 4, -1])
        XCTAssertEqual(own[2].frets, [-1, -1, 0, 2, 3, 2])
        // every shape plays only notes that belong to its chord
        let open = [4, 9, 2, 7, 11, 4]
        for name in ["C", "D", "E", "F", "G", "A", "B", "Am", "Dm", "Em", "Bm", "A7", "B7", "D7", "E7", "G7", "Cmaj7", "Fmaj7", "F#m", "Bb", "Eb", "G#", "C#", "Bbm", "F#7", "Cm7"] {
            guard let frets = ChordChart.shape(of: name), let notes = ChordChart.notes(of: name) else { XCTFail(name); continue }
            let played = Set(frets.enumerated().compactMap { $0.element < 0 ? nil : (open[$0.offset] + $0.element) % 12 })
            XCTAssertTrue(played.isSubset(of: notes), "\(name) \(frets)")
            XCTAssertTrue(played.contains(notes.first { $0 == played.first } ?? -1))
        }
    }
    func testDrumPatterns() {
        XCTAssertEqual(DrumPattern.library.count, 8)
        for pattern in DrumPattern.library {
            XCTAssertFalse(pattern.bars.isEmpty, pattern.name)
            XCTAssertTrue(pattern.bars.allSatisfy { $0.count == pattern.steps })
            for size in [TextSize.large, .small] {
                let screen = Screen(size: size)
                let card = DrumTrainer(pattern: pattern).card(listening: true, arrows: true, screen: screen)
                XCTAssertLessThanOrEqual(card.lines.count, screen.rows, pattern.name)
                XCTAssertTrue(card.lines.dropFirst().allSatisfy { Grid.cells($0) <= screen.wideColumns }, pattern.name)
            }
        }
        let rock = DrumPattern.library[1]
        XCTAssertEqual(rock.bars[0][0], [.hat, .kick])
        XCTAssertEqual(rock.bars[0][4], [.hat, .snare])
        XCTAssertNil(DrumPattern.parse(name: "x", "nothing here"))
        var trainer = DrumTrainer(pattern: rock)
        XCTAssertFalse(trainer.hit([.snare], at: 0))                // the bar starts on a kick
        XCTAssertEqual(trainer.wrong, 1)
        // one bar at 120 bpm: eighth notes a quarter of a second apart
        let bar: [Set<Drum>] = [[.kick, .hat], [.hat], [.snare], [], [.kick], [.hat], [.snare, .hat], [.hat]]
        for (i, heard) in bar.enumerated() { XCTAssertTrue(trainer.hit(heard, at: 1 + Double(i) * 0.25), "hit \(i)") }
        XCTAssertEqual(trainer.laps, 1)
        XCTAssertEqual(trainer.tempo, 120)
        XCTAssertEqual(trainer.step, 0)
        XCTAssertTrue(DrumTrainer.matches(heard: [.snare], expected: [.tom]))
        XCTAssertFalse(DrumTrainer.matches(heard: [.kick], expected: [.hat]))
        let lines = DrumTrainer(pattern: rock).card(listening: true, arrows: true, screen: Screen(size: .large)).lines
        XCTAssertEqual(lines[1], "ＨＨｘ－ｘ－ｘ－ｘ－ｘ－ｘ－ｘ－ｘ－")
        XCTAssertEqual(lines[4], "\u{3000}\u{3000}▲")
    }
    func testHearingDrums() {
        let rate = 44_100.0
        var seed: UInt64 = 42
        func noise() -> Double {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            let part = Int((seed >> 33) % 2000)
            return Double(part) / 1000 - 1
        }
        func silence(_ seconds: Double) -> [Float] { [Float](repeating: 0, count: Int(seconds * rate)) }
        func kick() -> [Float] {
            (0..<Int(0.15 * rate)).map { i in
                let t: Double = Double(i) / rate
                let tone: Double = sin(2 * Double.pi * 60 * t), fade: Double = exp(-t * 25)
                return Float(0.8 * tone * fade)
            }
        }
        func hat() -> [Float] {
            var last = 0.0, last2 = 0.0
            return (0..<Int(0.05 * rate)).map { i in
                let t: Double = Double(i) / rate, n: Double = noise()
                let high: Double = n - 2 * last + last2          // noise with the lows taken out
                last2 = last; last = n
                let fade: Double = exp(-t * 90)
                return Float(0.08 * high * fade)
            }
        }
        func snare() -> [Float] {
            var smooth = 0.0
            return (0..<Int(0.12 * rate)).map { i in
                let t: Double = Double(i) / rate
                let n: Double = noise(); smooth += 0.35 * (n - smooth)
                let tone: Double = 0.35 * sin(2 * Double.pi * 400 * t), fade: Double = exp(-t * 35)
                return Float((tone + 0.3 * smooth + 0.05 * n) * fade)
            }
        }
        func mixed(_ a: [Float], _ b: [Float]) -> [Float] {
            var out = [Float](repeating: 0, count: max(a.count, b.count))
            for i in a.indices { out[i] += a[i] }
            for i in b.indices { out[i] += b[i] }
            return out
        }
        func hear(_ sound: [Float]) -> [DrumHit] {
            var ear = DrumEar(sampleRate: rate)
            let audio = silence(0.3) + sound + silence(0.3)
            var hits = [DrumHit]()
            var at = 0
            while at < audio.count { let end = min(audio.count, at + 4096); hits += ear.process(Array(audio[at..<end])); at = end }
            return hits
        }
        let kit = DrumKit.standard
        let k = hear(kick()), s = hear(snare()), h = hear(hat())
        XCTAssertEqual(k.count, 1); XCTAssertEqual(s.count, 1); XCTAssertEqual(h.count, 1)
        XCTAssertEqual(k.first.map(kit.identify), [.kick])
        XCTAssertEqual(s.first.map(kit.identify), [.snare])
        XCTAssertEqual(h.first.map(kit.identify), [.hat])
        XCTAssertEqual(k.first?.time ?? 0, 0.3, accuracy: 0.03)
        // a kit learned from these sounds tells pairs apart too
        var learned = DrumKit(voices: [:])
        learned.calibrated = true
        learned.voices[.kick] = DrumKit.learn(k); learned.voices[.snare] = DrumKit.learn(s); learned.voices[.hat] = DrumKit.learn(h)
        XCTAssertEqual(hear(mixed(kick(), hat())).first.map(learned.identify), [.kick, .hat])
        XCTAssertEqual(hear(mixed(kick(), snare())).first.map(learned.identify), [.kick, .snare])
        XCTAssertEqual(hear(hat()).first.map(learned.identify), [.hat])
        // a groove: hits a quarter second apart are each heard, including a hat right after a kick
        let groove = hear(kick() + silence(0.1) + hat() + silence(0.2) + snare() + silence(0.13) + hat())
        XCTAssertEqual(groove.map(learned.identify), [[.kick], [.hat], [.snare], [.hat]])
    }
}
