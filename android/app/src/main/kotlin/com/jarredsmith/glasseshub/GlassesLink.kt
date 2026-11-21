package com.jarredsmith.glasseshub

import android.Manifest
import android.annotation.SuppressLint
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothGatt
import android.bluetooth.BluetoothGattCallback
import android.bluetooth.BluetoothGattCharacteristic
import android.bluetooth.BluetoothGattDescriptor
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothProfile
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import com.jarredsmith.glasseshub.core.CaptionSession
import com.jarredsmith.glasseshub.core.CaptionWire
import com.jarredsmith.glasseshub.core.Envelope
import com.jarredsmith.glasseshub.core.FrameStreamDecoder
import com.jarredsmith.glasseshub.core.GlassesFrame
import com.jarredsmith.glasseshub.core.GlassesReport
import com.jarredsmith.glasseshub.core.Json
import com.jarredsmith.glasseshub.core.TextSize
import com.jarredsmith.glasseshub.core.str
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.UUID

/**
 * The Bluetooth side of the display.
 *
 * Glasses Hub doesn't pair with the glasses or sign in to them. It joins the connection the RayNeo app
 * already has (Android lets apps share one), opens its own caption page and writes text to it. Everything
 * about what gets written lives in `CaptionSession`; this class only moves bytes.
 *
 * Things it never does: scan, pair, send the RayNeo sign-in handshake, change settings on the glasses,
 * turn the glasses' notifications channel off, or close anything it didn't open.
 */
@SuppressLint("MissingPermission")
class GlassesLink(private val context: Context) {
    enum class State { off, looking, connecting, opening, showing, closing, standby }

    var state by mutableStateOf(State.off); private set
    var status by mutableStateOf("Display is off."); private set
    val log = mutableStateListOf<String>()
    var rows by mutableIntStateOf(7); private set
    var framesSent by mutableIntStateOf(0); private set
    var glassesName by mutableStateOf(""); private set
    /** The glasses' battery, when they've mentioned it. */
    var battery by mutableStateOf<Int?>(null); private set

    /** The crown was turned forward (+1), turned back (-1) or clicked (0) while this app's page was up. */
    var onCrown: ((Int) -> Unit)? = null
    /** The wearer held the crown, which makes the glasses leave the page. Return true to reopen it. */
    var onHoldExit: (() -> Boolean)? = null
    var onDoubleClick: (() -> Unit)? = null
    var onHeadRaise: (() -> Unit)? = null
    /** A phone notification the glasses turned away because our page was up; the app's package name. */
    var onBlockedNotification: ((String) -> Unit)? = null
    /** A look up while the page is closed to let notifications through. */
    var onStandbyRaise: (() -> Unit)? = null
    /** Called when a running display ends for any reason other than the user pressing Stop. */
    var onEnded: ((String) -> Unit)? = null

    var translationMode = 0
    /** The shortest gap between screens, in seconds. */
    var pace: Double = 1.0
        set(value) { if (value != field) { field = value; session.minInterval = maxOf(0.25, value) } }
    /** After each crown click, start a new page session so the next click is reported too (0 off, 1, 2). */
    var rearm = 0
    var logEvents = false

    private val serviceID = UUID.fromString("0000b81d-0000-1000-8000-00805f9b34fb")
    private val outgoingID = UUID.fromString("ea8b70d5-2bd3-49ab-9c31-9c38b2c3c4f9")
    private val incomingID = UUID.fromString("7db3e235-3608-41f3-a03c-955fcbd2ea4b")
    private val configID = UUID.fromString("00002902-0000-1000-8000-00805f9b34fb")

    private val main = Handler(Looper.getMainLooper())
    private var gatt: BluetoothGatt? = null
    private var outgoing: BluetoothGattCharacteristic? = null
    private var incoming: BluetoothGattCharacteristic? = null
    private var candidates = ArrayDeque<BluetoothDevice>()
    private var mtu = 23
    private var linked = false
    private var session = CaptionSession()
    private var decoder = FrameStreamDecoder()
    private var userStopped = false
    private var standingBy = false
    private var deadline: Double? = null
    private var run = 0
    private var pieces = ArrayDeque<ByteArray>()
    private var piecesGiveUp = 0.0
    private var writingPieces = false
    private var telemetrySeen = HashSet<String>()
    private var eventsLogged = 0
    private var lastDepth = 0
    private var lastBack = 0.0
    private var lastRaise = 0.0
    private var lastTurn = 0.0
    private var lastBlocked = 0.0
    private var size = TextSize.small

    private val now: Double get() = System.currentTimeMillis() / 1000.0
    val isRunning: Boolean get() = state != State.off
    val isShowing: Boolean get() = state == State.showing
    val isStandingBy: Boolean get() = state == State.standby

    // MARK: Controls

    fun start(size: TextSize, refresh: Boolean, finishScrollingText: Boolean = false) {
        if (state != State.off) return
        this.size = size
        session = CaptionSession(size.fontSize, size.rows)
        session.refreshInterval = if (refresh) 30.0 else null
        session.finishScrollingText = finishScrollingText
        session.translationMode = translationMode
        session.minInterval = maxOf(0.25, pace)
        decoder = FrameStreamDecoder()
        rows = size.rows; framesSent = 0; eventsLogged = 0
        userStopped = false; standingBy = false; run += 1
        state = State.looking; status = "Looking for your glasses…"
        deadline = now + 12
        note("Start requested (${size.title}). Build ${BuildConfig.VERSION_CODE}, Android ${Build.VERSION.RELEASE}.")
        attach()
    }

    /** Close the caption page but stay connected and listening, so the glasses show notifications. */
    fun stepAside() {
        if (state != State.showing) return
        standingBy = true
        state = State.closing; status = "Getting out of the way…"
        note("Closing the page so notifications can show.")
        perform(session.stop(now))
    }

    /** Bring the page back after stepping aside. */
    fun comeBack() {
        if (state != State.standby) return
        standingBy = false
        if (gatt == null || !linked || incoming == null) { fail("The glasses disconnected."); return }
        reopen()
    }

    fun stop() {
        if (state == State.off) return
        userStopped = true
        if (state == State.standby) { standingBy = false; release("Display is off."); return }
        standingBy = false
        if (state == State.looking || state == State.connecting) { finish("Display is off."); return }
        state = State.closing; status = "Closing the display…"
        perform(session.stop(now))
    }

    /** Open the caption page again on the connection we already have (after the glasses closed it). */
    private fun reopen() {
        if (gatt == null || !linked || incoming == null) return
        val old = session
        session = CaptionSession(old.fontSize, old.maxLines)
        session.refreshInterval = old.refreshInterval
        session.finishScrollingText = old.finishScrollingText
        session.translationMode = translationMode
        session.minInterval = maxOf(0.25, pace)
        state = State.opening; status = "Opening the display…"
        note("Opening the page again.")
        session.start(now)
        perform(session.subscribed(now))
    }

    /** The text to keep on the glasses. Sent on the next tick the session allows. */
    fun show(text: String, scrolls: Boolean, finished: Boolean = false) = session.show(text, scrolls, finished)

    /** Call a few times a second while the display is on. */
    fun tick() {
        if (state == State.off) return
        val due = deadline
        if (due != null && now >= due && (state == State.looking || state == State.connecting)) {
            deadline = null
            if (state == State.connecting && candidates.isNotEmpty()) { dropGatt(); tryNext(); return }
            fail(if (state == State.looking) "Bluetooth didn't become available." else "Couldn't reach the glasses.")
            return
        }
        if (writingPieces && now > piecesGiveUp) { writingPieces = false; pieces.clear(); perform(session.writeFinished(false, now)) }
        perform(session.tick(now))
        if (framesSent != session.framesSent) framesSent = session.framesSent
    }

    fun clearLog() = log.clear()
    fun record(line: String) = note(line)

    // MARK: Attaching

    private fun allowed(): Boolean =
        Build.VERSION.SDK_INT < 31 || context.checkSelfPermission(Manifest.permission.BLUETOOTH_CONNECT) == PackageManager.PERMISSION_GRANTED

    private fun looksLikeGlasses(device: BluetoothDevice): Boolean {
        val name = (try { device.name } catch (e: Exception) { null } ?: "").lowercase()
        return name.contains("rayneo") || name.contains("ray neo") || name.contains("leiniao") || name.startsWith("io")
    }

    private fun attach() {
        if (!allowed()) { fail("Glasses Hub isn't allowed to use Bluetooth. Allow \"Nearby devices\" for it in the phone's Settings."); return }
        val manager = context.getSystemService(Context.BLUETOOTH_SERVICE) as? BluetoothManager
        val adapter = manager?.adapter
        if (adapter == null) { fail("This device has no Bluetooth."); return }
        if (!adapter.isEnabled) { fail("Bluetooth is off."); return }
        // The glasses are already connected to the phone by the RayNeo app; find them among what's connected.
        val connected = try { manager.getConnectedDevices(BluetoothProfile.GATT) } catch (e: Exception) { emptyList() }
        val bonded = try { adapter.bondedDevices?.toList() ?: emptyList() } catch (e: Exception) { emptyList() }
        val order = LinkedHashMap<String, BluetoothDevice>()
        for (d in connected.filter { looksLikeGlasses(it) }) order[d.address] = d
        for (d in bonded.filter { looksLikeGlasses(it) }) order[d.address] = d
        for (d in connected) order.putIfAbsent(d.address, d)
        note("Connected Bluetooth devices: ${connected.size}; paired with a RayNeo name: ${bonded.count { looksLikeGlasses(it) }}.")
        if (order.isEmpty()) {
            fail("Your glasses aren't connected to this phone. Open the RayNeo app, wait for it to connect, then try again.")
            return
        }
        candidates = ArrayDeque(order.values)
        tryNext()
    }

    private fun tryNext() {
        val target = candidates.removeFirstOrNull()
        if (target == null) {
            fail("None of the connected Bluetooth devices were RayNeo glasses. Open the RayNeo app, wait for it to connect, then try again.")
            return
        }
        glassesName = (try { target.name } catch (e: Exception) { null }) ?: "RayNeo glasses"
        state = State.connecting; status = "Joining the glasses' connection…"
        deadline = now + 10
        linked = false; mtu = 23
        val thisRun = run
        gatt = try { target.connectGatt(context, false, Callback(thisRun), BluetoothDevice.TRANSPORT_LE) } catch (e: Exception) { null }
        if (gatt == null) tryNext()
    }

    private fun dropGatt() {
        val old = gatt
        gatt = null; outgoing = null; incoming = null; linked = false
        try { old?.disconnect() } catch (e: Exception) {}
        try { old?.close() } catch (e: Exception) {}
    }

    /** Bluetooth calls back on its own threads; everything is handed to the main thread first. */
    private inner class Callback(val forRun: Int) : BluetoothGattCallback() {
        private fun mine(g: BluetoothGatt) = forRun == run && g === gatt
        private fun onMain(g: BluetoothGatt, block: () -> Unit) { main.post { if (mine(g)) block() } }

        override fun onConnectionStateChange(g: BluetoothGatt, status: Int, newState: Int) = onMain(g) {
            if (newState == BluetoothProfile.STATE_CONNECTED && status == BluetoothGatt.GATT_SUCCESS) {
                if (state != State.connecting) return@onMain
                linked = true
                deadline = now + 10
                // Ask how big a write may be. The link is already set up by the RayNeo app, so this only reads
                // the size back; if the phone won't say, discovery goes ahead after a moment anyway.
                val asked = try { g.requestMtu(512) } catch (e: Exception) { false }
                if (!asked) discover(g)
                else main.postDelayed({ if (mine(g) && state == State.connecting && !discovering) discover(g) }, 1500)
            } else if (newState == BluetoothProfile.STATE_DISCONNECTED) {
                linked = false
                if (state == State.connecting) {
                    note("Couldn't join $glassesName (status $status).")
                    dropGatt(); tryNext()
                    return@onMain
                }
                perform(session.connectionLost())
                val reason = if (userStopped) "Display is off." else (session.closeReason ?: "The glasses disconnected.")
                finish(reason, notify = !userStopped)
            }
        }

        private var discovering = false
        private fun discover(g: BluetoothGatt) {
            if (discovering) return
            discovering = true
            if (!(try { g.discoverServices() } catch (e: Exception) { false })) { dropGatt(); tryNext() }
        }

        override fun onMtuChanged(g: BluetoothGatt, value: Int, status: Int) = onMain(g) {
            if (status == BluetoothGatt.GATT_SUCCESS && value >= 23) mtu = value
            if (state == State.connecting) discover(g)
        }

        override fun onServicesDiscovered(g: BluetoothGatt, status: Int) = onMain(g) {
            if (state != State.connecting) return@onMain
            val match = g.getService(serviceID)
            if (status != BluetoothGatt.GATT_SUCCESS || match == null) {
                note("$glassesName doesn't offer the glasses' data service.")
                dropGatt(); tryNext()
                return@onMain
            }
            val out = match.getCharacteristic(outgoingID)
            val inc = match.getCharacteristic(incomingID)
            val canWrite = out != null && out.properties and (BluetoothGattCharacteristic.PROPERTY_WRITE or BluetoothGattCharacteristic.PROPERTY_WRITE_NO_RESPONSE) != 0
            val canNotify = inc != null && inc.properties and (BluetoothGattCharacteristic.PROPERTY_NOTIFY or BluetoothGattCharacteristic.PROPERTY_INDICATE) != 0
            if (!canWrite || !canNotify) {
                fail("The glasses' data channels weren't where they were expected. A firmware update may have moved them.")
                return@onMain
            }
            outgoing = out; incoming = inc
            candidates.clear()
            deadline = null
            state = State.opening; this@GlassesLink.status = "Opening the display…"
            note("Joined $glassesName. Write limit ${mtu - 3} bytes.")
            perform(session.start(now))
        }

        override fun onDescriptorWrite(g: BluetoothGatt, descriptor: BluetoothGattDescriptor, status: Int) = onMain(g) {
            if (descriptor.uuid != configID || descriptor.characteristic.uuid != incomingID) return@onMain
            if (status == BluetoothGatt.GATT_SUCCESS) perform(session.subscribed(now))
            else if (state == State.opening) {
                // The RayNeo app has usually turned this channel on already; carry on and see whether data arrives.
                note("Couldn't confirm the receive channel (status $status); carrying on.")
                perform(session.subscribed(now))
            }
        }

        override fun onCharacteristicWrite(g: BluetoothGatt, characteristic: BluetoothGattCharacteristic, status: Int) = onMain(g) {
            if (characteristic.uuid != outgoingID) return@onMain
            if (writingPieces) {
                if (status != BluetoothGatt.GATT_SUCCESS) { writingPieces = false; pieces.clear(); note("Write failed: $status."); perform(session.writeFinished(false, now)) }
                else main.postDelayed({ if (mine(g)) nextPiece() }, 15)
                return@onMain
            }
            if (status != BluetoothGatt.GATT_SUCCESS) note("Write failed: $status.")
            perform(session.writeFinished(status == BluetoothGatt.GATT_SUCCESS, now))
        }

        @Deprecated("Used on Android 12 and earlier")
        override fun onCharacteristicChanged(g: BluetoothGatt, characteristic: BluetoothGattCharacteristic) {
            if (Build.VERSION.SDK_INT >= 33) return
            @Suppress("DEPRECATION")
            val data = characteristic.value?.copyOf() ?: return
            if (characteristic.uuid == incomingID) onMain(g) { received(data) }
        }

        override fun onCharacteristicChanged(g: BluetoothGatt, characteristic: BluetoothGattCharacteristic, value: ByteArray) {
            val data = value.copyOf()
            if (characteristic.uuid == incomingID) onMain(g) { received(data) }
        }
    }

    // MARK: Sending

    private fun perform(actions: List<CaptionSession.Action>) {
        for (action in actions) {
            when (action) {
                is CaptionSession.Action.Subscribe -> subscribe()
                is CaptionSession.Action.Write -> {
                    if (action.text) lastDepth = 0             // a new screen starts at the bottom again
                    send(action.packet)
                }
                is CaptionSession.Action.Log -> note(action.line)
                is CaptionSession.Action.Release -> {
                    if (standingBy && !userStopped && linked) {
                        state = State.standby; status = "Out of the way so notifications can show. Look up to bring it back."
                        note("Page closed; still listening.")
                    } else release(action.reason)
                }
            }
        }
        if (session.phase == CaptionSession.Phase.active && state == State.opening) {
            state = State.showing; status = "Showing on your glasses."
        }
        if (rows != session.maxLines) rows = session.maxLines
    }

    private fun subscribe() {
        val g = gatt; val inc = incoming
        if (g == null || inc == null) return
        try { g.setCharacteristicNotification(inc, true) } catch (e: Exception) {}
        val descriptor = inc.getDescriptor(configID)
        if (descriptor == null) { perform(session.subscribed(now)); return }
        val value = if (inc.properties and BluetoothGattCharacteristic.PROPERTY_NOTIFY != 0)
            BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE else BluetoothGattDescriptor.ENABLE_INDICATION_VALUE
        val ok = try {
            if (Build.VERSION.SDK_INT >= 33) g.writeDescriptor(descriptor, value) == 0
            else { @Suppress("DEPRECATION") descriptor.value = value; @Suppress("DEPRECATION") g.writeDescriptor(descriptor) }
        } catch (e: Exception) { false }
        if (!ok) { note("Couldn't ask for the receive channel; carrying on."); perform(session.subscribed(now)) }
    }

    private fun write(value: ByteArray, type: Int): Boolean {
        val g = gatt ?: return false
        val out = outgoing ?: return false
        return try {
            if (Build.VERSION.SDK_INT >= 33) g.writeCharacteristic(out, value, type) == 0
            else { out.writeType = type; @Suppress("DEPRECATION") out.value = value; @Suppress("DEPRECATION") g.writeCharacteristic(out) }
        } catch (e: Exception) { false }
    }

    private fun send(packet: ByteArray) {
        val out = outgoing
        if (gatt == null || out == null || !linked) { perform(session.writeFinished(false, now)); return }
        val limit = maxOf(20, mtu - 3)
        val withResponse = out.properties and BluetoothGattCharacteristic.PROPERTY_WRITE != 0
        val streamed = out.properties and BluetoothGattCharacteristic.PROPERTY_WRITE_NO_RESPONSE != 0
        if (withResponse && packet.size <= limit) {
            if (!write(packet, BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT)) perform(session.writeFinished(false, now))
            return                                                  // answered in onCharacteristicWrite
        }
        if (!streamed) {
            // No streamed writes: let Android split a long write itself (it can, up to 512 bytes).
            if (withResponse && packet.size <= 512) {
                if (!write(packet, BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT)) perform(session.writeFinished(false, now))
                return
            }
            note("A ${packet.size}-byte screen is too big for one write and the glasses don't take streamed writes.")
            perform(session.writeFinished(false, now)); return
        }
        // Too long for one write: send it as a stream of pieces. The glasses reassemble by the packet's own
        // length field.
        val step = minOf(512, limit)
        pieces.clear()
        var at = 0
        while (at < packet.size) { pieces.addLast(packet.copyOfRange(at, minOf(packet.size, at + step))); at += step }
        writingPieces = true
        piecesGiveUp = now + 5
        nextPiece()
    }

    private fun nextPiece() {
        if (!writingPieces) return
        val piece = pieces.removeFirstOrNull()
        if (piece == null) { writingPieces = false; perform(session.writeFinished(true, now)); return }
        if (!write(piece, BluetoothGattCharacteristic.WRITE_TYPE_NO_RESPONSE)) {
            writingPieces = false; pieces.clear()
            perform(session.writeFinished(false, now))
        }
    }

    // MARK: Receiving

    private fun received(data: ByteArray) {
        for (frame in decoder.append(data)) {
            if (logEvents && eventsLogged < 400) { eventsLogged += 1; note(describe(frame)) }
            val report = GlassesReport.from(frame)
            if (report != null) {
                report.battery?.let { if (it != battery) battery = it }
                val pkg = report.blockedNotification
                if (pkg != null && state == State.showing) {
                    if (now - lastBlocked > 1.5) { note("The glasses blocked a notification from $pkg."); onBlockedNotification?.invoke(pkg) }
                    lastBlocked = now
                }
                val action = report.action
                if (action != null && state == State.standby) {
                    note("Report while out of the way: ${action::class.simpleName}.")
                    if (action is GlassesReport.Action.HeadRaise) {
                        if (now - lastRaise > 3.5) onStandbyRaise?.invoke()
                        lastRaise = now
                    }
                }
                if (action != null && state == State.showing) {
                    when (action) {
                        is GlassesReport.Action.CrownTurn -> {
                            // one notch of the crown reports twice; treat reports close together as one turn.
                            // a forward turn right after a back turn is the crown settling, not a new step
                            if (now - lastTurn > 0.3 && now - lastBack > 0.6) onCrown?.invoke(1)
                            lastTurn = now; lastDepth = 0
                        }
                        is GlassesReport.Action.CrownBack -> {
                            // only the first line scrolled back counts; a spin shouldn't flip several pages
                            if (action.depth > lastDepth && now - lastBack > 0.7) { lastBack = now; onCrown?.invoke(-1) }
                            lastDepth = action.depth
                        }
                        is GlassesReport.Action.CrownClick -> {
                            note("Crown click.")
                            onCrown?.invoke(0)
                            if (rearm > 0) {
                                val actions = session.renew(now, closeFirst = rearm == 2)
                                if (actions.isNotEmpty()) note(if (rearm == 2) "Reopening the page so the next click counts." else "New page session so the next click counts.")
                                perform(actions)
                            }
                        }
                        is GlassesReport.Action.DoubleClick -> { note("Crown double click."); onDoubleClick?.invoke() }
                        is GlassesReport.Action.HoldExit -> {
                            note("Crown held: the glasses left the page.")
                            if (onHoldExit?.invoke() == true) reopen()
                            else { userStopped = false; release("The caption page was closed on the glasses.") }
                        }
                        is GlassesReport.Action.HeadRaise -> {
                            // looking back down is reported as a second raise a couple of seconds later
                            if (now - lastRaise > 3.5) onHeadRaise?.invoke()
                            lastRaise = now
                        }
                    }
                }
            }
            if (frame.business == CaptionWire.business) {
                perform(session.received(frame, now))
            } else if (frame.business == 15 && frame.isPlain) {
                val message = Envelope.decode(frame.payload)
                val command = message?.json?.get("cmd").str()
                // Status the glasses announce on their own. Logged once each; nothing is sent in reply.
                val harmless = setOf("battery_change", "wear_status", "screen_status", "brightness_change", "device_status")
                if (message != null && command != null && command in harmless && telemetrySeen.add(command)) {
                    note("Glasses status $command: ${Json.encode(message.json).take(220)}")
                }
            }
        }
    }

    /** One line about a packet from the glasses, with anything that identifies the device blanked. */
    private fun describe(frame: GlassesFrame): String {
        var line = "EVENT ch${frame.business}"
        val message = if (frame.isPlain) Envelope.decode(frame.payload) else null
        if (message == null) return "$line (${frame.payload.size} bytes, not readable)"
        line += " type ${message.type}"
        if (message.dataBytes > 0) line += " +${message.dataBytes} bytes"
        fun scrub(value: Any?): Any? = when (value) {
            is Map<*, *> -> value.entries.associate { (key, item) ->
                val k = key.toString().lowercase()
                val hide = listOf("sn", "did", "mac", "sid", "uid", "token", "account", "serial").any { k == it || k.endsWith(it) || k.startsWith(it) }
                key.toString() to (if (hide) "-" else scrub(item))
            }
            is List<*> -> value.take(6).map { scrub(it) }
            // some fields hold JSON inside a string; open it so its fields are scrubbed too
            is String -> if (value.startsWith("{")) (Json.parse(value)?.let { scrub(it) } ?: value.take(60)) else if (value.length > 60) value.take(60) + "…" else value
            else -> value
        }
        return line + " " + Json.encode(scrub(message.json)).take(420)
    }

    // MARK: Ending

    private fun release(reason: String) {
        writingPieces = false; pieces.clear()
        // Lets go of this app's share of the connection only. The RayNeo app keeps its own.
        dropGatt()
        finish(if (userStopped) "Display is off." else reason, notify = !userStopped)
    }

    private fun fail(reason: String) {
        note(reason)
        dropGatt()
        finish(reason, notify = true)
    }

    private fun finish(reason: String, notify: Boolean = false) {
        if (state == State.off) return
        writingPieces = false; pieces.clear()
        dropGatt()
        candidates.clear()
        deadline = null
        run += 1
        state = State.off; status = reason
        framesSent = session.framesSent
        if (notify) onEnded?.invoke(reason)
    }

    private val clock = SimpleDateFormat("HH:mm:ss.SS", Locale.US)
    private fun note(line: String) {
        log.add("${clock.format(Date())}  $line")
        while (log.size > 200) log.removeAt(0)
    }
}
