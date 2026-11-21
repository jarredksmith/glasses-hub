package com.jarredsmith.glasseshub.core

import org.xml.sax.Attributes
import org.xml.sax.InputSource
import org.xml.sax.helpers.DefaultHandler
import java.io.StringReader
import java.time.Instant
import java.time.OffsetDateTime
import java.time.ZoneId
import java.time.ZonedDateTime
import java.time.format.DateTimeFormatter
import java.util.Locale
import javax.xml.parsers.SAXParserFactory
import kotlin.math.max
import kotlin.math.min

data class NewsItem(val title: String, val summary: String, val link: String?, val source: String, val date: Double?) {
    val id: String get() = (link ?: "") + "|" + title
}

data class NewsSource(val name: String, val url: String) {
    companion object {
        /** Public feeds that publishers offer for exactly this: reading their headlines somewhere else. */
        val builtIn = listOf(
            NewsSource("BBC News", "https://feeds.bbci.co.uk/news/rss.xml"),
            NewsSource("NPR", "https://feeds.npr.org/1001/rss.xml"),
            NewsSource("BBC Tech", "https://feeds.bbci.co.uk/news/technology/rss.xml"),
            NewsSource("The Verge", "https://www.theverge.com/rss/index.xml"),
            NewsSource("ESPN", "https://www.espn.com/espn/rss/news"),
            NewsSource("NASA", "https://www.nasa.gov/feed/"),
        )
    }
}

object News {
    // MARK: Feeds (RSS and Atom)

    fun parseFeed(data: String, source: String): List<NewsItem> {
        val items = ArrayList<NewsItem>()
        val handler = object : DefaultHandler() {
            var inItem = false
            val text = StringBuilder()
            var fields = HashMap<String, String>()
            var link: String? = null
            override fun startElement(uri: String?, localName: String?, qName: String?, attributes: Attributes?) {
                val tag = (qName ?: localName ?: "").lowercase()
                if (tag == "item" || tag == "entry") { inItem = true; fields = HashMap(); link = null }
                if (inItem && tag == "link") {
                    val href = attributes?.getValue("href")
                    if (href != null && (attributes.getValue("rel") ?: "alternate") == "alternate") link = href
                }
                text.setLength(0)
            }
            override fun characters(ch: CharArray, start: Int, length: Int) { text.append(ch, start, length) }
            override fun endElement(uri: String?, localName: String?, qName: String?) {
                val tag = (qName ?: localName ?: "").lowercase()
                if (!inItem) return
                if (tag == "item" || tag == "entry") {
                    inItem = false
                    val title = plain(fields["title"] ?: "")
                    if (title.isEmpty()) return
                    val body = fields["content:encoded"] ?: fields["description"] ?: fields["summary"] ?: fields["content"] ?: ""
                    val stamp = fields["pubdate"] ?: fields["published"] ?: fields["updated"] ?: fields["dc:date"] ?: ""
                    items.add(NewsItem(title, plain(body), (link ?: fields["link"])?.trim()?.ifEmpty { null }, source, date(stamp)))
                } else if (fields[tag] == null || tag == "content:encoded") fields[tag] = text.toString().trim()
            }
        }
        try {
            val factory = SAXParserFactory.newInstance()
            factory.isNamespaceAware = false
            try { factory.setFeature("http://apache.org/xml/features/nonvalidating/load-external-dtd", false) } catch (e: Exception) {}
            factory.newSAXParser().parse(InputSource(StringReader(data.trimStart('﻿', ' ', '\n', '\r', '\t'))), handler)
        } catch (e: Exception) { /* a feed cut off part-way still gives the items before the break */ }
        return items
    }

    internal fun date(text: String): Double? {
        val value = text.trim()
        if (value.isEmpty()) return null
        try { return Instant.parse(value).toEpochMilli() / 1000.0 } catch (e: Exception) {}
        try { return OffsetDateTime.parse(value).toInstant().toEpochMilli() / 1000.0 } catch (e: Exception) {}
        try { return ZonedDateTime.parse(value, DateTimeFormatter.RFC_1123_DATE_TIME).toInstant().toEpochMilli() / 1000.0 } catch (e: Exception) {}
        for (pattern in listOf("EEE, dd MMM yyyy HH:mm:ss Z", "EEE, dd MMM yyyy HH:mm:ss zzz", "EEE, d MMM yyyy HH:mm:ss zzz", "EEE, dd MMM yyyy HH:mm Z", "yyyy-MM-dd'T'HH:mm:ss.SSSZ")) {
            try { return ZonedDateTime.parse(value, DateTimeFormatter.ofPattern(pattern, Locale.US)).toInstant().toEpochMilli() / 1000.0 } catch (e: Exception) {}
        }
        return null
    }

    // MARK: Text out of HTML

    private val entities = mapOf(
        "amp" to "&", "lt" to "<", "gt" to ">", "quot" to "\"", "apos" to "'", "nbsp" to " ", "mdash" to "-", "ndash" to "-",
        "hellip" to "...", "rsquo" to "'", "lsquo" to "'", "rdquo" to "\"", "ldquo" to "\"", "copy" to "(c)", "deg" to "°",
    )

    fun decodeEntities(text: String): String {
        if (!text.contains('&')) return text
        val out = StringBuilder()
        var i = 0
        while (i < text.length) {
            val amp = text.indexOf('&', i)
            if (amp < 0) { out.append(text, i, text.length); break }
            out.append(text, i, amp)
            val semi = text.indexOf(';', amp + 1)
            if (semi > 0 && semi - amp - 1 <= 8) {
                val name = text.substring(amp + 1, semi)
                val swap: String? = try {
                    if (name.startsWith("#x") || name.startsWith("#X")) cp(name.substring(2).toInt(16))
                    else if (name.startsWith("#")) cp(name.substring(1).toInt())
                    else entities[name]
                } catch (e: Exception) { null }
                if (swap != null) { out.append(swap); i = semi + 1; continue }
            }
            out.append('&'); i = amp + 1
        }
        return out.toString()
    }

    private val options = setOf(RegexOption.IGNORE_CASE, RegexOption.DOT_MATCHES_ALL)
    private val anyTag = Regex("<[^>]+>", options)

    /** One line of plain text from a snippet of HTML. */
    fun plain(html: String): String = TextLayout.clean(decodeEntities(anyTag.replace(html, " ")))

    /**
     * The readable paragraphs of an article page, in order, separated by blank lines. This is a small
     * reader view: it keeps <p> text from the article body and drops scripts, menus and captions.
     */
    fun articleText(html: String): String {
        var page = html
        for (tag in listOf("script", "style", "noscript", "svg", "figure", "nav", "header", "footer", "aside", "form", "button")) {
            page = Regex("<$tag\\b[^>]*>.*?</$tag>", options).replace(page, " ")
        }
        var body = page
        val largest = Regex("<article\\b[^>]*>(.*?)</article>", options).findAll(page).map { it.groupValues[1] }.maxByOrNull { it.length }
        if (largest != null && largest.length > 400) body = largest
        val seen = HashSet<String>()
        return Regex("<p\\b[^>]*>(.*?)</p>", options).findAll(body).mapNotNull { match ->
            val text = plain(match.groupValues[1])
            // short scraps are bylines, captions and buttons, not the story
            if ((text.count >= 60 || (text.count >= 25 && text.endsWith("."))) && seen.add(text)) text else null
        }.joinToString("\n\n")
    }

    // MARK: Cards

    fun age(date: Double?, now: Double): String {
        if (date == null) return ""
        val minutes = ((now - date) / 60).toInt()
        if (minutes < 1) return "now"
        if (minutes < 60) return "${minutes}m"
        if (minutes < 48 * 60) return "${minutes / 60}h"
        return "${minutes / (24 * 60)}d"
    }

    /** One headline: where it's from and how old, the headline, then as much of the summary as fits. */
    fun headlineCard(item: NewsItem, index: Int, count: Int, screen: Screen, now: Double, glyphs: Glyphs = Glyphs.plain): Card {
        val rich = glyphs.style != GlyphStyle.plain
        val age = age(item.date, now)
        val position = if (count > 1) "  ${index + 1}/$count" else ""
        val lines = mutableListOf((if (rich) glyphs.bullet + " " else "") + TextLayout.fit(item.source + (if (age.isEmpty()) "" else "  $age") + position, screen.columns - (if (rich) 3 else 0)))
        lines += TextLayout.wrap(item.title, screen.columns, max(2, screen.rows - 2))
        val room = screen.rows - lines.size
        if (room > 0 && item.summary.isNotEmpty() && item.summary != item.title) {
            if (rich && room > 1) lines.add(glyphs.rule.repeat(min(8, screen.wideColumns)))
            lines += TextLayout.wrap(item.summary, screen.columns, screen.rows - lines.size)
        }
        return Card(lines.take(screen.rows))
    }

    /** A whole story as lines, headline first, for paging. */
    fun articleCard(item: NewsItem, text: String, screen: Screen): Card {
        val body = text.ifEmpty { item.summary }
        return Card(TextLayout.wrap(item.title, screen.columns) + "" + TextLayout.wrap(body, screen.columns) + listOf("", "- end -"), scrolls = true)
    }

    /** Newest first, the same story from two feeds listed once. */
    fun merged(lists: List<List<NewsItem>>, limit: Int = 40): List<NewsItem> {
        val seen = HashSet<String>()
        return lists.flatten().filter { seen.add(it.title.lowercase()) }.sortedByDescending { it.date ?: -Double.MAX_VALUE }.take(limit)
    }
}

object MailText {
    /** Plain text with quoted replies, long links and runs of blank lines taken out. */
    fun tidy(text: String): String {
        val out = ArrayList<String>()
        var blank = false
        for (raw in text.replace("\r\n", "\n").split("\n")) {
            val line = raw.trim(' ', '\t')
            if (line.startsWith(">")) continue
            if (line.startsWith("On ") && line.endsWith("wrote:")) break          // the rest is the message being replied to
            if (line.isEmpty()) { if (!blank && out.isNotEmpty()) out.add(""); blank = true; continue }
            blank = false
            out.add(line.split(" ").filter { it.isNotEmpty() }.joinToString(" ") { w ->
                if ((w.startsWith("http://") || w.startsWith("https://") || w.startsWith("<http")) && w.length > 30) "[link]" else w
            })
        }
        while (out.isNotEmpty() && out.last().isEmpty()) out.removeAt(out.size - 1)
        return out.joinToString("\n")
    }
}

/** One event on its own: what, when, where, and its notes. */
fun Agenda.detailCard(item: AgendaItem, index: Int, count: Int, screen: Screen, now: Double, glyphs: Glyphs = Glyphs.plain, zone: ZoneId = ZoneId.systemDefault()): Card {
    fun dayOf(t: Double) = Instant.ofEpochMilli((t * 1000).toLong()).atZone(zone).toLocalDate()
    val day = if (dayOf(item.start) == dayOf(now)) "Today" else HubClock.day(item.start, zone)
    val lines = mutableListOf((if (glyphs.style != GlyphStyle.plain) glyphs.bullet + " " else "") + "Event ${index + 1}/$count  $day")
    lines += TextLayout.wrap(item.title, screen.columns, 2)
    lines.add(if (item.allDay) "All day" else "${HubClock.time(item.start, zone)} - ${HubClock.time(item.end, zone)}" +
        (if (item.start > now) "  (${HubClock.until(item.start, now)})" else if (item.end > now) "  (now)" else ""))
    val place = item.place
    if (place != null && TextLayout.clean(place).isNotEmpty()) lines += TextLayout.wrap("At $place", screen.columns, 2)
    val notes = item.notes
    if (!notes.isNullOrBlank()) lines += listOf("") + TextLayout.wrap(MailText.tidy(notes), screen.columns)
    return Card(lines, scrolls = lines.size > screen.rows)
}

/** The on-glasses list of apps, with a marker on the one a click would open. */
object AppMenu {
    fun card(title: String = "Apps", titles: List<String>, selected: Int, screen: Screen, glyphs: Glyphs = Glyphs.plain, hint: String? = null): Card {
        if (titles.isEmpty()) return Card(listOf(title))
        // A reminder of the controls takes the bottom line, when there's a line to spare.
        val shown = if (screen.rows >= 4) hint else null
        val room = max(1, screen.rows - (if (shown == null) 1 else 2))
        val start = max(0, min(titles.size - room, selected - room / 2))
        val lines = mutableListOf(title)
        for (i in start until min(titles.size, start + room)) lines.add((if (i == selected) glyphs.next else glyphs.blank) + " " + titles[i])
        if (shown != null) lines.add(shown)
        return Card(lines)
    }
    /** The reminder under the menu: how to move, and how to open, whichever control is set to select. */
    fun hint(select: String?, columns: Int): String? {
        if (select == null) return null
        val full = "Turn: move, $select: open"
        if (TextLayout.measure(full) <= columns * 0.96) return full
        val short = "$select: open"
        return if (TextLayout.measure(short) <= columns * 0.96) short else null
    }
    /** The screen for trying each control, ticking them off as the glasses report them. */
    fun practiceCard(done: List<Boolean>): Card {
        val names = listOf("Turn crown forward", "Turn crown back", "Look up", "Double click crown")
        if (done.size >= names.size && !done.take(names.size).contains(false)) return Card(listOf("Controls check", "All four work.", "You're set."))
        return Card(listOf("Try each control") + names.mapIndexed { i, name -> (if (i < done.size && done[i]) "[x] " else "[ ] ") + name })
    }
    /** Shown after the last item of a list, so there's a way out to the menu. */
    fun endCard(what: String): Card = Card(listOf("End of $what", "Turn: back to the start", "Select: apps menu"))
}
