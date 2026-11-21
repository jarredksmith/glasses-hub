package com.jarredsmith.glasseshub.core

import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.util.Locale
import kotlin.math.abs
import kotlin.math.ceil
import kotlin.math.floor
import kotlin.math.max
import kotlin.math.min

/** The code points of a string: one entry per character as the glasses see it. */
fun String.points(): IntArray = codePoints().toArray()
fun cp(point: Int): String = String(Character.toChars(point))
/** How many characters, counting an emoji or other wide character as one. */
val String.count: Int get() = codePointCount(0, length)
/** The first `n` characters. */
fun String.head(n: Int): String {
    if (n <= 0) return ""
    val pts = points()
    return if (pts.size <= n) this else String(pts, 0, n)
}
fun String.dropHead(n: Int): String {
    val pts = points()
    return if (n >= pts.size) "" else String(pts, n, pts.size - n)
}
fun String.tail(n: Int): String {
    val pts = points()
    return if (pts.size <= n) this else String(pts, pts.size - n, n)
}

/**
 * The two text sizes the caption page offers. Rows and grid widths were measured by the OpenRayneo
 * project on stock firmware; `columns` (ordinary text per row) is a safe starting point the wearer can
 * tune, because the glasses' Latin letters aren't all the same width.
 */
enum class TextSize {
    small, large;
    val fontSize: Int get() = if (this == small) 1 else 2
    val rows: Int get() = if (this == small) 7 else 5
    /** Double-width ("full-width") characters that fit on a row. */
    val wideColumns: Int get() = if (this == small) 26 else 20
    val defaultColumns: Int get() = if (this == small) 44 else 34
    val title: String get() = if (this == small) "Small (7 lines)" else "Large (5 lines)"
}

data class Screen(val rows: Int, val columns: Int, val wideColumns: Int) {
    companion object {
        fun of(rows: Int, columns: Int, wideColumns: Int) = Screen(max(1, rows), max(12, columns), max(6, wideColumns))
        fun of(size: TextSize, columns: Int? = null) = of(size.rows, columns ?: size.defaultColumns, size.wideColumns)
    }
}

/** What an app wants on the glasses: a few lines, already fitted to the screen. */
data class Card(var lines: List<String>, val scrolls: Boolean = false) {
    fun text(rows: Int): String = (if (scrolls) lines else lines.take(rows)).joinToString("\n")
    val isEmpty: Boolean get() = lines.all { it.isBlank() }
}

object TextLayout {
    private val replacements = mapOf(
        0x2018 to "'", 0x2019 to "'", 0x201C to "\"", 0x201D to "\"", 0x2013 to "-", 0x2014 to "-",
        0x2026 to "...", 0x00A0 to " ", 0x2022 to "-", 0x00D7 to "x", 0x2212 to "-", 0x00B0 to "°",
        0x09 to " ",
    )
    private fun isNewline(p: Int) = p == 0x0A || p == 0x0D || p == 0x0B || p == 0x0C || p == 0x85 || p == 0x2028 || p == 0x2029

    /** One tidy line: plain punctuation, single spaces, no control characters or emoji. */
    fun clean(text: String): String {
        val out = StringBuilder()
        var lastWasSpace = true
        fun append(p: Int) {
            if (p == ' '.code) { if (lastWasSpace) return; lastWasSpace = true } else lastWasSpace = false
            out.appendCodePoint(p)
        }
        for (p in text.points()) {
            val swap = replacements[p]
            if (swap != null) { for (c in swap.points()) append(c); continue }
            if (isNewline(p)) { append(' '.code); continue }
            if (p < 32 || p == 127) continue
            // emoji and other picture characters: the glasses' font has no shapes for them
            if (p >= 0x1F000 || (p in 0x2600..0x27BF && p != 0x2605 && p != 0x2606) || p in 0xFE00..0xFE0F) continue
            append(p)
        }
        while (out.isNotEmpty() && out[out.length - 1] == ' ') out.setLength(out.length - 1)
        return out.toString()
    }

    /**
     * How wide a character is on the glasses, in units of an average character of ordinary English text.
     * The glasses draw Latin text in a proportional font, so a line's width is the sum of these, not its
     * character count. Double-width characters (symbols, CJK, the full-width space) take about two units.
     */
    fun unitWidth(p: Int): Double = when (p.toChar().takeIf { p < 0x80 }) {
        ' ' -> 0.6
        'i', 'l', 'j', '\'', '|', '.', ',', ':', ';', '!' -> 0.52
        'f', 't', 'r', 'I' -> 0.67
        '-', '(', ')', '[', ']', '/', '\\', '"' -> 0.72
        'm', 'M' -> 1.8
        'w' -> 1.57
        'W' -> 2.04
        'G', 'O', 'Q' -> 1.7
        'C', 'D', 'H', 'N', 'R', 'U' -> 1.57
        'A', 'B', 'E', 'K', 'P', 'S', 'V', 'X', 'Y' -> 1.46
        'F', 'L', 'T', 'Z' -> 1.33
        'J' -> 1.09
        else -> when {
            // Latin, including the accented letters of Vietnamese and other European languages
            p in 0x300..0x36F -> 0.0           // accents that sit on the letter before
            p < 0x250 || p in 0x1E00..0x1EFF -> 1.2
            else -> 2.17
        }
    }

    const val blank = "　"
    private const val blankPoint = 0x3000

    /** The width of a line, in average characters. */
    fun measure(text: String): Double { var w = 0.0; for (p in text.points()) w += unitWidth(p); return w }
    private fun limit(width: Int): Double = max(4, width) * 0.96

    /**
     * Moves lines toward the middle of the row by putting full-width blanks in front of them. With `each`,
     * every line is centred on its own; otherwise the whole block moves together. Tables, grids and lists
     * always move as a block, so their columns stay lined up.
     */
    fun centered(lines: List<String>, width: Int, each: Boolean): List<String> {
        val room = max(4, width) * 0.92
        val step = unitWidth(blankPoint)
        fun isBlank(line: String) = line.points().all { it == ' '.code || it == blankPoint }
        fun pad(wide: Double) = max(0, ((room - wide) / 2 / step).toInt())
        fun isGridRow(line: String): Boolean {
            val pts = line.points()
            if (pts.isEmpty()) return false
            if (pts[0] == blankPoint) return true
            val marks = pts.count { it in 0xFF00..0xFFEF || it in 0x2500..0x259F }
            return marks >= 3 && marks * 2 >= pts.size
        }
        val table = lines.count { isGridRow(it) } >= 2
        if (each && !table) return lines.map { if (isBlank(it)) it else blank.repeat(pad(measure(it))) + it }
        val widest = lines.filter { !isBlank(it) }.maxOfOrNull { measure(it) } ?: 0.0
        val lead = blank.repeat(pad(widest))
        return lines.map { if (isBlank(it)) it else lead + it }
    }

    /** Pushes a short line to the right-hand edge with full-width blanks in front of it. */
    fun rightAligned(line: String, width: Int): String {
        val room = max(4, width) * 0.92
        val blanks = max(0, ((room - measure(line)) / unitWidth(blankPoint)).toInt())
        return blank.repeat(blanks) + line
    }

    /** Break text into lines that fit a row `width` average characters wide, at spaces where possible. */
    fun wrap(text: String, width: Int): List<String> {
        val room = limit(width)
        val lines = ArrayList<String>()
        for (paragraph in text.split('\n', '\r', '\u000B', '\u000C', '\u0085', ' ', ' ')) {
            val cleaned = clean(paragraph)
            if (cleaned.isEmpty()) { if (lines.isNotEmpty() && lines.last().isNotEmpty()) lines.add(""); continue }
            var line = StringBuilder()
            var used = 0.0
            for (word in cleaned.split(' ')) {
                if (word.isEmpty()) continue
                val w = measure(word)
                val gap = if (line.isEmpty()) 0.0 else unitWidth(' '.code)
                if (used + gap + w <= room) {
                    if (line.isNotEmpty()) line.append(' ')
                    line.append(word); used += gap + w
                    continue
                }
                if (line.isNotEmpty()) { lines.add(line.toString()); line = StringBuilder(); used = 0.0 }
                if (w <= room) { line.append(word); used = w; continue }
                for (p in word.points()) {                        // one very long word: cut it where the row ends
                    val c = unitWidth(p)
                    if (used + c > room && line.isNotEmpty()) { lines.add(line.toString()); line = StringBuilder(); used = 0.0 }
                    line.appendCodePoint(p); used += c
                }
            }
            if (line.isNotEmpty()) lines.add(line.toString())
        }
        while (lines.isNotEmpty() && lines.last().isEmpty()) lines.removeAt(lines.size - 1)
        return lines
    }

    /** Cut a line to `width`, ending in ".." when something was lost. */
    fun fit(text: String, width: Int): String {
        val line = clean(text)
        if (line.count <= width) return line
        if (width <= 2) return line.head(width)
        return line.head(width - 2).trim(' ') + ".."
    }

    /** Wrap to at most `maxLines` lines; the last one ends in ".." if text was left over. */
    fun wrap(text: String, width: Int, maxLines: Int): List<String> {
        val all = wrap(text, width)
        if (all.size <= maxLines || maxLines <= 0) return all
        val kept = all.take(maxLines).toMutableList()
        var last = kept[maxLines - 1]
        while (measure("$last..") > limit(width) && last.isNotEmpty()) last = last.head(last.count - 1)
        kept[maxLines - 1] = last.trim(' ') + ".."
        return kept
    }

    /** "[#####-----]" */
    fun bar(fraction: Double, cells: Int = 10): String {
        val filled = max(0, min(cells, (fraction * cells).rounded()))
        return "[" + "#".repeat(filled) + "-".repeat(cells - filled) + "]"
    }

    /**
     * Printable ASCII as double-width characters. They're twice as wide on the glasses, so a short line
     * reads as a headline, and they are all the same width, so columns line up.
     */
    fun wide(text: String): String {
        val out = StringBuilder()
        for (p in text.points()) out.appendCodePoint(if (p == 32) 0x3000 else if (p in 33..126) p + 0xFEE0 else p)
        return out.toString()
    }

    /** A headline: double-width when it fits the row, ordinary text when it doesn't. */
    fun headline(text: String, screen: Screen): String {
        val line = clean(text)
        val ascii = line.points().all { it in 32..126 || it == 0xB0 }
        return if (ascii && line.count <= screen.wideColumns) wide(line) else fit(line, screen.columns)
    }

    /**
     * A screenful with one extra line above it, so the caption page has something to scroll back to.
     * The glasses show the last `rows` lines, so what the wearer sees is unchanged; but a turn of the crown
     * backwards now scrolls and is reported as such, where a turn forwards at the bottom is reported as
     * failing. That difference is how the app tells the two apart.
     */
    fun withScrollRoom(lines: List<String>, rows: Int, marker: String): List<String> {
        val shown = lines.take(rows)
        val free = rows - shown.size
        return listOf(marker) + List(free / 2) { blank } + shown + List(free - free / 2) { blank }
    }

    /** Split lines into pages of `rows`, each page ending "(2/5)" style when there is more than one. */
    fun pages(lines: List<String>, rows: Int): List<List<String>> {
        if (lines.size <= rows || rows <= 1) return listOf(lines)
        val body = rows - 1
        val count = ceil(lines.size.toDouble() / body).toInt()
        return (0 until count).map { page -> lines.subList(page * body, min(lines.size, (page + 1) * body)) + "(${page + 1}/$count)" }
    }
}

/** Rounds half away from zero, as the iPhone app does. */
fun roundHalfUp(x: Double): Double = if (x >= 0) floor(x + 0.5) else -floor(-x + 0.5)
fun Double.rounded(): Int = roundHalfUp(this).toInt()

/** The line of timekeeping a speaker sees while reading from the glasses. */
object ReaderClock {
    /** What the line shows: nothing, the time of day, time since starting, both, or time left of a target. */
    enum class Mode {
        off, clock, elapsed, both, countdown, clockCountdown;
        val usesTimer: Boolean get() = this != off && this != clock
        val countsDown: Boolean get() = this == countdown || this == clockCountdown
    }

    /** Minutes and seconds, with hours once there are any: "3:05", "1:02:09". */
    fun span(seconds: Double): String {
        val total = max(0, floor(seconds).toInt())
        val h = total / 3600; val m = (total % 3600) / 60; val s = total % 60
        return if (h > 0) String.format(Locale.US, "%d:%02d:%02d", h, m, s) else String.format(Locale.US, "%d:%02d", m, s)
    }

    /** `now` and `started` are seconds since 1970. */
    fun line(mode: Mode, now: Double, started: Double, targetMinutes: Int, page: Int, pages: Int, zone: ZoneId = ZoneId.systemDefault()): String {
        val elapsed = now - started
        val parts = ArrayList<String>()
        when (mode) {
            Mode.off -> return ""
            Mode.clock -> parts.add(HubClock.time(now, zone))
            Mode.elapsed -> parts.add(span(elapsed))
            Mode.both -> { parts.add(HubClock.time(now, zone)); parts.add(span(elapsed)) }
            Mode.countdown, Mode.clockCountdown -> {
                if (mode == Mode.clockCountdown) parts.add(HubClock.time(now, zone))
                val left = max(1, targetMinutes) * 60.0 - elapsed
                parts.add(if (left >= 0) span(left) + " left" else "+" + span(-left) + " over")
            }
        }
        if (pages > 1) parts.add("$page/$pages")
        return parts.joinToString("  ")
    }
}

/** Times are seconds since 1970 throughout. */
object HubClock {
    private fun format(pattern: String, at: Double, zone: ZoneId): String =
        DateTimeFormatter.ofPattern(pattern, Locale.US).withZone(zone).format(Instant.ofEpochMilli((at * 1000).toLong()))
            .replace("am", "AM").replace("pm", "PM").replace("a.m.", "AM").replace("p.m.", "PM")
    fun time(at: Double, zone: ZoneId = ZoneId.systemDefault()): String = format("h:mm a", at, zone)
    fun day(at: Double, zone: ZoneId = ZoneId.systemDefault()): String = format("EEE MMM d", at, zone)
    fun weekdayTime(at: Double, zone: ZoneId = ZoneId.systemDefault()): String = format("EEE h:mm a", at, zone)
    /** "in 25 min", "in 2 hr", "now" */
    fun until(date: Double, now: Double): String {
        val minutes = ((date - now) / 60).rounded()
        if (minutes <= 0) return "now"
        if (minutes < 90) return "in $minutes min"
        val hours = (minutes / 60.0).rounded()
        return if (hours < 36) "in $hours hr" else "in ${(hours / 24.0).rounded()} days"
    }
    fun now(): Double = System.currentTimeMillis() / 1000.0
}
