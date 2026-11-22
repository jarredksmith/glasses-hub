package com.jarredsmith.glasseshub

import android.Manifest
import android.annotation.SuppressLint
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.SharedPreferences
import android.content.pm.PackageManager
import android.location.Location
import android.location.LocationListener
import android.location.LocationManager
import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.AudioTrack
import android.media.MediaRecorder
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.provider.CalendarContract
import android.speech.RecognitionListener
import android.speech.RecognizerIntent
import android.speech.SpeechRecognizer
import androidx.compose.runtime.mutableStateOf
import androidx.core.app.NotificationCompat
import com.jarredsmith.glasseshub.core.AgendaItem
import com.jarredsmith.glasseshub.core.Chroma
import com.jarredsmith.glasseshub.core.DrumEar
import com.jarredsmith.glasseshub.core.DrumHit
import com.jarredsmith.glasseshub.core.Json
import com.jarredsmith.glasseshub.core.Metronome
import com.jarredsmith.glasseshub.core.Pitch
import com.jarredsmith.glasseshub.core.at
import com.jarredsmith.glasseshub.core.list
import com.jarredsmith.glasseshub.core.str
import java.io.ByteArrayOutputStream
import java.net.HttpURLConnection
import java.net.URL
import java.time.Instant
import java.time.ZoneId
import java.util.concurrent.Executors
import kotlin.properties.ReadWriteProperty
import kotlin.reflect.KProperty

val mainHandler = Handler(Looper.getMainLooper())
fun granted(context: Context, permission: String) = context.checkSelfPermission(permission) == PackageManager.PERMISSION_GRANTED

// MARK: Saved settings

/** A setting the screens can watch, written to storage whenever it changes. */
class Stored<T>(initial: T, private val save: (T) -> Unit, private val changed: (() -> Unit)? = null) : ReadWriteProperty<Any?, T> {
    private val state = mutableStateOf(initial)
    override fun getValue(thisRef: Any?, property: KProperty<*>): T = state.value
    override fun setValue(thisRef: Any?, property: KProperty<*>, value: T) {
        if (state.value == value) return
        state.value = value
        save(value)
        changed?.invoke()
    }
}

class Settings(val prefs: SharedPreferences) {
    fun bool(key: String, fallback: Boolean, changed: (() -> Unit)? = null) = Stored(prefs.getBoolean(key, fallback), { prefs.edit().putBoolean(key, it).apply() }, changed)
    fun int(key: String, fallback: Int, changed: (() -> Unit)? = null) = Stored(prefs.getInt(key, fallback), { prefs.edit().putInt(key, it).apply() }, changed)
    fun number(key: String, fallback: Double, changed: (() -> Unit)? = null) = Stored(prefs.getFloat(key, fallback.toFloat()).toDouble(), { prefs.edit().putFloat(key, it.toFloat()).apply() }, changed)
    fun text(key: String, fallback: String, changed: (() -> Unit)? = null) = Stored(prefs.getString(key, null) ?: fallback, { prefs.edit().putString(key, it).apply() }, changed)
    fun <E : Enum<E>> choice(key: String, fallback: E, all: List<E>, changed: (() -> Unit)? = null) =
        Stored(all.firstOrNull { it.name == prefs.getString(key, null) } ?: fallback, { prefs.edit().putString(key, it.name).apply() }, changed)
    fun texts(key: String, fallback: List<String>, changed: (() -> Unit)? = null) =
        Stored(prefs.getString(key, null)?.let { Json.parse(it).list()?.mapNotNull { v -> v.str() } } ?: fallback, { prefs.edit().putString(key, Json.encode(it)).apply() }, changed)
    fun json(key: String): Any? = prefs.getString(key, null)?.let { Json.parse(it) }
    fun putJson(key: String, value: Any?) = prefs.edit().putString(key, Json.encode(value)).apply()
}

// MARK: The web

object Http {
    private val pool = Executors.newFixedThreadPool(5)
    const val agent = "GlassesHub/2.0 (personal Android app)"

    class Answer(val bytes: ByteArray?, val problem: String?, val status: Int) {
        val text: String? get() = bytes?.let { String(it, Charsets.UTF_8) }
    }

    /** Asks on a background thread; `done` runs on the main thread. */
    fun get(url: String, headers: Map<String, String> = emptyMap(), limit: Int = 4_000_000, done: (Answer) -> Unit) = send("GET", url, headers, null, limit, done)
    fun post(url: String, headers: Map<String, String>, body: String, done: (Answer) -> Unit) = send("POST", url, headers, body, 4_000_000, done)

    private fun send(method: String, url: String, headers: Map<String, String>, body: String?, limit: Int, done: (Answer) -> Unit) {
        pool.execute {
            val answer = now(method, url, headers, body, limit)
            mainHandler.post { done(answer) }
        }
    }

    fun now(method: String, url: String, headers: Map<String, String>, body: String?, limit: Int = 4_000_000): Answer {
        var connection: HttpURLConnection? = null
        try {
            connection = URL(url).openConnection() as HttpURLConnection
            connection.requestMethod = method
            connection.connectTimeout = 15000; connection.readTimeout = 20000
            connection.instanceFollowRedirects = true
            connection.useCaches = false
            if (headers.keys.none { it.equals("User-Agent", true) }) connection.setRequestProperty("User-Agent", agent)
            for ((key, value) in headers) connection.setRequestProperty(key, value)
            if (body != null) { connection.doOutput = true; connection.outputStream.use { it.write(body.toByteArray(Charsets.UTF_8)) } }
            val status = connection.responseCode
            val stream = if (status in 200..299) connection.inputStream else connection.errorStream
            val out = ByteArrayOutputStream()
            stream?.use { input ->
                val buffer = ByteArray(16384)
                while (true) { val n = input.read(buffer); if (n < 0 || out.size() > limit) break; out.write(buffer, 0, n) }
            }
            if (status in 200..299) return Answer(out.toByteArray(), null, status)
            val problem = when (status) {
                401, 403 -> "The address refused the request. Check the access token."
                404 -> "Not found at that address."
                else -> "The server answered with an error ($status)."
            }
            return Answer(if (out.size() > 0) out.toByteArray() else null, problem, status)
        } catch (e: Exception) {
            return Answer(null, "Couldn't reach that address.", 0)
        } finally { connection?.disconnect() }
    }
}

/** Asks Claude one question and returns its reply. */
object AIClient {
    fun ask(key: String, model: String, system: String, messages: List<Map<String, String>>, done: (String?, String?) -> Unit) {
        val body = Json.encode(mapOf("model" to model, "max_tokens" to 120, "system" to system, "messages" to messages))
        Http.post("https://api.anthropic.com/v1/messages", mapOf("x-api-key" to key, "anthropic-version" to "2026-10-21", "content-type" to "application/json"), body) { answer ->
            val json = answer.text?.let { Json.obj(it) }
            if (answer.status !in 200..299) {
                done(null, when (answer.status) {
                    0 -> "Couldn't reach the AI. Check your connection."
                    401 -> "The AI key was refused. Check it in the app."
                    404 -> "The AI model name wasn't recognised. Check it in the app."
                    else -> json?.get("error").at("message").str()?.let { "AI: $it" } ?: "The AI service answered ${answer.status}."
                })
            } else {
                val text = (json?.get("content").list() ?: emptyList()).mapNotNull { if (it.at("type").str() == "text") it.at("text").str() else null }.joinToString(" ")
                if (text.isEmpty()) done(null, "The AI sent nothing back.") else done(text, null)
            }
        }
    }
}

// MARK: Notifications

class Notifier(private val context: Context) {
    private val manager = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
    private var next = 100

    init {
        manager.createNotificationChannel(NotificationChannel("alerts", "Alerts", NotificationManager.IMPORTANCE_DEFAULT).apply { description = "Scores, timers and other alerts when the glasses' display is off" })
        manager.createNotificationChannel(NotificationChannel("running", "Display running", NotificationManager.IMPORTANCE_LOW).apply { description = "Shown while Glasses Hub is showing on your glasses" })
    }

    val allowed: Boolean get() = (Build.VERSION.SDK_INT < 33 || granted(context, Manifest.permission.POST_NOTIFICATIONS)) && manager.areNotificationsEnabled()

    fun post(title: String, body: String) {
        if (!allowed) return
        val open = PendingIntent.getActivity(context, 0, Intent(context, MainActivity::class.java), PendingIntent.FLAG_IMMUTABLE)
        val note = NotificationCompat.Builder(context, "alerts").setSmallIcon(R.drawable.ic_glasses).setContentTitle(title).setContentText(body)
            .setStyle(NotificationCompat.BigTextStyle().bigText(body)).setContentIntent(open).setAutoCancel(true).build()
        try { manager.notify(next++, note) } catch (e: Exception) {}
        if (next > 140) next = 100
    }
}

// MARK: Calendar

class CalendarReader(private val context: Context) {
    val allowed: Boolean get() = granted(context, Manifest.permission.READ_CALENDAR)

    private fun between(from: Double, to: Double): List<AgendaItem> {
        if (!allowed) return emptyList()
        val out = ArrayList<AgendaItem>()
        try {
            val uri = CalendarContract.Instances.CONTENT_URI.buildUpon().appendPath((from * 1000).toLong().toString()).appendPath((to * 1000).toLong().toString()).build()
            val columns = arrayOf(CalendarContract.Instances.TITLE, CalendarContract.Instances.BEGIN, CalendarContract.Instances.END,
                CalendarContract.Instances.ALL_DAY, CalendarContract.Instances.EVENT_LOCATION, CalendarContract.Instances.DESCRIPTION)
            context.contentResolver.query(uri, columns, null, null, CalendarContract.Instances.BEGIN + " ASC")?.use { rows ->
                while (rows.moveToNext() && out.size < 80) {
                    val allDay = rows.getInt(3) != 0
                    var start = rows.getLong(1) / 1000.0
                    var end = rows.getLong(2) / 1000.0
                    if (allDay) {
                        // all-day events are stored as UTC midnights; move them to the phone's own day
                        val offset = ZoneId.systemDefault().rules.getOffset(Instant.ofEpochMilli(rows.getLong(1))).totalSeconds
                        start -= offset; end -= offset
                    }
                    out.add(AgendaItem(rows.getString(0)?.ifBlank { null } ?: "(no title)", start, end, allDay, rows.getString(4), rows.getString(5)))
                }
            }
        } catch (e: Exception) {}
        return out
    }

    /** From now until the end of today. */
    fun today(now: Double): List<AgendaItem> {
        val zone = ZoneId.systemDefault()
        val end = Instant.ofEpochMilli((now * 1000).toLong()).atZone(zone).toLocalDate().plusDays(1).atStartOfDay(zone).toEpochSecond().toDouble()
        return between(now - 12 * 3600, end).filter { it.end > now && it.start < end }
    }
    fun upcoming(days: Int, now: Double): List<AgendaItem> = between(now, now + days * 86400.0).filter { it.end > now }.sortedBy { it.start }
}

// MARK: Location

@SuppressLint("MissingPermission")
class Locator(private val context: Context) : LocationListener {
    var latitude: Double? = null; private set
    var longitude: Double? = null; private set
    var onMove: (() -> Unit)? = null
    private var on = false
    private val manager = context.getSystemService(Context.LOCATION_SERVICE) as LocationManager

    val denied: Boolean get() = !granted(context, Manifest.permission.ACCESS_FINE_LOCATION) && !granted(context, Manifest.permission.ACCESS_COARSE_LOCATION)

    fun set(wanted: Boolean) {
        if (wanted == on) { if (wanted && denied) { on = false }; return }
        if (wanted) {
            if (denied) return
            on = true
            for (provider in listOf(LocationManager.NETWORK_PROVIDER, LocationManager.GPS_PROVIDER)) {
                try {
                    if (!manager.isProviderEnabled(provider)) continue
                    manager.getLastKnownLocation(provider)?.let { if (latitude == null) onLocationChanged(it) }
                    manager.requestLocationUpdates(provider, 15000L, 25f, this, Looper.getMainLooper())
                } catch (e: Exception) {}
            }
        } else {
            on = false
            try { manager.removeUpdates(this) } catch (e: Exception) {}
        }
    }

    override fun onLocationChanged(location: Location) {
        latitude = location.latitude; longitude = location.longitude
        onMove?.invoke()
    }
    @Deprecated("Needed on older Android") override fun onStatusChanged(provider: String?, status: Int, extras: Bundle?) {}
    override fun onProviderEnabled(provider: String) {}
    override fun onProviderDisabled(provider: String) {}
}

// MARK: Microphone and sound

/** Reads the microphone on its own thread and hands over the samples as they come. */
@SuppressLint("MissingPermission")
class Mic(private val context: Context) {
    private var record: AudioRecord? = null
    @Volatile private var running = false
    var sampleRate = 44100; private set

    /** Starts listening. `onSamples` runs on the microphone's thread. Returns what went wrong, or null. */
    fun start(onSamples: (FloatArray, Int) -> Unit): String? {
        stop()
        if (!granted(context, Manifest.permission.RECORD_AUDIO)) return "Allow the microphone for Glasses Hub in the phone's Settings."
        for (rate in listOf(44100, 48000, 16000)) {
            val size = AudioRecord.getMinBufferSize(rate, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT)
            if (size <= 0) continue
            val made = try { AudioRecord(MediaRecorder.AudioSource.UNPROCESSED.takeIf { Build.VERSION.SDK_INT >= 24 } ?: MediaRecorder.AudioSource.MIC, rate, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT, maxOf(size, 8192)) } catch (e: Exception) { null }
            val usable = made?.takeIf { it.state == AudioRecord.STATE_INITIALIZED }
                ?: run { made?.release(); try { AudioRecord(MediaRecorder.AudioSource.MIC, rate, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT, maxOf(size, 8192)).takeIf { it.state == AudioRecord.STATE_INITIALIZED } } catch (e: Exception) { null } }
            if (usable == null) continue
            record = usable; sampleRate = rate
            break
        }
        val mic = record ?: return "The microphone isn't available."
        try { mic.startRecording() } catch (e: Exception) { mic.release(); record = null; return "Couldn't start the microphone." }
        running = true
        val rate = sampleRate
        Thread({
            val raw = ShortArray(1024)
            while (running) {
                val n = try { mic.read(raw, 0, raw.size) } catch (e: Exception) { -1 }
                if (n <= 0) { if (n < 0) break; continue }
                onSamples(FloatArray(n) { raw[it] / 32768f }, rate)
            }
        }, "hub-mic").start()
        return null
    }

    fun stop() {
        running = false
        val mic = record
        record = null
        try { mic?.stop() } catch (e: Exception) {}
        try { mic?.release() } catch (e: Exception) {}
    }
}

/** The metronome's clicks and the tuner's ear. */
class ToolSound(context: Context) {
    private val mic = Mic(context)
    private var track: AudioTrack? = null
    var onPitch: ((Double?) -> Unit)? = null
    val metronomeOn: Boolean get() = track != null

    fun startMetronome(bpm: Int, beats: Int) {
        stopMetronome()
        val rate = 44100
        val bar = Metronome.bar(bpm, beats, rate.toDouble())
        val pcm = ShortArray(bar.size) { (bar[it] * 32767).toInt().toShort() }
        try {
            val made = AudioTrack.Builder()
                .setAudioAttributes(AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_MEDIA).setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION).build())
                .setAudioFormat(AudioFormat.Builder().setEncoding(AudioFormat.ENCODING_PCM_16BIT).setSampleRate(rate).setChannelMask(AudioFormat.CHANNEL_OUT_MONO).build())
                .setTransferMode(AudioTrack.MODE_STATIC).setBufferSizeInBytes(pcm.size * 2).build()
            made.write(pcm, 0, pcm.size)
            made.setLoopPoints(0, pcm.size, -1)
            made.play()
            track = made
        } catch (e: Exception) { track = null }
    }
    fun stopMetronome() {
        val old = track
        track = null
        try { old?.stop() } catch (e: Exception) {}
        try { old?.release() } catch (e: Exception) {}
    }

    /** Listens for a note. Returns what went wrong, or null. */
    fun startListening(): String? {
        val buffer = FloatArray(4096)
        var filled = 0
        return mic.start { samples, rate ->
            var at = 0
            while (at < samples.size) {
                val take = minOf(samples.size - at, buffer.size - filled)
                System.arraycopy(samples, at, buffer, filled, take)
                filled += take; at += take
                if (filled == buffer.size) {
                    val hz = Pitch.detect(buffer, rate.toDouble())
                    mainHandler.post { onPitch?.invoke(hz) }
                    System.arraycopy(buffer, 2048, buffer, 0, 2048); filled = 2048      // half a window of overlap
                }
            }
        }
    }
    fun stopListening() = mic.stop()
}

/** Listens for chords or drum hits for the music trainers. */
class MusicEar(context: Context) {
    enum class Mode { chords, drums }
    private val mic = Mic(context)
    var onChroma: ((DoubleArray, Double) -> Unit)? = null
    var onHit: ((DrumHit) -> Unit)? = null

    fun start(mode: Mode): String? {
        if (mode == Mode.chords) {
            val buffer = FloatArray(4096)
            var filled = 0
            return mic.start { samples, rate ->
                var at = 0
                while (at < samples.size) {
                    val take = minOf(samples.size - at, buffer.size - filled)
                    System.arraycopy(samples, at, buffer, filled, take)
                    filled += take; at += take
                    if (filled == buffer.size) {
                        val (chroma, level) = Chroma.compute(buffer, rate.toDouble())
                        mainHandler.post { onChroma?.invoke(chroma, level) }
                        System.arraycopy(buffer, 2048, buffer, 0, 2048); filled = 2048
                    }
                }
            }
        }
        var ear: DrumEar? = null
        return mic.start { samples, rate ->
            val listening = ear ?: DrumEar(rate.toDouble()).also { ear = it }
            for (hit in listening.process(samples)) mainHandler.post { onHit?.invoke(hit) }
        }
    }
    fun stop() = mic.stop()
}

/**
 * Turns speech into text with Android's own recogniser, a phrase at a time. The recogniser stops after
 * every phrase, so this starts it again each time for as long as listening is on.
 */
class SpeechListener(private val context: Context) : RecognitionListener {
    private var recognizer: SpeechRecognizer? = null
    private var locale = "en-US"
    var running = false; private set
    /** The phrase so far, as it grows. */
    var onPartial: ((String) -> Unit)? = null
    /** A finished phrase. */
    var onFinal: ((String) -> Unit)? = null
    private var generation = 0

    /** Starts listening in the given language ("es-ES"). Returns what went wrong, or null. */
    fun start(locale: String): String? {
        stop()
        if (!granted(context, Manifest.permission.RECORD_AUDIO)) return "Allow the microphone for Glasses Hub in the phone's Settings."
        if (!SpeechRecognizer.isRecognitionAvailable(context)) return "This phone has no speech recognition service. Install or turn on Google's speech services."
        this.locale = locale
        running = true
        begin()
        return null
    }

    fun stop() {
        if (!running && recognizer == null) return
        running = false; generation += 1
        val old = recognizer
        recognizer = null
        try { old?.cancel() } catch (e: Exception) {}
        try { old?.destroy() } catch (e: Exception) {}
    }

    private fun begin() {
        if (!running) return
        val made = recognizer ?: (try { SpeechRecognizer.createSpeechRecognizer(context) } catch (e: Exception) { null })?.also { it.setRecognitionListener(this); recognizer = it }
        if (made == null) { running = false; return }
        val intent = Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH).apply {
            putExtra(RecognizerIntent.EXTRA_LANGUAGE_MODEL, RecognizerIntent.LANGUAGE_MODEL_FREE_FORM)
            putExtra(RecognizerIntent.EXTRA_LANGUAGE, locale)
            putExtra(RecognizerIntent.EXTRA_PARTIAL_RESULTS, true)
            putExtra(RecognizerIntent.EXTRA_MAX_RESULTS, 1)
            putExtra(RecognizerIntent.EXTRA_CALLING_PACKAGE, context.packageName)
        }
        try { made.startListening(intent) } catch (e: Exception) { again(600) }
    }

    private fun again(afterMs: Long) {
        val mine = generation
        mainHandler.postDelayed({ if (running && mine == generation) begin() }, afterMs)
    }

    private fun best(results: Bundle?): String = results?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)?.firstOrNull()?.trim() ?: ""

    override fun onPartialResults(partialResults: Bundle?) { val text = best(partialResults); if (running && text.isNotEmpty()) onPartial?.invoke(text) }
    override fun onResults(results: Bundle?) {
        val text = best(results)
        if (running && text.isNotEmpty()) { onPartial?.invoke(text); onFinal?.invoke(text) }
        again(60)
    }
    override fun onError(error: Int) {
        // "no speech" and "busy" are routine: start listening again; a recogniser that's stuck is rebuilt
        if (error == SpeechRecognizer.ERROR_RECOGNIZER_BUSY || error == SpeechRecognizer.ERROR_CLIENT) {
            val old = recognizer; recognizer = null
            try { old?.destroy() } catch (e: Exception) {}
            again(500)
        } else again(if (error == SpeechRecognizer.ERROR_NO_MATCH || error == SpeechRecognizer.ERROR_SPEECH_TIMEOUT) 80 else 800)
    }
    override fun onReadyForSpeech(params: Bundle?) {}
    override fun onBeginningOfSpeech() {}
    override fun onRmsChanged(rmsdB: Float) {}
    override fun onBufferReceived(buffer: ByteArray?) {}
    override fun onEndOfSpeech() {}
    override fun onEvent(eventType: Int, params: Bundle?) {}
}

/**
 * Streams the phone's microphone to Soniox's real-time API and hands back its messages, which carry
 * the translation as it forms. Needs the wearer's own Soniox API key and an internet connection; the
 * audio goes to Soniox's servers.
 */
@SuppressLint("MissingPermission")
class CloudTranslator(private val context: Context) {
    private val client by lazy { okhttp3.OkHttpClient.Builder().pingInterval(20, java.util.concurrent.TimeUnit.SECONDS).build() }
    private var socket: okhttp3.WebSocket? = null
    private var record: AudioRecord? = null
    @Volatile private var run = 0
    var running = false; private set
    /** One message from the service, as received. */
    var onMessage: ((String) -> Unit)? = null
    /** The stream ended without being asked to, with the reason. */
    var onDropped: ((String) -> Unit)? = null

    /** Starts listening and translating. Returns what went wrong, or null. */
    fun start(key: String, from: String, to: String, speakers: Boolean): String? {
        stop()
        val trimmed = key.trim()
        if (trimmed.isEmpty()) return "Add your Soniox API key in the app, under Apps > Live translate."
        if (!granted(context, Manifest.permission.RECORD_AUDIO)) return "Allow the microphone for Glasses Hub in the phone's Settings."
        val size = AudioRecord.getMinBufferSize(16000, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT)
        val mic = try { AudioRecord(MediaRecorder.AudioSource.VOICE_RECOGNITION, 16000, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT, maxOf(size, 6400)).takeIf { it.state == AudioRecord.STATE_INITIALIZED } } catch (e: Exception) { null }
            ?: return "The microphone isn't available."
        try { mic.startRecording() } catch (e: Exception) { mic.release(); return "Couldn't start the microphone." }
        run += 1
        val mine = run
        val config = Json.encode(mapOf("model" to "stt-rt-v6", "audio_format" to "s16le", "num_channels" to 1, "sample_rate" to 16000,
            "language_hints" to listOf(from), "enable_endpoint_detection" to true, "enable_speaker_diarization" to speakers,
            "translation" to mapOf("type" to "one_way", "target_language" to to)))
        val request = okhttp3.Request.Builder().url("wss://stt-rt.soniox.com/transcribe-websocket").header("Authorization", "Bearer $trimmed").build()
        val made = client.newWebSocket(request, object : okhttp3.WebSocketListener() {
            override fun onOpen(webSocket: okhttp3.WebSocket, response: okhttp3.Response) { webSocket.send(config) }
            override fun onMessage(webSocket: okhttp3.WebSocket, text: String) { mainHandler.post { if (mine == run && running) onMessage?.invoke(text) } }
            override fun onFailure(webSocket: okhttp3.WebSocket, t: Throwable, response: okhttp3.Response?) {
                val why = if (response?.code == 401 || response?.code == 403) "Soniox didn't accept the API key." else "The connection to Soniox dropped. Check your connection and your API key."
                mainHandler.post { if (mine == run && running) { stop(); onDropped?.invoke(why) } }
            }
            override fun onClosed(webSocket: okhttp3.WebSocket, code: Int, reason: String) { mainHandler.post { if (mine == run && running) { stop(); onDropped?.invoke("Soniox closed the connection.") } } }
        })
        socket = made; record = mic; running = true
        Thread({
            val buffer = ByteArray(3200)                                // a tenth of a second
            while (mine == run) {
                val n = try { mic.read(buffer, 0, buffer.size) } catch (e: Exception) { -1 }
                if (n < 0) break
                if (n > 0) made.send(okio.ByteString.of(*buffer.copyOf(n)))
            }
        }, "hub-translate").start()
        return null
    }

    fun stop() {
        if (!running && socket == null) return
        running = false; run += 1
        val mic = record; record = null
        try { mic?.stop() } catch (e: Exception) {}
        try { mic?.release() } catch (e: Exception) {}
        try { socket?.send("") } catch (e: Exception) {}                 // an empty text frame ends the stream politely
        try { socket?.close(1000, null) } catch (e: Exception) {}
        socket = null
    }
}
