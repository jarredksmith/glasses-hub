package com.jarredsmith.glasseshub.core

import java.net.URLDecoder
import java.net.URLEncoder
import java.time.Instant
import java.time.LocalDate
import java.time.LocalDateTime
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.util.Locale
import kotlin.math.ceil
import kotlin.math.max
import kotlin.math.min

fun urlEncode(text: String): String = URLEncoder.encode(text, "UTF-8").replace("+", "%20")
private fun fmt(pattern: String, vararg args: Any?) = String.format(Locale.US, pattern, *args)

// MARK: - Trivia host

data class TriviaQuestion(val category: String, val question: String, val answer: String)

object Trivia {
    /** Open Trivia Database, asked for URL-encoded text so no HTML entities need untangling. */
    fun feed(count: Int): String = "https://opentdb.com/api.php?amount=${max(1, min(20, count))}&type=multiple&encode=url3986"

    fun parse(data: String): List<TriviaQuestion> {
        val results = Json.obj(data)?.get("results").list() ?: return emptyList()
        fun text(value: Any?): String = TextLayout.clean(try { URLDecoder.decode((value.str() ?: "").replace("+", "%2B"), "UTF-8") } catch (e: Exception) { "" })
        return results.mapNotNull { r ->
            val q = text(r.at("question")); val a = text(r.at("correct_answer"))
            if (q.isEmpty() || a.isEmpty()) return@mapNotNull null
            var category = text(r.at("category"))
            val colon = category.indexOf(": ")
            if (colon >= 0) category = category.substring(colon + 2)
            TriviaQuestion(category, q, a)
        }
    }
}

/** A round of trivia where the wearer is the host: the question shows on the glasses, then its answer. */
data class TriviaRound(
    val questions: List<TriviaQuestion>,
    var phaseStarted: Double,
    /** Seconds before the answer appears on its own. Zero means wait for a tap. */
    val questionSeconds: Double = 20.0,
    val answerSeconds: Double = 8.0,
    /** Move on to the next question without a tap. */
    val autoAdvance: Boolean = true,
    var index: Int = 0,
    var phase: Phase = if (questions.isEmpty()) Phase.done else Phase.question,
) {
    enum class Phase { question, answer, done }

    val current: TriviaQuestion? get() = questions.getOrNull(index)

    fun reveal(now: Double) { if (phase == Phase.question) { phase = Phase.answer; phaseStarted = now } }
    fun next(now: Double) {
        if (phase == Phase.done) return
        if (index + 1 < questions.size) { index += 1; phase = Phase.question } else phase = Phase.done
        phaseStarted = now
    }
    fun tick(now: Double) {
        when (phase) {
            Phase.question -> if (questionSeconds > 0 && now - phaseStarted >= questionSeconds) reveal(now)
            Phase.answer -> if (autoAdvance && now - phaseStarted >= answerSeconds) next(now)
            Phase.done -> {}
        }
    }

    fun card(screen: Screen, now: Double): Card {
        val q = current
        if (q == null || phase == Phase.done) return Card(listOf("Trivia", TextLayout.headline("ROUND OVER", screen), "${questions.size} questions asked."))
        val header = "Q${index + 1} of ${questions.size}: ${q.category}"
        return when (phase) {
            Phase.question -> {
                val lines = mutableListOf(TextLayout.fit(header, screen.columns))
                lines += TextLayout.wrap(q.question, screen.columns, screen.rows - 2)
                if (questionSeconds > 0) lines.add("Answer in ${max(0, ceil(questionSeconds - (now - phaseStarted)).toInt())}s")
                Card(lines)
            }
            Phase.answer -> {
                val lines = mutableListOf(TextLayout.fit("Answer ${index + 1} of ${questions.size}", screen.columns))
                if (q.answer.count <= screen.wideColumns) lines.add(TextLayout.headline(q.answer, screen))
                else lines += TextLayout.wrap(q.answer, screen.columns, screen.rows - 1)
                Card(lines)
            }
            Phase.done -> Card(emptyList())
        }
    }
}

// MARK: - Odd facts

object Facts {
    const val randomFeed = "https://uselessfacts.jsph.pl/api/v2/facts/random?language=en"
    fun onThisDayFeed(now: Double, zone: ZoneId = ZoneId.systemDefault()): String {
        val d = Instant.ofEpochMilli((now * 1000).toLong()).atZone(zone)
        return fmt("https://api.wikimedia.org/feed/v1/wikipedia/en/onthisday/selected/%02d/%02d", d.monthValue, d.dayOfMonth)
    }
    fun parseRandom(data: String): String? {
        val fact = TextLayout.clean(Json.obj(data)?.get("text").str() ?: return null)
        return fact.ifEmpty { null }
    }
    /** "On this day in 1969: ..." for every entry Wikipedia picked for the date. */
    fun parseOnThisDay(data: String): List<String> {
        val list = Json.obj(data)?.get("selected").list() ?: return emptyList()
        return list.mapNotNull { item ->
            val text = item.at("text").str()
            if (text.isNullOrEmpty()) return@mapNotNull null
            val year = item.at("year").int()?.let { "On this day in $it: " } ?: "On this day: "
            TextLayout.clean(year + text)
        }
    }
    fun card(fact: String, screen: Screen): Card {
        val lines = listOf("Odd fact") + TextLayout.wrap(fact, screen.columns)
        return Card(lines, scrolls = lines.size > screen.rows)
    }
}

// MARK: - Timer

data class HubTimer(
    val duration: Double,
    val label: String = "Timer",
    /** Wall-clock time the timer will hit zero, while running. */
    var endsAt: Double? = null,
    /** What was left when it was paused. */
    var pausedRemaining: Double? = duration,
) {
    val isRunning: Boolean get() = endsAt != null
    fun remaining(now: Double): Double = endsAt?.let { max(0.0, it - now) } ?: (pausedRemaining ?: duration)
    fun isDone(now: Double): Boolean = endsAt != null && remaining(now) <= 0
    fun start(now: Double) { if (endsAt == null) { endsAt = now + (pausedRemaining ?: duration); pausedRemaining = null } }
    fun pause(now: Double) { if (endsAt != null) { pausedRemaining = remaining(now); endsAt = null } }
    fun reset() { endsAt = null; pausedRemaining = duration }

    fun card(screen: Screen, now: Double, glyphs: Glyphs = Glyphs.plain): Card {
        val left = remaining(now)
        val state = if (isDone(now)) "TIME'S UP" else if (isRunning) label else "$label (paused)"
        val fraction = if (duration > 0) left / duration else 0.0
        val percent = " ${(fraction * 100).rounded()}%"
        return Card(listOf(TextLayout.fit(state, screen.columns), TextLayout.headline(clock(left), screen),
            if (glyphs.style == GlyphStyle.plain) TextLayout.bar(fraction, 16) + percent
            else glyphs.meter(fraction, min(12, screen.wideColumns - 4)) + percent))
    }

    companion object {
        fun minutes(minutes: Double, label: String = "Timer") = HubTimer(max(1.0, minutes * 60), label)
        fun clock(seconds: Double): String {
            val s = max(0, ceil(seconds).toInt())
            return if (s >= 3600) fmt("%d:%02d:%02d", s / 3600, (s / 60) % 60, s % 60) else fmt("%02d:%02d", s / 60, s % 60)
        }
    }
}

// MARK: - Weather

data class Weather(
    val place: String, val temperature: Int, val feelsLike: Int, val condition: String, val wind: Int,
    val high: Int? = null, val low: Int? = null, val rainChance: Int? = null, var tomorrow: String? = null,
    var code: Int = -1, var hours: List<Hour> = emptyList(), var days: List<Day> = emptyList(),
) {
    data class Hour(val label: String, val temperature: Int, val rain: Int, val code: Int)
    data class Day(val label: String, val high: Int, val low: Int, val rain: Int, val code: Int)
    data class Place(val name: String, val latitude: Double, val longitude: Double)

    /** The next half day as a table: a column every three hours with temperature, sky and chance of rain. */
    fun hoursCard(screen: Screen, glyphs: Glyphs = Glyphs.plain): Card? {
        val columns = min(screen.wideColumns / 4, 6)
        val picked = hours.filterIndexed { i, _ -> i % 3 == 0 }.take(columns)
        if (picked.size < 3) return null
        val lines = mutableListOf(TextLayout.fit("$place  $temperature° $condition", screen.columns))
        lines.add(Grid.row(picked.mapIndexed { i, h -> Triple(if (i == 0) "Now" else h.label, 4, false) }))
        lines.add(Grid.row(picked.map { Triple("${it.temperature}", 4, false) }))
        lines.add(picked.joinToString("") { glyphs.weather(it.code) + glyphs.blank.repeat(3) }.trim('　'))
        if (picked.any { it.rain >= 20 }) lines.add(Grid.row(picked.map { Triple(if (it.rain >= 100) "99" else "${it.rain}", 4, false) }) + " %rain")
        else {
            val spark = glyphs.spark(hours.map { it.temperature.toDouble() })
            lines.add(if (spark != null) "$spark temp" else "No rain expected")
        }
        if (lines.size < screen.rows) lines.add(TextLayout.fit(glyphs.weatherLegend, screen.columns))
        return Card(lines.take(screen.rows))
    }

    /** The days ahead, one per row: day, sky, high and low, chance of rain. */
    fun weekCard(screen: Screen, glyphs: Glyphs = Glyphs.plain): Card? {
        if (days.size < 2) return null
        val lines = mutableListOf(TextLayout.fit("$place  now $temperature°", screen.columns))
        for (day in days.take(screen.rows - 1)) {
            val name = if (day.label == "Today") "Now" else day.label
            val rain = if (day.rain >= 30) glyphs.blank + glyphs.weather(61) + (if (day.rain >= 100) "99" else "${day.rain}") else ""
            lines.add(Grid.row(listOf(Triple(name, 4, false), Triple(glyphs.weather(day.code), 2, false), Triple("${day.high}", 2, true), Triple("/", 1, false), Triple("${day.low}", 2, false))) + rain)
        }
        return Card(lines)
    }

    val summary: String get() = "$temperature° $condition" + (rainChance?.let { if (it >= 30) ", rain $it%" else "" } ?: "")

    fun card(screen: Screen): Card {
        val lines = mutableListOf(TextLayout.fit(place.ifEmpty { "Weather" }, screen.columns), TextLayout.headline("$temperature° $condition", screen))
        lines.add("Feels $feelsLike°, wind $wind")
        if (high != null && low != null) lines.add("High $high, low $low" + (rainChance?.let { ", rain $it%" } ?: ""))
        tomorrow?.let { lines.add(TextLayout.fit(it, screen.columns)) }
        return Card(lines.take(screen.rows))
    }

    companion object {
        fun placeLookup(name: String): String = "https://geocoding-api.open-meteo.com/v1/search?name=${urlEncode(name)}&count=1&language=en"

        fun parsePlace(data: String): Place? {
            val first = Json.obj(data)?.get("results").list()?.firstOrNull() ?: return null
            val lat = first.at("latitude").num() ?: return null
            val lon = first.at("longitude").num() ?: return null
            return Place(first.at("name").str() ?: "", lat, lon)
        }

        fun feed(latitude: Double, longitude: Double, celsius: Boolean = false): String =
            "https://api.open-meteo.com/v1/forecast?latitude=${fmt("%.4f", latitude)}&longitude=${fmt("%.4f", longitude)}" +
                "&current=temperature_2m,apparent_temperature,weather_code,wind_speed_10m" +
                "&daily=weather_code,temperature_2m_max,temperature_2m_min,precipitation_probability_max" +
                "&temperature_unit=${if (celsius) "celsius" else "fahrenheit"}&wind_speed_unit=${if (celsius) "kmh" else "mph"}" +
                "&hourly=temperature_2m,precipitation_probability,weather_code&forecast_hours=14&timezone=auto&forecast_days=6"

        fun parse(data: String, place: String): Weather? {
            val root = Json.obj(data) ?: return null
            val current = root["current"].dict() ?: return null
            val temp = current["temperature_2m"].num() ?: return null
            fun whole(value: Any?): Int? = value.num()?.rounded()
            val daily = root["daily"].dict()
            fun item(key: String, day: Int): Any? = daily?.get(key).list()?.getOrNull(day)
            val weather = Weather(place, temp.rounded(), whole(current["apparent_temperature"]) ?: temp.rounded(),
                describe(current["weather_code"].int() ?: -1), whole(current["wind_speed_10m"]) ?: 0,
                whole(item("temperature_2m_max", 0)), whole(item("temperature_2m_min", 0)), item("precipitation_probability_max", 0).int())
            val hi = whole(item("temperature_2m_max", 1)); val lo = whole(item("temperature_2m_min", 1))
            if (hi != null && lo != null) weather.tomorrow = "Tomorrow $hi/$lo ${describe(item("weather_code", 1).int() ?: -1)}"
            weather.code = current["weather_code"].int() ?: -1
            val hourly = root["hourly"].dict()
            val hourTimes = hourly?.get("time").list()
            if (hourly != null && hourTimes != null) {
                val hours = ArrayList<Hour>()
                for ((i, time) in hourTimes.withIndex()) {
                    val t = whole(hourly["temperature_2m"].list()?.getOrNull(i)) ?: continue
                    val date = try { LocalDateTime.parse(time.str() ?: "") } catch (e: Exception) { continue }
                    val h = date.hour
                    val label = "${if (h % 12 == 0) 12 else h % 12}${if (h < 12) "a" else "p"}"
                    hours.add(Hour(label, t, hourly["precipitation_probability"].list()?.getOrNull(i).int() ?: 0, hourly["weather_code"].list()?.getOrNull(i).int() ?: -1))
                }
                weather.hours = hours
            }
            val dayTimes = daily?.get("time").list()
            if (dayTimes != null) {
                val days = ArrayList<Day>()
                for ((i, time) in dayTimes.withIndex()) {
                    val h = whole(item("temperature_2m_max", i)) ?: continue
                    val l = whole(item("temperature_2m_min", i)) ?: continue
                    val date = try { LocalDate.parse(time.str() ?: "") } catch (e: Exception) { continue }
                    days.add(Day(if (i == 0) "Today" else DateTimeFormatter.ofPattern("EEE", Locale.US).format(date), h, l,
                        item("precipitation_probability_max", i).int() ?: 0, item("weather_code", i).int() ?: -1))
                }
                weather.days = days
            }
            return weather
        }

        /** WMO weather codes, as Open-Meteo reports them. */
        fun describe(code: Int): String = when (code) {
            0 -> "Clear"; 1 -> "Mostly clear"; 2 -> "Partly cloudy"; 3 -> "Cloudy"
            45, 48 -> "Fog"; 51, 53, 55 -> "Drizzle"; 56, 57 -> "Freezing drizzle"
            61 -> "Light rain"; 63 -> "Rain"; 65 -> "Heavy rain"
            66, 67 -> "Freezing rain"; 71 -> "Light snow"; 73 -> "Snow"
            75 -> "Heavy snow"; 77 -> "Snow grains"; 80, 81 -> "Showers"
            82 -> "Heavy showers"; 85, 86 -> "Snow showers"; 95 -> "Thunderstorm"
            96, 99 -> "Storm with hail"; else -> "Weather"
        }
    }
}

// MARK: - Calendar

data class AgendaItem(val title: String, val start: Double, val end: Double, val allDay: Boolean = false, val place: String? = null, val notes: String? = null)

object Agenda {
    /** Events still ahead (or under way), soonest first; all-day ones last. */
    fun upcoming(items: List<AgendaItem>, now: Double): List<AgendaItem> =
        items.filter { it.end > now }.sortedWith(compareBy<AgendaItem> { it.allDay }.thenBy { it.start })

    fun line(item: AgendaItem, now: Double): String = when {
        item.allDay -> "All day: ${item.title}"
        item.start <= now -> "Now: ${item.title}"
        else -> "${HubClock.time(item.start)} ${item.title}"
    }
    fun summary(items: List<AgendaItem>, now: Double): String? {
        val next = upcoming(items, now).firstOrNull { !it.allDay } ?: return null
        return if (next.start <= now) "Now: ${next.title}" else "${next.title} ${HubClock.until(next.start, now)}"
    }
    fun card(items: List<AgendaItem>, screen: Screen, now: Double): Card {
        val list = upcoming(items, now)
        if (list.isEmpty()) return Card(listOf("Calendar", "Nothing else today."))
        val lines = mutableListOf("Calendar, ${HubClock.day(now)}")
        val next = list.first()
        if (!next.allDay && next.start > now) lines.add(TextLayout.fit("Next ${HubClock.until(next.start, now)}", screen.columns))
        for (item in list) lines.add(TextLayout.fit(line(item, now), screen.columns))
        return Card(lines, scrolls = lines.size > screen.rows)
    }

    /**
     * A month calendar: weekday letters over rows of dates, today marked. On the 5-line screen it shows
     * the weeks around today. Days with events can carry a dot when the style allows.
     */
    fun monthCard(now: Double, screen: Screen, glyphs: Glyphs = Glyphs.plain, busyDays: Set<Int> = emptySet(), zone: ZoneId = ZoneId.systemDefault()): Card {
        val date = Instant.ofEpochMilli((now * 1000).toLong()).atZone(zone).toLocalDate()
        val today = date.dayOfMonth
        val monthStart = date.withDayOfMonth(1)
        val dayCount = date.lengthOfMonth()
        val lead = monthStart.dayOfWeek.value % 7                       // Sunday first
        var weeks = ArrayList<List<Int?>>()
        var week = ArrayList<Int?>(List(lead) { null })
        for (day in 1..dayCount) {
            week.add(day)
            if (week.size == 7) { weeks.add(week); week = ArrayList() }
        }
        if (week.isNotEmpty()) weeks.add(week + List(7 - week.size) { null })
        var room = screen.rows - 2                                      // title and weekday rows
        var showTitle = true
        if (weeks.size > room && weeks.size <= screen.rows - 1) { showTitle = false; room = screen.rows - 1 }
        if (weeks.size > room) {
            val current = weeks.indexOfFirst { it.contains(today) }.coerceAtLeast(0)
            val start = max(0, min(weeks.size - room, current - room / 2))
            weeks = ArrayList(weeks.subList(start, start + room))
        }
        val lines = ArrayList<String>()
        if (showTitle) lines.add(DateTimeFormatter.ofPattern("MMMM yyyy", Locale.US).format(date))
        lines.add(listOf("S", "M", "T", "W", "T", "F", "S").joinToString("") { TextLayout.wide(it) + glyphs.blank }.trim('　'))
        for (row in weeks) {
            val line = StringBuilder()
            for (day in row) {
                if (day == null) { line.append(glyphs.blank).append(glyphs.blank); continue }
                val mark = if (day == today) glyphs.here else if (busyDays.contains(day) && glyphs.style != GlyphStyle.plain) "·" else glyphs.blank
                line.append(Grid.cell(day.toString(), 1, right = true)).append(mark)
            }
            lines.add(line.toString().trimEnd('　'))
        }
        return Card(lines)
    }

    /** Today's events with markers: what's on now, what's next, what's later. */
    fun listCard(items: List<AgendaItem>, screen: Screen, now: Double, glyphs: Glyphs): Card {
        if (glyphs.style == GlyphStyle.plain) return card(items, screen, now)
        val list = upcoming(items, now)
        if (list.isEmpty()) return Card(listOf("Calendar, ${HubClock.day(now)}", "Nothing else today."))
        val lines = mutableListOf("Calendar, ${HubClock.day(now)}")
        var markedNext = false
        for (item in list) {
            val mark = when {
                item.allDay -> glyphs.hollow
                item.start <= now -> glyphs.live
                !markedNext -> { markedNext = true; glyphs.next }
                else -> glyphs.hollow
            }
            var text = if (item.allDay) item.title else if (item.start <= now) "Now: ${item.title}" else "${HubClock.time(item.start)} ${item.title}"
            if (mark == glyphs.next) text += " (${HubClock.until(item.start, now)})"
            lines.add(mark + " " + TextLayout.fit(text, screen.columns - 3))
        }
        return Card(lines, scrolls = lines.size > screen.rows)
    }
}

/**
 * Turns a card that's taller than the screen into pages that turn by themselves. The glasses' own
 * crown scrolling can't be relied on for reading: the caption page jumps back to the end of the text
 * a few seconds after you scroll.
 */
class AutoPager {
    var index = 0; private set
    var count = 1; private set
    var paused = false
    private var key = ""
    private var turnedAt = 0.0

    /** The page to show now. `loops` starts over after the last page; otherwise it stays there. */
    fun page(card: Card, rows: Int, now: Double, seconds: Double, loops: Boolean): Card {
        if (card.lines.size <= rows) { count = 1; index = 0; key = ""; return Card(card.lines) }
        val pages = TextLayout.pages(card.lines, rows)
        val newKey = card.lines.joinToString("\n")
        if (newKey != key) { key = newKey; index = 0; turnedAt = now }
        count = pages.size
        index = min(index, count - 1)
        if (!paused && seconds > 0 && now - turnedAt >= seconds) {
            if (index + 1 < count) { index += 1; turnedAt = now }
            else if (loops) { index = 0; turnedAt = now }
        }
        return Card(pages[index])
    }

    fun step(by: Int, now: Double) { index = max(0, min(count - 1, index + by)); turnedAt = now }
    fun restart(now: Double) { index = 0; turnedAt = now }
}

// MARK: - Reader and messages

object Reader {
    /** Longest text sent in one go; more than this is split into parts the phone steps through. */
    const val partBytes = 1500

    /** Fit text to the screen. Short text is a plain card; long text goes up whole (in parts if very long). */
    fun parts(text: String, screen: Screen): List<Card> {
        val lines = TextLayout.wrap(text, screen.columns)
        if (lines.isEmpty()) return emptyList()
        if (lines.size <= screen.rows) return listOf(Card(lines))
        val parts = ArrayList<List<String>>()
        var current = ArrayList<String>()
        var bytes = 0
        for (line in lines) {
            val cost = line.toByteArray(Charsets.UTF_8).size + 1
            if (bytes + cost > partBytes && current.isNotEmpty()) { parts.add(current); current = ArrayList(); bytes = 0 }
            current.add(line); bytes += cost
        }
        if (current.isNotEmpty()) parts.add(current)
        if (parts.size == 1) return listOf(Card(parts[0], scrolls = true))
        return parts.mapIndexed { i, body -> Card(body + "(part ${i + 1} of ${parts.size})", scrolls = true) }
    }

    /** A short note as a card with its title on top. */
    fun note(title: String, body: String, screen: Screen): Card {
        val lines = ArrayList<String>()
        val head = TextLayout.clean(title)
        if (head.isNotEmpty()) lines += TextLayout.wrap(head, screen.columns, 2)
        if (TextLayout.clean(body).isNotEmpty()) lines += TextLayout.wrap(body, screen.columns)
        return Card(lines, scrolls = lines.size > screen.rows)
    }
}

// MARK: - Dashboard

object Dashboard {
    /**
     * The home screen: time on top, then one line from each thing that has something to say. When there
     * are more lines than rows, the extras rotate through the last rows every `rotate` seconds.
     */
    fun card(now: Double, summaries: List<String>, screen: Screen, rotate: Double = 8.0): Card {
        val lines = mutableListOf(TextLayout.headline(HubClock.time(now), screen), HubClock.day(now))
        val room = max(1, screen.rows - lines.size)
        val items = summaries.map { TextLayout.fit(it, screen.columns) }.filter { it.isNotEmpty() }
        if (items.size <= room) lines += items
        else {
            val pages = ceil(items.size.toDouble() / room).toInt()
            val page = (now / max(2.0, rotate)).toLong().mod(pages)
            lines += items.subList(page * room, min(items.size, (page + 1) * room))
        }
        return Card(lines)
    }
}

// MARK: - Alerts that briefly take over the screen

class OverlayQueue {
    private class Item(val card: Card, val seconds: Double, var shownAt: Double? = null)
    private val items = ArrayList<Item>()

    fun push(card: Card, seconds: Double = 10.0) {
        if (card.isEmpty) return
        items.add(Item(card, seconds))
        while (items.size > 8) items.removeAt(0)
    }
    /** The alert on screen right now, if any. Starts the next one when the current one has had its time. */
    fun current(now: Double): Card? {
        while (items.isNotEmpty()) {
            val first = items[0]
            val shown = first.shownAt
            if (shown == null) { first.shownAt = now; return first.card }
            if (now - shown < first.seconds) return first.card
            items.removeAt(0)
        }
        return null
    }
    fun clear() = items.clear()
    val isEmpty: Boolean get() = items.isEmpty()
}
