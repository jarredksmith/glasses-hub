package com.jarredsmith.glasseshub.core

/**
 * Runs one display session on the glasses' caption page, without knowing anything about Bluetooth.
 *
 * The app feeds it what happens (subscribed, a packet arrived, a write finished, time passed) and it
 * answers with what to do next. That keeps every rule about what may be sent in one place that can be
 * tested off the phone:
 *   - nothing is written until the app's own receive channel is on
 *   - one write at a time, and at most one screen per `minInterval`
 *   - only this session's own page is ever stopped
 *   - no retries: a failed write ends the session
 */
class CaptionSession(fontSize: Int = 1, maxLines: Int = 7, sequenceStart: Int? = null) {
    enum class Phase { idle, subscribing, configuring, active, stopping, closed }

    sealed class Action {
        /** Turn on notifications for the glasses' outgoing channel. */
        object Subscribe : Action()
        /** Write this packet. `text` is true for a screen of text (which may need slicing if large). */
        class Write(val packet: ByteArray, val text: Boolean) : Action()
        /** The session is over; let go of the local Bluetooth attachment. */
        data class Release(val reason: String) : Action()
        data class Log(val line: String) : Action()
    }

    var phase = Phase.idle; private set
    var sid = ""; private set
    var fontSize: Int = fontSize.coerceIn(1, 2); private set
    var maxLines: Int = if (fontSize.coerceIn(1, 2) == 1) maxLines.coerceIn(1, 7) else maxLines.coerceIn(1, 5); private set
    /** True once the glasses confirmed the layout. Text is sent either way. */
    var acknowledged = false; private set
    var framesSent = 0; private set
    var lastSentFrame: String? = null; private set
    var closeReason: String? = null; private set

    var minInterval = 1.0
    /** Re-send an unchanged screen this often so the page doesn't go stale. Null turns that off. */
    var refreshInterval: Double? = 30.0
    var finishScrollingText = false
    /** Experiment: send text as original plus translation under this mode number (0 = off). */
    var translationMode = 0

    private var sequence = sequenceStart ?: (32768 + (Math.random() * 32232).toInt())
    private enum class BusyWrite { configure, text, stop, renewStop }
    private var busy: BusyWrite? = null
    private var busySince = 0.0
    private var textAllowedAt = Double.POSITIVE_INFINITY
    private var lastTextAt = Double.NEGATIVE_INFINITY
    private var deadline: Double? = null
    private var wanted: String? = null
    private var wantedScrolls = false
    private var wantedFinished = false
    private var stopQueued = false
    private var renewAt: Double? = null

    val isRunning: Boolean get() = phase == Phase.subscribing || phase == Phase.configuring || phase == Phase.active
    val isOver: Boolean get() = phase == Phase.closed || phase == Phase.idle

    private fun packet(payload: ByteArray): ByteArray {
        val data = GlassesFrame(sequence, CaptionWire.business, payload).encoded()
        sequence = (sequence + 1) and 0xFFFF
        return data
    }

    fun start(now: Double): List<Action> {
        if (phase != Phase.idle && phase != Phase.closed) return emptyList()
        sid = CaptionWire.newSessionID()
        phase = Phase.subscribing; acknowledged = false; framesSent = 0; lastSentFrame = null; closeReason = null
        busy = null; stopQueued = false; textAllowedAt = Double.POSITIVE_INFINITY; lastTextAt = Double.NEGATIVE_INFINITY
        deadline = now + 8
        return listOf(Action.Subscribe)
    }

    fun subscribed(now: Double): List<Action> {
        if (phase != Phase.subscribing) return emptyList()
        phase = Phase.configuring; busy = BusyWrite.configure; busySince = now; deadline = null
        return listOf(Action.Log("Asking the glasses for a $maxLines-line caption page, text size $fontSize."),
            Action.Write(packet(CaptionWire.configure(sid, fontSize, maxLines)), false))
    }

    /**
     * The screen to show. Sent on the next `tick` that the rate limit allows.
     * `scrolls` marks text longer than the page, which is left alone once sent so the crown can scroll it.
     */
    fun show(frame: String, scrolls: Boolean = false, finished: Boolean = false) {
        wanted = frame; wantedScrolls = scrolls; wantedFinished = finished
    }

    fun writeFinished(ok: Boolean, now: Double): List<Action> {
        val kind = busy ?: return emptyList()
        busy = null
        when (kind) {
            BusyWrite.configure -> {
                if (!ok) return close("The glasses didn't accept the setup write.")
                if (phase == Phase.configuring) { phase = Phase.active; textAllowedAt = now + 1.0 }
            }
            BusyWrite.text -> if (!ok) return close("A screen update failed to send.")
            BusyWrite.renewStop -> renewAt = now + 0.9
            BusyWrite.stop -> return close(if (ok) "Display closed." else "The close request failed to send. Hold the crown to leave the page.")
        }
        if (stopQueued) return sendStop(now)
        return emptyList()
    }

    fun received(frame: GlassesFrame, now: Double): List<Action> {
        if (phase == Phase.idle || phase == Phase.closed || frame.business != CaptionWire.business || !frame.isPlain) return emptyList()
        val message = Envelope.decode(frame.payload) ?: return emptyList()
        if (message.dataBytes != 0 || message.json["sid"].str() != sid) return emptyList()
        if (message.type == CaptionWire.stopType) return close("The caption page was closed on the glasses.")
        if (message.type != CaptionWire.acknowledgeType) return emptyList()
        val code = message.int("code")
        if (code != null && code != 1) {
            // The glasses said no (something else owns the screen). Never force it.
            return close("The glasses declined the display (code $code). Close what's open on them and try again.")
        }
        acknowledged = true
        message.json["effective_config"].dict()?.let { config ->
            config["font_size"].int()?.let { if (it in 1..2) fontSize = it }
            config["max_lines"].int()?.let { if (it in 1..7) maxLines = it }
        }
        return listOf(Action.Log("The glasses confirmed: text size $fontSize, $maxLines lines."))
    }

    fun tick(now: Double): List<Action> {
        val due = deadline
        if (due != null && now >= due) {
            deadline = null
            when (phase) {
                Phase.subscribing -> return close("The glasses didn't open a receive channel.")
                Phase.stopping -> return close("No answer to the close request. Hold the crown to leave the page if it's still up.")
                else -> {}
            }
        }
        val at = renewAt
        if (at != null && now >= at && busy == null && phase == Phase.configuring) {
            renewAt = null
            busy = BusyWrite.configure; busySince = now
            return listOf(Action.Write(packet(CaptionWire.configure(sid, fontSize, maxLines)), false))
        }
        if (busy != null && now - busySince > 6) {
            busy = null
            return close("A write to the glasses timed out.")
        }
        val text = wanted
        if (phase != Phase.active || busy != null || now < textAllowedAt || now - lastTextAt < minInterval || text.isNullOrEmpty()) return emptyList()
        val changed = text != lastSentFrame
        val stale = !wantedScrolls && (refreshInterval?.let { now - lastTextAt >= it } ?: false)
        if (!changed && !stale) return emptyList()
        if (text.toByteArray(Charsets.UTF_8).size > CaptionWire.maxTextBytes) {
            lastSentFrame = text          // don't keep retrying an oversized screen
            return listOf(Action.Log("Skipped a screen that was too long to send."))
        }
        busy = BusyWrite.text; busySince = now; lastTextAt = now; lastSentFrame = text; framesSent += 1
        return listOf(Action.Write(packet(CaptionWire.text(sid, text, wantedFinished || (wantedScrolls && finishScrollingText), translationMode)), true))
    }

    /**
     * Start a fresh page session on the glasses in place of the current one. The glasses report the
     * first crown click of each caption session and then go quiet, so a new session after every click
     * keeps clicks coming. `closeFirst` closes the old page before opening the new one.
     */
    fun renew(now: Double, closeFirst: Boolean): List<Action> {
        if (phase != Phase.active || busy != null) return emptyList()
        val old = sid
        sid = CaptionWire.newSessionID()
        phase = Phase.configuring; busySince = now
        lastSentFrame = null; textAllowedAt = Double.POSITIVE_INFINITY
        if (closeFirst) {
            busy = BusyWrite.renewStop
            return listOf(Action.Write(packet(CaptionWire.stop(old)), false))
        }
        busy = BusyWrite.configure
        return listOf(Action.Write(packet(CaptionWire.configure(sid, fontSize, maxLines)), false))
    }

    /** Close this session's page. Safe to call at any point. */
    fun stop(now: Double): List<Action> = when (phase) {
        Phase.idle, Phase.closed, Phase.stopping -> emptyList()
        Phase.subscribing -> close("Stopped before anything was sent.")
        Phase.configuring, Phase.active -> if (busy != null) { stopQueued = true; emptyList() } else sendStop(now)
    }

    /** The Bluetooth link went away underneath the session. */
    fun connectionLost(): List<Action> {
        if (phase == Phase.idle || phase == Phase.closed) return emptyList()
        phase = Phase.closed; busy = null; closeReason = "The glasses disconnected."
        return listOf(Action.Log("The glasses disconnected."))
    }

    private fun sendStop(now: Double): List<Action> {
        stopQueued = false
        phase = Phase.stopping; busy = BusyWrite.stop; busySince = now; deadline = now + 4
        return listOf(Action.Write(packet(CaptionWire.stop(sid)), false))
    }

    private fun close(reason: String): List<Action> {
        phase = Phase.closed; busy = null; deadline = null; stopQueued = false; closeReason = reason
        return listOf(Action.Log(reason), Action.Release(reason))
    }
}
