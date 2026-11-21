package com.jarredsmith.glasseshub.core

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

class AppsTest {
    private val screen = Screen.of(TextSize.large)

    @Test fun timerAndTrivia() {
        val timer = HubTimer.minutes(1.0)
        timer.start(100.0)
        assertEquals(30.0, timer.remaining(130.0), 0.001)
        assertEquals("00:30", HubTimer.clock(30.0))
        timer.pause(130.0); assertEquals(30.0, timer.remaining(999.0), 0.001)
        assertTrue(HubTimer.minutes(1.0).also { it.start(0.0) }.isDone(61.0))
        val round = TriviaRound(listOf(TriviaQuestion("Science", "What is H2O?", "Water")), 0.0)
        round.tick(21.0); assertEquals(TriviaRound.Phase.answer, round.phase)
        round.tick(30.0); assertEquals(TriviaRound.Phase.done, round.phase)
        val parsed = Trivia.parse("""{"results":[{"category":"Entertainment%3A%20Film","question":"Who%3F","correct_answer":"Me"}]}""")
        assertEquals(TriviaQuestion("Film", "Who?", "Me"), parsed.single())
    }

    @Test fun scoresAndAlerts() {
        val feed = """{"events":[{"id":"1","date":"2026-11-15T18:00Z","competitions":[{"status":{"period":2,"type":{"state":"in","shortDetail":"4:12 - 2nd"}},
          "competitors":[{"homeAway":"home","score":"14","team":{"id":"12","abbreviation":"KC","shortDisplayName":"Chiefs"},"linescores":[{"value":7},{"value":7}]},
                         {"homeAway":"away","score":"10","team":{"id":"7","abbreviation":"DEN","shortDisplayName":"Broncos"}}],
          "situation":{"downDistanceText":"2nd & 7 at KC 43","possession":"12","isRedZone":false}}]}]}"""
        val game = Scoreboard.parse(feed, League.nfl).single()
        assertEquals(Game.State.live, game.state)
        assertEquals("DEN 10 - KC 14", game.scoreLine)
        assertEquals("KC", game.possession)
        assertEquals(listOf(7, 7), game.home.periods)
        assertNotNull(game.start)
        val before = game.copy(home = game.home.copy(score = 7))
        assertEquals(listOf("TOUCHDOWN KC!", "DEN 10 - KC 14"), Scoreboard.alerts(before, game).single())
        assertTrue(Scoreboard.card(game, screen, 0.0).lines.any { it.contains("2nd & 7") })
        assertEquals(game, Scoreboard.pick(listOf(game), listOf("KC"), 0.0))
        assertEquals("Tyquan Thornton 2-yd pass", Scoreboard.shortPlay("(12:41 - 2nd) Tyquan Thornton 2 Yd pass"))
    }

    @Test fun newsWeatherAndStocks() {
        val rss = """<?xml version="1.0"?><rss><channel><item><title>First &amp; best</title><link>https://x.test/a</link>
            <description><![CDATA[<p>Body <b>text</b></p>]]></description><pubDate>Sat, 21 Nov 2026 12:00:00 GMT</pubDate></item></channel></rss>"""
        val item = News.parseFeed(rss, "Test").single()
        assertEquals("First & best", item.title); assertEquals("Body text", item.summary); assertEquals("https://x.test/a", item.link)
        assertNotNull(item.date)
        assertEquals("5m", News.age(700.0, 1000.0))
        val weather = assertNotNull(Weather.parse("""{"current":{"temperature_2m":71.6,"apparent_temperature":70.1,"weather_code":2,"wind_speed_10m":8.2},
            "daily":{"time":["2026-11-21","2026-11-22"],"weather_code":[2,61],"temperature_2m_max":[75.2,60.0],"temperature_2m_min":[51.0,44.4],"precipitation_probability_max":[10,80]},
            "hourly":{"time":["2026-11-21T13:00","2026-11-21T14:00"],"temperature_2m":[71.0,72.4],"precipitation_probability":[0,5],"weather_code":[2,2]}}""", "Tulsa"))
        assertEquals(72, weather.temperature); assertEquals("Partly cloudy", weather.condition)
        assertEquals("Tomorrow 60/44 Light rain", weather.tomorrow)
        assertEquals(listOf("1p", "2p"), weather.hours.map { it.label })
        assertEquals("44,210", Stocks.money(44210.4)); assertEquals("1,234.50", Stocks.money(1234.5))
        assertEquals(listOf("^GSPC", "AAPL", "TSLA"), Stocks.symbols("s&p 500, aapl tsla"))
        val quote = assertNotNull(Stocks.parse("""{"chart":{"result":[{"meta":{"symbol":"AAPL","regularMarketPrice":200.0,"previousClose":198.0,"currency":"USD"}}]}}"""))
        assertEquals("AAPL 200.00 ↑1.01%", Stocks.line("AAPL", quote, arrows = true))
    }

    @Test fun feedsGamesAndNearby() {
        val glucose = DataFeed(kind = FeedKind.nightscout, address = "example.org/")
        assertEquals("https://example.org/api/v1/entries.json?count=1&token=abc", glucose.request("abc")?.first)
        val reading = assertNotNull(FeedParser.read(glucose, """[{"sgv":112,"direction":"Flat","date":1000000}]""", 1300.0))
        assertEquals("112", reading.value)
        assertEquals("Glucose 112 → 5m ago", FeedParser.line(glucose, reading, now = 1300.0, arrows = true))
        val custom = DataFeed(kind = FeedKind.custom, address = "http://x", item = "data.0.price", unit = "USD")
        assertEquals("12.5 USD", FeedParser.read(custom, """{"data":[{"price":12.5}]}""", 0.0)?.value)
        val word = WordGame("APPLE")
        word.cursor = "A"; word.guess(); assertEquals("A _ _ _ _", word.shown)
        assertEquals(WordGame.daily(5), WordGame.daily(5))
        assertEquals("NE", Geo.compass(44.0))
        assertEquals("350 ft", Geo.length(107.0, metric = false))
        val planes = assertNotNull(Planes.parse("""{"ac":[{"hex":"a1","flight":"UAL12 ","t":"B738","lat":35.5,"lon":-97.5,"alt_baro":31000,"gs":440.2,"track":90},{"hex":"b2","lat":35.4,"lon":-97.6,"alt_baro":"ground"}]}""", 35.47, -97.52))
        assertEquals("UAL12", planes.single().name)
    }

    @Test fun musicFollowsChordsAndDrums() {
        assertEquals(setOf(7, 11, 2), ChordChart.notes("G"))
        assertEquals(listOf(3, 2, 0, 0, 0, 3), ChordChart.shape("G"))
        assertEquals(listOf(6, 8, 8, 7, 6, 6), ChordChart.shape("A#"))
        val steps = ChordChart.parse("[G]Amazing grace, how [C]sweet the [G]sound")
        assertEquals(listOf("G", "C", "G"), steps.map { it.chord })
        assertEquals("Amazing grace, how", steps[0].lyric)
        val rock = DrumPattern.library[1]
        assertEquals(16, rock.steps)
        val trainer = DrumTrainer(rock)
        assertEquals(setOf(Drum.hat, Drum.kick), trainer.expected)
        assertTrue(trainer.hit(setOf(Drum.kick), 0.0))
        assertTrue(!trainer.hit(setOf(Drum.kick), 0.2))
        assertTrue(DrumTrainer.matches(setOf(Drum.tom), setOf(Drum.snare)))
        assertEquals(setOf(Drum.kick), DrumKit.standard.identify(DrumHit(0.0, listOf(8.0, 1.5, 0.2), 3.0)))
        assertNull(Pitch.detect(FloatArray(2048), 44100.0))
        val tone = FloatArray(4096) { (kotlin.math.sin(2 * Math.PI * 440 * it / 44100.0) * 0.5).toFloat() }
        assertEquals(440.0, Pitch.detect(tone, 44100.0)!!, 2.0)
        assertEquals("A", TunerReading.of(440.0)?.note)
    }

    @Test fun movieCaptionsFollowTheDialogue() {
        val file = "1\n00:00:10,000 --> 00:00:12,500\n<i>Where were you last night?</i>\n\n2\n00:00:20,000 --> 00:00:23,000\n[door slams]\nMARTHA: Nobody leaves until we find the ledger.\n\n" +
            "3\n00:01:40,000 --> 00:01:43,000\nI don't know what you mean.\n\n4\n00:05:04,000 --> 00:05:06,000\nSubtitles by www.example.org\n"
        val cues = SubtitleFile.parse(file)
        assertEquals(3, cues.size)
        assertEquals(listOf("nobody", "leaves", "dont", "you", "see"), SubtitleIndex.words("[door slams]\nMARTHA: Nobody leaves, (sighs) don't you see?"))
        val movie = MovieTracker(cues)
        assertNull(movie.position(0.0))
        assertTrue(!movie.hear("some chatter in the room", 1000.0))
        assertTrue(movie.hear("nobody leaves until we find", 1002.0))
        assertEquals(21.9, movie.position(1002.0)!!, 1.0)
        assertEquals(20.0, movie.cue(1002.0)?.start)
        movie.hear("I don't know what you mean", 1300.0)
        assertEquals(102.3, movie.position(1300.0)!!, 1.0)
        movie.toggleHold(1301.0); assertEquals(MovieTracker.State.held, movie.state)
        assertEquals("1:02:05", MovieTracker.clock(3725.0))
        assertEquals("café", SubtitleFile.decode(byteArrayOf(0x63, 0x61, 0x66, 0xE9.toByte())))
    }

    @Test fun menusPagersAndDashboard() {
        val menu = AppMenu.card(titles = listOf("Dashboard", "Info", "Reading", "Music", "Tools", "Nearby"), selected = 4, screen = screen, hint = "Turn: move")
        assertEquals(5, menu.lines.size); assertTrue(menu.lines.any { it.endsWith("Tools") && it.startsWith("＞") })
        val pager = AutoPager()
        val long = Card((1..9).map { "line $it" })
        assertEquals("(1/3)", pager.page(long, 5, 0.0, 8.0, true).lines.last())
        assertEquals("(2/3)", pager.page(long, 5, 9.0, 8.0, true).lines.last())
        val dash = Dashboard.card(0.0, listOf("a", "", "b"), screen)
        assertEquals(listOf("a", "b"), dash.lines.takeLast(2))
        val queue = OverlayQueue()
        queue.push(Card(listOf("first")), 10.0); queue.push(Card(listOf(" ")))
        assertEquals(listOf("first"), queue.current(100.0)?.lines); assertNull(queue.current(111.0))
        assertEquals("[●　●]", "[" + Picker.face(4)[0] + "]")
        assertEquals(3, SpeedRead.size(600, 1))
        val live = LiveText(); live.show("one", false); live.show("two", true)
        assertEquals(listOf("one", "two"), live.card(screen).lines)
        assertTrue(Agenda.monthCard(1795300000.0, screen).lines.size <= 5)
    }
}
