package com.jarredsmith.glasseshub.core

import java.util.Locale
import kotlin.math.abs
import kotlin.math.ceil
import kotlin.math.exp
import kotlin.math.ln
import kotlin.math.max
import kotlin.math.min
import kotlin.math.sin

// MARK: Tuner

/** Finds the pitch in a short stretch of microphone samples. */
object Pitch {
    /**
     * The fundamental frequency in Hz, or null when there's no clear note (silence, noise).
     * Autocorrelation with a normalised difference, searched between `low` and `high` Hz.
     */
    fun detect(samples: FloatArray, sampleRate: Double, low: Double = 60.0, high: Double = 1200.0): Double? {
        val n = samples.size
        if (n < 1024 || sampleRate <= 0) return null
        var energy = 0f
        for (s in samples) energy += s * s
        if (energy / n <= 1e-5f) return null                             // too quiet to call
        val minLag = max(2, (sampleRate / high).toInt())
        val maxLag = min(n / 2, (sampleRate / low).toInt())
        if (maxLag <= minLag + 2) return null
        // cumulative mean normalised difference (the heart of the YIN method)
        val diff = FloatArray(maxLag + 1)
        val window = n - maxLag
        for (lag in 1..maxLag) {
            var sum = 0f
            var i = 0
            while (i < window) { val d = samples[i] - samples[i + lag]; sum += d * d; i++ }
            diff[lag] = sum
        }
        var running = 0f
        val norm = FloatArray(maxLag + 1) { 1f }
        for (lag in 1..maxLag) {
            running += diff[lag]
            norm[lag] = if (running > 0) diff[lag] * lag / running else 1f
        }
        // first dip under the threshold, followed down to its bottom
        var best = -1
        var lag = minLag
        while (lag < maxLag) {
            if (norm[lag] < 0.15f) {
                while (lag + 1 < maxLag && norm[lag + 1] < norm[lag]) lag++
                best = lag; break
            }
            lag++
        }
        if (best <= 0) return null
        // parabolic interpolation between neighbours for a finer estimate
        var refined = best.toDouble()
        if (best > 1 && best < maxLag) {
            val a = norm[best - 1].toDouble(); val b = norm[best].toDouble(); val c = norm[best + 1].toDouble()
            val denom = a - 2 * b + c
            if (abs(denom) > 1e-9) refined += 0.5 * (a - c) / denom
        }
        val hz = sampleRate / refined
        return if (hz in low..high) hz else null
    }
}

data class TunerReading(val hz: Double, val note: String, val octave: Int,
                        /** How far off the note is, in hundredths of a semitone (−50…+50). Negative is flat. */
                        val cents: Int) {
    val inTune: Boolean get() = abs(cents) <= 5

    companion object {
        val names = listOf("C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B")
        fun of(hz: Double, a4: Double = 440.0): TunerReading? {
            if (hz <= 0 || a4 <= 0) return null
            val exact = 69 + 12 * ln(hz / a4) / ln(2.0)                  // MIDI note number
            val nearest = exact.rounded()
            if (nearest !in 12..119) return null
            return TunerReading(hz, names[nearest % 12], nearest / 12 - 1, ((exact - nearest) * 100).rounded())
        }
    }
}

object Tuner {
    fun card(reading: TunerReading?, listening: Boolean, screen: Screen, glyphs: Glyphs = Glyphs.plain): Card {
        if (!listening) return Card(listOf("Tuner", "Look up to start listening", "(uses the phone's microphone)"))
        val r = reading ?: return Card(listOf("Tuner", "Listening…", "Play a note near your phone."))
        val cells = min(21, max(9, (screen.columns - 6) or 1))       // odd, so there's a centre
        val mid = cells / 2
        val at = max(0, min(cells - 1, mid + (r.cents / 50.0 * mid).rounded()))
        val meter = (0 until cells).joinToString("") { if (it == at) "●" else if (it == mid) "|" else "-" }
        // plain letters only: the glasses' font has no flat, sharp or cent signs
        val verdict = if (r.inTune) "In tune" else if (r.cents < 0) "Flat ${-r.cents} cents: tune up" else "Sharp ${r.cents} cents: tune down"
        return Card(listOf("Tuner", "${r.note}${r.octave}   ${String.format(Locale.US, "%.1f", r.hz)} Hz", "b $meter #", verdict))
    }
}

// MARK: Metronome

object Metronome {
    val range = 30..240

    /** One bar of clicks as mono samples, to be played in a loop: a higher click on the first beat. */
    fun bar(bpm: Int, beats: Int, sampleRate: Double): FloatArray {
        val tempo = bpm.coerceIn(range.first, range.last)
        val count = beats.coerceIn(1, 12)
        val perBeat = (sampleRate * 60 / tempo).rounded()
        val out = FloatArray(perBeat * count)
        val length = min(perBeat, (sampleRate * 0.03).toInt())           // a 30 ms tick
        for (beat in 0 until count) {
            val freq = if (beat == 0) 1760.0 else 1175.0
            for (i in 0 until length) {
                val t = i / sampleRate
                out[beat * perBeat + i] = (sin(2 * Math.PI * freq * t) * exp(-t * 140) * 0.9).toFloat()
            }
        }
        return out
    }

    fun tempoName(bpm: Int): String = when {
        bpm < 60 -> "Largo"; bpm < 76 -> "Adagio"; bpm < 108 -> "Andante"
        bpm < 120 -> "Moderato"; bpm < 156 -> "Allegro"; bpm < 176 -> "Vivace"
        else -> "Presto"
    }

    /** `beat` (0-based) is set when the glasses are following the beat: the screen is then two short lines. */
    fun card(bpm: Int, beats: Int, running: Boolean, beat: Int? = null, screen: Screen): Card {
        if (running && beat != null) {
            val dots = (0 until max(1, beats)).joinToString("") { if (it == beat) "●" else "○" }
            return Card(listOf("$bpm BPM   ${beat + 1}", dots))
        }
        return Card(listOf("Metronome", "$bpm BPM   $beats/4", tempoName(bpm), if (running) "● Playing on your phone" else "Stopped",
            "Turn: tempo   Look up: " + (if (running) "stop" else "start")))
    }
}

// MARK: Dice, coin, picker

enum class PickerMode {
    coin, d6, twoD6, d20, list;
    val title: String get() = when (this) {
        coin -> "Coin flip"; d6 -> "One die"; twoD6 -> "Two dice"; d20 -> "D20"; list -> "Pick from my list"
    }
}

data class PickerResult(val mode: PickerMode, val values: List<Int>, val text: String)

object Picker {
    fun options(text: String): List<String> = text.split('\n', ',').map { it.trim() }.filter { it.isNotEmpty() }

    fun roll(mode: PickerMode, options: List<String> = emptyList(), random: (Int) -> Int = { (Math.random() * it).toInt().coerceIn(0, it - 1) }): PickerResult = when (mode) {
        PickerMode.coin -> { val v = random(2); PickerResult(mode, listOf(v), if (v == 0) "Heads" else "Tails") }
        PickerMode.d6 -> { val v = random(6) + 1; PickerResult(mode, listOf(v), "$v") }
        PickerMode.twoD6 -> { val a = random(6) + 1; val b = random(6) + 1; PickerResult(mode, listOf(a, b), "${a + b}") }
        PickerMode.d20 -> { val v = random(20) + 1; PickerResult(mode, listOf(v), "$v") }
        PickerMode.list -> if (options.isEmpty()) PickerResult(mode, emptyList(), "Add options in the app") else { val i = random(options.size); PickerResult(mode, listOf(i), options[i]) }
    }

    /** A die face as three rows of pips. Every cell is a double-width character, so the rows line up. */
    fun face(value: Int): List<String> {
        val on = "●"; val off = "　"
        fun row(a: Boolean, b: Boolean, c: Boolean) = (if (a) on else off) + (if (b) on else off) + (if (c) on else off)
        return when (value) {
            1 -> listOf(row(false, false, false), row(false, true, false), row(false, false, false))
            2 -> listOf(row(true, false, false), row(false, false, false), row(false, false, true))
            3 -> listOf(row(true, false, false), row(false, true, false), row(false, false, true))
            4 -> listOf(row(true, false, true), row(false, false, false), row(true, false, true))
            5 -> listOf(row(true, false, true), row(false, true, false), row(true, false, true))
            else -> listOf(row(true, false, true), row(true, false, true), row(true, false, true))
        }
    }

    fun card(mode: PickerMode, result: PickerResult?, rolling: Boolean, screen: Screen): Card {
        val lines = mutableListOf(mode.title)
        if (rolling) return Card(lines + listOf("", "…"))
        if (result == null || result.mode != mode) {
            val verb = if (mode == PickerMode.coin) "flip" else if (mode == PickerMode.list) "pick" else "roll"
            return Card(lines + listOf("Look up to $verb", "Turn: change what to roll"))
        }
        when (mode) {
            PickerMode.d6 -> for (row in face(result.values.firstOrNull() ?: 1)) lines.add("[$row]")
            PickerMode.twoD6 -> {
                val a = face(result.values.firstOrNull() ?: 1); val b = face(result.values.lastOrNull() ?: 1)
                for (i in 0 until 3) lines.add("[${a[i]}]　[${b[i]}]")
                lines.add("Total " + result.text)
            }
            PickerMode.coin, PickerMode.d20 -> { lines.add(""); lines.add(TextLayout.wide(result.text)) }
            PickerMode.list -> { lines.add(""); lines += TextLayout.wrap(result.text, screen.columns) }
        }
        return Card(lines)
    }
}

// MARK: Speed read

/** Shows text a few words at a time in one spot, so the eyes don't have to move. */
object SpeedRead {
    fun words(text: String): List<String> = text.split(' ', '\n', '\t').filter { it.isNotEmpty() }

    /** Seconds each chunk stays up. Never faster than `floor`, the quickest the glasses are sent screens. */
    fun interval(wpm: Int, chunk: Int, floor: Double = 0.3): Double = max(floor, 60.0 * max(1, chunk) / max(60, wpm))

    /** Words per screen: what was asked for, or more when the speed needs it. */
    fun size(wpm: Int, chunk: Int, floor: Double = 0.3): Int = max(max(1, chunk), ceil(max(60, wpm) * floor / 60 - 1e-9).toInt())

    /** The chunk starting at `index`, kept inside the row width (a long word still gets its own turn). */
    fun chunk(words: List<String>, index: Int, size: Int, width: Int): Pair<String, Int> {
        if (index !in words.indices) return "" to 0
        var text = words[index]
        var count = 1
        while (count < max(1, size) && index + count in words.indices && text.count + 1 + words[index + count].count <= width) {
            text += " " + words[index + count]; count += 1
            if (text.last() in ".!?") break                                 // let a sentence end land on its own
        }
        return text to count
    }

    fun card(words: List<String>, index: Int, size: Int, playing: Boolean, wpm: Int, screen: Screen): Card {
        if (words.isEmpty()) return Card(listOf("Speed read", "Paste some text in the app,", "under Apps > Reader."))
        if (index >= words.size) return Card(listOf("Speed read", "The end.", "Look up to start over"))
        val piece = chunk(words, index, size, screen.columns).first
        val pad = " ".repeat(max(0, (screen.columns - piece.count) / 2))
        val done = index.toDouble() / words.size
        val status = (if (playing) "$wpm wpm" else "Paused") + "  " + TextLayout.bar(done, 8) + " ${(done * 100).toInt()}%"
        val rows = screen.rows
        val lines = MutableList(max(3, rows)) { "" }
        lines[0] = status
        lines[min(rows - 1, max(1, rows / 2))] = pad + piece
        return Card(lines)
    }
}
