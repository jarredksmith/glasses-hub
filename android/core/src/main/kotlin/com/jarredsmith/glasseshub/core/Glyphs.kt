package com.jarredsmith.glasseshub.core

import kotlin.math.max
import kotlin.math.min

/**
 * How adventurous the screen may be with characters.
 *
 * The glasses' font is undocumented. Plain letters, digits and their double-width forms are known to
 * work. Symbols here are limited to the old GB2312 set, which a Chinese-market display font almost
 * certainly carries. Block shading is one step less certain, so it's its own level.
 */
enum class GlyphStyle {
    plain, symbols, blocks;
    val title: String get() = when (this) {
        plain -> "Plain text only"
        symbols -> "Symbols and lines"
        blocks -> "Symbols plus shaded bars"
    }
}

data class Glyphs(val style: GlyphStyle = GlyphStyle.plain) {
    private val rich: Boolean get() = style != GlyphStyle.plain
    private fun pick(fancy: String, simple: String) = if (rich) fancy else simple

    /** Each of these is one double-width cell in both styles, so tables stay aligned. */
    val live get() = pick("●", "＊")
    val bullet get() = pick("◆", "－")
    val hollow get() = pick("○", "ｏ")
    val star get() = pick("★", "＊")
    val next get() = pick("→", "＞")
    val here get() = pick("◀", "＜")
    val up get() = pick("↑", "＋")
    val down get() = pick("↓", "－")
    val note get() = pick("※", "！")
    val full get() = pick("■", "＃")
    val empty get() = pick("□", "－")
    val rule get() = pick("─", "－")
    val bar get() = pick("│", "｜")
    val blank get() = "　"

    /** A progress bar of double-width cells: ■■■■□□□□ */
    fun meter(fraction: Double, cells: Int): String {
        val n = max(1, cells)
        val filled = max(0, min(n, (fraction * n).rounded()))
        return full.repeat(filled) + empty.repeat(n - filled)
    }

    /** A row of dots showing position in a set: ○○●○○. Falls back to "3/5" when there are too many. */
    fun pager(index: Int, count: Int, maxCells: Int = 8): String {
        if (count <= 1) return ""
        if (count > maxCells) return "${index + 1}/$count"
        return (0 until count).joinToString("") { if (it == index) live else hollow }
    }

    /** A tiny chart, one cell per value. Needs the shaded blocks; null otherwise. */
    fun spark(values: List<Double>): String? {
        if (style != GlyphStyle.blocks || values.isEmpty()) return null
        val low = values.min(); val high = values.max()
        val steps = "▁▂▃▄▅▆▇█"
        return values.joinToString("") { v -> (if (high - low < 0.0001) steps[3] else steps[min(7, (((v - low) / (high - low)) * 7.999).toInt())]).toString() }
    }

    /** One cell that stands for the weather. Symbols when allowed, a double-width letter otherwise. */
    fun weather(code: Int): String {
        val kind = when (code) {
            0, 1 -> "○" to "Ｓ"                  // sun
            2 -> "◎" to "Ｐ"                     // partly cloudy
            3 -> "●" to "Ｃ"                     // cloud
            45, 48 -> "≡" to "Ｆ"                // fog
            in 51..67, in 80..82 -> "∴" to "Ｒ"  // rain
            in 71..77, 85, 86 -> "※" to "Ｎ"     // snow
            in 95..99 -> "▲" to "Ｔ"             // thunder
            else -> "？" to "？"
        }
        return pick(kind.first, kind.second)
    }
    /** The key for those cells, to show once on a weather card. */
    val weatherLegend: String get() = if (rich) "○sun ◎part ●cloud ∴rain ※snow" else "S sun P part C cloud R rain N snow"

    companion object {
        val plain = Glyphs(GlyphStyle.plain)
        /** Every character this style can put on screen, grouped, for the on-glasses test cards. */
        val testPages: List<List<String>> = listOf(
            listOf("Symbols test 1 of 3", "Stars ★ ☆  Dots ● ○ ◎", "Squares ■ □ ◆ ◇", "Triangles ▲ △  Note ※ §", "Arrows → ← ↑ ↓ ◀"),
            listOf("Symbols test 2 of 3", "Lines ─ │ ┌ ┐ └ ┘ ├ ┤ ┬ ┴ ┼", "┌──┬──┐", "│12│34│", "└──┴──┘"),
            listOf("Symbols test 3 of 3", "Weather ○ ◎ ● ≡ ∴ ※ ▲", "Blocks ▁▂▃▄▅▆▇█", "Shade ░ ▒ ▓  Math ± × ÷ ≈ ≤ ≥ ∞", "Degrees ° ℃  Misc № ‰ 〓"),
        )
    }
}

/**
 * Tables that line up. The glasses' ordinary letters vary in width, but double-width characters are all
 * one size, and two ordinary digits take the space of one of them. So a table cell is built from
 * double-width letters and either one double-width digit or a pair of ordinary ones.
 */
object Grid {
    private const val space = 0x3000

    /** Text in table form: letters and symbols double-width, digits paired where there are two together. */
    fun mono(text: String): String {
        val out = StringBuilder()
        val digits = StringBuilder()
        fun flush() {
            var run = digits.toString()
            if (run.length % 2 == 1) { out.append(TextLayout.wide(run.substring(0, 1))); run = run.substring(1) }
            out.append(run)
            digits.setLength(0)
        }
        for (p in text.points()) {
            if (p in '0'.code..'9'.code) digits.appendCodePoint(p) else { flush(); out.append(TextLayout.wide(cp(p))) }
        }
        flush()
        return out.toString()
    }

    /** Width of table text, in double-width cells. A pair of ordinary characters counts as one. */
    fun cells(text: String): Int {
        var halves = 0
        for (p in text.points()) halves += if (p in 32..126 || p == 0xB0) 1 else 2
        return (halves + 1) / 2
    }

    /** One table cell, exactly `width` cells wide. Text that's too long is cut. */
    fun cell(text: String, width: Int, right: Boolean = false): String {
        var body = mono(text)
        while (cells(body) > width && body.isNotEmpty()) body = body.head(body.count - 1)
        val pad = "　".repeat(max(0, width - cells(body)))
        return if (right) pad + body else body + pad
    }

    /** A row from (text, width, right-aligned) cells, with trailing blanks removed to save bytes. */
    fun row(parts: List<Triple<String, Int, Boolean>>): String {
        val line = StringBuilder(parts.joinToString("") { cell(it.first, it.second, it.third) })
        while (line.isNotEmpty() && line[line.length - 1].code == space) line.setLength(line.length - 1)
        return line.toString()
    }
}
