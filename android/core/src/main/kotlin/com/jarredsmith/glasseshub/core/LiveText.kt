package com.jarredsmith.glasseshub.core

import kotlin.math.max
import kotlin.math.min

/** Text handed to Glasses Hub by another app (a translator, a script, a share) to show on the glasses. */
class LiveText {
    var text = ""; private set
    /** Whether the text is a running stream (lines added one after another) or one piece put up whole. */
    var streaming = false; private set

    /** Replace what's showing, or add to the end of it (on a new line). */
    fun show(incoming: String, append: Boolean) {
        val cleaned = incoming.replace("\r\n", "\n")
        text = if (append && text.isNotEmpty()) text + "\n" + cleaned else cleaned
        streaming = append
        if (text.count > limit) text = text.tail(limit)
    }
    fun clear() { text = ""; streaming = false }

    /** How many screens a whole piece of text takes (always 1 for a stream). */
    fun pageCount(screen: Screen): Int = if (streaming) 1 else max(1, TextLayout.pages(TextLayout.wrap(text, screen.columns), screen.rows).size)

    /**
     * A stream shows its newest lines, like captions, with the latest at the bottom. A whole piece of
     * text (a note) shows from its first line, and pages if it's longer than the screen.
     */
    fun card(screen: Screen, page: Int = 0): Card {
        val lines = TextLayout.wrap(text, screen.columns)
        if (lines.isEmpty()) return Card(listOf("Live text", "Waiting for text from", "another app."))
        if (streaming) return Card(lines.takeLast(screen.rows))
        val pages = TextLayout.pages(lines, screen.rows)
        return Card(pages[max(0, min(pages.size - 1, page))])
    }

    companion object { const val limit = 4000 }
}

/**
 * A running caption built from a streaming speech service's messages (Soniox's real-time API):
 * text that's settled, followed by the words still being worked out.
 */
class CloudCaption(
    /** Put "S1:", "S2:" in front of each change of speaker (when the service labels speakers). */
    var labelSpeakers: Boolean = false,
) {
    var settled = ""; private set
    var pending = ""; private set
    private var lastSpeaker = ""

    sealed class Event {
        object Updated : Event()
        object Finished : Event()
        data class Failed(val message: String) : Event()
    }

    val text: String get() = (settled + pending).trim()

    /** Takes one message from the service: newly settled words (sent once) and the current tentative words. */
    fun take(data: String): Event? {
        val obj = Json.obj(data) ?: return null
        obj["error_message"].str()?.let { return Event.Failed(it) }
        val tentative = StringBuilder()
        var speaker = lastSpeaker
        for (token in obj["tokens"].list() ?: emptyList()) {
            val piece = token.at("text").str()
            if (piece.isNullOrEmpty()) continue
            if (piece.startsWith("<") && piece.endsWith(">")) continue           // markers such as <end>
            // With translation on, the words to show are the translated ones; originals are skipped.
            if (token.at("translation_status").str() == "original") continue
            val final = token.at("is_final").bool() ?: false
            var add: String = piece
            val who = token.at("speaker")?.toString() ?: ""
            if (labelSpeakers && who.isNotEmpty() && who != (if (final) lastSpeaker else speaker)) {
                add = "\nS$who: " + piece.trim()
                if (final) lastSpeaker = who
                speaker = who
            }
            if (final) settled += add else tentative.append(add)
        }
        pending = tentative.toString()
        if (settled.count > limit) settled = settled.tail(limit)
        return if (obj["finished"].bool() == true) Event.Finished else Event.Updated
    }

    /** The newest lines that fit, like captions. */
    fun lines(screen: Screen): List<String> = TextLayout.wrap(text, screen.columns).takeLast(screen.rows)

    companion object { const val limit = 3000 }
}
