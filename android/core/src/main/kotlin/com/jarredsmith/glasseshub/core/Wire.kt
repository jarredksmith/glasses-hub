package com.jarredsmith.glasseshub.core

import java.io.ByteArrayOutputStream

// The RayNeo iO wire format, as far as Glasses Hub needs it.
//
// Layout of one packet (all multi-byte numbers big-endian):
//   AA 55 | length (2) | sequence (2) | type (1) | business (1) | payload | CRC-16/XMODEM (2)
// `length` counts sequence, type, business and payload, so a whole packet is length + 6 bytes.
// The CRC covers the same bytes that `length` counts.
//
// Sources: the owner's own Bluetooth captures, and the public protocol notes in Turbo-IO and OpenRayneo.
// This file is an independent implementation of that format; no third-party code is included.

object CRC16 {
    /** CRC-16/XMODEM: polynomial 0x1021, start value 0. */
    fun xmodem(bytes: ByteArray, from: Int = 0, to: Int = bytes.size): Int {
        var crc = 0
        for (i in from until to) {
            crc = crc xor ((bytes[i].toInt() and 0xFF) shl 8)
            repeat(8) { crc = if (crc and 0x8000 != 0) ((crc shl 1) xor 0x1021) and 0xFFFF else (crc shl 1) and 0xFFFF }
        }
        return crc
    }
}

class GlassesFrame(
    val sequence: Int,
    val business: Int,
    val payload: ByteArray,
    /** Low five bits of the type byte. Zero for every packet Glasses Hub sends. */
    val flags: Int = 0,
    /** Bytes of slice information announced by the top three bits of the type byte (zero for whole packets). */
    val sliceBytes: Int = 0,
) {
    /** A whole, unsliced packet: the only kind Glasses Hub reads the payload of. */
    val isPlain: Boolean get() = flags == 0 && sliceBytes == 0

    /** Bytes to put on the wire. Only plain packets are ever encoded. */
    fun encoded(): ByteArray {
        val length = payload.size + 4          // sequence (2) + type + business + payload
        val out = ByteArrayOutputStream(payload.size + 10)
        out.write(0xAA); out.write(0x55); out.write(length shr 8); out.write(length and 0xFF)
        out.write(sequence shr 8); out.write(sequence and 0xFF); out.write(0x00); out.write(business)
        out.write(payload)
        val soFar = out.toByteArray()
        val crc = CRC16.xmodem(soFar, 4)
        out.write(crc shr 8); out.write(crc and 0xFF)
        return out.toByteArray()
    }
}

/**
 * Turns the stream of Bluetooth notifications back into packets. Notifications can split a packet
 * anywhere or carry several at once; bad or oversized data is skipped, never guessed at.
 */
class FrameStreamDecoder(val maxFrameBytes: Int = 8192) {
    private var buffer = ByteArray(0)
    var dropped = 0
        private set

    private fun drop(n: Int) { buffer = buffer.copyOfRange(n, buffer.size) }
    private fun at(i: Int) = buffer[i].toInt() and 0xFF

    fun append(data: ByteArray): List<GlassesFrame> {
        buffer += data
        val frames = ArrayList<GlassesFrame>()
        while (true) {
            // find the AA 55 marker
            var start = 0
            while (start + 1 < buffer.size && !(at(start) == 0xAA && at(start + 1) == 0x55)) start++
            if (start > 0) {
                if (start + 1 >= buffer.size) {
                    // no marker; keep a trailing AA in case 55 comes next
                    val keep = if (buffer.isNotEmpty() && at(buffer.size - 1) == 0xAA) 1 else 0
                    dropped += buffer.size - keep
                    drop(buffer.size - keep)
                    break
                }
                dropped += start
                drop(start)
            }
            if (buffer.size < 4) break
            val total = ((at(2) shl 8) or at(3)) + 6
            if (total < 10 || total > maxFrameBytes) { dropped += 2; drop(2); continue }
            if (buffer.size < total) break
            val crc = (at(total - 2) shl 8) or at(total - 1)
            if (CRC16.xmodem(buffer, 4, total - 2) != crc) { dropped += 2; drop(2); continue }
            val type = at(6)
            val flags = type and 0x1F
            val slice = type shr 5
            val address = if (flags and 0x02 != 0) 1 else 0
            val businessAt = 7 + address + slice
            if (businessAt < total - 2) {
                frames.add(GlassesFrame((at(4) shl 8) or at(5), at(businessAt), buffer.copyOfRange(businessAt + 1, total - 2), flags, slice))
            }
            drop(total)
        }
        if (buffer.size > maxFrameBytes * 2) { dropped += buffer.size; buffer = ByteArray(0) }
        return frames
    }
}

/**
 * The message inside a packet: a tiny Protobuf wrapper around a JSON string.
 *   field 1 = version (always 1), field 2 = message type, field 3 = JSON text, field 4 = binary data
 */
class Envelope private constructor(val type: Int, val json: Map<String, Any?>, val dataBytes: Int) {
    fun int(key: String): Int? = json[key].int()

    companion object {
        fun encode(type: Int, json: Map<String, Any?>): ByteArray {
            val body = Json.encode(json).toByteArray(Charsets.UTF_8)
            val out = ByteArrayOutputStream(body.size + 12)
            out.write(0x08); out.write(0x01); out.write(0x10)
            putVarint(type.toLong(), out)
            out.write(0x1A); putVarint(body.size.toLong(), out); out.write(body)
            return out.toByteArray()
        }

        private fun putVarint(value: Long, out: ByteArrayOutputStream) {
            var n = value
            while (n >= 0x80) { out.write(((n and 0x7F) or 0x80).toInt()); n = n ushr 7 }
            out.write(n.toInt())
        }

        /** Null when the bytes aren't one of these messages. */
        fun decode(a: ByteArray): Envelope? {
            var i = 0
            var version: Long? = null
            var type: Long? = null
            var body: ByteArray? = null
            var binary = 0
            fun varint(): Long? {
                var n = 0L
                var shift = 0
                while (i < a.size && shift < 64) {
                    val b = a[i].toInt() and 0xFF; i++
                    n = n or ((b and 0x7F).toLong() shl shift)
                    if (b < 0x80) return n
                    shift += 7
                }
                return null
            }
            while (i < a.size) {
                val key = varint() ?: return null
                when ((key and 7).toInt()) {
                    0 -> {
                        val v = varint() ?: return null
                        if (key shr 3 == 1L) version = v else if (key shr 3 == 2L) type = v
                    }
                    1 -> i += 8
                    5 -> i += 4
                    2 -> {
                        val n = varint() ?: return null
                        if (n < 0 || n > (a.size - i).toLong()) return null
                        val slice = a.copyOfRange(i, i + n.toInt()); i += n.toInt()
                        if (key shr 3 == 3L) body = slice else if (key shr 3 == 4L) binary = slice.size
                    }
                    else -> return null
                }
                if (i > a.size) return null
            }
            val t = type
            if (version != 1L || t == null || t < 0 || t > 0xFFFFFFFFL) return null
            val json: Map<String, Any?> = if (body != null && body.isNotEmpty()) Json.obj(String(body, Charsets.UTF_8)) ?: return null else emptyMap()
            return Envelope(t.toInt(), json, binary)
        }
    }
}

/**
 * The glasses' Live Captions page, used as a text screen.
 *
 * A session is: configure (7) -> the glasses may answer (8) -> text (5), each one replacing the last ->
 * stop (3). `force` is always false, so Glasses Hub never takes the screen away from something else, and
 * the layout is `temporary`, so the wearer's own caption settings are left alone.
 */
object CaptionWire {
    const val business = 19
    const val configureType = 7
    const val acknowledgeType = 8
    const val textType = 5
    const val stopType = 3
    /** Longest text Glasses Hub will send in one screen. */
    const val maxTextBytes = 3800

    fun newSessionID(): String {
        val bytes = ByteArray(16).also { java.security.SecureRandom().nextBytes(it) }
        return bytes.joinToString("") { String.format("%02x", it.toInt() and 0xFF) }
    }

    fun configure(sid: String, fontSize: Int, maxLines: Int): ByteArray = Envelope.encode(configureType, mapOf(
        "sid" to sid, "force" to false, "scope" to "temporary",
        "config" to mapOf("font_size" to fontSize, "content_width" to 100, "max_lines" to maxLines,
            "position" to "center", "is_display" to true, "straight_view" to "original"),
    ))

    /**
     * `status` 0 marks the text as still changing, which is what makes the next one replace it in place.
     * `finished` marks it as done instead. `translationMode` 0 sends plain text as usual; 1, 2 or 3 send the
     * same text as both the original and its "translation" under that mode number.
     */
    fun text(sid: String, frame: String, finished: Boolean = false, translationMode: Int = 0): ByteArray {
        val content = HashMap<String, Any?>()
        content["source_transcript"] = frame
        if (translationMode > 0) content["target_translation"] = frame
        return Envelope.encode(textType, mapOf(
            "sid" to sid, "mode" to (if (translationMode > 0) translationMode else 3), "status" to (if (finished) 1 else 0), "content" to content,
        ))
    }

    fun stop(sid: String): ByteArray = Envelope.encode(stopType, mapOf("sid" to sid, "reason_code" to 10, "text" to ""))
}

/**
 * Things the glasses announce about themselves, read from their usage reports (channel 15, type 76).
 * The reports aren't meant as a control channel, but on firmware 1.0.6.11 they arrive within about a
 * second of the action, which is fast enough to turn pages with.
 */
class GlassesReport private constructor(val action: Action?, val battery: Int?, val blockedNotification: String?) {
    sealed class Action {
        /** The crown was turned forward at the bottom of the page: the glasses report a scroll that failed. */
        object CrownTurn : Action()
        /** The crown was turned back and the page scrolled up, to this many lines above the bottom. */
        data class CrownBack(val depth: Int) : Action()
        object CrownClick : Action()
        /** The wearer tilted their head up far enough to wake the screen. */
        object HeadRaise : Action()
        /** The wearer held the crown and the glasses left the caption page. */
        object HoldExit : Action()
        object DoubleClick : Action()
    }

    companion object {
        const val business = 15

        fun from(frame: GlassesFrame): GlassesReport? {
            if (frame.business != business || !frame.isPlain) return null
            val message = Envelope.decode(frame.payload) ?: return null
            if (message.json["cmd"].str() != "analytics_log") return null
            // some firmware packs the inner part as JSON inside a string
            fun dict(value: Any?): Map<String, Any?>? = value.dict() ?: value.str()?.let { Json.obj(it) }
            val data = dict(dict(message.json["payload"])?.get("data")) ?: return null
            val extras = dict(data["extras"]) ?: return null
            var action: Action? = null
            if (extras["action_type"].str() == "scroll") {
                val depth = extras["history_depth"].int() ?: 0
                action = if (extras["action_result"].str() == "success" && depth > 0) Action.CrownBack(depth) else Action.CrownTurn
            }
            // A look up while the caption page is showing, reported every time.
            else if (extras["action_type"].str() == "raise_head") action = Action.HeadRaise
            // A crown double click. With the double-click shortcut set to "None" in the RayNeo app it does
            // nothing on the glasses, and they still report every one.
            else if (extras["trigger_action"].str() == "double_click") action = Action.DoubleClick
            else if (extras["event_name"].str() == "KEY_PRESS") action = Action.CrownClick
            else if (extras["exit_type"].str() == "crown_long_press") action = Action.HoldExit
            else if (extras["trigger_source"].str() == "raise_head" && extras["screen_state"].str() == "screen_on") action = Action.HeadRaise
            var battery = extras["battery_level"].int() ?: extras["bat"].int()
            if (battery != null && battery !in 0..100) battery = null
            var blocked: String? = null
            if (extras.containsKey("conflict_app_name") && extras["display_result"].str() == "fail") {
                val pkg = extras["package_name"].str()
                if (!pkg.isNullOrEmpty()) blocked = pkg
            }
            if (action == null && battery == null && blocked == null) return null
            return GlassesReport(action, battery, blocked)
        }
    }
}

/** Plain names for the apps a notification can come from. */
object AppNames {
    private val known = mapOf(
        "com.google.android.apps.messaging" to "Messages", "com.samsung.android.messaging" to "Messages",
        "com.google.android.gm" to "Gmail", "com.google.android.dialer" to "Phone", "com.samsung.android.dialer" to "Phone",
        "com.google.android.calendar" to "Calendar", "com.google.android.apps.maps" to "Google Maps",
        "com.google.android.youtube" to "YouTube", "com.microsoft.office.outlook" to "Outlook",
        "com.microsoft.teams" to "Teams", "com.Slack" to "Slack", "com.discord" to "Discord",
        "com.whatsapp" to "WhatsApp", "com.facebook.orca" to "Messenger", "com.facebook.katana" to "Facebook",
        "com.instagram.android" to "Instagram", "com.twitter.android" to "X", "org.telegram.messenger" to "Telegram",
        "org.thoughtcrime.securesms" to "Signal", "com.snapchat.android" to "Snapchat",
        "com.linkedin.android" to "LinkedIn", "com.zhiliaoapp.musically" to "TikTok",
        "com.amazon.mShop.android.shopping" to "Amazon", "com.ubercab" to "Uber", "com.spotify.music" to "Spotify",
    )
    /** The app's everyday name, or a best guess from the last part of its package name. */
    fun name(bundle: String): String {
        known[bundle]?.let { return it }
        known.entries.firstOrNull { it.key.equals(bundle, ignoreCase = true) }?.let { return it.value }
        val last = bundle.split(".").lastOrNull { it.isNotEmpty() } ?: return "an app"
        return last.substring(0, 1).uppercase() + last.substring(1)
    }
}
