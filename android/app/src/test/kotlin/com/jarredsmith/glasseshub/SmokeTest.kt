package com.jarredsmith.glasseshub

import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.MaterialTheme
import androidx.compose.ui.Modifier
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.test.core.app.ApplicationProvider
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import kotlin.test.assertTrue

/** Starts the app's brain and draws every screen once, to catch anything that would crash on a phone. */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34], application = HubApp::class)
class SmokeTest {
    @get:Rule val compose = createComposeRule()
    private val model: HubModel get() = ApplicationProvider.getApplicationContext<HubApp>().model

    @Test fun everyAppDrawsACardAndTakesInput() {
        val now = System.currentTimeMillis() / 1000.0
        for (program in Program.entries) {
            model.program = program
            model.tick()
            assertTrue(model.currentCard(now).lines.isNotEmpty(), "${program.name} drew nothing")
            for (step in listOf(HubModel.Input.next, HubModel.Input.select, HubModel.Input.previous, HubModel.Input.next, HubModel.Input.select)) { model.input(step); model.tick() }
            model.closeMenu()
        }
        // the menu, from top to an app and back
        model.program = Program.dashboard
        model.gesture(2); model.tick()
        repeat(3) { model.input(HubModel.Input.next); model.tick() }
        model.input(HubModel.Input.select); model.tick()
        model.input(HubModel.Input.next); model.input(HubModel.Input.select); model.tick()
        model.gesture(5)
        // alerts, notices, test cards, rings
        model.flash("Hello there"); model.showTestCard(); model.showSymbolTest(); model.tick()
        model.phoneNotice("com.whatsapp", "WhatsApp", "Sam", "On my way")
        for (event in RemoteEvent.entries) model.ring(event)
        model.showLive("Shared text", append = false); model.tick()
        model.startDisplay(); model.tick(); model.stopDisplay()
        model.startPractice(); model.tick(); model.stopPractice()
        assertTrue(model.preview.isNotEmpty())
    }

    @Test fun everyScreenDraws() {
        val pages: List<Pair<String, @androidx.compose.runtime.Composable () -> Unit>> = buildList {
            add("display" to { DisplayScreen(model) })
            add("apps" to { AppsScreen(model) })
            add("settings" to { SettingsScreen(model) })
            for (program in Program.entries) add("app ${program.name}" to { AppPage(model, program) })
            for (name in listOf("Screen and text", "Glasses controls", "Phone buttons and remotes", "Notifications and alerts", "Help", "Advanced")) add("setting $name" to { SettingPage(model, name) })
            add("practice" to { PracticePage(model) })
            add("feed" to { FeedEditor(model, null) })
            add("movie search" to { MovieSearchPage(model) })
            add("movie versions" to { MovieVersionsPage(model, SubtitleSearch.Title(1, "Test", "2020", true)) })
            add("pad" to { RemotePad(model) })
        }
        var index = androidx.compose.runtime.mutableIntStateOf(0)
        compose.setContent {
            MaterialTheme {
                CompositionLocalProvider(LocalNav provides Nav()) {
                    Column(Modifier.verticalScroll(rememberScrollState())) { androidx.compose.runtime.key(index.intValue) { pages[index.intValue].second() } }
                }
            }
        }
        for (i in pages.indices) {
            index.intValue = i
            try { compose.waitForIdle() } catch (e: Throwable) { throw AssertionError("Screen '${pages[i].first}' failed: $e", e) }
        }
    }
}
