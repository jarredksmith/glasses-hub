package com.jarredsmith.glasseshub

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.provider.Settings as SystemSettings
import android.view.WindowManager
import androidx.activity.ComponentActivity
import androidx.compose.foundation.background
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.gestures.detectTransformGestures
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.systemBarsPadding
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.jarredsmith.glasseshub.core.GlyphStyle
import com.jarredsmith.glasseshub.core.TextSize
import kotlin.math.abs

private val pages = listOf(
    "Screen and text" to "Text size, width, symbols, centering",
    "Glasses controls" to "Crown, look up, double click",
    "Phone buttons and remotes" to "Volume buttons, rings, clickers",
    "Notifications and alerts" to "Phone notifications on the glasses, pop-ups",
    "Help" to "Getting connected, and what to try when it won't",
    "Advanced" to "Experiments and the connection log",
)

@Composable
fun SettingsScreen(model: HubModel) {
    val nav = LocalNav.current
    Group { for ((name, detail) in pages) Go(name, detail) { nav.open(Page.Setting(name)) } }
    Group("About", "Glasses Hub is an independent app and isn't made or endorsed by RayNeo.") {
        Info("Version", BuildConfig.VERSION_NAME)
        Info("Build", "${BuildConfig.VERSION_CODE}")
    }
}

@Composable
fun SettingPage(model: HubModel, name: String) {
    val nav = LocalNav.current
    val context = LocalContext.current
    @Suppress("UNUSED_VARIABLE") val beat = model.pulse
    when (name) {
        "Screen and text" -> {
            Group(footer = "Text size applies the next time the display starts. If lines wrap early on the glasses, lower the characters per line; if there's room to spare, raise it. The test card has a ruler to check against.") {
                Choice("Text size", TextSize.entries.map { it to it.title }, model.textSize) { model.textSize = it }
                if (model.textSize == TextSize.small) Stepper("Characters per line: ${model.columnsSmall}", model.columnsSmall, 24..60) { model.columnsSmall = it }
                else Stepper("Characters per line: ${model.columnsLarge}", model.columnsLarge, 18..48) { model.columnsLarge = it }
                Choice("Position", listOf(0 to "Left", 1 to "Centered block", 2 to "Every line centered"), model.centering) { model.centering = it }
                Action("Show a test card") { model.showTestCard() }
            }
            Group(footer = "Symbols make scores and weather easier to read at a glance. If any show as empty boxes on your glasses, drop a level.") {
                Choice("Symbols", GlyphStyle.entries.map { it to it.title }, model.glyphStyle) { model.glyphStyle = it }
                Action("Show every symbol") { model.showSymbolTest() }
            }
            Group(footer = "Long cards turn their own pages. Zero leaves the turning to you.") {
                Stepper("Turn pages every ${model.pageSeconds.toInt()} s", model.pageSeconds.toInt(), 0..60, 2) { model.pageSeconds = it.toDouble() }
                Toggle("Refresh an unchanged screen every 30 s", model.refreshScreen) { model.refreshScreen = it }
            }
        }
        "Glasses controls" -> {
            Group("Crown", "Turn forward for next, turn back for previous. Telling the two apart needs a spare line above each screen, which is why short screens sit a line lower.") {
                Toggle("Navigate with the crown", model.crownPaging) { model.crownPaging = it }
                Toggle("Turning back goes to the previous item", model.crownBack, enabled = model.crownPaging) { model.crownBack = it }
                ActionChoice("Double click", model.doubleClickAction) { model.doubleClickAction = it }
            }
            Group("Look up", "Tilt your head up, as if glancing at the ceiling. The glasses report it about a second later.") {
                Toggle("Use look up", model.headPaging) { model.headPaging = it }
                ActionChoice("Look up does", model.headAction) { model.headAction = it }
            }
            Group(footer = "In the RayNeo app, set the crown's double-click shortcut to None, or the glasses will act on it themselves.") {
                Go("Try the controls", "A checklist that ticks off each one as the glasses report it") { nav.open(Page.Practice) }
            }
        }
        "Phone buttons and remotes" -> {
            Group("Volume buttons", "While Glasses Hub is open on the phone's screen and the display is on, the volume buttons drive the glasses.") {
                Toggle("Navigate with the volume buttons", model.volumePaging) { model.volumePaging = it }
                if (model.volumePaging) {
                    ActionChoice("Volume up", model.volumeUpAction) { model.volumeUpAction = it }
                    ActionChoice("Volume down", model.volumeDownAction) { model.volumeDownAction = it }
                }
            }
            Group("Bluetooth ring or clicker", "Scrolling rings and page-turner clickers work by faking swipes, taps and pinches, or by sending keys. Open the remote pad from the Display tab, press each button there once to see what it sends, then set what it should do here. Media keys (next, previous, play) work from any screen of the app.") {
                for (event in RemoteEvent.entries) ActionChoice(event.title, model.ringAction(event)) { model.setRing(event.name, it) }
                ActionChoice("Double swipe right", model.ringDouble(RemoteEvent.swipeRight)) { model.setRing("swipeRightDouble", it) }
                ActionChoice("Double swipe left", model.ringDouble(RemoteEvent.swipeLeft)) { model.setRing("swipeLeftDouble", it) }
                if (model.ringLast.isNotEmpty()) Info("Last received", model.ringLast)
                Go("Open the remote pad") { nav.open(Page.Pad) }
            }
        }
        "Notifications and alerts" -> {
            val allowed = NoticeListener.allowed(context)
            Group("Phone notifications", "The glasses turn away their own notifications while Glasses Hub's page is up. With this on, Glasses Hub reads the phone's notifications itself and shows each one for a few seconds. Android asks you to allow that in its settings. Nothing is stored or sent anywhere.") {
                Toggle("Show phone notifications on the glasses", model.phoneNotices) { model.phoneNotices = it }
                if (model.phoneNotices) {
                    if (!allowed) Action("Allow notification access…") { try { context.startActivity(Intent(SystemSettings.ACTION_NOTIFICATION_LISTENER_SETTINGS).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)) } catch (e: Exception) {} }
                    else Info("Notification access", "Allowed")
                    Stepper("Show each for ${model.noticeSeconds.toInt()} s", model.noticeSeconds.toInt(), 3..30) { model.noticeSeconds = it.toDouble() }
                    Field("Apps to leave out (names, separated by commas)", model.noticeSkip) { model.noticeSkip = it }
                }
                Toggle("Otherwise, name the app when the glasses block one", model.noticeBlocked) { model.noticeBlocked = it }
            }
            Group("Glasses Hub's own alerts", "Scores, the timer and nearby places.") {
                Choice("Send them to", AlertStyle.entries.map { it to it.title }, model.alertStyle) { model.alertStyle = it }
                Stepper("Keep each up for ${model.alertSeconds.toInt()} s", model.alertSeconds.toInt(), 4..30) { model.alertSeconds = it.toDouble() }
                Info("Phone notifications from Glasses Hub", if (model.notificationsAllowed) "Allowed" else "Not allowed")
            }
            Group("Pop-up mode", "The display stays closed, so the glasses behave as usual, and opens by itself only when there's an alert or a fact to show.") {
                Toggle("Pop-up mode", model.popUps) { model.popUps = it }
                if (model.popUps) Stepper(if (model.popFactMinutes.toInt() == 0) "No odd facts" else "An odd fact every ${model.popFactMinutes.toInt()} min", model.popFactMinutes.toInt(), 0..120, 5) { model.popFactMinutes = it.toDouble() }
            }
        }
        "Help" -> {
            Group("Getting connected") {
                Note("1. Open the RayNeo app and wait until it shows your glasses as connected.")
                Note("2. Come back here and tap Start the display on the Display tab. Allow \"Nearby devices\" if Android asks.")
                Note("3. The glasses open their caption page with Glasses Hub's text on it.")
            }
            Group("If it won't start") {
                Note("Nothing found: the glasses aren't connected to this phone yet. Open the RayNeo app first.")
                Note("\"Declined the display\": something else is open on the glasses. Close it there and try again.")
                Note("It stops when the phone's screen turns off: in Android's settings for Glasses Hub, set Battery to Unrestricted.")
                Note("Still stuck: turn on \"Log everything the glasses report\" under Advanced, try again, and send the log.")
            }
            Group("Leaving the page") { Note("Hold the crown on the glasses, or tap Stop the display here.") }
        }
        "Advanced" -> {
            Group("Experiments", "These change how the glasses are driven. Leave them off unless you're trying something.") {
                Toggle("Let the crown scroll long text itself", model.crownScroll) { model.crownScroll = it }
                Toggle("Holding the crown selects", model.holdSelects) { model.holdSelects = it }
                Choice("After a crown click", listOf(0 to "Do nothing", 1 to "New page session", 2 to "Reopen the page"), model.clickRearm) { model.clickRearm = it }
                Choice("Send text as", listOf(0 to "Plain captions", 1 to "Translation mode 1", 2 to "Translation mode 2", 3 to "Translation mode 3"), model.translationMode) { model.translationMode = it }
            }
            Group("Connection log", "What the app and the glasses said to each other. Serial numbers and the like are blanked.") {
                Toggle("Log everything the glasses report", model.logEvents) { model.logEvents = it }
                Buttons("Copy" to {
                    (context.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager).setPrimaryClip(ClipData.newPlainText("Glasses Hub log", model.link.log.joinToString("\n")))
                }, "Clear" to { model.link.clearLog() })
                Text(model.link.log.takeLast(60).joinToString("\n").ifEmpty { "Nothing yet." }, fontFamily = FontFamily.Monospace, fontSize = 11.sp, lineHeight = 15.sp, modifier = Modifier.padding(horizontal = 16.dp, vertical = 8.dp))
            }
        }
    }
}

@Composable
fun PracticePage(model: HubModel) {
    val ask = LocalAsk.current
    DisposableEffect(Unit) { onDispose { model.stopPractice() } }
    val names = listOf("Turn the crown forward", "Turn the crown back", "Look up", "Double click the crown")
    Group(footer = "Each one ticks itself off when the glasses report it. A report can take a second to arrive. If double click never ticks, set the crown's double-click shortcut to None in the RayNeo app.") {
        if (!model.practicing) Action("Start the check") { ask(displayPermissions()) { model.startPractice() } }
        else for ((i, name) in names.withIndex()) Info(name, if (model.practiced.getOrElse(i) { false }) "✓ works" else "waiting")
        if (model.practicing && !model.link.isShowing) Note(model.link.status)
        if (model.practicing) Action("Done") { model.stopPractice() }
    }
    if (model.practicing) GlassesPreview(model)
}

/**
 * A dark full-screen pad that turns whatever a ring or clicker does on the phone's screen into steps on
 * the glasses. It keeps the screen awake and dim.
 */
@Composable
fun RemotePad(model: HubModel) {
    val nav = LocalNav.current
    val context = LocalContext.current
    DisposableEffect(Unit) {
        val window = (context as? ComponentActivity)?.window
        window?.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        val before = window?.attributes?.screenBrightness
        window?.attributes = window?.attributes?.also { it.screenBrightness = 0.05f }
        onDispose {
            window?.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
            window?.attributes = window?.attributes?.also { it.screenBrightness = before ?: -1f }
        }
    }
    var lastSent by remember { mutableStateOf(0L) }
    fun send(event: RemoteEvent) {
        // one press of a ring button is one step, however many touches it fakes
        val now = System.currentTimeMillis()
        if (now - lastSent < 150) return
        lastSent = now
        model.ring(event)
    }
    Box(Modifier.fillMaxSize().background(Color.Black)
        .pointerInput(Unit) { detectTapGestures(onTap = { send(RemoteEvent.tap) }) }
        .pointerInput(Unit) {
            var moved = Offset.Zero
            var scale = 1f
            var fingers = 1
            awaitPointerEventScopeLoop(onStart = { moved = Offset.Zero; scale = 1f; fingers = 1 }, onMove = { pan, zoom, count -> moved += pan; scale *= zoom; fingers = maxOf(fingers, count) }) {
                if (fingers >= 2 && abs(scale - 1f) > 0.08f) send(if (scale > 1f) RemoteEvent.zoomIn else RemoteEvent.zoomOut)
                else if (maxOf(abs(moved.x), abs(moved.y)) > 24f) {
                    if (abs(moved.y) >= abs(moved.x)) send(if (moved.y < 0) RemoteEvent.swipeUp else RemoteEvent.swipeDown) else send(if (moved.x < 0) RemoteEvent.swipeLeft else RemoteEvent.swipeRight)
                }
            }
        }) {
        Column(Modifier.fillMaxSize().systemBarsPadding().padding(20.dp), verticalArrangement = Arrangement.SpaceBetween, horizontalAlignment = Alignment.CenterHorizontally) {
            TextButton({ nav.back() }, Modifier.align(Alignment.End)) { Text("Close", color = Color.Gray) }
            Column(horizontalAlignment = Alignment.CenterHorizontally) {
                Text(model.ringLast.ifEmpty { "Press a button on your ring" }, color = Color(0xFF39E66B), fontWeight = FontWeight.SemiBold, fontSize = 18.sp, textAlign = TextAlign.Center)
                Text(if (model.link.isShowing) "Leave this screen open. Swipes, taps, pinches and keys drive the glasses." else "The glasses' display is off. Start it first, then come back here.",
                    color = Color.Gray, style = MaterialTheme.typography.bodySmall, textAlign = TextAlign.Center, modifier = Modifier.padding(top = 10.dp))
            }
            Text(model.preview.ifEmpty { " " }, color = Color(0xFF39E66B).copy(alpha = 0.55f), fontFamily = FontFamily.Monospace, fontSize = 12.sp, maxLines = 7)
        }
    }
}

/** Follows one touch gesture from first finger down to last finger up, adding up how it moved and pinched. */
private suspend fun androidx.compose.ui.input.pointer.PointerInputScope.awaitPointerEventScopeLoop(onStart: () -> Unit, onMove: (Offset, Float, Int) -> Unit, onEnd: () -> Unit) {
    awaitPointerEventScope {
        while (true) {
            val first = awaitPointerEvent()
            if (first.changes.none { it.pressed }) continue
            onStart()
            var last = first.changes.filter { it.pressed }
            var span = spanOf(last)
            while (true) {
                val event = awaitPointerEvent()
                val down = event.changes.filter { it.pressed }
                if (down.isEmpty()) break
                val pan = down.fold(Offset.Zero) { sum, change -> sum + (change.position - change.previousPosition) } / down.size.toFloat()
                val now = spanOf(down)
                val zoom = if (down.size >= 2 && down.size == last.size && span > 1f && now > 1f) now / span else 1f
                span = now; last = down
                onMove(pan, zoom, down.size)
            }
            onEnd()
        }
    }
}
private fun spanOf(points: List<androidx.compose.ui.input.pointer.PointerInputChange>): Float {
    if (points.size < 2) return 0f
    val centre = points.fold(Offset.Zero) { sum, p -> sum + p.position } / points.size.toFloat()
    return points.map { (it.position - centre).getDistance() }.average().toFloat()
}
