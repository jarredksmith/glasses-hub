package com.jarredsmith.glasseshub.core

import java.util.Locale
import kotlin.math.abs
import kotlin.math.max
import kotlin.math.min

/** One caption from a subtitle file: when it shows, when it goes, and what it says. */
data class SubtitleCue(val start: Double, val end: Double, val text: String)

/** Reads .srt and .vtt subtitle files. */
object SubtitleFile {
    /** Subtitle files come in whatever encoding their maker's computer used. */
    fun decode(data: ByteArray): String {
        if (data.size >= 2 && ((data[0] == 0xFF.toByte() && data[1] == 0xFE.toByte()) || (data[0] == 0xFE.toByte() && data[1] == 0xFF.toByte()))) return String(data, Charsets.UTF_16)
        val text = String(data, Charsets.UTF_8)
        if (!text.contains('�')) return text                       // not UTF-8 after all: an older Windows file
        return try { String(data, charset("windows-1252")) } catch (e: Exception) { String(data, Charsets.ISO_8859_1) }
    }

    /** "01:02:03,450", "01:02:03.450" or "02:03.450" as seconds. */
    fun seconds(stamp: String): Double? {
        val parts = stamp.trim().replace(",", ".").split(":")
        if (parts.size != 2 && parts.size != 3) return null
        var total = 0.0
        for (part in parts) total = total * 60 + (part.toDoubleOrNull() ?: return null)
        return total
    }

    /** Takes out styling: <i>…</i>, {\an8}, and the spaces they leave behind. */
    fun plain(text: String): String {
        val out = StringBuilder()
        var depth: Char? = null
        for (ch in text) {
            val close = depth
            if (close != null) { if (ch == close) depth = null; continue }
            if (ch == '<') { depth = '>'; continue }
            if (ch == '{') { depth = '}'; continue }
            out.append(ch)
        }
        return out.split(' ').filter { it.isNotEmpty() }.joinToString(" ")
    }

    private val adverts = listOf("opensubtitles", "www.", "http", "subtitles by", "synced and corrected", "osdb")

    fun parse(raw: String): List<SubtitleCue> {
        val lines = raw.replace("\r\n", "\n").replace("\r", "\n").replace("﻿", "").split("\n")
        val cues = ArrayList<SubtitleCue>()
        var i = 0
        while (i < lines.size) {
            val line = lines[i]
            i += 1
            val arrow = line.indexOf("-->")
            if (arrow < 0) continue
            val endStamp = line.substring(arrow + 3).trim().split(" ").firstOrNull() ?: ""
            val start = seconds(line.substring(0, arrow)) ?: continue
            val end = seconds(endStamp) ?: continue
            val text = ArrayList<String>()
            while (i < lines.size && lines[i].isNotBlank() && !lines[i].contains("-->")) { text.add(plain(lines[i])); i += 1 }
            // a file with no blank lines between captions: the next caption's number isn't dialogue
            if (i < lines.size && lines[i].contains("-->") && text.isNotEmpty() && text.last().toIntOrNull() != null) text.removeAt(text.size - 1)
            val joined = text.filter { it.isNotEmpty() }.joinToString("\n")
            val lowered = joined.lowercase()
            if (joined.isEmpty() || end <= start || adverts.any { lowered.contains(it) }) continue
            cues.add(SubtitleCue(start, end, joined))
        }
        return cues.sortedBy { it.start }
    }
}

/** Every spoken word of a film in order, set up so a few words overheard can be found in it. */
class SubtitleIndex(val cues: List<SubtitleCue>) {
    private val words = ArrayList<String>()
    private val wordCue = ArrayList<Int>()
    private val cueFirstWord = ArrayList<Int>()
    private val trigrams = HashMap<String, MutableList<Int>>()

    init {
        for ((n, cue) in cues.withIndex()) {
            cueFirstWord.add(words.size)
            for (word in words(cue.text)) { words.add(word); wordCue.add(n) }
        }
        for (at in 0..(words.size - 3)) trigrams.getOrPut(words[at] + " " + words[at + 1] + " " + words[at + 2]) { ArrayList() }.add(at)
    }

    val wordCount: Int get() = words.size

    /** How many words are spoken between two moments of the film. */
    fun wordsSpoken(from: Double, to: Double): Int {
        var total = 0
        for ((n, cue) in cues.withIndex()) {
            if (cue.start < from || cue.start >= to) continue
            val next = if (n + 1 < cueFirstWord.size) cueFirstWord[n + 1] else words.size
            total += next - cueFirstWord[n]
        }
        return total
    }

    /** Roughly when the word at this place in the film has just been said. */
    private fun spokenAt(at: Int): Double {
        val n = wordCue[at]
        val cue = cues[n]
        val next = if (n + 1 < cueFirstWord.size) cueFirstWord[n + 1] else words.size
        val count = max(1, next - cueFirstWord[n])
        val speech = min(cue.end - cue.start, count * 0.38)
        return cue.start + speech * (at - cueFirstWord[n] + 1) / count
    }

    data class Match(
        /** Where the film is at the moment the last heard word was spoken. */
        val time: Double,
        /** How many overlapping three-word runs agreed. */
        val hits: Int,
    )

    private class Found(val shift: Int, val run: Int, val rare: Boolean)

    /**
     * Finds the last few words heard in the film. `near` is where the film is thought to be: a place close
     * to it is believed on little evidence, a jump elsewhere only when several words in a row line up.
     */
    fun locate(heard: List<String>, near: Double?): Match? {
        val tail = heard.takeLast(14)
        if (tail.size < 3) return null
        // every place a three-word run of what was heard turns up
        val found = ArrayList<Found>()
        for (run in 0..(tail.size - 3)) {
            val places = trigrams[tail[run] + " " + tail[run + 1] + " " + tail[run + 2]] ?: continue
            if (places.size > 40) continue
            for (place in places) found.add(Found(place - run, run, places.size == 1))
        }
        if (found.isEmpty()) return null
        found.sortBy { it.shift }
        var best: Match? = null
        var bestScore = Double.NEGATIVE_INFINITY
        var low = 0
        for (high in found.indices) {
            while (found[high].shift - found[low].shift > 3) low += 1           // a dropped or extra word or two is fine
            val group = found.subList(low, high + 1)
            val runs = group.map { it.run }.toSet().size
            val rare = group.filter { it.rare }.map { it.run }.toSet().size
            val last = group.maxByOrNull { it.run } ?: continue
            val lastWord = min(words.size - 1, last.shift + last.run + 2)
            val trailing = tail.size - 1 - (last.run + 2)                       // words heard since, not in the file
            val time = spokenAt(lastWord) + trailing * 0.3
            val distance = near?.let { abs(time - it) } ?: Double.POSITIVE_INFINITY
            val believed = if (distance <= 8) true else if (distance <= 60) runs >= 2 else runs >= 3 || rare >= 2
            if (!believed) continue
            // more agreement wins; among equals, the place nearest to where the film already is
            val score = runs * 1000.0 - min(distance, 900.0)
            if (score > bestScore) { bestScore = score; best = Match(time, runs) }
        }
        return best
    }

    companion object {
        /**
         * Words as they would be recognised from speech: lower case, no punctuation, and none of the things
         * nobody says, such as [door slams], (LAUGHS), ♪ lyrics marks or "JOHN:" before a line.
         */
        fun words(text: String): List<String> {
            val spoken = StringBuilder()
            var depth: Char? = null
            for (ch in text) {
                val close = depth
                if (close != null) { if (ch == close) depth = null; continue }
                if (ch == '[') { depth = ']'; continue }
                if (ch == '(') { depth = ')'; continue }
                spoken.append(ch)
            }
            val out = ArrayList<String>()
            for (line in spoken.split('\n')) {
                var rest = line
                val colon = rest.indexOf(':')
                if (colon > 0) {                                            // a speaker's name in capitals
                    val name = rest.substring(0, colon)
                    if (name.length <= 24 && name == name.uppercase() && name.any { it.isLetter() }) rest = rest.substring(colon + 1)
                }
                val word = StringBuilder()
                for (ch in rest.lowercase()) {
                    if (ch.isLetterOrDigit()) word.append(ch)
                    else if (ch == '\'' || ch == '’') continue
                    else if (word.isNotEmpty()) { out.add(word.toString()); word.setLength(0) }
                }
                if (word.isNotEmpty()) out.add(word.toString())
            }
            return out
        }
    }
}

/** Follows a film: knows where it is from the dialogue it overhears, and runs on the clock in between. */
class MovieTracker(cues: List<SubtitleCue>) {
    enum class State { waiting, running, held }

    val index = SubtitleIndex(cues)
    var state = State.waiting; private set
    /** Speech recognition and the trip to the glasses both take a moment; captions are shown this much early. */
    var lead = 0.9
    /** Stops the captions when the room has gone quiet although the film should be talking. */
    var holdsWhenQuiet = true
    private var filmAt = 0.0
    private var clockAt = 0.0
    private var lastHeard = 0.0
    var lastLock: Double? = null; private set

    val isEmpty: Boolean get() = index.cues.isEmpty()
    val length: Double get() = index.cues.lastOrNull()?.end ?: 0.0

    /** Where the film is, in seconds from its start. Null until the first line has been recognised. */
    fun position(now: Double): Double? = when (state) {
        State.waiting -> null
        State.held -> filmAt
        State.running -> filmAt + (now - clockAt)
    }

    private fun set(film: Double, now: Double) { filmAt = min(max(0.0, film), length + 5); clockAt = now }

    /** Words from the microphone. True when they moved the captions. */
    fun hear(text: String, now: Double): Boolean {
        val heard = SubtitleIndex.words(text)
        if (heard.isEmpty()) return false
        lastHeard = now
        val here = position(now)
        val match = index.locate(heard, here) ?: return false
        lastLock = now
        if (state != State.running || here == null) { set(match.time, now); state = State.running; return true }
        val off = match.time - here
        if (abs(off) < 1.5) { set(here + off * 0.35, now); return abs(off) > 0.3 }   // ease small corrections in
        set(match.time, now)
        return true
    }

    /** Call now and then: holds the captions when the film seems to have been paused. */
    fun tick(now: Double) {
        val here = position(now) ?: return
        if (state != State.running) return
        if (here > length + 2) { set(length, now); state = State.held; return }
        if (!holdsWhenQuiet || now - lastHeard <= 25) return
        val quietFrom = here - (now - lastHeard)
        if (index.wordsSpoken(quietFrom, here) >= 20) { set(max(0.0, quietFrom + 2), now); state = State.held }
    }

    /** Starts the clock by hand at a point in the film, for when it can't be heard. */
    fun start(film: Double, now: Double) { set(film, now); state = State.running; lastHeard = now }

    fun toggleHold(now: Double) {
        when (state) {
            State.waiting -> start(max(0.0, (index.cues.firstOrNull()?.start ?: 0.0) - lead), now)
            State.running -> { set(position(now) ?: 0.0, now); state = State.held }
            State.held -> { clockAt = now; lastHeard = now; state = State.running }
        }
    }

    /** Moves the captions earlier or later by hand. */
    fun shift(seconds: Double, now: Double) {
        val here = position(now) ?: return
        set(here + seconds, now)
        lastHeard = now
    }

    fun reset() { state = State.waiting; filmAt = 0.0; lastLock = null }

    /** The caption on screen at this moment, if any. */
    fun cue(now: Double): SubtitleCue? {
        if (state == State.waiting) return null
        val t = (position(now) ?: return null) + lead
        var low = 0
        var high = index.cues.size
        while (low < high) {                                                // the last caption starting at or before t
            val mid = (low + high) / 2
            if (index.cues[mid].start <= t) low = mid + 1 else high = mid
        }
        if (low <= 0) return null
        val cue = index.cues[low - 1]
        return if (t < cue.end) cue else null
    }

    fun card(title: String, listening: Boolean, note: String, now: Double, screen: Screen): Card {
        val name = TextLayout.fit(title.ifEmpty { "Movie captions" }, screen.columns)
        if (isEmpty) return Card(listOf("Movie captions") + TextLayout.wrap(note.ifEmpty { "Pick a movie or show in the app." }, screen.columns))
        return when (state) {
            State.waiting -> {
                val what = if (listening) "Listening for the dialogue. Captions start by themselves once it hears a line." else note.ifEmpty { "Select to start listening." }
                Card(listOf(name) + TextLayout.wrap(what, screen.columns, screen.rows - 2) + (if (listening) listOf("Select: start at the first line") else emptyList()))
            }
            State.held -> Card(listOf(name, "Paused at " + clock(position(now) ?: 0.0)) +
                TextLayout.wrap(if (listening) "Carries on when the film does. Select: carry on now." else "Select: carry on.", screen.columns, screen.rows - 2))
            State.running -> {
                val cue = cue(now) ?: return Card(listOf(" "))
                Card(cue.text.split("\n").flatMap { TextLayout.wrap(it, screen.columns) }.takeLast(screen.rows))
            }
        }
    }

    companion object {
        fun clock(seconds: Double): String {
            val s = max(0.0, seconds).toInt()
            return if (s >= 3600) String.format(Locale.US, "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) else String.format(Locale.US, "%d:%02d", s / 60, s % 60)
        }
    }
}
