package com.jarredsmith.glasseshub.core

import java.time.Instant
import java.time.OffsetDateTime
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.util.Locale
import java.util.UUID
import kotlin.math.abs
import kotlin.math.max
import kotlin.math.min

enum class League {
    nfl, ncaaf, nba, wnba, ncaam, mlb, nhl, mls, epl;
    enum class Sport { football, basketball, baseball, hockey, soccer }

    val title: String get() = when (this) {
        nfl -> "NFL"; nba -> "NBA"; mlb -> "MLB"; nhl -> "NHL"
        ncaaf -> "College football"; ncaam -> "College basketball"
        wnba -> "WNBA"; mls -> "MLS"; epl -> "Premier League"
    }
    val short: String get() = when (this) { ncaaf -> "CFB"; ncaam -> "CBB"; else -> name.uppercase() }
    val sport: Sport get() = when (this) {
        nfl, ncaaf -> Sport.football
        nba, wnba, ncaam -> Sport.basketball
        mlb -> Sport.baseball
        nhl -> Sport.hockey
        mls, epl -> Sport.soccer
    }
    private val path: String get() = when (this) {
        nfl -> "football/nfl"; ncaaf -> "football/college-football"
        nba -> "basketball/nba"; wnba -> "basketball/wnba"
        ncaam -> "basketball/mens-college-basketball"
        mlb -> "baseball/mlb"; nhl -> "hockey/nhl"
        mls -> "soccer/usa.1"; epl -> "soccer/eng.1"
    }
    /** ESPN's public scoreboard feed. */
    val feed: String get() = "https://site.api.espn.com/apis/site/v2/sports/$path/scoreboard"
    /** A team's page in the same feed, which names its next game even when it isn't on today's board. */
    fun teamFeed(abbreviation: String): String? {
        val safe = abbreviation.lowercase().filter { it.isLetterOrDigit() }
        return if (safe.isEmpty()) null else "https://site.api.espn.com/apis/site/v2/sports/$path/teams/$safe"
    }
}

data class Game(
    val id: String, val league: League, val away: Side, val home: Side, val state: State,
    /** ESPN's short status, like "4:12 - 3rd", "Final/OT" or "11/15 - 12:00 PM EST". */
    val detail: String,
    val start: Double? = null,
    var period: Int = 0,
    /** "2nd & 7 at KC 43" */
    var situation: String? = null,
    var lastPlay: String? = null,
    /** Abbreviation of the team with the ball, when the feed says. */
    var possession: String? = null,
    var redZone: Boolean = false,
    var network: String? = null,
) {
    enum class State { scheduled, live, final }
    data class Side(val abbr: String, val name: String, var score: Int? = null, val record: String? = null,
                    /** Points in each period so far. */
                    var periods: List<Int> = emptyList(), var timeouts: Int? = null)

    fun has(team: String) = away.abbr == team || home.abbr == team
    val scoreLine: String get() = "${away.abbr} ${away.score ?: "-"} - ${home.abbr} ${home.score ?: "-"}"
    val title: String get() = "${away.abbr} at ${home.abbr}"
    /** The lead, in points; positive when the home side is ahead. */
    val margin: Int get() = (home.score ?: 0) - (away.score ?: 0)

    /** A status short enough for a table column: "Q3 4:12", "Half", "Final", "Sun 7:20p". */
    fun shortStatus(now: Double, zone: ZoneId = ZoneId.systemDefault()): String = when (state) {
        State.final -> if (detail.contains("OT")) "F/OT" else "Final"
        State.live -> detail.replace(" - ", " ").let { if (it.count <= 12) it else it.head(12) }
        State.scheduled -> {
            val s = start
            if (s == null) "Soon" else {
                val pattern = if (abs(s - now) < 20 * 3600) "h:mma" else "EEE h:mma"
                DateTimeFormatter.ofPattern(pattern, Locale.US).withZone(zone).format(Instant.ofEpochMilli((s * 1000).toLong()))
                    .replace("AM", "a").replace("PM", "p").replace("am", "a").replace("pm", "p")
            }
        }
    }
}

object Scoreboard {
    private fun number(value: Any?): Int? = when (value) {
        is String -> value.toIntOrNull()
        is Map<*, *> -> number(value["displayValue"]) ?: value["value"].int()
        else -> value.int()
    }

    private fun date(text: String): Double? {
        if (text.isEmpty()) return null
        try { return Instant.parse(text).toEpochMilli() / 1000.0 } catch (e: Exception) {}
        try { return OffsetDateTime.parse(text).toInstant().toEpochMilli() / 1000.0 } catch (e: Exception) {}
        // "2026-11-15T17:00Z": no seconds
        try { return Instant.parse(text.removeSuffix("Z") + ":00Z").toEpochMilli() / 1000.0 } catch (e: Exception) {}
        return null
    }

    internal fun game(event: Map<String, Any?>, league: League): Game? {
        val comp = event["competitions"].list()?.firstOrNull().dict() ?: return null
        val sides = comp["competitors"].list() ?: return null
        if (sides.size != 2) return null
        val ids = HashMap<String, String>()
        fun side(which: String): Game.Side? {
            val raw = sides.firstOrNull { it.at("homeAway").str() == which }.dict() ?: return null
            val team = raw["team"].dict() ?: return null
            val abbr = team["abbreviation"].str() ?: return null
            team["id"].str()?.let { ids[it] = abbr }
            val record = (raw["records"].list() ?: raw["record"].list())?.firstOrNull().at("summary").str()
            val periods = (raw["linescores"].list() ?: emptyList()).mapNotNull { number(it.at("value")) ?: number(it.at("displayValue")) }
            return Game.Side(abbr, team["shortDisplayName"].str() ?: abbr, number(raw["score"]), record, periods)
        }
        val away = side("away") ?: return null
        val home = side("home") ?: return null
        val status = comp["status"].dict() ?: event["status"].dict() ?: emptyMap()
        val type = status["type"].dict() ?: emptyMap()
        val state = when (type["state"].str()) { "in" -> Game.State.live; "post" -> Game.State.final; else -> Game.State.scheduled }
        val start = date(event["date"].str() ?: comp["date"].str() ?: "")
        val situation = comp["situation"].dict()
        if (state == Game.State.scheduled) { away.score = null; home.score = null; away.periods = emptyList(); home.periods = emptyList() }
        if (situation != null && state == Game.State.live) {
            away.timeouts = situation["awayTimeouts"].int(); home.timeouts = situation["homeTimeouts"].int()
        }
        val game = Game(event["id"].str() ?: UUID.randomUUID().toString(), league, away, home, state, type["shortDetail"].str() ?: "", start)
        game.period = status["period"].int() ?: 0
        val broadcast = comp["broadcasts"].list()?.firstOrNull()
        game.network = broadcast.at("names").list()?.firstOrNull().str() ?: broadcast.at("media").at("shortName").str()
        if (situation != null && state == Game.State.live) {
            game.situation = situation["downDistanceText"].str() ?: situation["shortDownDistanceText"].str()
            game.lastPlay = situation["lastPlay"].at("text").str()
            situation["possession"].str()?.let { game.possession = ids[it] }
            game.redZone = situation["isRedZone"].bool() ?: false
        }
        return game
    }

    fun parse(data: String, league: League): List<Game> {
        val events = Json.obj(data)?.get("events").list() ?: return emptyList()
        return events.mapNotNull { e -> e.dict()?.let { game(it, league) } }
    }

    /** A team's next game, from its own page. Used when the team isn't on today's scoreboard. */
    fun parseTeamNext(data: String, league: League): Game? {
        val events = Json.obj(data)?.get("team").at("nextEvent").list() ?: return null
        return events.firstNotNullOfOrNull { e -> e.dict()?.let { game(it, league) } }
    }

    /**
     * The game to show: a followed team's live game, else its next one today, else its latest final;
     * with no followed team in the list, the first live game, else the next to start.
     */
    fun pick(games: List<Game>, teams: List<String>, now: Double): Game? {
        val mine = games.filter { g -> teams.any { g.has(it) } }
        fun best(list: List<Game>): Game? {
            list.firstOrNull { it.state == Game.State.live }?.let { return it }
            val upcoming = list.filter { it.state == Game.State.scheduled }.sortedBy { it.start ?: Double.MAX_VALUE }
            val finals = list.filter { it.state == Game.State.final }.sortedByDescending { it.start ?: -Double.MAX_VALUE }
            // a game that ended in the last few hours beats one that's a day away
            val done = finals.firstOrNull()
            val began = done?.start
            if (done != null && began != null && now - began < 8 * 3600 && ((upcoming.firstOrNull()?.start ?: Double.MAX_VALUE) - now) > 3600) return done
            return upcoming.firstOrNull() ?: finals.firstOrNull()
        }
        return best(mine) ?: best(games)
    }

    /** Games in the order worth listing: followed teams first, then live, upcoming, finished. */
    fun ordered(games: List<Game>, teams: List<String>): List<Game> {
        fun rank(g: Game): Int {
            val mine = if (teams.any { g.has(it) }) 0 else 10
            return when (g.state) { Game.State.live -> mine; Game.State.scheduled -> mine + 1; Game.State.final -> mine + 2 }
        }
        return games.withIndex().sortedWith(compareBy<IndexedValue<Game>> { rank(it.value) }.thenBy { it.value.start ?: Double.MAX_VALUE }.thenBy { it.index }).map { it.value }
    }

    // MARK: Cards

    private fun cellsOf(vararg parts: Triple<String, Int, Boolean>) = Grid.row(parts.toList())
    private fun c(text: String, width: Int, right: Boolean = false) = Triple(text, width, right)

    /** The main view of one game. */
    fun card(game: Game, screen: Screen, now: Double, stale: Boolean = false, glyphs: Glyphs = Glyphs.plain): Card {
        val lines = ArrayList<String>()
        val w = screen.columns
        val rich = glyphs.style != GlyphStyle.plain
        when (game.state) {
            Game.State.live -> {
                val head = "${game.league.short} ${game.detail}" + (if (stale) " (old)" else "")
                lines.add((if (rich) glyphs.live + " " else "") + TextLayout.fit(head, w - (if (rich) 3 else 0)))
                if (rich || game.possession != null) {
                    // one team per row, the score in a column, a marker on the side with the ball
                    for (side in listOf(game.away, game.home)) {
                        val mark = if (game.possession == side.abbr) glyphs.here else ""
                        lines.add(cellsOf(c(side.abbr, 5), c(side.score?.toString() ?: "-", 2, true), c("", 1)) + (if (mark.isEmpty()) "" else glyphs.blank + mark))
                    }
                } else lines.add(TextLayout.headline(game.scoreLine, screen))
                val situation = game.situation
                if (!situation.isNullOrEmpty()) lines.add(TextLayout.fit((if (game.redZone) "RED ZONE " else "") + situation, w))
                val play = game.lastPlay
                if (!play.isNullOrEmpty() && lines.size < screen.rows) lines += TextLayout.wrap("Last: " + shortPlay(play), w, max(1, screen.rows - lines.size))
            }
            Game.State.final -> {
                lines.add(TextLayout.fit("${game.league.short} ${game.detail.ifEmpty { "Final" }}", w))
                val a = game.away.score ?: 0; val h = game.home.score ?: 0
                if (rich) {
                    val won = if (a > h) game.away.abbr else if (h > a) game.home.abbr else ""
                    for (side in listOf(game.away, game.home)) {
                        lines.add(cellsOf(c(side.abbr, 5), c(side.score?.toString() ?: "-", 2, true)) + (if (won == side.abbr) glyphs.blank + glyphs.star else ""))
                    }
                } else lines.add(TextLayout.headline(game.scoreLine, screen))
                val winner = if (a >= h) game.away else game.home
                winner.record?.let { lines.add(TextLayout.fit("${winner.name} now $it", w)) }
            }
            Game.State.scheduled -> {
                lines.add(TextLayout.fit("${game.league.short} up next", w))
                lines.add(TextLayout.headline(game.title, screen))
                val start = game.start
                if (start != null) {
                    lines.add(TextLayout.fit(HubClock.weekdayTime(start) + (game.network?.let { " on $it" } ?: ""), w))
                    if (start - now < 36 * 3600) {
                        val verb = if (game.league.sport == League.Sport.football || game.league.sport == League.Sport.soccer) "Kickoff" else "Starts"
                        lines.add("$verb ${HubClock.until(start, now)}")
                    }
                }
                val records = listOf(game.away, game.home).mapNotNull { s -> s.record?.let { "${s.abbr} $it" } }
                if (records.size == 2) lines.add(TextLayout.fit(records.joinToString(", "), w))
            }
        }
        return Card(lines.take(screen.rows))
    }

    /** The box score: points by period in a table. Null when there's nothing to tabulate. */
    fun boxCard(game: Game, screen: Screen, glyphs: Glyphs = Glyphs.plain): Card? {
        val played = max(game.away.periods.size, game.home.periods.size)
        if (game.state == Game.State.scheduled || played <= 0 || game.league.sport == League.Sport.baseball) return null
        val regulation = when (game.league.sport) { League.Sport.hockey -> 3; League.Sport.soccer -> 2; else -> if (game.league == League.ncaam) 2 else 4 }
        val columns = min(max(regulation, played), (screen.wideColumns - 4 - 3) / 2)
        val first = max(0, played - columns)                       // long overtime: show the latest periods
        fun label(i: Int) = if (i < regulation) "${i + 1}" else if (i == regulation) "OT" else "${i - regulation + 1}O"
        val lines = mutableListOf(TextLayout.fit("${game.league.short} ${if (game.state == Game.State.final) game.detail.ifEmpty { "Final" } else game.detail}", screen.columns))
        lines.add(Grid.row(listOf(c("", 4)) + (first until first + columns).map { c(label(it), 2, true) } + c("T", 3, true)))
        for (side in listOf(game.away, game.home)) {
            val cells = (first until first + columns).map { i -> c(side.periods.getOrNull(i)?.toString() ?: "", 2, true) }
            lines.add(Grid.row(listOf(c(side.abbr, 4)) + cells + c(side.score?.toString() ?: "-", 3, true)))
        }
        val situation = game.situation
        if (!situation.isNullOrEmpty() && lines.size < screen.rows) {
            lines.add(TextLayout.fit((game.possession?.let { "$it: " } ?: "") + situation, screen.columns))
        } else if (game.state == Game.State.final && lines.size < screen.rows) {
            val diff = abs(game.margin)
            val winner = if (game.margin > 0) game.home else game.away
            if (diff > 0) lines.add(TextLayout.fit("${winner.name} by $diff", screen.columns))
        }
        val a = game.away.timeouts; val h = game.home.timeouts
        if (a != null && h != null && lines.size < screen.rows) lines.add(TextLayout.fit("Timeouts ${game.away.abbr} $a, ${game.home.abbr} $h", screen.columns))
        return Card(lines.take(screen.rows))
    }

    /** Every game in a list as a table, split into pages that fit the screen. */
    fun tablePages(games: List<Game>, title: String, screen: Screen, now: Double, glyphs: Glyphs = Glyphs.plain): List<Card> {
        if (games.isEmpty()) return listOf(Card(listOf(title, "No games on the schedule.")))
        val perPage = max(1, screen.rows - 1)
        val statusCells = max(3, screen.wideColumns - 15)
        val pages = games.chunked(perPage)
        return pages.mapIndexed { index, page ->
            val head = if (pages.size > 1) "$title  ${glyphs.pager(index, pages.size)}" else title
            Card(listOf(head) + page.map { g ->
                val lead = if (g.state == Game.State.live) glyphs.live else if (g.state == Game.State.final) glyphs.blank else glyphs.hollow
                val status = g.shortStatus(now)
                val fitted = if (status.count > statusCells * 2) status.head(statusCells * 2) else status
                lead + cellsOf(c(g.away.abbr, 4), c(g.away.score?.toString() ?: "", 2, true), c("", 1),
                    c(g.home.abbr, 4), c(g.home.score?.toString() ?: "", 2, true), c("", 1)) + fitted
            })
        }
    }

    /** One line for the dashboard. */
    fun summary(game: Game, now: Double): String = when (game.state) {
        Game.State.live -> "${game.scoreLine}, ${game.detail}"
        Game.State.final -> "${game.scoreLine}, final"
        Game.State.scheduled -> "${game.title}, ${game.start?.let { HubClock.weekdayTime(it) } ?: game.detail}"
    }

    // MARK: Alerts

    /** What's worth interrupting for, comparing the last look at a game with this one. */
    fun alerts(old: Game?, new: Game): List<List<String>> {
        if (old == null || old.id != new.id) return emptyList()
        val out = ArrayList<List<String>>()
        val sport = new.league.sport
        if (old.state == Game.State.scheduled && new.state == Game.State.live) out.add(listOf("${new.league.short} underway", new.title))
        if (new.state == Game.State.live || (old.state == Game.State.live && new.state == Game.State.final)) {
            for ((before, after) in listOf(old.away to new.away, old.home to new.home)) {
                val was = before.score ?: continue
                val now = after.score ?: continue
                if (now <= was) continue
                val points = now - was
                val lines: MutableList<String> = when (sport) {
                    League.Sport.football -> {
                        val kind = if (points >= 6) "TOUCHDOWN" else if (points == 3) "FIELD GOAL" else if (points == 2) "SAFETY" else "SCORE"
                        mutableListOf("$kind ${after.abbr}!", new.scoreLine)
                    }
                    League.Sport.hockey, League.Sport.soccer -> mutableListOf("GOAL ${after.abbr}!", new.scoreLine)
                    League.Sport.baseball -> mutableListOf("${after.abbr} scores $points", new.scoreLine)
                    League.Sport.basketball -> continue          // far too often; see lead changes below
                }
                val play = new.lastPlay
                if (!play.isNullOrEmpty()) lines.add(shortPlay(play))
                out.add(lines)
            }
        }
        if (sport == League.Sport.basketball && new.state == Game.State.live) {
            // the end of each period, and the lead changing hands late in a game
            if (new.period > old.period && old.period > 0) out.add(listOf("End of ${ordinal(old.period)}", new.scoreLine))
            else if (new.period >= 4 && old.margin != 0 && new.margin != 0 && (old.margin > 0) != (new.margin > 0)) {
                val leader = if (new.margin > 0) new.home.abbr else new.away.abbr
                out.add(listOf("$leader takes the lead", new.scoreLine, new.detail))
            }
        }
        val team = new.possession
        if (sport == League.Sport.football && new.state == Game.State.live && new.redZone && !old.redZone && team != null) {
            out.add(listOf("$team in the red zone", new.scoreLine))
        }
        if (old.state == Game.State.live && new.state == Game.State.final) out.add(listOf("FINAL", new.scoreLine))
        return out
    }

    internal fun ordinal(n: Int): String = when (n) { 1 -> "1st"; 2 -> "2nd"; 3 -> "3rd"; else -> "${n}th" }

    /** How long to wait before asking the feed again. */
    fun pollInterval(game: Game?, now: Double): Double {
        if (game == null) return 600.0
        return when (game.state) {
            Game.State.live -> 15.0
            Game.State.final -> 600.0
            Game.State.scheduled -> {
                val start = game.start ?: return 300.0
                val wait = start - now
                if (wait < 600) 30.0 else if (wait < 3600) 120.0 else 600.0
            }
        }
    }

    /** Trims the clock prefix from a play and spells yards the short way. */
    internal fun shortPlay(text: String): String {
        var s = TextLayout.clean(text)
        if (s.startsWith("(")) {
            val end = s.indexOf(')')
            if (end in 0 until 20) s = s.substring(end + 1).trim()
        }
        for ((a, b) in listOf(" Yds " to "-yd ", " Yd " to "-yd ", " yards " to "-yd ", " yard " to "-yd ")) s = s.replace(a, b)
        return s
    }
}
