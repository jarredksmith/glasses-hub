package com.jarredsmith.glasseshub.core

import java.util.Locale
import java.util.UUID
import kotlin.math.abs
import kotlin.math.ceil
import kotlin.math.max
import kotlin.math.min

/** Where a data feed's number comes from. */
enum class FeedKind {
    nightscout, homeAssistant, custom;
    val title: String get() = when (this) { nightscout -> "Nightscout"; homeAssistant -> "Home Assistant"; custom -> "Any web address" }
}

/** One value fetched from the wearer's own source and shown on the glasses. */
data class DataFeed(
    val id: String = UUID.randomUUID().toString(),
    val name: String = "",
    val kind: FeedKind,
    /** The site (Nightscout, Home Assistant) or the whole address (custom). */
    val address: String = "",
    /** Home Assistant: the entity. Custom: the JSON field to show, as a dotted path. */
    val item: String = "",
    /** Custom: text after the value. Nightscout: "mmol" for mmol/L. */
    val unit: String = "",
    val minutes: Int = 5,
    val onDashboard: Boolean = true,
) {
    val title: String get() {
        val own = name.trim()
        if (own.isNotEmpty()) return own
        return when (kind) { FeedKind.nightscout -> "Glucose"; FeedKind.homeAssistant -> item.ifEmpty { "Home" }; FeedKind.custom -> "Feed" }
    }

    /** The address with a scheme and no trailing slash. */
    internal val base: String get() {
        var text = address.trim()
        if (text.isEmpty()) return ""
        if (!text.lowercase().startsWith("http://") && !text.lowercase().startsWith("https://")) text = "https://$text"
        return text.trimEnd('/')
    }

    /** What to ask for (address and headers), or null while the feed isn't filled in yet. */
    fun request(token: String): Pair<String, Map<String, String>>? {
        val key = token.trim()
        if (base.isEmpty()) return null
        return when (kind) {
            FeedKind.nightscout -> (base + "/api/v1/entries.json?count=1" + (if (key.isNotEmpty()) "&token=" + urlEncode(key) else "")) to mapOf("Accept" to "application/json")
            FeedKind.homeAssistant -> {
                val entity = item.trim()
                if (entity.isEmpty() || key.isEmpty()) null
                else (base + "/api/states/" + urlEncode(entity)) to mapOf("Authorization" to "Bearer $key", "Accept" to "application/json")
            }
            FeedKind.custom -> base to (if (key.isEmpty()) emptyMap() else mapOf("Authorization" to "Bearer $key"))
        }
    }

    fun toMap(): Map<String, Any?> = mapOf("id" to id, "name" to name, "kind" to kind.name, "address" to address, "item" to item, "unit" to unit, "minutes" to minutes, "onDashboard" to onDashboard)

    companion object {
        fun from(map: Map<String, Any?>): DataFeed? {
            val kind = FeedKind.entries.firstOrNull { it.name == map["kind"].str() } ?: return null
            return DataFeed(map["id"].str() ?: UUID.randomUUID().toString(), map["name"].str() ?: "", kind, map["address"].str() ?: "",
                map["item"].str() ?: "", map["unit"].str() ?: "", map["minutes"].int() ?: 5, map["onDashboard"].bool() ?: true)
        }
    }
}

/** What a feed last said. */
data class FeedReading(val value: String,
                       /** Nightscout's direction of travel ("Flat", "SingleUp" and so on). */
                       val trend: String? = null,
                       /** When the source took the reading, if it says. */
                       val at: Double? = null, val fetched: Double)

object FeedParser {
    /** Turns a feed's answer into a reading. Null when the answer doesn't hold what the feed asks for. */
    fun read(feed: DataFeed, data: String, now: Double): FeedReading? {
        val json = Json.parse(data.trim())
        when (feed.kind) {
            FeedKind.nightscout -> {
                val entry = json.list()?.firstOrNull().dict() ?: return null
                val level = number(entry["sgv"]) ?: number(entry["mbg"]) ?: return null
                val value = if (feed.unit == "mmol") String.format(Locale.US, "%.1f", level / 18.018) else level.rounded().toString()
                return FeedReading(value, entry["direction"].str(), number(entry["date"])?.let { it / 1000 }, now)
            }
            FeedKind.homeAssistant -> {
                val state = json.dict() ?: return null
                val value = text(state["state"]) ?: return null
                val unit = state["attributes"].at("unit_of_measurement").str() ?: ""
                return FeedReading(if (unit.isEmpty()) value else "$value $unit", fetched = now)
            }
            FeedKind.custom -> {
                val path = feed.item.trim()
                val value: String? = if (path.isEmpty()) {
                    (if (json != null) text(json) else null) ?: data.lines().map { it.trim() }.firstOrNull { it.isNotEmpty() }
                } else if (json != null) text(walk(json, path)) else null
                var shown = value
                if (shown.isNullOrEmpty()) return null
                if (shown.count > 60) shown = shown.head(58) + ".."
                val unit = feed.unit.trim()
                return FeedReading(if (unit.isEmpty()) shown else "$shown $unit", fetched = now)
            }
        }
    }

    /** Follows a dotted path through JSON: names for objects, numbers for lists ("data.0.price"). */
    internal fun walk(json: Any?, path: String): Any? {
        var here: Any? = json
        for (part in path.split(".").filter { it.isNotEmpty() }) {
            val list = here.list()
            val index = part.toIntOrNull()
            here = if (list != null && index != null) list.getOrNull(index) else if (here is Map<*, *>) here[part] else return null
        }
        return here
    }

    internal fun number(value: Any?): Double? = when (value) { is String -> value.toDoubleOrNull(); is Number -> value.toDouble(); else -> null }

    /** A single value as text; null for lists, objects and nothing. */
    internal fun text(value: Any?): String? {
        if (value is String) return value.trim()
        if (value is Boolean) return if (value) "1" else "0"
        val d = (value as? Number)?.toDouble() ?: return null
        if (d == Math.rint(d) && abs(d) < 1e15) return d.toLong().toString()
        return String.format(Locale.US, "%.2f", d).trimEnd('0')
    }

    /** Nightscout's direction, as arrows the glasses have or as words. */
    fun trend(direction: String?, arrows: Boolean): String = when (direction ?: "") {
        "DoubleUp", "TripleUp" -> if (arrows) "↑↑" else "rising fast"
        "SingleUp" -> if (arrows) "↑" else "rising"
        "FortyFiveUp" -> if (arrows) "↑ slow" else "rising slowly"
        "Flat" -> if (arrows) "→" else "steady"
        "FortyFiveDown" -> if (arrows) "↓ slow" else "falling slowly"
        "SingleDown" -> if (arrows) "↓" else "falling"
        "DoubleDown", "TripleDown" -> if (arrows) "↓↓" else "falling fast"
        else -> ""
    }

    /** How old a reading is, when that's worth saying: "4m", "2h", or nothing for a fresh one. */
    fun age(reading: FeedReading, feed: DataFeed, now: Double): String {
        val minutes = ((now - (reading.at ?: reading.fetched)) / 60).toInt()
        // a source that stamps its readings always shows the age; others only once a refresh was missed
        if (reading.at == null && minutes < max(2, feed.minutes * 2)) return ""
        if (minutes < 1) return "now"
        return if (minutes < 90) "${minutes}m ago" else "${minutes / 60}h ago"
    }

    /** One line for a feed: "Glucose 112 → 3m ago". */
    fun line(feed: DataFeed, reading: FeedReading?, note: String = "", now: Double, arrows: Boolean): String {
        if (reading == null) return feed.title + ": " + note.ifEmpty { "waiting" }
        val parts = mutableListOf(feed.title, reading.value)
        val trend = trend(reading.trend, arrows)
        if (trend.isNotEmpty()) parts.add(trend)
        val age = age(reading, feed, now)
        if (age.isNotEmpty()) parts.add(if (arrows || trend.isEmpty()) age else "($age)")
        return parts.joinToString(" ")
    }

    /** The feeds' own screen. One feed gets the screen to itself; several take a line each. */
    fun card(feeds: List<DataFeed>, readings: Map<String, FeedReading>, notes: Map<String, String>, now: Double, screen: Screen, arrows: Boolean, turn: Int): Card {
        if (feeds.isEmpty()) return Card(listOf("Data feeds", "Add one in the app,", "under Apps > Data feeds."))
        if (feeds.size == 1) {
            val feed = feeds[0]
            val reading = readings[feed.id] ?: return Card(listOf(feed.title) + TextLayout.wrap(notes[feed.id] ?: "Waiting for the first reading.", screen.columns))
            val trend = trend(reading.trend, arrows)
            val lines = mutableListOf(feed.title, TextLayout.headline(if (trend.isEmpty()) reading.value else reading.value + " " + trend, screen))
            val age = age(reading, feed, now)
            if (age.isNotEmpty()) lines.add(age)
            val note = notes[feed.id]
            if (!note.isNullOrEmpty()) lines += TextLayout.wrap(note, screen.columns)
            return Card(lines.take(screen.rows))
        }
        val lines = feeds.map { TextLayout.fit(line(it, readings[it.id], notes[it.id] ?: "", now, arrows), screen.columns) }
        val room = max(1, screen.rows - 1)
        val pages = max(1, ceil(lines.size.toDouble() / room).toInt())
        val page = turn.mod(pages)
        return Card(listOf("Data feeds") + lines.subList(page * room, min(lines.size, (page + 1) * room)))
    }
}
