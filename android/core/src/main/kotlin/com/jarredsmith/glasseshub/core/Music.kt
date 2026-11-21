package com.jarredsmith.glasseshub.core

import kotlin.math.cos
import kotlin.math.exp
import kotlin.math.max
import kotlin.math.min
import kotlin.math.pow
import kotlin.math.sqrt

// MARK: - Chord charts

data class ChordStep(val chord: String, var lyric: String,
                     /** A fingering written into the chart for this chord ("[G:320003]"), instead of the usual one. */
                     val shape: List<Int>? = null) {
    /** Frets from the low E string to the high e; -1 is a string that isn't played. Null when no fingering is known. */
    val frets: List<Int>? get() = shape ?: ChordChart.shape(chord)
}

object ChordChart {
    private val letters = mapOf('C' to 0, 'D' to 2, 'E' to 4, 'F' to 5, 'G' to 7, 'A' to 9, 'B' to 11)
    private val qualities = mapOf(
        "" to listOf(0, 4, 7), "maj" to listOf(0, 4, 7), "m" to listOf(0, 3, 7), "min" to listOf(0, 3, 7), "5" to listOf(0, 7),
        "7" to listOf(0, 4, 7, 10), "maj7" to listOf(0, 4, 7, 11), "M7" to listOf(0, 4, 7, 11), "m7" to listOf(0, 3, 7, 10), "min7" to listOf(0, 3, 7, 10),
        "6" to listOf(0, 4, 7, 9), "m6" to listOf(0, 3, 7, 9), "9" to listOf(0, 2, 4, 7, 10), "add9" to listOf(0, 2, 4, 7), "m9" to listOf(0, 2, 3, 7, 10),
        "sus2" to listOf(0, 2, 7), "sus4" to listOf(0, 5, 7), "sus" to listOf(0, 5, 7), "7sus4" to listOf(0, 5, 7, 10),
        "dim" to listOf(0, 3, 6), "dim7" to listOf(0, 3, 6, 9), "aug" to listOf(0, 4, 8), "+" to listOf(0, 4, 8), "m7b5" to listOf(0, 3, 6, 10),
    )

    /** Root pitch class and what follows it, or null if the text doesn't start with a note name. */
    private fun root(name: String): Pair<Int, String>? {
        val base = letters[name.firstOrNull() ?: return null] ?: return null
        var rest = name.substring(1)
        var root = base
        if (rest.startsWith("#")) { root += 1; rest = rest.substring(1) } else if (rest.startsWith("b")) { root -= 1; rest = rest.substring(1) }
        return root to rest
    }

    /** The notes of a chord as pitch classes (C = 0), or null if the text isn't a chord name. */
    fun notes(chord: String): Set<Int>? {
        val text = chord.trim().substringBefore("/")                       // the bass note doesn't change the chord
        val (root, rest) = root(text) ?: return null
        val shape = qualities[rest] ?: return null
        return shape.map { (it + root).mod(12) }.toSet()
    }

    /** Reads a fingering like "320003" or "x32010" (low E string first). Frets above 9 go in brackets. */
    fun frets(text: String): List<Int>? {
        val out = ArrayList<Int>()
        val s = text.trim()
        var i = 0
        while (i < s.length) {
            val ch = s[i]; i++
            if (ch == 'x' || ch == 'X') out.add(-1)
            else if (ch in '0'..'9') out.add(ch - '0')
            else if (ch == '(') {
                val close = s.indexOf(')', i)
                val fret = if (close > 0) s.substring(i, close).toIntOrNull() else null
                if (fret == null || fret !in 0..24) return null
                out.add(fret); i = close + 1
            } else if (ch == ' ' || ch == '-') continue
            else return null
        }
        return if (out.size == 6) out else null
    }

    private val shapes = mapOf(
        "C" to "x32010", "D" to "xx0232", "E" to "022100", "F" to "133211", "G" to "320003", "A" to "x02220", "B" to "x24442",
        "Am" to "x02210", "Dm" to "xx0231", "Em" to "022000", "Fm" to "133111", "Gm" to "355333", "Bm" to "x24432", "Cm" to "x35543",
        "A7" to "x02020", "B7" to "x21202", "C7" to "x32310", "D7" to "xx0212", "E7" to "020100", "G7" to "320001", "F7" to "131211",
        "Am7" to "x02010", "Dm7" to "xx0211", "Em7" to "022030", "Bm7" to "x24232",
        "Cmaj7" to "x32000", "Dmaj7" to "xx0222", "Emaj7" to "021100", "Fmaj7" to "xx3210", "Gmaj7" to "320002", "Amaj7" to "x02120",
        "Asus2" to "x02200", "Asus4" to "x02230", "Dsus2" to "xx0230", "Dsus4" to "xx0233", "Esus4" to "022200", "Gsus4" to "320013",
        "Cadd9" to "x32030", "Gadd9" to "320203", "E5" to "022xxx", "A5" to "x022xx", "D5" to "xx023x", "G5" to "355xxx",
        "F#m" to "244222", "C#m" to "x46654", "G#m" to "466444", "F#" to "244322", "Bb" to "x13331", "Eb" to "x68886", "Ab" to "466544",
    )

    /** The usual way to finger a chord, or a barre shape worked out from its root. Null for chords it has no shape for. */
    fun shape(chord: String): List<Int>? {
        var name = chord.trim().substringBefore("/")
        for ((long, short) in listOf("min7" to "m7", "min" to "m", "M7" to "maj7")) if (name.endsWith(long)) name = name.dropLast(long.length) + short
        if (name.endsWith("maj") && !name.endsWith("maj7")) name = name.dropLast(3)
        shapes[name]?.let { return frets(it) }
        // a barre chord: the E shape moved up the neck, or the A shape when that would sit too high
        val (root, rest) = root(name) ?: return null
        val fromE = (root - 4).mod(12); val fromA = (root - 9).mod(12)
        val eShapes = mapOf("" to listOf(0, 2, 2, 1, 0, 0), "m" to listOf(0, 2, 2, 0, 0, 0), "7" to listOf(0, 2, 0, 1, 0, 0), "m7" to listOf(0, 2, 0, 0, 0, 0))
        val aShapes = mapOf("" to listOf(-1, 0, 2, 2, 2, 0), "m" to listOf(-1, 0, 2, 2, 1, 0), "7" to listOf(-1, 0, 2, 0, 2, 0), "m7" to listOf(-1, 0, 2, 0, 1, 0))
        val e = eShapes[rest] ?: return null
        val a = aShapes[rest] ?: return null
        if (fromE >= 1 && (fromE <= 7 || fromA == 0)) return e.map { it + fromE }
        return a.map { if (it < 0) -1 else it + fromA }
    }

    /**
     * Reads a chart into the chord changes in order, each with the words sung over it. Takes chords in
     * square brackets inside the words ("[G]Amazing [C]grace") or a line of chords above a line of words.
     */
    fun parse(text: String): List<ChordStep> {
        val steps = ArrayList<ChordStep>()
        fun add(written: String, lyric: String) {
            // "G:320003" names the chord and gives its fingering
            val parts = written.split(":", limit = 2)
            val chord = parts[0]
            val shape = if (parts.size > 1) frets(parts[1]) else null
            val words = lyric.trim()
            val last = steps.lastOrNull()
            if (last != null && last.chord == chord) {
                if (words.isNotEmpty()) last.lyric += (if (last.lyric.isEmpty()) "" else " / ") + words
            } else steps.add(ChordStep(chord, words, shape))
        }
        fun carry(lyric: String) {
            val words = lyric.trim()
            val last = steps.lastOrNull() ?: return
            if (words.isNotEmpty()) last.lyric += (if (last.lyric.isEmpty()) "" else " / ") + words
        }
        var waiting = listOf<String>()            // chords from a chord-only line, for the words on the next line
        for (raw in text.lines()) {
            val line = raw.trim()
            if (line.isEmpty() || line.startsWith("#") || line.startsWith("{")) continue
            if (line.contains("[")) {
                for (chord in waiting) add(chord, "")
                waiting = emptyList()
                var rest = line
                val first = rest.indexOf('[')
                if (first >= 0) { carry(rest.substring(0, first)); rest = rest.substring(first) }
                while (true) {
                    val open = rest.indexOf('[')
                    val close = if (open >= 0) rest.indexOf(']', open) else -1
                    if (open < 0 || close < 0) break
                    val chord = rest.substring(open + 1, close).trim()
                    rest = rest.substring(close + 1)
                    val end = rest.indexOf('[').let { if (it < 0) rest.length else it }
                    if (notes(chord.substringBefore(":")) != null) add(chord, rest.substring(0, end)) else carry(rest.substring(0, end))
                    rest = rest.substring(end)
                }
                continue
            }
            val words = line.split(" ").filter { it.isNotEmpty() }
            if (words.isNotEmpty() && words.all { notes(it) != null }) {
                for (chord in waiting) add(chord, "")
                waiting = words
            } else if (waiting.isNotEmpty()) {
                add(waiting[0], line)
                for (chord in waiting.drop(1)) add(chord, "")
                waiting = emptyList()
            } else carry(line)
        }
        for (chord in waiting) add(chord, "")
        return steps
    }

    data class Song(val id: String, val title: String, val chart: String)

    /** Traditional songs, long out of copyright, with simple open-chord arrangements. */
    val songs = listOf(
        Song("grace", "Amazing Grace", "[G]Amazing grace, how [C]sweet the [G]sound\nThat saved a wretch like [D]me\nI [G]once was lost, but [C]now am [G]found\nWas blind, but [D]now I [G]see"),
        Song("susanna", "Oh! Susanna", "I [C]come from Alabama with my banjo on my [G]knee\nI'm [C]going to Louisiana, my true love [G]for to [C]see\n[F]Oh! Susanna, oh [C]don't you cry for [G]me\nI [C]come from Alabama with my banjo [G]on my [C]knee"),
        Song("auld", "Auld Lang Syne", "Should [G]auld acquaintance [D]be forgot\nAnd [G]never brought to [C]mind\nShould [G]auld acquaintance [D]be forgot\nAnd [Em]days of [C]auld lang [G]syne\nFor [G]auld lang [D]syne, my dear\nFor [G]auld lang [C]syne\nWe'll [G]take a cup of [D]kindness yet\nFor [Em]auld [C]lang [G]syne"),
        Song("swing", "Swing Low, Sweet Chariot", "Swing [D]low, sweet [G]chari[D]ot\nComing for to carry me [A]home\nSwing [D]low, sweet [G]chari[D]ot\nComing for to [A]carry me [D]home"),
        Song("scarborough", "Scarborough Fair", "[Am]Are you going to [G]Scarborough [Am]Fair\n[C]Parsley, [Am]sage, rose[D]mary and [Am]thyme\nRemember [C]me to one who lives [G]there\n[Am]She once [G]was a true love of [Am]mine"),
    )
}

/** How much of each of the twelve notes is sounding, whatever the octave. */
object Chroma {
    /** Twelve values adding up to 1 (C first), and how loud the sound was overall. */
    fun compute(samples: FloatArray, sampleRate: Double): Pair<DoubleArray, Double> {
        val count = samples.size
        if (count < 1024 || sampleRate <= 0) return DoubleArray(12) to 0.0
        val windowed = DoubleArray(count)
        var power = 0.0
        for (i in 0 until count) {
            val value = samples[i].toDouble()
            power += value * value
            windowed[i] = value * (0.5 - 0.5 * cos(2 * Math.PI * i / (count - 1)))
        }
        val chroma = DoubleArray(12)
        for (midi in 40..88) {                                   // the guitar's low E up to the E four octaves above
            val frequency = 440 * 2.0.pow((midi - 69) / 12.0)
            if (frequency >= sampleRate / 2) break
            val coefficient = 2 * cos(2 * Math.PI * frequency / sampleRate)
            var s1 = 0.0; var s2 = 0.0
            for (value in windowed) { val s0 = value + coefficient * s1 - s2; s2 = s1; s1 = s0 }
            chroma[midi % 12] += sqrt(max(0.0, s1 * s1 + s2 * s2 - coefficient * s1 * s2))
        }
        val total = chroma.sum()
        if (total > 0) for (i in 0 until 12) chroma[i] /= total
        return chroma to sqrt(power / count)
    }

    /** How well the sound fits a chord: the share of it on the chord's notes, less the share that's elsewhere. */
    fun score(chroma: DoubleArray, notes: Set<Int>): Double {
        var inside = 0.0
        for (note in notes) if (note in chroma.indices) inside += chroma[note]
        return inside - (1 - inside) * 0.5
    }
}

/** Follows a player through a chord chart, moving on when the next chord is heard. */
class ChordFollower(val steps: List<ChordStep>) {
    var index = 0; private set
    private var streak = 0
    /** Sounds quieter than this are ignored (room noise, fingers on strings). */
    var gate = 0.01

    val finished: Boolean get() = steps.isNotEmpty() && index >= steps.size - 1
    fun step(by: Int) { if (steps.isNotEmpty()) { index = min(steps.size - 1, max(0, index + by)); streak = 0 } }
    fun restart() { index = 0; streak = 0 }

    /** Takes a moment of sound. True when it moved on to the next chord. */
    fun hear(chroma: DoubleArray, level: Double): Boolean {
        val now = steps.getOrNull(index)?.let { ChordChart.notes(it.chord) }
        val next = steps.getOrNull(index + 1)?.let { ChordChart.notes(it.chord) }
        if (now == null || next == null || level < gate || now == next) { streak = 0; return false }
        val ahead = Chroma.score(chroma, next); val here = Chroma.score(chroma, now)
        if (ahead > 0.25 && ahead - here > 0.12) streak += 1 else streak = 0
        if (streak < 2) return false
        index += 1; streak = 0
        return true
    }

    /** How much of the fingering to show: the name only, the six frets on a line, or six tab lines. */
    enum class Style { chord, frets, tab }

    fun card(title: String, listening: Boolean, style: Style = Style.frets, screen: Screen): Card {
        if (steps.isEmpty()) return Card(listOf("Chords", "No chords found.", "Add a chart in the app."))
        val step = steps[min(index, steps.size - 1)]
        val after = steps.getOrNull(index + 1)
        val next = after?.chord ?: "end"
        val status = "${index + 1}/${steps.size}  " + (if (listening) "listening" else "Look up: listen")
        val now = step.frets
        if (style == Style.tab && screen.rows >= 7 && now != null) {
            // six lines, high string on top as tab is written: this chord, then the next one
            val then = after?.frets
            val lines = mutableListOf(TextLayout.fit(step.chord + "  then " + next + "   " + status, screen.columns))
            val names = listOf("e", "B", "G", "D", "A", "E")
            for (row in 0 until 6) {
                val string = 5 - row
                var line = TextLayout.wide(names[row]) + "｜" + cell(now[string])
                if (then != null) line += "－－" + cell(then[string])
                lines.add(line)
            }
            return Card(lines)
        }
        val lines = mutableListOf(TextLayout.wide(step.chord) + "　" + "then " + next)
        if (style != Style.chord && now != null) {
            lines[0] = TextLayout.wide(step.chord) + "　" + TextLayout.wide(fretText(now))
            lines.add(TextLayout.fit("then " + next + (after?.frets?.let { "  " + fretText(it) } ?: ""), screen.columns))
        }
        val room = max(0, screen.rows - lines.size - 1)
        if (step.lyric.isNotEmpty() && room > 0) lines += TextLayout.wrap(step.lyric, screen.columns, room)
        lines.add(TextLayout.fit(status, screen.columns))
        return Card(lines)
    }

    companion object {
        internal fun fretText(frets: List<Int>): String = frets.joinToString("") { if (it < 0) "x" else if (it > 9) "($it)" else "$it" }
        /** One fret as a double-width cell, so tab lines stay in step. */
        internal fun cell(fret: Int?): String = when {
            fret == null -> "　"
            fret < 0 -> "ｘ"
            fret > 9 -> "$fret"
            else -> TextLayout.wide("$fret")
        }
    }
}

// MARK: - Drums

enum class Drum {
    kick, snare, hat, tom;
    val label: String get() = when (this) { kick -> "kick"; snare -> "snare"; hat -> "hi-hat"; tom -> "tom" }
}

/** A groove written on a grid: bars of equal steps, each step naming the drums struck on it. */
data class DrumPattern(val name: String, val bars: List<List<Set<Drum>>>) {
    val steps: Int get() = bars.firstOrNull()?.size ?: 0
    val usesToms: Boolean get() = bars.any { bar -> bar.any { Drum.tom in it } }

    companion object {
        private val labels = mapOf("HH" to Drum.hat, "H" to Drum.hat, "HAT" to Drum.hat, "SD" to Drum.snare, "S" to Drum.snare, "SN" to Drum.snare,
            "BD" to Drum.kick, "K" to Drum.kick, "KD" to Drum.kick, "B" to Drum.kick, "TM" to Drum.tom, "T" to Drum.tom, "TOM" to Drum.tom)

        /** Reads rows like "HH x-x-x-x-", "SD ----o---", "BD o-------", "TM ------oo". A repeated row starts a new bar. */
        fun parse(name: String, text: String): DrumPattern? {
            val bars = ArrayList<Map<Drum, List<Boolean>>>()
            var current = LinkedHashMap<Drum, List<Boolean>>()
            for (raw in text.lines()) {
                val line = raw.trim()
                val space = line.indexOfFirst { it == ' ' || it == '|' || it == ':' }
                if (space < 0) continue
                val drum = labels[line.substring(0, space).uppercase()] ?: continue
                val cells = line.substring(space).filter { it !in " |:" }.map { it !in "-._" }
                if (cells.isEmpty()) continue
                if (current.containsKey(drum)) { bars.add(current); current = LinkedHashMap() }
                current[drum] = cells
            }
            if (current.isNotEmpty()) bars.add(current)
            val length = bars.flatMap { it.values.map { cells -> cells.size } }.maxOrNull() ?: 0
            if (length <= 0 || length > 32) return null
            val built = bars.map { bar -> (0 until length).map { step -> bar.filter { it.value.getOrNull(step) == true }.keys.toSet() } }
            if (built.none { bar -> bar.any { it.isNotEmpty() } }) return null
            return DrumPattern(name, built)
        }

        private fun make(name: String, text: String) = parse(name, text) ?: DrumPattern(name, emptyList())

        /** Standard grooves to learn on, simplest first. */
        val library = listOf(
            make("Kick and snare", "SD ----o-------o---\nBD o-------o-------"),
            make("Basic rock", "HH x-x-x-x-x-x-x-x-\nSD ----o-------o---\nBD o-------o-------"),
            make("Rock, extra kick", "HH x-x-x-x-x-x-x-x-\nSD ----o-------o---\nBD o-------o-o-----"),
            make("Four on the floor", "HH --x---x---x---x-\nSD ----o-------o---\nBD o---o---o---o---"),
            make("Half time", "HH x-x-x-x-x-x-x-x-\nSD --------o-------\nBD o---------o-----"),
            make("Sixteenth hats", "HH xxxxxxxxxxxxxxxx\nSD ----o-------o---\nBD o-------o-o-----"),
            make("Shuffle", "HH x-xx-xx-xx-x\nSD ---o-----o--\nBD o-----o-----"),
            make("Rock with a fill", "HH x-x-x-x-x-x-x-x-\nSD ----o-------o---\nBD o-------o-------\nHH x-x-x-x---------\nSD ----o---oooo----\nTM ------------oooo\nBD o-------o-------"),
        )
    }
}

/** One thing the microphone heard hit: how its energy rose in the low, middle and high ranges. */
data class DrumHit(val time: Double, val rise: List<Double>, val level: Double) {
    /** The rise as shares of the whole, so loud and soft hits compare. */
    val shape: List<Double> get() { val total = rise.sum(); return if (total > 0) rise.map { it / total } else rise }
}

/** Listens to raw audio for drum hits. Feed it buffers in order; it remembers what it needs between them. */
class DrumEar(val sampleRate: Double) {
    private val hop = max(64, (sampleRate * 0.006).toInt())
    private val filters = DoubleArray(6)
    private val sums = DoubleArray(3)
    private var filled = 0
    private val averages = DoubleArray(3)
    private val previous = DoubleArray(3)
    private var hops = 0
    private var lastHit = -1.0
    private var pendingTime = 0.0
    private var pendingRise: DoubleArray? = null
    private var pendingLeft = 0
    /** How far above the recent level a band must jump to count as a hit. */
    var sensitivity = 4.0
    /** Hits quieter than this (as band energy) are ignored. */
    var floor = 1e-5

    private fun alpha(cutoff: Double) = 1 - exp(-2 * Math.PI * cutoff / sampleRate)

    fun process(samples: FloatArray): List<DrumHit> {
        val hits = ArrayList<DrumHit>()
        val aLow = alpha(150.0); val aMidLow = alpha(250.0); val aMidHigh = alpha(2500.0); val aHigh = alpha(6000.0)
        for (sample in samples) {
            val x = sample.toDouble()
            filters[0] += aLow * (x - filters[0]); filters[1] += aLow * (filters[0] - filters[1])              // below ~150 Hz
            filters[2] += aMidLow * (x - filters[2]); filters[3] += aMidHigh * (x - filters[3])                // 250 Hz to 2.5 kHz between these
            filters[4] += aHigh * (x - filters[4]); filters[5] += aHigh * (filters[4] - filters[5])            // above ~6 kHz is what's left
            val low = filters[1]; val mid = filters[3] - filters[2]; val high = x - filters[5]
            sums[0] += low * low; sums[1] += mid * mid; sums[2] += high * high
            filled += 1
            if (filled < hop) continue
            val energy = DoubleArray(3) { sums[it] / hop }
            sums.fill(0.0); filled = 0; hops += 1
            val time = hops.toDouble() * hop / sampleRate
            val rise = DoubleArray(3)
            var fired = false
            for (band in 0 until 3) {
                val jump = energy[band] - previous[band]
                if (energy[band] > floor && energy[band] > averages[band] * sensitivity && jump > 0) { rise[band] = energy[band] - averages[band]; fired = true }
            }
            val open = pendingRise
            if (open != null) {
                // the hit is still building: keep the strongest reading of each band over a few hops
                for (band in 0 until 3) open[band] = max(open[band], max(0.0, energy[band] - averages[band]))
                pendingLeft -= 1
                if (pendingLeft <= 0) { hits.add(DrumHit(pendingTime, open.toList(), sqrt(open.sum()))); pendingRise = null }
            } else if (fired && hops > 20 && time - lastHit > 0.05) {
                pendingTime = time; pendingRise = rise; pendingLeft = 3; lastHit = time
            }
            for (band in 0 until 3) {
                // the running level rises slowly and falls a little faster, so a ringing drum doesn't hide the next hit
                val rate = if (energy[band] > averages[band]) 0.08 else 0.2
                averages[band] += rate * (energy[band] - averages[band])
                previous[band] = energy[band]
            }
        }
        return hits
    }
}

/** Tells drums apart by the shape of their hits. Calibrating to the wearer's own kit replaces the defaults. */
data class DrumKit(val voices: Map<Drum, Voice>,
                   /** True once the voices were learned from the wearer's own kit, so their loudness can be trusted. */
                   val calibrated: Boolean = false) {
    data class Voice(val shape: List<Double>, val level: Double)

    /** The drum, or pair of drums struck together, that best explains a hit. */
    fun identify(hit: DrumHit): Set<Drum> {
        val heard = hit.shape
        val known = Drum.entries.filter { voices[it] != null }
        val options = ArrayList<Set<Drum>>(known.map { setOf(it) })
        for ((i, a) in known.withIndex()) for (b in known.drop(i + 1)) options.add(setOf(a, b))
        var best: Set<Drum> = emptySet()
        var bestDistance = Double.POSITIVE_INFINITY
        fun mixOf(drums: Set<Drum>): DoubleArray {
            val mix = DoubleArray(3)
            for (drum in drums) voices[drum]?.let { voice -> for (band in 0 until 3) mix[band] += voice.shape[band] * voice.level * voice.level }
            return mix
        }
        for (option in options) {
            val mix = mixOf(option)
            val total = mix.sum()
            if (total <= 0) continue
            var distance = 0.0
            for (band in 0 until 3) { val d = mix[band] / total - (heard.getOrNull(band) ?: 0.0); distance += d * d }
            distance += if (option.size > 1) 0.004 else 0.0              // when it's close, one drum is the likelier story
            if (distance < bestDistance) { bestDistance = distance; best = option }
        }
        if (!calibrated) return best
        // A quiet drum under a loud one (a hi-hat with a kick) barely changes the shape. Look instead for
        // energy in its own range beyond what the drums already named would put there.
        val total = hit.rise.sum()
        val expected = mixOf(best)
        val scale = if (expected.sum() > 0) total / expected.sum() else 0.0
        val out = best.toMutableSet()
        for (drum in known) {
            if (drum in out || out.size >= 2) continue
            val voice = voices[drum] ?: continue
            val band = voice.shape.indices.maxByOrNull { voice.shape[it] } ?: continue
            val own = voice.shape[band] * voice.level * voice.level
            val spare = hit.rise[band] - expected[band] * scale
            if (own > 0 && spare > own * 0.3 && hit.rise[band] > expected[band] * scale * 3) out.add(drum)
        }
        return out
    }

    fun toMap(): Map<String, Any?> = mapOf("calibrated" to calibrated, "voices" to voices.entries.associate { it.key.name to mapOf("shape" to it.value.shape, "level" to it.value.level) })

    companion object {
        val standard = DrumKit(mapOf(
            Drum.kick to Voice(listOf(0.85, 0.13, 0.02), 1.0), Drum.snare to Voice(listOf(0.05, 0.55, 0.40), 1.0), Drum.hat to Voice(listOf(0.0, 0.08, 0.92), 0.3)))

        /** A voice learned from a few hits of one drum. */
        fun learn(hits: List<DrumHit>): Voice? {
            if (hits.isEmpty()) return null
            val shape = DoubleArray(3)
            for (hit in hits) { val s = hit.shape; for (band in 0 until 3) shape[band] += (s.getOrNull(band) ?: 0.0) / hits.size }
            return Voice(shape.toList(), hits.sumOf { it.level } / hits.size)
        }

        fun from(map: Map<String, Any?>): DrumKit? {
            val voices = HashMap<Drum, Voice>()
            for ((key, value) in map["voices"].dict() ?: return null) {
                val drum = Drum.entries.firstOrNull { it.name == key } ?: continue
                val shape = value.at("shape").list()?.mapNotNull { it.num() } ?: continue
                if (shape.size == 3) voices[drum] = Voice(shape, value.at("level").num() ?: 1.0)
            }
            return if (voices.isEmpty()) null else DrumKit(voices, map["calibrated"].bool() ?: false)
        }
    }
}

/** Walks a player through a pattern: each right hit moves the marker on, and a finished bar reports the tempo. */
class DrumTrainer(val pattern: DrumPattern) {
    var bar = 0; private set
    var step = firstNote(pattern.bars.firstOrNull() ?: emptyList(), 0) ?: 0; private set
    var wrong = 0; private set
    var tempo: Int? = null; private set
    var laps = 0; private set
    private var barStartTime: Double? = null
    private var barStartStep = 0
    /** Steps to a beat, for working out the tempo: 4 for sixteenths, 3 for a shuffle's triplets. */
    val perBeat: Int get() = if ((pattern.steps % 3 == 0 && pattern.steps % 4 != 0) || pattern.steps == 12) 3 else 4

    val expected: Set<Drum> get() = pattern.bars.getOrNull(bar)?.getOrNull(step) ?: emptySet()

    /** Takes a hit. True when it was the right one and the marker moved. */
    fun hit(heard: Set<Drum>, time: Double): Boolean {
        if (pattern.bars.isEmpty() || expected.isEmpty()) return false
        if (!matches(heard, expected)) { wrong += 1; return false }
        if (barStartTime == null) { barStartTime = time; barStartStep = step }
        val next = firstNote(pattern.bars[bar], step + 1)
        if (next != null) { step = next; return true }
        // end of the bar: tempo from the first note to this one
        val start = barStartTime
        if (start != null && step > barStartStep && time > start) tempo = (60 * ((step - barStartStep).toDouble() / perBeat) / (time - start)).rounded()
        barStartTime = null
        bar += 1
        if (bar >= pattern.bars.size) { bar = 0; laps += 1 }
        step = firstNote(pattern.bars[bar], 0) ?: 0
        return true
    }

    fun card(listening: Boolean, note: String = "", arrows: Boolean, screen: Screen): Card {
        val notes = pattern.bars.getOrNull(bar) ?: return Card(listOf("Drums", "No pattern.", "Pick one in the app."))
        if (note.isNotEmpty()) return Card(listOf("Drums") + TextLayout.wrap(note, screen.columns, max(1, screen.rows - 1)))
        val blank = "　"
        // show the whole bar if it fits beside the two-letter label, else the half the marker is in
        val room = max(4, screen.wideColumns - 2)
        var from = 0
        var to = notes.size
        if (notes.size > room) { val half = (notes.size + 1) / 2; from = if (step < half) 0 else half; to = min(notes.size, from + half) }
        val showToms = pattern.usesToms && screen.rows >= 6
        fun row(label: String, drums: List<Drum>, mark: String): String {
            val line = StringBuilder(TextLayout.wide(label))
            for (i in from until to) {
                if (!showToms && Drum.snare in drums && Drum.tom in notes[i]) line.append("ｔ")
                else line.append(if (drums.any { it in notes[i] }) mark else "－")
            }
            return line.toString()
        }
        var head = pattern.name + (if (pattern.bars.size > 1) "  ${bar + 1}/${pattern.bars.size}" else "")
        tempo?.let { head += "  $it bpm" }
        if (!listening) head = "Look up: start. " + pattern.name
        val lines = mutableListOf(TextLayout.fit(head, screen.columns), row("HH", listOf(Drum.hat), "ｘ"))
        if (showToms) lines.add(row("TM", listOf(Drum.tom), "ｏ"))
        lines.add(row("SD", listOf(Drum.snare), "ｏ"))
        lines.add(row("BD", listOf(Drum.kick), "ｏ"))
        if (screen.rows >= lines.size + 1 && step >= from && step < to) lines.add(blank + blank + blank.repeat(step - from) + (if (arrows) "▲" else "＾"))
        return Card(lines)
    }

    companion object {
        private fun firstNote(bar: List<Set<Drum>>, from: Int): Int? = bar.indices.firstOrNull { it >= from && bar[it].isNotEmpty() }

        /**
         * Whether what was heard will do for what's written. Kick and snare must be there; toms and snare
         * stand in for each other; a lone hi-hat is satisfied by anything that isn't a kick or snare.
         */
        fun matches(heard: Set<Drum>, expected: Set<Drum>): Boolean {
            val body = setOf(Drum.snare, Drum.tom)
            if ((Drum.kick in expected) != (Drum.kick in heard)) return false
            return expected.any { it in body } == heard.any { it in body }
        }
    }
}
