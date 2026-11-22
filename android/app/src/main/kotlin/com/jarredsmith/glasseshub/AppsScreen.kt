package com.jarredsmith.glasseshub

import android.Manifest
import android.content.ClipboardManager
import android.content.Context
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.platform.LocalContext
import com.jarredsmith.glasseshub.core.ChordChart
import com.jarredsmith.glasseshub.core.DataFeed
import com.jarredsmith.glasseshub.core.DrumPattern
import com.jarredsmith.glasseshub.core.FeedKind
import com.jarredsmith.glasseshub.core.FeedParser
import com.jarredsmith.glasseshub.core.HubTimer
import com.jarredsmith.glasseshub.core.League
import com.jarredsmith.glasseshub.core.Metronome
import com.jarredsmith.glasseshub.core.MovieTracker
import com.jarredsmith.glasseshub.core.NewsSource
import com.jarredsmith.glasseshub.core.PickerMode
import com.jarredsmith.glasseshub.core.ReaderClock
import com.jarredsmith.glasseshub.core.Scoreboard
import com.jarredsmith.glasseshub.core.Stocks
import com.jarredsmith.glasseshub.core.SubtitleFile
import com.jarredsmith.glasseshub.core.TriviaRound
import java.util.Locale

@Composable
fun AppsScreen(model: HubModel) {
    val nav = LocalNav.current
    var search by remember { mutableStateOf("") }
    Group { Field("Search apps", search) { search = it } }
    val wanted = search.trim().lowercase()
    if (wanted.isNotEmpty()) {
        Group { for (app in model.apps.filter { it.title.lowercase().contains(wanted) || it.blurb.lowercase().contains(wanted) }) Go(app.title, app.blurb) { nav.open(Page.App(app)) } }
        return
    }
    Group { Go(Program.dashboard.title, Program.dashboard.blurb) { nav.open(Page.App(Program.dashboard)) } }
    for (group in model.menuGroups) Group(group.title) { for (app in group.items) Go(app.title + (if (model.isFavorite(app)) "  ★" else ""), app.blurb) { nav.open(Page.App(app)) } }
}

@Composable
fun AppPage(model: HubModel, program: Program) {
    val nav = LocalNav.current
    val ask = LocalAsk.current
    @Suppress("UNUSED_VARIABLE") val beat = model.pulse
    Group(footer = program.blurb) {
        Action(if (model.program == program) "Showing now" else "Show this on the glasses", enabled = model.program != program) { model.closeMenu(); model.program = program }
        Toggle("Pin to the Display tab", model.isFavorite(program)) { model.toggleFavorite(program) }
    }
    when (program) {
        Program.dashboard -> {
            Group("Lines to include", "The time and date are always on top. A running timer adds its own line. If there are more lines than fit, they take turns.") {
                Toggle("Score", model.dashScores) { model.dashScores = it }
                Toggle("Weather", model.dashWeather) { model.dashWeather = it }
                Toggle("Next calendar event", model.dashAgenda) { model.dashAgenda = it }
                Toggle("Top headline", model.dashNews) { model.dashNews = it }
                Toggle("First two stocks", model.dashStocks) { model.dashStocks = it }
                Field("Your own line (optional)", model.dashNote) { model.dashNote = it }
            }
            Group("Going blank", "The dashboard can go blank after a while and come back when you look up or use the crown. \"Close the page\" also lets the glasses show their own notifications while it's blank.") {
                Toggle("Go blank when idle", model.dashSleep) { model.dashSleep = it }
                if (model.dashSleep) {
                    Stepper("After ${model.dashSleepSeconds} seconds", model.dashSleepSeconds, 5..120, 5) { model.dashSleepSeconds = it }
                    Toggle("Close the page while blank", model.dashSleepCloses) { model.dashSleepCloses = it }
                }
            }
        }
        Program.scores -> {
            Group("Leagues") { for (league in League.entries) Check(league.title, league in model.leagues) { on -> model.leagues = if (on) model.leagues + league else model.leagues - league } }
            Group("Your teams", "Team abbreviations as the scoreboard writes them, separated by spaces: KC OKC NYY.") {
                Field("Teams", model.teams, capitals = true) { model.teams = it }
                Toggle("Alert me when they score", model.scoreAlerts) { model.scoreAlerts = it }
                Choice("Show", ScoresView.entries.map { it to it.title }, model.scoresView) { model.scoresView = it }
            }
            if (model.games.isNotEmpty()) Group("Games", "Tap one to keep it on the glasses.") {
                if (model.pinnedGame.isNotEmpty()) Action("Back to picking for me") { model.pinnedGame = "" }
                for (g in Scoreboard.ordered(model.games, model.followed).take(30)) Go(g.scoreLine + (if (g.id == model.game?.id) "  ●" else ""), "${g.league.short} ${g.shortStatus(System.currentTimeMillis() / 1000.0)}") { model.pinnedGame = g.id }
            } else Group { Note(model.scoresNote.ifEmpty { "Games show here once the scoreboard has been checked." }) }
        }
        Program.news -> {
            Group("Sources") {
                for (source in NewsSource.builtIn) Check(source.name, source.url in model.newsSourceList) { on -> model.newsSourceList = if (on) model.newsSourceList + source.url else model.newsSourceList - source.url }
                Field("Your own feed address (RSS)", model.customFeed) { model.customFeed = it }
            }
            Group(footer = "Zero keeps a headline up until you move on yourself.") {
                Stepper("Turn headlines every ${model.headlineSeconds.toInt()} s", model.headlineSeconds.toInt(), 0..60, 2) { model.headlineSeconds = it.toDouble() }
                Action("Check for news now") { model.refreshNews() }
            }
            if (model.reading != null) Group("Reading") {
                Note(model.reading?.title ?: "")
                Action("Copy the story into the Reader") { model.readerText = model.readingText }
                Action("Back to headlines") { model.stopReading() }
            }
            if (model.news.isNotEmpty()) Group("Headlines", "Tap one to read it on the glasses.") {
                for (item in model.news.take(25)) Go(item.title, item.source) { model.read(item) }
            } else Group { Note(model.newsNote.ifEmpty { "Headlines show here once they've been fetched." }) }
        }
        Program.agenda -> Group(footer = "Reads the calendars on this phone. Nothing is changed or sent anywhere.") {
            Choice("Show", AgendaView.entries.map { it to it.title }, model.agendaView) { model.agendaView = it }
            if (!model.calendarAllowed) Action("Allow calendar access") { ask(listOf(Manifest.permission.READ_CALENDAR)) { model.refreshPermissions() } }
            else Info("Events today", "${model.agenda.size}")
        }
        Program.weather -> Group(footer = "From Open-Meteo. Type a city name; add the state or country if there's more than one.") {
            Field("City", model.city) { model.city = it }
            Toggle("Celsius and km/h", model.celsius) { model.celsius = it }
            Choice("Show", WeatherView.entries.map { it to it.title }, model.weatherView) { model.weatherView = it }
            Note(model.weather?.let { "${it.place}: ${it.summary}" } ?: model.weatherNote)
        }
        Program.stocks -> StockSettings(model)
        Program.feeds -> {
            Group("Your feeds", "A feed is one number from a source of your own: glucose from Nightscout, a sensor from Home Assistant, or a value from any web address that answers with JSON or plain text.") {
                for (feed in model.feeds) Go(feed.title, FeedParser.line(feed, model.feedReadings[feed.id], model.feedNotes[feed.id] ?: "", System.currentTimeMillis() / 1000.0, arrows = true)) { nav.open(Page.Feed(feed.id)) }
                Action("Add a feed") { nav.open(Page.Feed(null)) }
                if (model.feeds.isNotEmpty()) Action("Check them all now") { model.refreshFeeds() }
            }
        }
        Program.reader, Program.speed -> {
            val context = LocalContext.current
            Group("Text", "The Reader shows this a page at a time; Speed read shows it a few words at a time.") {
                Field("Paste or type text", model.readerText, lines = 5) { model.readerText = it }
                Buttons("Paste" to {
                    val clip = (context.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager).primaryClip
                    clip?.getItemAt(0)?.coerceToText(context)?.toString()?.let { if (it.isNotBlank()) model.readerText = it }
                }, "Clear" to { model.readerText = "" })
            }
            if (program == Program.reader) Group("Clock and timer", "A line of timekeeping while you read, for using the Reader as a teleprompter. Turning the crown back on the first page sets the timer to zero.") {
                Choice("Show", listOf(0 to "Nothing", 1 to "Clock", 2 to "Time reading", 3 to "Clock and time reading", 4 to "Countdown", 5 to "Clock and countdown"), model.readerClock) { model.readerClock = it }
                if (ReaderClock.Mode.entries.getOrNull(model.readerClock)?.countsDown == true) Stepper("Target ${model.readerTargetMinutes} min", model.readerTargetMinutes, 1..180) { model.readerTargetMinutes = it }
                if (model.readerClock != 0) Toggle("On the top line", model.readerClockTop) { model.readerClockTop = it }
                Stepper("Turn pages every ${model.pageSeconds.toInt()} s", model.pageSeconds.toInt(), 0..60, 2) { model.pageSeconds = it.toDouble() }
                Action("Reset the timer") { model.restartReaderTimer() }
            } else Group("Speed", "Above about 200 words a minute the glasses can't redraw fast enough for one word at a time, so more words share a screen.") {
                Stepper("${model.speedWPM} words a minute", model.speedWPM, 100..900, 25) { model.speedWPM = it }
                Stepper("${model.speedSize} word${if (model.speedSize == 1) "" else "s"} at a time", model.speedChunk, 1..6) { model.speedChunk = it }
                Buttons((if (model.speedPlaying) "Pause" else "Play") to { model.program = Program.speed; model.toggleSpeedRead() }, "Start over" to { model.restartSpeedRead() })
            }
        }
        Program.message -> Group(footer = "Stays on the glasses until you change it.") { Field("Message", model.messageText, lines = 3) { model.messageText = it } }
        Program.movie -> MovieSettings(model)
        Program.live -> Group(footer = "Share text to Glasses Hub from any app and it shows here. A link works too: glasseshub://show?text=Hello&start=1") {
            Note(model.live.text.ifEmpty { "Nothing received yet." }.take(400))
            Toggle("Switch to Live text when text arrives", model.liveSwitches) { model.liveSwitches = it }
            if (model.live.text.isNotEmpty()) Action("Clear", danger = true) { model.clearLive() }
        }
        Program.translate -> {
            var key by remember { mutableStateOf(model.sonioxKey) }
            Group(footer = "Translates while the person is still speaking, through Soniox's service. It needs your own API key from console.soniox.com and an internet connection, and the audio is sent to Soniox's servers. Soniox bills your account by the hour of audio. The key stays on this phone. On the glasses: look up to start or stop.") {
                Choice("They speak", model.translateLanguages, model.translateFrom) { model.translateFrom = it }
                Choice("Show me", model.translateLanguages, model.translateTo) { model.translateTo = it }
                Field("Soniox API key", key, secret = true) { key = it; model.sonioxKey = it }
                Toggle("Label who's speaking", model.translateSpeakers) { model.translateSpeakers = it }
                Action(if (model.translateOn) "Stop listening" else "Start listening") { ask(listOf(Manifest.permission.RECORD_AUDIO)) { model.program = Program.translate; model.toggleTranslate() } }
                Note(model.translateNote)
            }
        }
        Program.chords -> {
            Group("Song", "Chords go in square brackets where they change: [G]Amazing [C]grace. Add a fingering after a colon: [G:320003].") {
                Choice("Chart", ChordChart.songs.map { it.id to it.title } + ("custom" to "My chart"), model.chordSong) { model.chordSong = it }
                if (model.chordSong == "custom") Field("Your chart", model.chordText, lines = 5) { model.chordText = it }
                Choice("Show", listOf(0 to "Chord name", 1 to "Name and frets", 2 to "Tab lines (small text)"), model.chordShow) { model.chordShow = it }
                Info("Chord changes", "${model.chordCount}")
            }
            Group(footer = "Listens through the phone's microphone and moves on when it hears the next chord. Strum each chord fully; keep the phone near the guitar.") {
                Action(if (model.chordOn) "Stop listening" else "Start listening") { ask(listOf(Manifest.permission.RECORD_AUDIO)) { model.program = Program.chords; model.toggleChords() } }
                Action("Back to the first chord") { model.restartChords() }
                Note(model.musicNote)
            }
        }
        Program.drums -> {
            Group("Groove", "Rows are HH, SD, BD and TM; x or o is a hit, - is a rest. A repeated row starts a new bar.") {
                Choice("Pattern", DrumPattern.library.map { it.name to it.name } + ("custom" to "My pattern"), model.drumPattern) { model.drumPattern = it }
                if (model.drumPattern == "custom") Field("Your pattern", model.drumText, lines = 4) { model.drumText = it }
                Stepper("Sensitivity ${model.drumSensitivity}", model.drumSensitivity, 1..9) { model.drumSensitivity = it }
                Action(if (model.drumOn) "Stop listening" else "Start listening") { ask(listOf(Manifest.permission.RECORD_AUDIO)) { model.program = Program.drums; model.toggleDrums() } }
                Action("Back to the first bar") { model.restartDrums() }
                if (model.drumOn) Info("Last heard", model.drumHeard.ifEmpty { "nothing yet" })
                Note(model.musicNote)
            }
            Group("Your kit", "Teaching the app your own drums makes it much better at telling them apart. It asks for four hits of each: kick, snare, hi-hat, tom.") {
                val prompt = model.drumCalibration
                if (prompt != null) {
                    Note(prompt)
                    Buttons("Skip this drum" to { model.skipCalibrationStage() }, "Cancel" to { model.cancelCalibration() })
                } else Action(if (model.drumKit.calibrated) "Teach it my kit again" else "Teach it my kit") { ask(listOf(Manifest.permission.RECORD_AUDIO)) { model.startCalibration() } }
                if (model.drumKit.calibrated && prompt == null) Action("Forget my kit", danger = true) { model.forgetKit() }
            }
        }
        Program.metronome -> Group(footer = "The clicks come from the phone. On the glasses: turn the crown to change the tempo.") {
            Stepper("${model.metroBPM} BPM  (${Metronome.tempoName(model.metroBPM)})", model.metroBPM, Metronome.range, 1) { model.metroBPM = it }
            Choice("Beats in a bar", listOf(2, 3, 4, 6).map { it to "$it" }, model.metroBeats) { model.metroBeats = it }
            Action(if (model.metroOn) "Stop" else "Start") { model.program = Program.metronome; model.toggleMetronome() }
        }
        Program.tuner -> Group(footer = "Play one note near the phone. Works for guitar, bass, ukulele, voice or anything else with a clear pitch.") {
            Action(if (model.tunerOn) "Stop listening" else "Start listening") { ask(listOf(Manifest.permission.RECORD_AUDIO)) { model.program = Program.tuner; model.toggleTuner() } }
            model.tunerReading?.let { Info("Hearing", "${it.note}${it.octave}  ${if (it.cents >= 0) "+" else ""}${it.cents} cents") }
            Note(model.tunerNote)
        }
        Program.timer -> Group {
            Stepper("${model.timerMinutes.toInt()} minutes", model.timerMinutes.toInt(), 1..180) { model.timerMinutes = it.toDouble() }
            Info("Left", HubTimer.clock(model.timer.remaining(System.currentTimeMillis() / 1000.0)))
            Buttons((if (model.timer.isRunning) "Pause" else "Start") to { if (model.timer.isRunning) model.timerPause() else model.timerStart() }, "Reset" to { model.timerReset() })
        }
        Program.picker -> Group(footer = "On the glasses: turn to change what to roll, look up to roll.") {
            Choice("Roll", PickerMode.entries.map { it to it.title }, model.pickerMode) { model.pickerMode = it }
            if (model.pickerMode == PickerMode.list) Field("Options, one per line", model.pickerOptions, lines = 4) { model.pickerOptions = it }
            Action("Roll now") { model.program = Program.picker; model.roll() }
            model.pickerResult?.let { Info("Result", it.text) }
        }
        Program.tour, Program.planes -> {
            Group(footer = if (program == Program.tour) "Places with a Wikipedia article within about a mile, nearest first. Look up to read about one."
                else "Aircraft within about 15 miles, from the adsb.lol community network, with each flight's route when it's known.") {
                val problem = model.nearbyProblem
                if (problem != null) { Note(problem); Action("Allow location") { ask(listOf(Manifest.permission.ACCESS_FINE_LOCATION, Manifest.permission.ACCESS_COARSE_LOCATION)) { model.refreshPermissions() } } }
                else Info(if (program == Program.tour) "Places nearby" else "Aircraft overhead", "${if (program == Program.tour) model.places.size else model.planes.size}")
                if (program == Program.tour) Toggle("Tell me when I walk past one", model.tourAnnounce) { model.tourAnnounce = it }
            }
        }
        Program.word -> Group(footer = "One daily word, then as many more as you like. On the glasses: turn to pick a letter, look up to guess it.") {
            Info("Streak", "${model.wordStreak}")
            Action("New word") { model.newWord() }
        }
        Program.twenty -> {
            var key by remember { mutableStateOf(model.aiKey) }
            Group("AI", "Uses Claude through your own Anthropic API key (console.anthropic.com). The key stays on this phone. Each game costs a fraction of a cent.") {
                Field("Anthropic API key", key, secret = true) { key = it; model.aiKey = it }
                Field("Model", model.aiModel) { model.aiModel = it }
                Action("Start a game") { model.program = Program.twenty; model.startTwenty() }
            }
        }
        Program.trivia -> Group(footer = "You host: read each question aloud from the glasses, and the answer follows.") {
            Stepper("${model.triviaCount} questions", model.triviaCount, 3..20) { model.triviaCount = it }
            Stepper("Answer after ${model.triviaQuestionSeconds.toInt()} s", model.triviaQuestionSeconds.toInt(), 0..60, 5) { model.triviaQuestionSeconds = it.toDouble() }
            Toggle("Move on by itself", model.triviaAuto) { model.triviaAuto = it }
            Action(if (model.round == null || model.round?.phase == TriviaRound.Phase.done) "Start a round" else "Start a new round") { model.startTrivia() }
            if (model.round != null) Buttons("Reveal" to { model.triviaReveal() }, "Next" to { model.triviaNext() }, "Stop" to { model.triviaStop() })
            Note(model.triviaNote)
        }
        Program.facts -> Group {
            Stepper("A new fact every ${model.factMinutes.toInt()} min", model.factMinutes.toInt(), 1..60) { model.factMinutes = it.toDouble() }
            Toggle("Prefer \"on this day\" facts", model.factsOnThisDay) { model.factsOnThisDay = it }
            Action("Another one now") { model.nextFact() }
        }
    }
}

@Composable
fun StockSettings(model: HubModel) {
    var typed by remember { mutableStateOf("") }
    var problem by remember { mutableStateOf("") }
    Group("Following", "Type ticker symbols separated by commas. Names work for the main ones: Dow, S&P 500, Nasdaq, Russell 2000, VIX, Bitcoin, Gold, Oil.") {
        for (symbol in model.stockSymbols) {
            val quote = model.stockQuotes[symbol]
            Go(Stocks.label(symbol) + (quote?.let { "   " + Stocks.money(it.price) + (it.percent?.let { p -> String.format(Locale.US, "  %+.2f%%", p) } ?: "") } ?: ""), "Tap to remove") { model.stockSymbols = model.stockSymbols - symbol }
        }
        Field("Add: AAPL, TSLA, Nasdaq…", typed, capitals = true) { typed = it }
        Action("Add", enabled = typed.isNotBlank()) { problem = if (model.addStocks(typed)) "" else "That doesn't look like a ticker symbol."; if (problem.isEmpty()) typed = "" }
        Note(problem.ifEmpty { model.stockNote })
    }
    Group(footer = "Prices come from Yahoo Finance and can be delayed by 15 minutes or more. For a glance only, not for trading decisions.") {
        Toggle("Show the first two on the dashboard", model.dashStocks) { model.dashStocks = it }
    }
}

@Composable
fun FeedEditor(model: HubModel, id: String?) {
    val nav = LocalNav.current
    val start = remember { model.feeds.firstOrNull { it.id == id } ?: DataFeed(kind = FeedKind.nightscout) }
    var feed by remember { mutableStateOf(start) }
    var token by remember { mutableStateOf(model.feedToken(start.id)) }
    Group {
        Choice("Kind", FeedKind.entries.map { it to it.title }, feed.kind) { feed = feed.copy(kind = it) }
        Field("Name (optional)", feed.name) { feed = feed.copy(name = it) }
        Field(when (feed.kind) { FeedKind.nightscout -> "Your Nightscout site"; FeedKind.homeAssistant -> "Home Assistant address"; FeedKind.custom -> "Web address" }, feed.address) { feed = feed.copy(address = it) }
        when (feed.kind) {
            FeedKind.nightscout -> {
                Field("Access token (if your site needs one)", token, secret = true) { token = it }
                Toggle("Show mmol/L", feed.unit == "mmol") { feed = feed.copy(unit = if (it) "mmol" else "") }
            }
            FeedKind.homeAssistant -> {
                Field("Entity, like sensor.living_room_temperature", feed.item) { feed = feed.copy(item = it) }
                Field("Long-lived access token", token, secret = true) { token = it }
            }
            FeedKind.custom -> {
                Field("Value to show, like data.0.price (blank for the whole answer)", feed.item) { feed = feed.copy(item = it) }
                Field("Text after the value (optional)", feed.unit) { feed = feed.copy(unit = it) }
                Field("Access token (optional)", token, secret = true) { token = it }
            }
        }
        Stepper("Check every ${feed.minutes} min", feed.minutes, 1..120) { feed = feed.copy(minutes = it) }
        Toggle("Show on the dashboard", feed.onDashboard) { feed = feed.copy(onDashboard = it) }
    }
    Group(footer = "Tokens are kept on this phone only. An address on your home network (http://192.168...) works while the phone is on that network.") {
        Action("Save") {
            model.saveFeeds(if (model.feeds.any { it.id == feed.id }) model.feeds.map { if (it.id == feed.id) feed else it } else model.feeds + feed)
            model.setFeedToken(feed.id, token)
            model.refreshFeeds()
            nav.back()
        }
        if (model.feeds.any { it.id == feed.id }) Action("Delete this feed", danger = true) { model.saveFeeds(model.feeds.filter { it.id != feed.id }); nav.back() }
    }
}

@Composable
fun MovieSettings(model: HubModel) {
    val nav = LocalNav.current
    val ask = LocalAsk.current
    val context = LocalContext.current
    var problem by remember { mutableStateOf("") }
    val picker = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocument()) { uri ->
        if (uri != null) {
            val bytes = try { context.contentResolver.openInputStream(uri)?.use { it.readBytes() } } catch (e: Exception) { null }
            val name = (try { context.contentResolver.query(uri, null, null, null, null)?.use { c -> if (c.moveToFirst()) c.getString(c.getColumnIndexOrThrow(android.provider.OpenableColumns.DISPLAY_NAME)) else null } } catch (e: Exception) { null } ?: "Subtitles").substringBeforeLast(".")
            problem = if (bytes == null) "Couldn't open that file." else if (model.addMovie(name, "Imported file", SubtitleFile.decode(bytes))) "" else "That doesn't look like a subtitle file (.srt or .vtt)."
        }
    }
    val now = System.currentTimeMillis() / 1000.0
    Group(footer = if (model.movieCanListen) "Start the film, then tap Start captions and leave the phone where it can hear. Once it recognises a line, the real subtitles follow along, and it finds its place again after a pause or a skip. On the glasses: click to pause or carry on, turn the crown to move the captions earlier or later."
        else "The captions are in a different language from the film, so they can't follow by ear. Tap Start at the first line as the first line is spoken, then use Earlier and Later (or the crown) to line them up.") {
        if (model.movie.isEmpty) Note("Nothing loaded yet. Find a movie or show below.")
        else {
            Info("Loaded", model.movieTitle)
            Info("Captions", when (model.movie.state) {
                MovieTracker.State.waiting -> if (model.movieOn) "Listening for a line…" else "Not started"
                MovieTracker.State.held -> "Paused at " + MovieTracker.clock(model.movie.position(now) ?: 0.0)
                MovieTracker.State.running -> MovieTracker.clock(model.movie.position(now) ?: 0.0) + " of " + MovieTracker.clock(model.movie.length)
            })
            if (model.movieCanListen) Action(if (model.movieOn) "Stop listening" else "Start captions") {
                ask(listOf(Manifest.permission.RECORD_AUDIO)) { if (!model.movieOn) model.program = Program.movie; model.toggleMovie() }
            }
            if (model.movie.state != MovieTracker.State.waiting || !model.movieCanListen) Action(when (model.movie.state) { MovieTracker.State.running -> "Pause the captions"; MovieTracker.State.held -> "Carry on"; else -> "Start at the first line" }) { model.program = Program.movie; model.holdMovie() }
            if (model.movie.state != MovieTracker.State.waiting) Buttons("Earlier" to { model.nudgeMovie(0.5) }, "Later" to { model.nudgeMovie(-0.5) }, "Start over" to { model.restartMovie() })
        }
        Note(model.movieNote)
    }
    Group(footer = "Importing takes an .srt or .vtt file from the phone's storage or a cloud drive.") {
        Go("Find a movie or show") { nav.open(Page.MovieSearch) }
        Action("Import a subtitle file") { picker.launch(arrayOf("*/*")) }
        Note(problem)
    }
    if (model.movieLibrary.isNotEmpty()) Group("On this phone", "Tap to load one. The last thirty are kept.") {
        for (entry in model.movieLibrary) Go(entry.title + (if (entry.id == model.movieCurrent) "  ✓" else ""), entry.detail) { model.movieCurrent = entry.id }
        model.movieLibrary.firstOrNull { it.id == model.movieCurrent }?.let { current -> Action("Remove \"${current.title}\"", danger = true) { model.removeMovie(current) } }
    }
    var key by remember { mutableStateOf(model.subtitleKey) }
    Group(footer = "Pick a captions language different from the film's to read a translation. \"Pause when the room goes quiet\" holds the captions if half a minute of dialogue goes by unheard, which usually means the film was paused." +
        (if (SubtitleSearch.builtInKey.isEmpty()) "\n\nSearching needs a free API key from opensubtitles.com (sign in, then Consumers > New consumer). Importing a file works without one." else "") +
        "\n\nSubtitle files come from OpenSubtitles.com, where volunteers upload them. The phone's speech recognition is used only to match the dialogue.") {
        Choice("Captions in", SubtitleSearch.languages.map { it.code to it.name }, model.movieLanguage) { model.movieLanguage = it }
        Choice("The film is in", SubtitleSearch.languages.map { it.code to it.name }, model.movieAudio) { model.movieAudio = it }
        Toggle("Pause when the room goes quiet", model.movieHolds) { model.movieHolds = it }
        if (SubtitleSearch.builtInKey.isEmpty()) Field("OpenSubtitles API key", key, secret = true) { key = it; model.subtitleKey = it }
    }
}

@Composable
fun MovieSearchPage(model: HubModel) {
    val nav = LocalNav.current
    var typed by remember { mutableStateOf("") }
    var results by remember { mutableStateOf<List<SubtitleSearch.Title>>(emptyList()) }
    var busy by remember { mutableStateOf(false) }
    var note by remember { mutableStateOf("") }
    Group {
        Field("Name of a movie or show", typed) { typed = it }
        Action(if (busy) "Searching…" else "Search", enabled = !busy && typed.trim().length >= 2) {
            if (model.movieKey.isEmpty()) note = "Add an OpenSubtitles API key on the previous page to search, or import a file instead."
            else {
                busy = true; note = ""
                SubtitleSearch.titles(typed.trim(), model.movieKey) { found, problem -> busy = false; results = found; note = problem ?: (if (found.isEmpty()) "Nothing found by that name." else "") }
            }
        }
        Note(note)
    }
    if (results.isNotEmpty()) Group { for (title in results) Go(title.title, listOf(if (title.isSeries) "Series" else "Movie", title.year).filter { it.isNotEmpty() }.joinToString(" · ")) { nav.open(Page.MovieVersions(title)) } }
}

@Composable
fun MovieVersionsPage(model: HubModel, title: SubtitleSearch.Title) {
    val ask = LocalAsk.current
    var season by remember { mutableIntStateOf(1) }
    var episode by remember { mutableIntStateOf(1) }
    var versions by remember { mutableStateOf<List<SubtitleSearch.Version>>(emptyList()) }
    var busy by remember { mutableStateOf(false) }
    var looked by remember { mutableStateOf(false) }
    var note by remember { mutableStateOf("") }
    var done by remember { mutableStateOf(false) }
    val label = if (title.isSeries || title.year.isEmpty()) title.title else "${title.title} (${title.year})"
    fun look() {
        if (busy) return
        busy = true; looked = true; note = ""; done = false
        SubtitleSearch.versions(title, season, episode, model.movieLanguage, model.movieKey) { found, problem -> busy = false; versions = found; note = problem ?: (if (found.isEmpty()) "No subtitles in that language for this one." else "") }
    }
    fun get(version: SubtitleSearch.Version) {
        if (busy) return
        busy = true; note = ""
        SubtitleSearch.download(version, model.movieKey) { text, problem ->
            busy = false
            if (text != null && model.addMovie(if (title.isSeries) "${title.title} S${season}E${episode}" else label, version.release, text)) done = true
            else note = problem ?: "That file couldn't be read. Try another version."
        }
    }
    if (title.isSeries) Group {
        Stepper("Season $season", season, 0..60) { season = it }
        Stepper("Episode $episode", episode, 1..400) { episode = it }
        Action("Find this episode", enabled = !busy) { look() }
    } else if (!looked) { looked = true; look() }
    if (busy) Group { Note("Working…") }
    if (note.isNotEmpty()) Group { Note(note) }
    if (done) Group(footer = "Start the film first. If the timing looks off for this copy of the film, try another version below.") {
        Info("Ready", model.movieTitle)
        Action("Start captions") { ask(listOf(Manifest.permission.RECORD_AUDIO)) { model.program = Program.movie; if (!model.movieOn) model.toggleMovie() } }
    }
    if (versions.isNotEmpty()) Group("Versions", "Different releases of a film can be timed a little differently. The most downloaded is usually right.") {
        if (!done) Action("Get the most popular", enabled = !busy) { get(versions[0]) }
        for (version in versions.take(12)) Go(version.release, "${version.downloads} downloads" + (if (version.hearingImpaired) " · includes sounds" else "")) { get(version) }
    }
}
