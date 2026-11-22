package com.jarredsmith.glasseshub

import android.Manifest
import android.content.Intent
import android.os.Build
import android.os.Bundle
import android.view.KeyEvent
import androidx.activity.ComponentActivity
import androidx.activity.compose.BackHandler
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.Apps
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material.icons.filled.Visibility
import androidx.compose.material3.AssistChip
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilledTonalButton
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.NavigationBar
import androidx.compose.material3.NavigationBarItem
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.dynamicDarkColorScheme
import androidx.compose.material3.dynamicLightColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.compositionLocalOf
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.jarredsmith.glasseshub.core.HubTimer
import com.jarredsmith.glasseshub.core.ReaderClock

/** Where the app can go beyond its three tabs. */
sealed class Page(val title: String) {
    class App(val program: Program) : Page(program.title)
    class Feed(val id: String?) : Page(if (id == null) "New feed" else "Edit feed")
    object MovieSearch : Page("Find subtitles")
    class MovieVersions(val found: SubtitleSearch.Title) : Page(found.title)
    class Setting(val name: String) : Page(name)
    object Pad : Page("Remote pad")
    object Practice : Page("Try the controls")
}

class Nav {
    val stack = mutableStateListOf<Page>()
    fun open(page: Page) { stack.add(page) }
    fun back() { if (stack.isNotEmpty()) stack.removeAt(stack.size - 1) }
}
val LocalNav = compositionLocalOf<Nav> { error("no nav") }
/** Asks the phone for permissions, then reports whether all were given. */
val LocalAsk = compositionLocalOf<(List<String>, (Boolean) -> Unit) -> Unit> { { _, done -> done(false) } }

class MainActivity : ComponentActivity() {
    private val model: HubModel get() = (application as HubApp).model
    private var waiting: ((Boolean) -> Unit)? = null
    private val asker = registerForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) { result ->
        val done = waiting; waiting = null
        model.refreshPermissions()
        done?.invoke(result.values.all { it })
    }
    /** True while the remote pad is on screen: every key then belongs to the glasses. */
    var padOpen = false

    private fun ask(permissions: List<String>, done: (Boolean) -> Unit) {
        val missing = permissions.filter { !granted(this, it) }
        if (missing.isEmpty()) { done(true); return }
        waiting = done
        asker.launch(missing.toTypedArray())
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        setContent {
            val dark = isSystemInDarkTheme()
            val colors = if (Build.VERSION.SDK_INT >= 31) (if (dark) dynamicDarkColorScheme(this) else dynamicLightColorScheme(this)) else if (dark) darkColorScheme() else lightColorScheme()
            MaterialTheme(colorScheme = colors) {
                androidx.compose.runtime.CompositionLocalProvider(LocalNav provides remember { Nav() }, LocalAsk provides ::ask) { Root(model, this) }
            }
        }
        handle(intent)
    }

    override fun onNewIntent(intent: Intent) { super.onNewIntent(intent); handle(intent) }

    /** Text shared from another app, or a glasseshub:// link, goes to Live text. */
    private fun handle(intent: Intent?) {
        if (intent == null) return
        if (intent.action == Intent.ACTION_SEND) {
            val text = intent.getStringExtra(Intent.EXTRA_TEXT)
            if (!text.isNullOrBlank()) model.showLive(text, append = false)
        } else if (intent.action == Intent.ACTION_VIEW && intent.data?.scheme?.lowercase() == "glasseshub") {
            val uri = intent.data ?: return
            val fields = HashMap<String, String>()
            try { for (name in uri.queryParameterNames) fields[name] = uri.getQueryParameter(name) ?: "" } catch (e: Exception) {}
            model.open(uri.host ?: "", fields)
        }
        intent.action = null
    }

    override fun onResume() { super.onResume(); model.scene(true) }
    override fun onPause() { super.onPause(); model.scene(false) }

    override fun dispatchKeyEvent(event: KeyEvent): Boolean {
        val code = event.keyCode
        val volume = code == KeyEvent.KEYCODE_VOLUME_UP || code == KeyEvent.KEYCODE_VOLUME_DOWN
        if (volume && model.volumePaging && (model.link.isShowing || model.link.isStandingBy)) {
            if (event.action == KeyEvent.ACTION_DOWN && event.repeatCount == 0) model.remote(if (code == KeyEvent.KEYCODE_VOLUME_UP) model.volumeUpAction else model.volumeDownAction)
            return true
        }
        // Clickers, rings and keyboards: media keys always count while the display is on; the rest only on the remote pad.
        val media = when (code) {
            KeyEvent.KEYCODE_MEDIA_NEXT, KeyEvent.KEYCODE_MEDIA_FAST_FORWARD -> RemoteEvent.keyNext
            KeyEvent.KEYCODE_MEDIA_PREVIOUS, KeyEvent.KEYCODE_MEDIA_REWIND -> RemoteEvent.keyPrevious
            KeyEvent.KEYCODE_MEDIA_PLAY_PAUSE, KeyEvent.KEYCODE_MEDIA_PLAY, KeyEvent.KEYCODE_MEDIA_PAUSE, KeyEvent.KEYCODE_HEADSETHOOK -> RemoteEvent.keySelect
            else -> null
        }
        val pad = if (!padOpen) null else when (code) {
            KeyEvent.KEYCODE_DPAD_RIGHT, KeyEvent.KEYCODE_DPAD_DOWN, KeyEvent.KEYCODE_PAGE_DOWN, KeyEvent.KEYCODE_SPACE -> RemoteEvent.keyNext
            KeyEvent.KEYCODE_DPAD_LEFT, KeyEvent.KEYCODE_DPAD_UP, KeyEvent.KEYCODE_PAGE_UP -> RemoteEvent.keyPrevious
            KeyEvent.KEYCODE_ENTER, KeyEvent.KEYCODE_NUMPAD_ENTER, KeyEvent.KEYCODE_DPAD_CENTER -> RemoteEvent.keySelect
            KeyEvent.KEYCODE_ESCAPE -> RemoteEvent.keyMenu
            else -> null
        }
        val found = media ?: pad
        if (found != null && (model.link.isRunning || padOpen)) {
            if (event.action == KeyEvent.ACTION_DOWN && event.repeatCount == 0) model.ring(found)
            return true
        }
        return super.dispatchKeyEvent(event)
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun Root(model: HubModel, activity: MainActivity) {
    val nav = LocalNav.current
    var tab by remember { mutableIntStateOf(0) }
    val page = nav.stack.lastOrNull()
    BackHandler(page != null) { nav.back() }
    activity.padOpen = page is Page.Pad
    if (page is Page.Pad) { RemotePad(model); return }
    Scaffold(
        topBar = {
            TopAppBar(title = { Text(page?.title ?: listOf("Glasses Hub", "Apps", "Settings")[tab]) },
                navigationIcon = { if (page != null) IconButton({ nav.back() }) { Icon(Icons.AutoMirrored.Filled.ArrowBack, "Back") } })
        },
        bottomBar = {
            if (page == null) NavigationBar {
                NavigationBarItem(tab == 0, { tab = 0 }, { Icon(Icons.Filled.Visibility, null) }, label = { Text("Display") })
                NavigationBarItem(tab == 1, { tab = 1 }, { Icon(Icons.Filled.Apps, null) }, label = { Text("Apps") })
                NavigationBarItem(tab == 2, { tab = 2 }, { Icon(Icons.Filled.Settings, null) }, label = { Text("Settings") })
            }
        },
    ) { inner ->
        Column(Modifier.padding(inner).fillMaxSize().verticalScroll(rememberScrollState(), enabled = true)) {
            when (page) {
                null -> when (tab) { 0 -> DisplayScreen(model); 1 -> AppsScreen(model); else -> SettingsScreen(model) }
                is Page.App -> AppPage(model, page.program)
                is Page.Feed -> FeedEditor(model, page.id)
                is Page.MovieSearch -> MovieSearchPage(model)
                is Page.MovieVersions -> MovieVersionsPage(model, page.found)
                is Page.Setting -> SettingPage(model, page.name)
                is Page.Practice -> PracticePage(model)
                is Page.Pad -> {}
            }
            Spacer(Modifier.height(24.dp))
        }
    }
}

/** The permissions the display itself needs: Bluetooth, and (so its notification shows) notifications. */
fun displayPermissions(): List<String> = buildList {
    if (Build.VERSION.SDK_INT >= 31) add(Manifest.permission.BLUETOOTH_CONNECT)
    if (Build.VERSION.SDK_INT >= 33) add(Manifest.permission.POST_NOTIFICATIONS)
}

@Composable
fun GlassesPreview(model: HubModel) {
    Surface(color = Color.Black, shape = RoundedCornerShape(14.dp), modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp)) {
        Box(Modifier.heightIn(min = 150.dp).padding(14.dp), contentAlignment = Alignment.CenterStart) {
            Text(model.preview.ifEmpty { " " }, color = Color(0xFF39E66B), fontFamily = FontFamily.Monospace, fontSize = 13.sp, lineHeight = 18.sp, maxLines = if (model.previewScrolls) 9 else 7)
        }
    }
}

@OptIn(ExperimentalLayoutApi::class)
@Composable
fun DisplayScreen(model: HubModel) {
    val nav = LocalNav.current
    val ask = LocalAsk.current
    val link = model.link
    @Suppress("UNUSED_VARIABLE") val beat = model.pulse                    // redraw as the loop turns
    var note by remember { mutableStateOf("") }

    if (!model.setupSeen) Group("First time?", "Glasses Hub joins the connection your RayNeo app already has. Open the RayNeo app first and wait for it to connect to your glasses, then tap Start here. In the RayNeo app, set the crown's double-click shortcut to None so double clicks reach this app.") {
        Go("Try the controls", "A quick check that turns, look-up and double click all work") { nav.open(Page.Practice) }
        Action("Got it") { model.setupSeen = true }
    }

    Group {
        Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Box(Modifier.padding(end = 10.dp).background(if (link.isShowing) Color(0xFF2EBD59) else if (link.isRunning) Color(0xFFE6A23C) else Color.Gray, RoundedCornerShape(6.dp)).padding(6.dp))
                Column(Modifier.weight(1f)) {
                    Text(link.status, fontWeight = FontWeight.Medium)
                    val detail = listOfNotNull(link.glassesName.takeIf { it.isNotEmpty() && link.isRunning }, link.battery?.let { "battery $it%" }).joinToString(", ")
                    if (detail.isNotEmpty()) Text(detail, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
            }
            Button({ if (link.isRunning) model.stopDisplay() else ask(displayPermissions()) { model.startDisplay() } }, Modifier.fillMaxWidth(),
                colors = if (link.isRunning) ButtonDefaults.buttonColors(containerColor = MaterialTheme.colorScheme.error) else ButtonDefaults.buttonColors()) {
                Text(if (link.isRunning) "Stop the display" else "Start the display")
            }
            model.endedNotice?.let { Text(it, color = MaterialTheme.colorScheme.error, style = MaterialTheme.typography.bodyMedium) }
        }
    }

    GlassesPreview(model)
    Row(Modifier.fillMaxWidth().padding(horizontal = 16.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        FilledTonalButton({ model.input(HubModel.Input.previous) }, Modifier.weight(1f)) { Text("Back") }
        FilledTonalButton({ model.input(HubModel.Input.next) }, Modifier.weight(1f)) { Text("Next") }
        FilledTonalButton({ model.input(HubModel.Input.select) }, Modifier.weight(1f)) { Text("Select") }
        FilledTonalButton({ model.gesture(2) }, Modifier.weight(1f)) { Text("Menu") }
    }

    Group("Showing") {
        Choice("App", model.apps.map { it to it.title }, model.program) { model.closeMenu(); model.program = it }
        FlowRow(Modifier.padding(horizontal = 12.dp), horizontalArrangement = Arrangement.spacedBy(6.dp)) {
            for (app in model.favoriteApps) AssistChip({ model.closeMenu(); model.program = app }, { Text(app.title) })
        }
        Go("${model.program.title} settings") { nav.open(Page.App(model.program)) }
        when (model.program) {
            Program.timer -> {
                val now = System.currentTimeMillis() / 1000.0
                Info("Timer", HubTimer.clock(model.timer.remaining(now)))
                Buttons((if (model.timer.isRunning) "Pause" else "Start") to { if (model.timer.isRunning) model.timerPause() else model.timerStart() }, "Reset" to { model.timerReset() })
            }
            Program.reader -> {
                if (ReaderClock.Mode.entries.getOrNull(model.readerClock)?.usesTimer == true) Info("Reading for", ReaderClock.span(System.currentTimeMillis() / 1000.0 - model.readerStarted))
                Buttons("Reset timer" to { model.restartReaderTimer() }, "First page" to { model.pageRestart() }, (if (model.pagesPaused) "Resume pages" else "Hold page") to { model.togglePagesPaused() })
            }
            Program.trivia -> Buttons("New round" to { model.startTrivia() }, "Reveal" to { model.triviaReveal() }, "Next" to { model.triviaNext() })
            Program.news -> Buttons((if (model.reading == null) "Read story" else "Back to headlines") to { if (model.reading == null) model.readCurrent() else model.stopReading() })
            else -> {}
        }
        if (model.pageCount > 1) Info("Page", "${model.pageIndex + 1} of ${model.pageCount}")
    }

    Group("Send a note", "Shows on the glasses for a few seconds, over whatever is up.") {
        Field("Note", note) { note = it }
        Action("Send", enabled = note.isNotBlank()) { model.flash(note); note = "" }
    }
    Group {
        Go("Remote pad", "For a Bluetooth ring, clicker or keyboard") { nav.open(Page.Pad) }
    }
}
