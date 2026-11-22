package com.jarredsmith.glasseshub

import android.content.Context
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import com.jarredsmith.glasseshub.core.*
import java.io.File
import java.time.Instant
import java.time.ZoneId
import java.util.Locale
import java.util.UUID
import kotlin.math.ceil
import kotlin.math.max
import kotlin.math.min
import kotlin.math.pow

enum class Program(val title: String, val blurb: String) {
    dashboard("Dashboard", "Time, score, weather and your next event on one screen."),
    scores("Scoreboard", "Live score, box score by period, or the whole league as a table."),
    news("News", "Headlines that turn by themselves, and full stories a page at a time."),
    agenda("Calendar", "Today's events, or the month as a grid."),
    weather("Weather", "Now, the next 12 hours as a table, or the week ahead."),
    stocks("Stocks", "The Dow, the S&P 500 and any stocks you follow."),
    feeds("Data feeds", "Numbers from your own sources: Nightscout, Home Assistant, or any web address."),
    reader("Reader", "Paste any text and read it a page at a time."),
    speed("Speed read", "The Reader's text a few words at a time, in one spot."),
    message("Message", "Put a line of text on the glasses and leave it there."),
    movie("Movie captions", "A film's real subtitles, kept in step by listening to the dialogue."),
    live("Live text", "Text shared from another app, or sent by a link."),
    chords("Guitar chords", "A chord chart that listens and moves on as you play."),
    drums("Drum trainer", "Learn a groove a bar at a time; it hears your kit."),
    metronome("Metronome", "Clicks from your phone; set the tempo with the crown."),
    tuner("Tuner", "Play a note near your phone and see how far off it is."),
    timer("Timer", "A countdown you can see without looking down."),
    picker("Dice & coin", "Flip a coin, roll dice, or pick from your own list."),
    tour("Walking tour", "What's around you, from Wikipedia, as you walk."),
    planes("Planes overhead", "The flight above you: where it's going, how high, which way to look."),
    word("Word game", "Guess the daily word a letter at a time."),
    twenty("20 questions", "Think of something and an AI tries to guess it."),
    trivia("Trivia host", "You read the question off your glasses; the answer follows."),
    facts("Odd facts", "A new surprising fact every few minutes."),
}

enum class AlertStyle(val title: String) {
    auto("Display when it's on, else notify"), display("Display only"), notification("Notifications only"), both("Both")
}
enum class ScoresView(val title: String) { auto("Game, then box score"), game("Game"), box("Box score"), league("All games") }
enum class WeatherView(val title: String) { cycle("Take turns"), now("Now"), hours("Next 12 hours"), week("Week") }
enum class AgendaView(val title: String) { cycle("Take turns"), list("Today's events"), month("Month") }

/** What a Bluetooth ring, clicker or keyboard can send that the app is able to see. */
enum class RemoteEvent(val title: String, /** 0 next, 1 select, 2 apps menu, 3 previous, 4 nothing, 5 dashboard */ val usual: Int) {
    swipeUp("Swipe up", 0), swipeDown("Swipe down", 3), swipeLeft("Swipe left", 0), swipeRight("Swipe right", 3), tap("Tap", 1),
    zoomIn("Zoom in", 0), zoomOut("Zoom out", 3), keyNext("Right, down, space or page down key", 0), keyPrevious("Left, up or page up key", 3),
    keySelect("Enter or play/pause key", 1), keyMenu("Escape or back key", 2),
}

class MovieEntry(val id: String, val title: String, val detail: String)
class GroupOfApps(val title: String, val items: List<Program>)

/**
 * The app's brain: settings, the data each app shows, and the loop that decides what the glasses should
 * say right now.
 */
class HubModel(val context: Context) {
    val link = GlassesLink(context)
    val settings = Settings(context.getSharedPreferences("hub", Context.MODE_PRIVATE))
    private val secrets = context.getSharedPreferences("keys", Context.MODE_PRIVATE)
    private val s = settings
    val notifier = Notifier(context)
    private val calendar = CalendarReader(context)
    private val locator = Locator(context)
    private val sound = ToolSound(context)
    private val ear = MusicEar(context)
    private val listener = SpeechListener(context)
    private fun now() = HubClock.now()
    private val never = 0.0

    private fun secret(name: String) = secrets.getString(name, "") ?: ""
    private fun setSecret(name: String, value: String) = secrets.edit().putString(name, value.trim()).apply()

    /** Bumped on every pass of the loop, for screens that show something the loop changes. */
    var pulse by mutableIntStateOf(0); private set

    // MARK: Settings (saved)

    var program: Program by s.choice("program", Program.dashboard, Program.entries) { programChanged() }
    var textSize: TextSize by s.choice("textSize", TextSize.small, TextSize.entries)
    var columnsSmall: Int by s.int("columnsSmall", TextSize.small.defaultColumns)
    var columnsLarge: Int by s.int("columnsLarge", TextSize.large.defaultColumns)
    var refreshScreen: Boolean by s.bool("refreshScreen", true)
    var alertStyle: AlertStyle by s.choice("alertStyle", AlertStyle.auto, AlertStyle.entries)
    var alertSeconds: Double by s.number("alertSeconds", 10.0)
    var glyphStyle: GlyphStyle by s.choice("glyphStyle", GlyphStyle.symbols, GlyphStyle.entries)
    var pageSeconds: Double by s.number("pageSeconds", 12.0)
    var volumePaging: Boolean by s.bool("volumePaging", true)
    var liveSwitches: Boolean by s.bool("liveSwitches", true)
    var centering: Int by s.int("centering", 0)
    var setupSeen: Boolean by s.bool("setupSeen", false)
    var logEvents: Boolean by s.bool("logEvents", false) { link.logEvents = logEvents }

    // Controls
    var headPaging: Boolean by s.bool("lookUp", true)
    /** What a look up, double click or button does: 0 next, 1 select, 2 apps menu, 3 previous, 4 nothing, 5 dashboard. */
    var headAction: Int by s.int("headAction", 1)
    var volumeUpAction: Int by s.int("volumeUpAction", 0)
    var volumeDownAction: Int by s.int("volumeDownAction", 1)
    var doubleClickAction: Int by s.int("doubleClickAction", 2)
    var crownPaging: Boolean by s.bool("crownPaging", true)
    /** Turning the crown back is told apart from turning it forward. Needs a line of scroll room above each screen. */
    var crownBack: Boolean by s.bool("crownTwoWay", true)
    var crownScroll: Boolean by s.bool("crownScroll", false)
    var holdSelects: Boolean by s.bool("holdSelects", false)
    var clickRearm: Int by s.int("clickRearm2", 0) { link.rearm = clickRearm }
    var translationMode: Int by s.int("translationMode", 0) { link.translationMode = translationMode }
    var menuHintsLeft: Int by s.int("menuHintsLeft", 8)
    private var ringMapText: String by s.text("ringMap", "{}")
    var ringLast by mutableStateOf(""); private set

    // Phone notifications on the glasses (Android can read them; the glasses themselves block them while the page is up)
    var phoneNotices: Boolean by s.bool("phoneNotices", true)
    var noticeSeconds: Double by s.number("noticeSeconds", 8.0)
    var noticeSkip: String by s.text("noticeSkip", "")
    /** Say which app a notification came from when the glasses report blocking one (when notices aren't being read). */
    var noticeBlocked: Boolean by s.bool("noticeBlocked", true)

    // Pop-up mode: the display stays closed until something comes in, opens for it, then closes again.
    var popUps: Boolean by s.bool("popUps", false) { popFactDue = now() + max(1.0, popFactMinutes) * 60; applyKeepAwake() }
    var popFactMinutes: Double by s.number("popFactMinutes", 30.0) { popFactDue = now() + max(1.0, popFactMinutes) * 60 }

    // Dashboard
    var dashScores: Boolean by s.bool("dashScores", true)
    var dashWeather: Boolean by s.bool("dashWeather", true)
    var dashAgenda: Boolean by s.bool("dashAgenda", true)
    var dashNews: Boolean by s.bool("dashNews", false)
    var dashStocks: Boolean by s.bool("dashStocks", false) { stocksDue = never }
    var dashNote: String by s.text("dashNote", "")
    var dashSleep: Boolean by s.bool("dashSleep", false) { wakeDashboard() }
    var dashSleepSeconds: Int by s.int("dashSleepSeconds", 20) { wakeDashboard() }
    var dashSleepCloses: Boolean by s.bool("dashSleepCloses", false) { wakeDashboard() }
    private var dashAwakeUntil = Double.MAX_VALUE
    private val dashAsleep: Boolean get() = dashSleep && program == Program.dashboard && !menuOpen && now() > dashAwakeUntil
    private fun wakeDashboard() { dashAwakeUntil = now() + max(5, dashSleepSeconds) }

    // Scores
    var scoresView: ScoresView by s.choice("scoresView", ScoresView.auto, ScoresView.entries)
    var pinnedGame: String by s.text("pinnedGame", "") { repick() }
    private var leagueNames: List<String> by s.texts("leagues", listOf("nfl")) { scoresDue = never }
    var leagues: Set<League>
        get() = leagueNames.mapNotNull { n -> League.entries.firstOrNull { it.name == n } }.toSet()
        set(value) { leagueNames = value.map { it.name }.sorted() }
    var teams: String by s.text("teams", "KC") { lastGame = null }
    var scoreAlerts: Boolean by s.bool("scoreAlerts", true)

    // News
    var newsSourceList: List<String> by s.texts("newsSources", listOf(NewsSource.builtIn[0].url, NewsSource.builtIn[1].url)) { newsDue = never }
    var customFeed: String by s.text("customFeed", "") { newsDue = never }
    var headlineSeconds: Double by s.number("headlineSeconds", 12.0)

    // Weather, calendar
    var weatherView: WeatherView by s.choice("weatherView", WeatherView.cycle, WeatherView.entries)
    var agendaView: AgendaView by s.choice("agendaView", AgendaView.cycle, AgendaView.entries)
    var city: String by s.text("city", "Oklahoma City") { weatherDue = never }
    var celsius: Boolean by s.bool("celsius", false) { weatherDue = never }

    // Trivia and facts
    var triviaCount: Int by s.int("triviaCount", 10)
    var triviaQuestionSeconds: Double by s.number("triviaQuestionSeconds", 20.0)
    var triviaAnswerSeconds: Double by s.number("triviaAnswerSeconds", 8.0)
    var triviaAuto: Boolean by s.bool("triviaAuto", true)
    var factMinutes: Double by s.number("factMinutes", 5.0)
    var factsOnThisDay: Boolean by s.bool("factsOnThisDay", false)

    // Reader, message, timer
    var readerText: String by s.text("readerText", "")
    var messageText: String by s.text("messageText", "")
    var timerMinutes: Double by s.number("timerMinutes", 10.0)
    /** The Reader's timekeeping line, for using it as a teleprompter (a ReaderClock.Mode by position). */
    var readerClock: Int by s.int("readerClock", 0) { pager = AutoPager() }
    var readerClockTop: Boolean by s.bool("readerClockTop", true)
    var readerTargetMinutes: Int by s.int("readerTargetMinutes", 10)
    var readerStarted by mutableStateOf(now()); private set
    fun restartReaderTimer() { readerStarted = now() }

    // Tools
    var metroBPM: Int by s.int("metroBPM", 100) { if (metroOn) sound.startMetronome(metroBPM, metroBeats) }
    var metroBeats: Int by s.int("metroBeats", 4) { if (metroOn) sound.startMetronome(metroBPM, metroBeats) }
    var metroOn by mutableStateOf(false); private set
    var tunerOn by mutableStateOf(false); private set
    var tunerReading by mutableStateOf<TunerReading?>(null); private set
    var tunerNote by mutableStateOf(""); private set
    private var tunerHeardAt = never
    var speedWPM: Int by s.int("speedWPM", 200) { speedAnchor() }
    var speedChunk: Int by s.int("speedChunk", 2) { speedAnchor() }
    val speedSize: Int get() = SpeedRead.size(speedWPM, speedChunk)
    var speedPlaying by mutableStateOf(false); private set
    var speedIndex by mutableIntStateOf(0); private set
    private var speedWords: Pair<String, List<String>> = "" to emptyList()
    private var speedShownAt = never
    var pickerMode: PickerMode by s.choice("pickerMode", PickerMode.coin, PickerMode.entries)
    var pickerOptions: String by s.text("pickerOptions", "Pizza\nTacos\nSushi\nBurgers")
    var pickerResult by mutableStateOf<PickerResult?>(null); private set
    private var pickerRolledAt = never

    // Stocks
    var stockSymbols: List<String> by s.texts("stockSymbols", Stocks.defaults) { stocksDue = never }
    var stockQuotes by mutableStateOf<Map<String, StockQuote>>(emptyMap()); private set
    var stockNote by mutableStateOf(""); private set
    private var stocksDue = never
    private var stockPage = 0
    fun addStocks(typed: String): Boolean {
        val found = Stocks.symbols(typed)
        stockSymbols = stockSymbols + found.filter { it !in stockSymbols }
        return found.isNotEmpty()
    }

    // Data feeds. Access tokens are kept apart from the other settings.
    var feeds by mutableStateOf(s.json("dataFeeds").list()?.mapNotNull { it.dict()?.let { m -> DataFeed.from(m) } } ?: emptyList()); private set
    var feedReadings by mutableStateOf<Map<String, FeedReading>>(emptyMap()); private set
    var feedNotes by mutableStateOf<Map<String, String>>(emptyMap()); private set
    private val feedDue = HashMap<String, Double>()
    fun saveFeeds(list: List<DataFeed>) {
        for (old in feeds) if (list.none { it.id == old.id }) { setSecret("feed." + old.id, ""); feedReadings = feedReadings - old.id; feedNotes = feedNotes - old.id; feedDue.remove(old.id) }
        feeds = list
        s.putJson("dataFeeds", list.map { it.toMap() })
    }
    fun feedToken(id: String) = secret("feed.$id")
    fun setFeedToken(id: String, token: String) { setSecret("feed.$id", token); feedDue.remove(id) }

    // Music trainers
    var chordSong: String by s.text("chordSong", "grace") { loadChords() }
    var chordText: String by s.text("chordText", "[G]Put each chord in brackets [C]where it changes\n[D]One line of the song per [G]line") { if (chordSong == "custom") loadChords() }
    /** How the chord is drawn: 0 its name only, 1 with its six frets, 2 as six tab lines. */
    var chordShow: Int by s.int("chordShow", 1)
    var chordOn by mutableStateOf(false); private set
    private var follower = ChordFollower(emptyList())
    val chordCount: Int get() = follower.steps.size
    var drumPattern: String by s.text("drumPattern", "Basic rock") { loadDrums() }
    var drumText: String by s.text("drumText", "HH x-x-x-x-x-x-x-x-\nSD ----o-------o---\nBD o-------o-------") { if (drumPattern == "custom") loadDrums() }
    var drumOn by mutableStateOf(false); private set
    var drumKit by mutableStateOf(s.json("drumKit").dict()?.let { DrumKit.from(it) } ?: DrumKit.standard); private set
    var drumSensitivity: Int by s.int("drumSensitivity", 5)
    var drumHeard by mutableStateOf(""); private set
    /** While teaching the app the kit: what to hit next. Null when not teaching. */
    var drumCalibration by mutableStateOf<String?>(null); private set
    private var calibrationStage = 0
    private var calibrationHits = ArrayList<DrumHit>()
    private var calibrationVoices = HashMap<Drum, DrumKit.Voice>()
    private var trainer = DrumTrainer(DrumPattern.library[1])
    var musicNote by mutableStateOf(""); private set

    // Games
    var wordGame = s.json("wordGame").dict()?.let { WordGame.from(it) } ?: WordGame.day(now()).let { WordGame(WordGame.daily(it), it) }
        private set
    private var wordStreakSaved: Int by s.int("wordStreak", 0)
    val wordStreak: Int get() = wordStreakSaved
    private var wordWinDay: Int by s.int("wordWinDay", 0)
    private var wordDoneDay: Int by s.int("wordDoneDay", 0)
    private fun saveWord() = s.putJson("wordGame", wordGame.toMap())
    var twenty = TwentyQuestions(); private set
    private var twentyRun = 0
    var aiKey: String
        get() = secret("anthropic")
        set(value) { setSecret("anthropic", value); pulse++ }
    var aiModel: String by s.text("aiModel", "claude-haiku-5-5")

    // What's around the wearer
    var planes by mutableStateOf<List<Aircraft>>(emptyList()); private set
    private var planeRoutes = HashMap<String, PlaneRoute>()
    private var planeIndex = 0
    private var planeNote = ""
    private var planesDue = never
    private val routesAsked = HashSet<String>()
    var places by mutableStateOf<List<NearbyPlace>>(emptyList()); private set
    private var placeIndex = 0
    private var tourOpen = false
    private var tourNote = ""
    private var tourDue = never
    private var tourAt: Pair<Double, Double>? = null
    private val tourSeen = HashSet<Int>()
    var tourAnnounce: Boolean by s.bool("tourAnnounce", false)
    private val metricUnits: Boolean get() = Locale.getDefault().country !in setOf("US", "LR", "MM")
    /** Why the nearby apps have nothing to show, when it's about location. */
    val nearbyProblem: String? get() = if (locator.denied) "Allow location for Glasses Hub in the phone's Settings." else if (locator.latitude == null) "Finding where you are…" else null

    // Movie captions
    var movieLibrary by mutableStateOf(s.json("movieLibrary").list()?.mapNotNull { m -> m.at("id").str()?.let { MovieEntry(it, m.at("title").str() ?: "", m.at("detail").str() ?: "") } } ?: emptyList()); private set
    var movieCurrent: String by s.text("movieCurrent", "") { loadMovie() }
    var movieLanguage: String by s.text("movieLanguage", "en")
    var movieAudio: String by s.text("movieAudio", "en") { if (movieOn) stopMovie() }
    var movieHolds: Boolean by s.bool("movieHolds", true) { movie.holdsWhenQuiet = movieHolds }
    var subtitleKey: String
        get() = secret("opensubtitles")
        set(value) { setSecret("opensubtitles", value); pulse++ }
    var movieOn by mutableStateOf(false); private set
    var movieNote by mutableStateOf(""); private set
    var movie = MovieTracker(emptyList()); private set
    val movieTitle: String get() = movieLibrary.firstOrNull { it.id == movieCurrent }?.title ?: ""
    val movieKey: String get() = subtitleKey.trim().ifEmpty { SubtitleSearch.builtInKey }
    /** Whether the dialogue can be followed by ear: only when the captions are in the language being spoken. */
    val movieCanListen: Boolean get() = movieLanguage == movieAudio

    // Favourites
    var favorites: List<String> by s.texts("favorites", listOf("dashboard", "scores", "news", "weather", "timer", "reader"))
    val favoriteApps: List<Program> get() = favorites.mapNotNull { n -> Program.entries.firstOrNull { it.name == n } }
    fun isFavorite(program: Program) = program.name in favorites
    fun toggleFavorite(program: Program) { favorites = if (program.name in favorites) favorites - program.name else favorites + program.name }

    /** The menu on the glasses: the dashboard, then groups of apps. */
    val menuGroups = listOf(
        GroupOfApps("Info", listOf(Program.scores, Program.news, Program.agenda, Program.weather, Program.stocks, Program.feeds)),
        GroupOfApps("Reading", listOf(Program.reader, Program.speed, Program.message, Program.movie, Program.live)),
        GroupOfApps("Music", listOf(Program.chords, Program.drums, Program.metronome, Program.tuner)),
        GroupOfApps("Tools", listOf(Program.timer, Program.picker)),
        GroupOfApps("Nearby", listOf(Program.tour, Program.planes)),
        GroupOfApps("Fun", listOf(Program.word, Program.twenty, Program.trivia, Program.facts)),
    )
    var menuGroup by mutableStateOf<Int?>(null); private set
    private val menuTitles: List<String> get() {
        val g = menuGroup
        return if (g != null && g in menuGroups.indices) listOf("< Back") + menuGroups[g].items.map { it.title } else listOf(Program.dashboard.title) + menuGroups.map { it.title + " >" }
    }

    // MARK: Live state

    val live = LiveText()
    var liveReceivedAt by mutableStateOf<Double?>(null); private set
    private var livePage = 0
    var preview by mutableStateOf(""); private set
    var previewScrolls by mutableStateOf(false); private set
    var game by mutableStateOf<Game?>(null); private set
    var scoresNote by mutableStateOf(""); private set
    var weather by mutableStateOf<Weather?>(null); private set
    var weatherNote by mutableStateOf(""); private set
    var agenda by mutableStateOf<List<AgendaItem>>(emptyList()); private set
    var calendarAllowed by mutableStateOf(false); private set
    var fact by mutableStateOf<String?>(null); private set
    var round: TriviaRound? = null; private set
    var triviaNote by mutableStateOf(""); private set
    var timer = HubTimer.minutes(timerMinutes); private set
    var games by mutableStateOf<List<Game>>(emptyList()); private set
    var pageIndex by mutableIntStateOf(0); private set
    var pageCount by mutableIntStateOf(1); private set
    var pagesPaused by mutableStateOf(false); private set
    var news by mutableStateOf<List<NewsItem>>(emptyList()); private set
    var newsIndex by mutableIntStateOf(0); private set
    var newsNote by mutableStateOf(""); private set
    var menuOpen by mutableStateOf(false); private set
    var menuIndex by mutableIntStateOf(0); private set
    /** The current list has been scrolled past its last item, to the "end of list" stop. */
    var listEnd by mutableStateOf(false); private set
    var week by mutableStateOf<List<AgendaItem>>(emptyList()); private set
    var reading by mutableStateOf<NewsItem?>(null); private set
    var readingNote by mutableStateOf(""); private set
    var notificationsAllowed by mutableStateOf(false); private set
    /** Why the display last stopped on its own, until the user dismisses it or starts again. */
    var endedNotice by mutableStateOf<String?>(null)
    var practicing by mutableStateOf(false); private set
    var practiced by mutableStateOf(listOf(false, false, false, false)); private set

    private val overlays = OverlayQueue()
    private var inFront = true
    private var lastGame: Game? = null
    private var watched = HashMap<String, Game>()
    private var pager = AutoPager()
    private var popupOpen = false
    private var scrollingBlock = false
    private var sectionIndex = 0
    private var sectionKey = ""
    private var agendaStep = 0
    private var weatherStep: Int? = null
    private var popFactDue = Double.MAX_VALUE
    /** Alerts queued for a pop-up that hasn't opened yet, kept so they can go out as notifications if it can't. */
    private val unshown = ArrayList<Pair<String, String>>()
    private val nextGames = HashMap<String, Pair<Game?, Double>>()
    private var newsDue = never
    private var headlineTurnedAt = now()
    private val articles = HashMap<String, String>()
    private var wrapped: Pair<String, List<String>> = "" to emptyList()
    private var testCardsUntil = never
    private var scoresDue = never
    private var scoresAt = never
    private var weatherDue = never
    private var place: Weather.Place? = null
    private var agendaDue = never
    private var factDue = never
    private val fetching = HashSet<String>()
    private var timerAnnounced = false
    private var ringWaiting: Pair<RemoteEvent, Runnable>? = null

    init {
        link.logEvents = logEvents
        link.translationMode = translationMode
        link.rearm = clickRearm
        loadChords(); loadDrums(); loadMovie()
        calendarAllowed = calendar.allowed
        notificationsAllowed = notifier.allowed
        ear.onChroma = { chroma, level -> heardChroma(chroma, level) }
        ear.onHit = { hit -> heardHit(hit) }
        sound.onPitch = { hz -> heardPitch(hz) }
        listener.onPartial = { text -> heardPartial(text) }
        link.onHoldExit = { if (holdSelects) { input(Input.select); true } else false }
        link.onDoubleClick = { if (!practice(3) && crownPaging && link.isShowing) gesture(doubleClickAction) }
        link.onCrown = { direction ->
            if (practicing) { if (direction != 0) practice(if (direction > 0) 0 else 1) }
            else if (crownPaging && link.isShowing) {
                if (direction == 0) input(Input.select)
                else if (!scrollingBlock) input(if (direction > 0) Input.next else Input.previous)   // in crown-scroll mode the crown just scrolls
            }
        }
        link.onHeadRaise = {
            if (link.isShowing && !practice(2)) {
                if (dashAsleep) { link.record("Look up: dashboard back on."); wakeDashboard() }
                else if (headPaging) { link.record("Look up."); gesture(headAction) }
            }
        }
        link.onBlockedNotification = { pkg ->
            // when notifications are being read off the phone they're already shown in full
            if (noticeBlocked && !(phoneNotices && NoticeListener.connected) && pkg != context.packageName) {
                overlays.push(Card(listOf("Notification", TextLayout.headline(AppNames.name(pkg), screen))), min(alertSeconds, 6.0))
            }
        }
        locator.onMove = { moved() }
        link.onStandbyRaise = { link.record("Look up: bringing the page back."); wakeDashboard() }
        link.onEnded = { reason -> displayEnded(reason) }
        popFactDue = now() + max(1.0, popFactMinutes) * 60
        val loop = object : Runnable {
            override fun run() { tick(); mainHandler.postDelayed(this, 250) }
        }
        mainHandler.postDelayed(loop, 250)
    }

    val screen: Screen get() = Screen.of(if (link.isShowing) link.rows else textSize.rows, if (textSize == TextSize.small) columnsSmall else columnsLarge, textSize.wideColumns)
    val followed: List<String> get() = teams.uppercase().split(Regex("[^A-Z0-9]+")).filter { it.isNotEmpty() }
    val apps: List<Program> get() = listOf(Program.dashboard) + menuGroups.flatMap { it.items }

    // MARK: Display controls

    fun startDisplay() {
        wakeDashboard()
        endedNotice = null
        link.start(textSize, refreshScreen, crownScroll)
        applyKeepAwake()
        tick()
    }

    fun stopDisplay() {
        link.stop()
        overlays.clear(); unshown.clear(); popupOpen = false
        applyKeepAwake()
    }
    fun toggleDisplay() { if (link.isRunning) stopDisplay() else startDisplay() }

    fun scene(active: Boolean) {
        inFront = active
        if (active) refreshPermissions()
        applyKeepAwake()
    }

    /** Keeps the app running with the phone's screen off, for as long as there's something to show. */
    private fun applyKeepAwake() = HubService.set(context, link.isRunning || popUps, mic = micInUse, location = locatorInUse)
    private val micInUse: Boolean get() = tunerOn || chordOn || drumOn || movieOn
    private var locatorInUse = false

    private fun displayEnded(reason: String) {
        overlays.clear()
        applyKeepAwake()
        endedNotice = reason
        if (popupOpen) {
            // A pop-up couldn't open (glasses away, or something else on their screen). Don't lose what
            // it was for: send it as ordinary notifications instead.
            popupOpen = false
            if (notificationsAllowed) for ((title, body) in unshown) notifier.post(title, body)
            unshown.clear()
            return
        }
        if (!inFront) notifier.post("Glasses display stopped", reason)
    }

    private fun programChanged() {
        wakeDashboard()
        overlays.clear()
        stopTools()
        if (program == Program.facts) factDue = never
        if (program == Program.agenda || program == Program.dashboard) agendaDue = never
        pager = AutoPager(); pagesPaused = false
        listEnd = false; agendaStep = 0; weatherStep = null
        tourOpen = false; planeIndex = 0; planesDue = never; stockPage = 0; stocksDue = never
        if (program == Program.word) wordCheckDay()
        if (program == Program.reader) restartReaderTimer()
    }

    // MARK: The loop

    fun tick() {
        val now = now()
        val awake = inFront || link.isRunning || popUps
        if (awake) refreshData(now)
        if (popUps && !link.isRunning && !overlays.isEmpty) {
            popupOpen = true
            link.start(textSize, refreshScreen, crownScroll)
            applyKeepAwake()
        }

        if (movie.state == MovieTracker.State.running) {
            movie.tick(now)
            if (movie.state != MovieTracker.State.running) link.record("Movie captions: the room went quiet, holding.")
        }
        // captions and trainers should keep up with what's heard; speed reading sets its own pace
        link.pace = if ((program == Program.live || program == Program.chords || program == Program.drums || program == Program.movie) && !menuOpen) 0.3
            else if (program == Program.speed && speedPlaying && !menuOpen) SpeedRead.interval(speedWPM, speedSize) else 1.0
        if (program == Program.speed && speedPlaying && !menuOpen) {
            val words = speedText()
            if (now - speedShownAt >= SpeedRead.interval(speedWPM, speedSize)) {
                speedIndex = min(words.size, speedIndex + max(1, SpeedRead.chunk(words, speedIndex, speedSize, screen.columns).second))
                speedShownAt = now
                if (speedIndex >= words.size) speedPlaying = false
            }
        }

        // Trivia and the timer move on their own.
        round?.tick(now)
        if (timer.isDone(now) && !timerAnnounced) { timerAnnounced = true; alert(listOf("TIME'S UP", timer.label), Program.timer) }
        if (!timer.isDone(now)) timerAnnounced = false

        // Blank dashboard, set to get out of the way: close the page so the glasses' own notifications can
        // show, and open it again as soon as anything wakes the dashboard or an alert comes in.
        if (link.isStandingBy) {
            if (!overlays.isEmpty) wakeDashboard()
            if (!dashAsleep || !dashSleepCloses) link.comeBack()
        } else if (dashAsleep && dashSleepCloses && link.isShowing && overlays.isEmpty && !practicing && !popupOpen) link.stepAside()

        var card: Card
        var statusLine: String? = null
        val alert = if (popupOpen && !link.isShowing) null else overlays.current(now)
        if (popupOpen && !link.isShowing) card = currentCard(now)                // still opening; the alert's clock hasn't started
        else if (alert != null) { card = alert; unshown.clear() }
        else if (popupOpen) {
            popupOpen = false                                                    // everything has been shown: close again
            link.stop(); applyKeepAwake()
            card = currentCard(now)
        } else {
            card = currentCard(now)
            // Anything taller than the screen is shown a page at a time. Reading stops on the last page;
            // everything else starts over.
            val readingText = !menuOpen && !listEnd && (program == Program.reader || (program == Program.news && reading != null) ||
                (program == Program.tour && tourOpen) || (program == Program.agenda && agendaStep >= 2))
            if (crownScroll && readingText) {
                // Crown mode: send the text in one block for the glasses to scroll. A block can only be so
                // big, so long text goes up in sections, stepped with "next" like pages.
                val sections = ArrayList<List<String>>()
                var current = ArrayList<String>()
                var bytes = 0
                for (line in card.lines) {
                    val cost = line.toByteArray(Charsets.UTF_8).size + 1
                    if (bytes + cost > 2200 && current.isNotEmpty()) { sections.add(current); current = ArrayList(); bytes = 0 }
                    current.add(line); bytes += cost
                }
                if (current.isNotEmpty()) sections.add(current)
                val key = "${card.lines.size}|${card.lines.firstOrNull() ?: ""}"
                if (key != sectionKey) { sectionKey = key; sectionIndex = 0 }
                sectionIndex = max(0, min(sections.size - 1, sectionIndex))
                var shown = if (sections.isEmpty()) card.lines else sections[sectionIndex]
                if (sections.size > 1) shown = shown + "(section ${sectionIndex + 1} of ${sections.size})"
                card = Card(shown, scrolls = shown.size > screen.rows)
                pageIndex = sectionIndex; pageCount = max(1, sections.size)
            } else {
                pager.paused = pagesPaused
                // the Reader's clock takes a row of its own, so the text pages one row shorter
                val timed = if (program == Program.reader && readingText && card.scrolls && screen.rows >= 3) ReaderClock.Mode.entries.getOrElse(readerClock) { ReaderClock.Mode.off } else ReaderClock.Mode.off
                card = pager.page(card, if (timed == ReaderClock.Mode.off) screen.rows else screen.rows - 1, now, pageSeconds, loops = !readingText)
                pageIndex = pager.index; pageCount = pager.count
                if (timed != ReaderClock.Mode.off) {
                    statusLine = TextLayout.rightAligned(ReaderClock.line(timed, now, readerStarted, readerTargetMinutes, pager.index + 1, pager.count), screen.columns)
                }
            }
        }
        if (centering > 0 && !card.scrolls) card = Card(TextLayout.centered(card.lines.take(screen.rows - (if (statusLine == null) 0 else 1)), screen.columns, each = centering == 2), card.scrolls)
        if (statusLine != null) {
            val body = card.lines.take(screen.rows - 1).toMutableList()
            // keep the clock in its corner: short last pages are padded so it doesn't ride up
            if (!readerClockTop) while (body.size < screen.rows - 1) body.add("　")
            card = Card(if (readerClockTop) listOf(statusLine) + body else body + statusLine, card.scrolls)
        }
        val text = card.text(screen.rows)
        if (text != preview) preview = text
        if (card.scrolls != previewScrolls) previewScrolls = card.scrolls
        scrollingBlock = card.scrolls
        if (link.isRunning) {
            // Each screen goes up with a line of scroll room above it; that is what lets the glasses'
            // reports tell a turn back from a turn forward.
            val room = ((crownPaging && crownBack) || practicing) && !card.scrolls
            link.show(if (room) TextLayout.withScrollRoom(card.lines, screen.rows, "·").joinToString("\n") else text, card.scrolls)
            link.tick()
        }
        if (inFront) pulse++
    }

    // MARK: Crown and button navigation

    enum class Input { next, previous, select }

    /**
     * One step of navigation. "next" moves to the next thing (page, headline, game, event); "select" opens
     * what's showing if it can be opened, goes back if something is open, and otherwise brings up the menu
     * of apps. Lists end in a stop that also leads to the menu.
     */
    fun input(what: Input) {
        link.record("Input $what on ${program.name}" + (if (menuOpen) ", menu open" else "") + (if (listEnd) ", at list end" else ""))
        if (dashAsleep) { wakeDashboard(); return }           // the first touch only brings the dashboard back
        wakeDashboard()
        if (!menuOpen && !listEnd && toolInput(what)) { saveWord(); return }
        if (what == Input.previous) { goBack(); return }
        val next = what == Input.next
        if (menuOpen) {
            if (next) menuIndex = (menuIndex + 1) % menuTitles.size else menuSelect()
            return
        }
        if (listEnd) {
            listEnd = false
            if (next) restartList() else openMenu()
            return
        }
        val morePages = pageCount > 1 && pageIndex < pageCount - 1
        when (program) {
            Program.news ->
                if (reading != null) {
                    if (!next) stopReading() else if (morePages) pageStep(1) else { stopReading(); advanceNews() }
                } else if (next) { advanceNews(); headlineTurnedAt = now() } else readCurrent()
            Program.scores ->
                if (scoresView == ScoresView.league) {
                    if (!next) openMenu() else if (morePages) pageStep(1) else pageRestart()
                } else if (next) {
                    val list = Scoreboard.ordered(games, followed)
                    val at = list.indexOfFirst { it.id == game?.id }
                    if (at + 1 >= list.size) listEnd = true else pinnedGame = list[at + 1].id
                } else scoresView = if (scoresView == ScoresView.box) ScoresView.game else ScoresView.box
            Program.agenda ->
                if (!next) { if (agendaStep == 0) openMenu() else agendaStep = 0 }
                else if (morePages) pageStep(1)
                else if (agendaStep >= 1 + week.size) listEnd = true
                else { agendaStep += 1; pageRestart() }
            Program.weather -> if (next) weatherStep = (weatherStep ?: 0) + 1 else openMenu()
            Program.trivia ->
                if (!next) openMenu()
                else if (round == null || round?.phase == TriviaRound.Phase.done) startTrivia()
                else if (round?.phase == TriviaRound.Phase.question) triviaReveal() else triviaNext()
            Program.facts -> if (!next) openMenu() else if (morePages) pageStep(1) else nextFact()
            Program.reader -> if (!next) openMenu() else if (morePages) pageStep(1) else pageRestart()
            Program.timer -> if (!next) openMenu() else if (timer.isRunning) timerPause() else timerStart()
            Program.dashboard, Program.message -> openMenu()
            Program.live -> if (!next) openMenu() else if (livePage < live.pageCount(screen) - 1) livePage += 1 else livePage = 0
            Program.feeds -> if (!next) openMenu() else refreshFeeds()
            Program.stocks -> if (!next) openMenu() else stockPage += 1
            Program.tour ->
                if (tourOpen) {
                    if (!next) tourOpen = false else if (morePages) pageStep(1) else { tourOpen = false; stepPlace(1) }
                } else if (next) stepPlace(1)
                else if (placeIndex in places.indices && places[placeIndex].summary.isNotEmpty()) { tourOpen = true; pageRestart() }
                else tourDue = never
            else -> {}                                              // handled in toolInput
        }
    }

    private fun advanceNews() {
        if (news.isEmpty() || newsIndex >= news.size - 1) listEnd = news.isNotEmpty() else newsIndex += 1
        pageRestart()
    }

    /** Opens what the menu's arrow is on: a group, the way back, or an app. */
    private fun menuSelect() {
        if (menuHintsLeft > 0) menuHintsLeft -= 1
        val g = menuGroup
        if (g != null && g in menuGroups.indices) {
            val items = menuGroups[g].items
            if (menuIndex == 0 || items.isEmpty()) { menuGroup = null; menuIndex = g + 1; return }
            menuOpen = false; menuGroup = null
            program = items[min(menuIndex - 1, items.size - 1)]
        } else if (menuIndex == 0) { menuOpen = false; program = Program.dashboard }
        else { menuGroup = min(menuIndex - 1, menuGroups.size - 1); menuIndex = 1 }
    }

    /** The tools take all three inputs themselves. True when the input was used. */
    private fun toolInput(what: Input): Boolean {
        val at = now()
        when (program) {
            Program.metronome -> when (what) {
                Input.next -> metroBPM = min(Metronome.range.last, metroBPM + 4)
                Input.previous -> metroBPM = max(Metronome.range.first, metroBPM - 4)
                Input.select -> toggleMetronome()
            }
            Program.tuner -> if (what == Input.select) toggleTuner()
            Program.speed -> {
                val words = speedText()
                when (what) {
                    Input.select -> if (speedIndex >= words.size) { speedIndex = 0; speedPlaying = true } else speedPlaying = !speedPlaying
                    Input.next -> speedIndex = min(words.size, speedIndex + 12)
                    Input.previous -> speedIndex = max(0, speedIndex - 12)
                }
                speedAnchor()
            }
            Program.movie -> when (what) {
                Input.next -> movie.shift(0.5, at)
                Input.previous -> movie.shift(-0.5, at)
                Input.select -> if (!movieOn && movieCanListen && movie.state == MovieTracker.State.waiting && !movie.isEmpty) toggleMovie() else movie.toggleHold(at)
            }
            Program.chords -> when (what) {
                Input.next -> follower.step(1)
                Input.previous -> follower.step(-1)
                Input.select -> toggleChords()
            }
            Program.drums -> {
                val names = DrumPattern.library.map { it.name } + "custom"
                val index = max(0, names.indexOf(drumPattern))
                when (what) {
                    Input.next -> drumPattern = names[(index + 1) % names.size]
                    Input.previous -> drumPattern = names[(index + names.size - 1) % names.size]
                    Input.select -> toggleDrums()
                }
            }
            Program.word -> {
                wordCheckDay()
                when (what) {
                    Input.next -> wordGame.move(1)
                    Input.previous -> wordGame.move(-1)
                    Input.select ->
                        if (wordGame.over) wordGame = freshWord()
                        else {
                            wordGame.guess()
                            val day = wordGame.day
                            if (wordGame.over && day != null) {
                                wordDoneDay = day
                                if (wordGame.solved) { wordStreakSaved = if (wordWinDay == day - 1) wordStreakSaved + 1 else 1; wordWinDay = day } else wordStreakSaved = 0
                            }
                        }
                }
            }
            Program.twenty -> when (twenty.phase) {
                TwentyQuestions.Phase.Asking, TwentyQuestions.Phase.Guessing -> {
                    val answer = if (what == Input.next) TwentyQuestions.Answer.yes else if (what == Input.previous) TwentyQuestions.Answer.no else TwentyQuestions.Answer.unsure
                    if (!(twenty.phase == TwentyQuestions.Phase.Guessing && answer == TwentyQuestions.Answer.unsure) && twenty.answer(answer)) askTwenty()
                }
                TwentyQuestions.Phase.Waiting -> {}
                is TwentyQuestions.Phase.Failed -> if (what == Input.select) askTwenty()
                else -> if (what == Input.select) startTwenty()
            }
            Program.planes -> when (what) {
                Input.next -> if (planes.isNotEmpty()) planeIndex = (planeIndex + 1) % planes.size
                Input.previous -> if (planes.isNotEmpty()) planeIndex = (planeIndex + planes.size - 1) % planes.size
                Input.select -> planesDue = never
            }
            Program.picker -> {
                val all = PickerMode.entries
                val index = all.indexOf(pickerMode)
                when (what) {
                    Input.next -> pickerMode = all[(index + 1) % all.size]
                    Input.previous -> pickerMode = all[(index + all.size - 1) % all.size]
                    Input.select -> roll()
                }
            }
            else -> return false
        }
        return true
    }

    /** The crown turned backwards: the previous page, item or view. Never opens or closes anything. */
    private fun goBack() {
        if (menuOpen) { val n = menuTitles.size; menuIndex = (menuIndex + n - 1) % n; return }
        if (listEnd) { listEnd = false; return }                     // back from the end stop to the last item
        val earlierPage = pageCount > 1 && pageIndex > 0
        when (program) {
            Program.news -> if (reading != null) { if (earlierPage) pageStep(-1) } else if (newsIndex > 0) { newsIndex -= 1; headlineTurnedAt = now() }
            Program.scores ->
                if (scoresView == ScoresView.league) { if (earlierPage) pageStep(-1) }
                else {
                    val list = Scoreboard.ordered(games, followed)
                    val at = list.indexOfFirst { it.id == game?.id }
                    if (at > 0) pinnedGame = list[at - 1].id
                }
            Program.agenda -> if (earlierPage) pageStep(-1) else if (agendaStep > 0) { agendaStep -= 1; pageRestart() }
            Program.weather -> weatherStep = max(0, (weatherStep ?: 0) + 2)             // three views: two forward is one back
            Program.stocks -> stockPage -= 1
            Program.tour -> if (tourOpen) { if (earlierPage) pageStep(-1) } else stepPlace(-1)
            Program.reader -> if (earlierPage) pageStep(-1) else restartReaderTimer()   // back on the first page: zero the timer
            Program.facts -> if (earlierPage) pageStep(-1)
            Program.live -> if (livePage > 0) livePage -= 1
            else -> {}
        }
    }

    private fun restartList() {
        when (program) {
            Program.news -> { newsIndex = 0; headlineTurnedAt = now() }
            Program.scores -> pinnedGame = ""
            Program.agenda -> agendaStep = 0
            else -> {}
        }
    }

    /** What a look up, a double click or a button does: 0 next, 1 select, 2 the apps menu, 3 previous, 4 nothing, 5 dashboard. */
    fun gesture(action: Int) {
        if (action == 2) wakeDashboard()                  // the menu opens straight from a blank dashboard
        when (action) {
            0 -> input(Input.next)
            1 -> input(Input.select)
            3 -> input(Input.previous)
            4 -> {}
            5 -> { wakeDashboard(); if (menuOpen) closeMenu(); program = Program.dashboard }
            else -> { link.record("Apps menu " + (if (menuOpen) "closed." else "opened.")); if (menuOpen) closeMenu() else openMenu() }
        }
    }

    /** A step from the phone: a volume button, a media key, the buttons on the Display tab. */
    fun remote(action: Int) {
        if (link.isStandingBy) { wakeDashboard(); return }
        if (!link.isShowing) return
        gesture(action)
    }

    /** The control on the glasses that's set to select, for the menu's reminder. */
    private val selectControl: String? get() = if (headPaging && headAction == 1) "Look up" else if (crownPaging && doubleClickAction == 1) "Double click" else null

    fun startPractice() { practiced = listOf(false, false, false, false); practicing = true; if (!link.isRunning) startDisplay() }
    fun stopPractice() { practicing = false }
    /** Ticks a control off while practising. True when the report was used up by the practice. */
    private fun practice(step: Int): Boolean {
        if (!practicing || !link.isShowing || step !in practiced.indices) return false
        practiced = practiced.toMutableList().also { it[step] = true }
        link.record("Controls check: ${listOf("turn forward", "turn back", "look up", "double click")[step]} works.")
        return true
    }

    private fun openMenu() {
        // Always the top level, with the arrow on where the current app lives.
        menuGroup = null
        menuIndex = menuGroups.indexOfFirst { program in it.items }.let { if (it >= 0) it + 1 else 0 }
        menuOpen = true
    }
    fun closeMenu() { menuOpen = false; menuGroup = null; listEnd = false }

    fun pageStep(by: Int) { sectionIndex += by; pager.step(by, now()) }
    fun pageRestart() { sectionIndex = 0; pager.restart(now()); pagesPaused = false; if (program == Program.reader) restartReaderTimer() }
    fun togglePagesPaused() { pagesPaused = !pagesPaused }

    // MARK: Rings and clickers

    private val ringMap: Map<String, Any?> get() = Json.obj(ringMapText) ?: emptyMap()
    fun ringAction(event: RemoteEvent): Int = ringMap[event.name].int() ?: event.usual
    fun setRing(key: String, action: Int) { ringMapText = Json.encode(ringMap + (key to action)) }
    /** What the same sideways swipe twice in a row does. 4 is nothing, which also stops single swipes waiting. */
    fun ringDouble(event: RemoteEvent): Int {
        if (event != RemoteEvent.swipeLeft && event != RemoteEvent.swipeRight) return 4
        return ringMap[event.name + "Double"].int() ?: (if (event == RemoteEvent.swipeRight) 1 else 5)
    }
    /** Something arrived from a ring, clicker or keyboard. */
    fun ring(event: RemoteEvent) {
        val double = ringDouble(event)
        val waiting = ringWaiting
        if (waiting != null) {
            mainHandler.removeCallbacks(waiting.second); ringWaiting = null
            if (waiting.first == event && double != 4) { ringDo(event, double, twice = true); return }
            ringDo(waiting.first, ringAction(waiting.first), twice = false)      // a different button: the first one still counts
        }
        if (double == 4) { ringDo(event, ringAction(event), twice = false); return }
        // hold a single swipe for a moment in case a second one follows
        val later = Runnable { ringWaiting = null; ringDo(event, ringAction(event), twice = false) }
        ringWaiting = event to later
        mainHandler.postDelayed(later, 450)
    }
    private fun ringDo(event: RemoteEvent, action: Int, twice: Boolean) {
        val names = mapOf(0 to "next", 1 to "select", 2 to "apps menu", 3 to "previous", 4 to "nothing", 5 to "dashboard")
        val title = if (twice) "Double " + event.title.lowercase() else event.title
        ringLast = title + " → " + (names[action] ?: "")
        link.record("Ring: $title.")
        remote(action)
    }

    private val glyphs: Glyphs get() = Glyphs(glyphStyle)
    /** Which of `count` views is up, for programs that take turns. */
    private fun turn(count: Int, now: Double): Int = if (count < 2) 0 else (now / (if (pageSeconds == 0.0) 10.0 else max(4.0, pageSeconds))).toLong().mod(count)
    private fun linesOf(text: String): List<String> {
        val key = "${screen.columns}|${text.length}|${text.hashCode()}"
        if (wrapped.first != key) wrapped = key to TextLayout.wrap(text, screen.columns)
        return wrapped.second
    }

    /** The card for the chosen program, with nothing borrowing the screen. */
    fun currentCard(now: Double): Card {
        val screen = this.screen
        val glyphs = this.glyphs
        val rich = glyphStyle != GlyphStyle.plain
        if (now < testCardsUntil) {
            val pages = Glyphs.testPages
            return Card(pages[max(0, min(pages.size - 1, pages.size - 1 - ((testCardsUntil - now) / 12).toInt()))])
        }
        if (practicing) return AppMenu.practiceCard(practiced)
        if (dashAsleep) return Card(listOf("　"))
        if (menuOpen) {
            val title = menuGroup?.let { menuGroups.getOrNull(it)?.title } ?: "Apps"
            return AppMenu.card(title, menuTitles, min(menuIndex, menuTitles.size - 1), screen, glyphs, if (menuHintsLeft > 0) AppMenu.hint(selectControl, screen.columns) else null)
        }
        if (listEnd) return AppMenu.endCard(when (program) { Program.news -> "headlines"; Program.scores -> "games"; Program.agenda -> "events"; else -> "the list" })
        return when (program) {
            Program.dashboard -> {
                val lines = ArrayList<String>()
                fun add(mark: String, text: String) { lines.add(if (rich) mark + " " + TextLayout.fit(text, screen.columns - 3) else text) }
                game?.let { if (dashScores) add(if (it.state == Game.State.live) glyphs.live else glyphs.bullet, Scoreboard.summary(it, now)) }
                weather?.let { if (dashWeather) add(glyphs.weather(it.code), it.summary) }
                if (dashAgenda) Agenda.summary(agenda, now)?.let { add(glyphs.next, it) }
                if (timer.isRunning) {
                    val left = timer.remaining(now)
                    lines.add(if (rich) glyphs.meter(left / max(1.0, timer.duration), 6) + " " + HubTimer.clock(left) else "Timer ${HubTimer.clock(left)}")
                }
                if (dashStocks) for (symbol in stockSymbols.take(2)) stockQuotes[symbol]?.let { add(glyphs.bullet, Stocks.line(symbol, it, rich)) }
                for (feed in feeds) if (feed.onDashboard) feedReadings[feed.id]?.let { add(glyphs.bullet, FeedParser.line(feed, it, now = now, arrows = rich)) }
                if (dashNews) news.firstOrNull()?.let { add(glyphs.note, it.title) }
                if (dashNote.isNotEmpty()) add(glyphs.star, dashNote)
                Dashboard.card(now, lines, screen, if (pageSeconds == 0.0) 10.0 else max(4.0, pageSeconds))
            }
            Program.scores -> {
                if (scoresView == ScoresView.league) {
                    val pages = Scoreboard.tablePages(Scoreboard.ordered(games, followed), if (leagues.size == 1) leagues.first().short else "Scores", screen, now, glyphs)
                    return pages[turn(pages.size, now)]
                }
                val game = this.game ?: return Card(listOf("Scoreboard", scoresNote.ifEmpty { "Looking for games…" }))
                val main = Scoreboard.card(game, screen, now, stale = now - scoresAt > 120 && game.state == Game.State.live, glyphs = glyphs)
                val box = if (scoresView != ScoresView.game) Scoreboard.boxCard(game, screen, glyphs) else null
                if (box == null) main else if (scoresView == ScoresView.box || turn(2, now) == 1) box else main
            }
            Program.news -> {
                val story = reading
                if (story != null) {
                    val text = articles[story.id] ?: return Card(listOf(story.source, readingNote.ifEmpty { "Getting the story…" }))
                    return Card(TextLayout.wrap(story.title, screen.columns) + "" + linesOf(text.ifEmpty { story.summary }) + "- end -", scrolls = true)
                }
                if (news.isEmpty()) return Card(listOf("News", newsNote.ifEmpty { "Getting headlines…" }))
                val index = min(newsIndex, news.size - 1)
                News.headlineCard(news[index], index, news.size, screen, now, glyphs)
            }
            Program.trivia -> round?.card(screen, now) ?: Card(listOf("Trivia host", triviaNote.ifEmpty { "Start a round on your phone." }))
            Program.facts -> fact?.let { Card(listOf((if (rich) glyphs.note + " " else "") + "Odd fact") + TextLayout.wrap(it, screen.columns)) } ?: Card(listOf("Odd fact", "Finding one…"))
            Program.timer -> timer.card(screen, now, glyphs)
            Program.weather -> {
                val weather = this.weather ?: return Card(listOf("Weather", weatherNote.ifEmpty { "Checking $city…" }))
                val step = weatherStep
                if (step != null) {           // stepping through by hand: every view, in order
                    val all = listOfNotNull(weather.card(screen), weather.hoursCard(screen, glyphs), weather.weekCard(screen, glyphs))
                    return all[step % all.size]
                }
                val views = ArrayList<Card>()
                if (weatherView == WeatherView.cycle || weatherView == WeatherView.now) views.add(weather.card(screen))
                if (weatherView == WeatherView.cycle || weatherView == WeatherView.hours) weather.hoursCard(screen, glyphs)?.let { views.add(it) }
                if (weatherView == WeatherView.cycle || weatherView == WeatherView.week) weather.weekCard(screen, glyphs)?.let { views.add(it) }
                if (views.isEmpty()) weather.card(screen) else views[turn(views.size, now)]
            }
            Program.agenda -> {
                val zone = ZoneId.systemDefault()
                val busy = agenda.map { Instant.ofEpochMilli((it.start * 1000).toLong()).atZone(zone).dayOfMonth }.toSet()
                val month = Agenda.monthCard(now, screen, glyphs, busy)
                if (agendaStep == 1) return month
                if (agendaStep >= 2 && agendaStep - 2 in week.indices) return Agenda.detailCard(week[agendaStep - 2], agendaStep - 2, week.size, screen, now, glyphs)
                if (agendaView == AgendaView.month) return month
                if (!calendarAllowed) return if (agendaView == AgendaView.cycle) month else Card(listOf("Calendar", "Allow calendar access in the app."))
                val list = Agenda.listCard(agenda, screen, now, glyphs)
                // a long list pages by itself, so only take turns with the month when it fits one screen
                if (agendaView == AgendaView.cycle && list.lines.size <= screen.rows && turn(2, now) == 1) month else list
            }
            Program.reader -> linesOf(readerText).let { if (it.isEmpty()) Card(listOf("Reader", "Paste some text in the app.")) else Card(it, scrolls = true) }
            Program.message -> Reader.note("", messageText, screen).let { if (it.isEmpty) Card(listOf("Message", "Type one in the app.")) else it }
            Program.live -> live.card(screen, livePage)
            Program.stocks -> Stocks.card(stockSymbols, stockQuotes, stockNote, stockPage, rich, screen)
            Program.movie -> movie.card(movieTitle, movieOn,
                if (movieNote.isEmpty() && !movieCanListen) "Select to start at the first line. Turn the crown to move the captions earlier or later." else movieNote, now, screen)
            Program.chords ->
                if (musicNote.isNotEmpty() && !chordOn) Card(listOf("Guitar chords") + TextLayout.wrap(musicNote, screen.columns))
                else follower.card(chordTitle, chordOn, ChordFollower.Style.entries.getOrElse(chordShow) { ChordFollower.Style.frets }, screen)
            Program.drums -> trainer.card(drumOn, drumCalibration ?: (if (!drumOn) musicNote else ""), rich, screen)
            Program.word -> wordGame.card(wordStreak, screen)
            Program.twenty -> twenty.card(screen)
            Program.planes -> Planes.card(planes, planeIndex, planeRoutes, nearbyProblem ?: planeNote, metricUnits, rich, screen)
            Program.tour -> {
                val place = places.getOrNull(placeIndex)
                if (tourOpen && place != null) Card(listOf(TextLayout.fit(place.title, screen.columns)) + linesOf(place.summary) + "- Wikipedia -", scrolls = true)
                else Tour.listCard(places, placeIndex, nearbyProblem ?: tourNote, metricUnits, screen)
            }
            Program.feeds -> FeedParser.card(feeds, feedReadings, feedNotes, now, screen, rich, turn(ceil(feeds.size.toDouble() / max(1, screen.rows - 1)).toInt(), now))
            Program.speed -> SpeedRead.card(speedText(), speedIndex, speedSize, speedPlaying, speedWPM, screen)
            Program.metronome -> Metronome.card(metroBPM, metroBeats, metroOn, null, screen)
            Program.tuner -> if (tunerNote.isNotEmpty()) Card(listOf("Tuner") + TextLayout.wrap(tunerNote, screen.columns)) else Tuner.card(tunerReading, tunerOn, screen, glyphs)
            Program.picker -> Picker.card(pickerMode, pickerResult, now - pickerRolledAt < 0.6, screen)
        }
    }

    // MARK: Music trainers

    private fun loadChords() {
        val chart = if (chordSong == "custom") chordText else ChordChart.songs.firstOrNull { it.id == chordSong }?.chart ?: ""
        follower = ChordFollower(ChordChart.parse(chart))
    }
    private val chordTitle: String get() = ChordChart.songs.firstOrNull { it.id == chordSong }?.title ?: "My chart"
    fun restartChords() = follower.restart()
    fun toggleChords() {
        if (chordOn) { ear.stop(); chordOn = false; applyKeepAwake(); return }
        val problem = ear.start(MusicEar.Mode.chords)
        chordOn = problem == null; drumOn = false
        musicNote = problem ?: ""
        applyKeepAwake()
    }
    private fun heardChroma(chroma: DoubleArray, level: Double) {
        if (!chordOn || program != Program.chords || menuOpen) return
        if (follower.hear(chroma, level) && link.isRunning) tick()
    }

    private fun loadDrums() {
        val pattern = if (drumPattern == "custom") DrumPattern.parse("My pattern", drumText) else DrumPattern.library.firstOrNull { it.name == drumPattern }
        trainer = DrumTrainer(pattern ?: DrumPattern("My pattern", emptyList()))
    }
    fun restartDrums() { trainer = DrumTrainer(trainer.pattern) }
    fun toggleDrums() {
        if (drumOn) { ear.stop(); drumOn = false; drumCalibration = null; applyKeepAwake(); return }
        val problem = ear.start(MusicEar.Mode.drums)
        drumOn = problem == null; chordOn = false
        musicNote = problem ?: ""
        applyKeepAwake()
    }
    private fun heardHit(hit: DrumHit) {
        if (!drumOn) return
        // sensitivity 5 is the ear's own threshold; each step either way moves the loudness a hit must reach
        if (hit.level < 1.6.pow(5.0 - drumSensitivity) * 0.004) return
        if (drumCalibration != null) { calibrate(hit); return }
        val drums = drumKit.identify(hit)
        drumHeard = Drum.entries.filter { it in drums }.joinToString(" + ") { it.label }
        if (program != Program.drums || menuOpen) return
        trainer.hit(drums, hit.time)
        if (link.isRunning) tick()
    }

    private val calibrationOrder = listOf(Drum.kick, Drum.snare, Drum.hat, Drum.tom)
    private fun calibrationPrompt(): String =
        "Hit the ${calibrationOrder[calibrationStage].label} ${4 - calibrationHits.size} more time${if (calibrationHits.size == 3) "" else "s"}, about a second apart."
    fun startCalibration() {
        calibrationStage = 0; calibrationHits = ArrayList(); calibrationVoices = HashMap()
        if (!drumOn) {
            val problem = ear.start(MusicEar.Mode.drums)
            drumOn = problem == null; chordOn = false; musicNote = problem ?: ""
            applyKeepAwake()
        }
        if (drumOn) drumCalibration = calibrationPrompt()
    }
    fun cancelCalibration() { drumCalibration = null }
    fun skipCalibrationStage() { calibrationHits = ArrayList(); nextCalibrationStage() }
    fun forgetKit() { drumKit = DrumKit.standard; s.putJson("drumKit", drumKit.toMap()) }
    private fun calibrate(hit: DrumHit) {
        // hits less than a third of a second after the last are the same drum still ringing
        val last = calibrationHits.lastOrNull()
        if (last != null && hit.time - last.time < 0.3) return
        calibrationHits.add(hit)
        if (calibrationHits.size >= 4) {
            DrumKit.learn(calibrationHits)?.let { calibrationVoices[calibrationOrder[calibrationStage]] = it }
            calibrationHits = ArrayList()
            nextCalibrationStage()
        } else drumCalibration = calibrationPrompt()
    }
    private fun nextCalibrationStage() {
        calibrationStage += 1
        if (calibrationStage < calibrationOrder.size) { drumCalibration = calibrationPrompt(); return }
        drumCalibration = null
        // a kit needs at least a kick and a snare to be worth using
        if (calibrationVoices[Drum.kick] != null && calibrationVoices[Drum.snare] != null) {
            drumKit = DrumKit(HashMap(calibrationVoices), calibrated = true)
            s.putJson("drumKit", drumKit.toMap())
            musicNote = "Learned your kit."
        } else musicNote = "Not enough to go on. Teach it at least the kick and the snare."
    }

    // MARK: Games

    private fun freshWord(): WordGame {
        val today = WordGame.day(now())
        return if (wordDoneDay != today) WordGame(WordGame.daily(today), today) else WordGame(WordGame.random(wordGame.word))
    }
    /** A daily word left over from an earlier day gives way to today's. */
    private fun wordCheckDay() { val day = wordGame.day; if (day != null && day != WordGame.day(now())) { wordGame = freshWord(); saveWord() } }
    fun newWord() { wordGame = WordGame(WordGame.random(wordGame.word)); saveWord() }

    fun startTwenty() { twenty.start(); askTwenty() }
    private fun askTwenty() {
        val key = aiKey.trim()
        if (key.isEmpty()) { twenty.phase = TwentyQuestions.Phase.Failed("Add your AI key in the app, under Apps > 20 questions."); return }
        twenty.phase = TwentyQuestions.Phase.Waiting
        twentyRun += 1
        val run = twentyRun
        AIClient.ask(key, aiModel.trim().ifEmpty { "claude-haiku-5-5" }, TwentyQuestions.system, twenty.messages()) { text, problem ->
            if (twentyRun == run && twenty.phase == TwentyQuestions.Phase.Waiting) {
                if (text != null) twenty.take(text) else twenty.phase = TwentyQuestions.Phase.Failed(problem ?: "Couldn't reach the AI.")
            }
        }
    }

    // MARK: Nearby

    private fun stepPlace(by: Int) {
        if (places.isNotEmpty()) placeIndex = (placeIndex + by).mod(places.size)
        pageRestart()
    }

    /** The phone moved: measure the known places again and say so if one is now close. */
    private fun moved() {
        val latitude = locator.latitude ?: return
        val longitude = locator.longitude ?: return
        if (places.isEmpty()) return
        val shown = places.getOrNull(placeIndex)?.id
        places = Tour.moved(places, latitude, longitude)
        if (tourOpen && shown != null) places.indexOfFirst { it.id == shown }.let { if (it >= 0) placeIndex = it }
        announcePlaces()
    }
    private fun announcePlaces() {
        val near = places.firstOrNull { it.distance < 250 && it.id !in tourSeen } ?: return
        tourSeen.add(near.id)
        if (tourAnnounce && program != Program.tour) alert(listOf("Nearby", near.title, Tour.whereLine(near, metricUnits)), Program.tour)
    }

    private fun refreshNearby(now: Double) {
        val wantsPlanes = program == Program.planes && (link.isRunning || inFront)
        val wantsTour = (program == Program.tour && (link.isRunning || inFront)) || (tourAnnounce && (link.isRunning || popUps))
        if (locatorInUse != (wantsPlanes || wantsTour)) { locatorInUse = wantsPlanes || wantsTour; locator.set(locatorInUse); applyKeepAwake() }
        else locator.set(locatorInUse)
        val latitude = locator.latitude ?: return
        val longitude = locator.longitude ?: return
        if (wantsPlanes && now >= planesDue && fetching.add("planes")) {
            planesDue = now + 12
            Http.get(Planes.url(latitude, longitude)) { answer ->
                fetching.remove("planes")
                val fresh = answer.text?.let { Planes.parse(it, latitude, longitude) }
                if (fresh != null) {
                    val shown = planes.getOrNull(planeIndex)?.id
                    planes = fresh; planeNote = ""
                    planeIndex = fresh.indexOfFirst { it.id == shown }.let { if (it >= 0) it else min(planeIndex, max(0, fresh.size - 1)) }
                } else if (planes.isEmpty()) planeNote = answer.problem ?: "Couldn't read the flight data."
            }
        }
        if (program == Program.planes) {
            val callsign = planes.getOrNull(planeIndex)?.callsign ?: ""
            val url = if (callsign.isNotEmpty()) Planes.routeURL(callsign) else null
            if (url != null && routesAsked.add(callsign)) Http.get(url) { answer -> answer.text?.let { Planes.route(it) }?.let { planeRoutes[callsign] = it } }
        }
        if (wantsTour) {
            val far = tourAt?.let { Geo.distance(latitude, longitude, it.first, it.second) > 300 } ?: true
            if ((far || now >= tourDue) && fetching.add("tour")) {
                tourDue = now + 600; tourAt = latitude to longitude
                Http.get(Tour.url(latitude, longitude), mapOf("User-Agent" to "GlassesHub/2.0 (Android app; walking tour)")) { answer ->
                    fetching.remove("tour")
                    val fresh = answer.text?.let { Tour.parse(it, latitude, longitude) }
                    if (fresh != null) {
                        val shown = places.getOrNull(placeIndex)?.id
                        places = fresh; tourNote = ""
                        val at = fresh.indexOfFirst { it.id == shown }
                        if (at >= 0 && tourOpen) placeIndex = at else { tourOpen = false; placeIndex = min(placeIndex, max(0, fresh.size - 1)) }
                        announcePlaces()
                    } else {
                        if (places.isEmpty()) tourNote = answer.problem ?: "Couldn't read Wikipedia's answer."
                        tourDue = now() + 60; tourAt = null
                    }
                }
            }
        }
    }

    // MARK: Movie captions

    private val shelf: File get() = File(context.filesDir, "subtitles").also { it.mkdirs() }
    private fun loadMovie() {
        val text = if (movieCurrent.isEmpty()) "" else try { SubtitleFile.decode(File(shelf, "$movieCurrent.srt").readBytes()) } catch (e: Exception) { "" }
        movie = MovieTracker(SubtitleFile.parse(text)).also { it.holdsWhenQuiet = movieHolds }
    }
    private fun saveLibrary() = s.putJson("movieLibrary", movieLibrary.map { mapOf("id" to it.id, "title" to it.title, "detail" to it.detail) })

    /** Keeps a subtitle file and makes it the one showing. False when it isn't a subtitle file. */
    fun addMovie(title: String, detail: String, text: String): Boolean {
        if (SubtitleFile.parse(text).isEmpty()) return false
        val id = UUID.randomUUID().toString()
        try { File(shelf, "$id.srt").writeText(text) } catch (e: Exception) { return false }
        val all = listOf(MovieEntry(id, title, detail)) + movieLibrary
        for (old in all.drop(30)) File(shelf, old.id + ".srt").delete()      // the shelf holds thirty
        movieLibrary = all.take(30)
        saveLibrary()
        movieCurrent = id
        return true
    }
    fun removeMovie(entry: MovieEntry) {
        File(shelf, entry.id + ".srt").delete()
        if (entry.id == movieCurrent) { if (movieOn) stopMovie(); movieCurrent = "" }
        movieLibrary = movieLibrary.filter { it.id != entry.id }
        saveLibrary()
    }
    /** Back to waiting for the first line, as when a film is started over. */
    fun restartMovie() = movie.reset()
    fun nudgeMovie(seconds: Double) = movie.shift(seconds, now())
    fun holdMovie() = movie.toggleHold(now())

    fun toggleMovie() {
        if (movieOn) { stopMovie(); return }
        if (movie.isEmpty) { movieNote = "Pick a movie or show first."; return }
        if (!movieCanListen) { movieNote = ""; return }
        val problem = listener.start(SubtitleSearch.speech(movieAudio))
        movieOn = problem == null
        movieNote = problem ?: ""
        applyKeepAwake()
    }
    fun stopMovie() {
        if (!movieOn) return
        listener.stop()
        movieOn = false
        applyKeepAwake()
    }
    private fun heardPartial(text: String) {
        if (movieOn && movie.hear(text, now()) && program == Program.movie && link.isRunning) tick()
    }

    // MARK: Live text

    /** Text from outside the app: something shared to it, or a glasseshub:// link. `start` also turns the display on. */
    fun showLive(text: String, append: Boolean, start: Boolean = false) {
        live.show(text, append)
        liveReceivedAt = now()
        livePage = 0
        if (start && !link.isRunning) startDisplay()
        if (liveSwitches && program != Program.live) program = Program.live
        if (program == Program.live && link.isRunning) tick()
    }
    fun clearLive() { live.clear(); liveReceivedAt = null }

    /** Opens a glasseshub:// link: glasseshub://show?text=Hello&append=1&start=1, glasseshub://clear */
    fun open(host: String, fields: Map<String, String>) {
        fun truthy(key: String) = (fields[key] ?: "").lowercase() in listOf("1", "true", "yes")
        when (host.lowercase()) {
            "show" -> fields["text"]?.let { showLive(it, truthy("append"), truthy("start")) }
            "clear" -> clearLive()
            "start" -> if (!link.isRunning) startDisplay()
            "stop" -> if (link.isRunning) stopDisplay()
        }
    }

    // MARK: Tools

    fun toggleMetronome() {
        if (metroOn) sound.stopMetronome() else sound.startMetronome(metroBPM, metroBeats)
        metroOn = sound.metronomeOn
    }
    fun toggleTuner() {
        if (tunerOn) { sound.stopListening(); tunerOn = false; tunerReading = null; applyKeepAwake(); return }
        val problem = sound.startListening()
        tunerOn = problem == null
        tunerNote = problem ?: ""
        applyKeepAwake()
    }
    private fun heardPitch(hz: Double?) {
        val reading = hz?.let { TunerReading.of(it) }
        if (reading != null) { tunerReading = reading; tunerHeardAt = now() } else if (now() - tunerHeardAt > 2) tunerReading = null
    }
    private fun speedText(): List<String> {
        if (speedWords.first != readerText) speedWords = readerText to SpeedRead.words(readerText)
        return speedWords.second
    }
    private fun speedAnchor() { speedShownAt = now() }
    fun toggleSpeedRead() { toolInput(Input.select) }
    fun restartSpeedRead() { speedIndex = 0; speedAnchor() }
    fun roll() { pickerResult = Picker.roll(pickerMode, Picker.options(pickerOptions)); pickerRolledAt = now() }

    private fun stopTools() {
        if (metroOn) { sound.stopMetronome(); metroOn = false }
        if (tunerOn) { sound.stopListening(); tunerOn = false; tunerReading = null }
        if ((chordOn && program != Program.chords) || (drumOn && program != Program.drums)) { ear.stop(); chordOn = false; drumOn = false; drumCalibration = null }
        if (movieOn && program != Program.movie) stopMovie()
        speedPlaying = false
        applyKeepAwake()
    }

    // MARK: Data

    /** Ask every feed again now (a crown turn on the feeds screen, or "Check now" in the app). */
    fun refreshFeeds() { feedDue.clear(); refreshFeedData(now(), all = true) }

    private fun refreshFeedData(now: Double, all: Boolean = false) {
        for (feed in feeds) {
            val wanted = all || program == Program.feeds || (program == Program.dashboard && feed.onDashboard)
            if (!wanted || now < (feedDue[feed.id] ?: never)) continue
            val request = feed.request(feedToken(feed.id))
            if (request == null) { if (feedReadings[feed.id] == null) feedNotes = feedNotes + (feed.id to "Not set up yet."); continue }
            if (!fetching.add("feed." + feed.id)) continue
            feedDue[feed.id] = now + max(1, feed.minutes) * 60.0
            Http.get(request.first, request.second) { answer ->
                fetching.remove("feed." + feed.id)
                val current = feeds.firstOrNull { it.id == feed.id } ?: return@get
                val reading = if (answer.status in 200..299) answer.text?.let { FeedParser.read(current, it, now()) } else null
                if (reading != null) { feedReadings = feedReadings + (feed.id to reading); feedNotes = feedNotes + (feed.id to "") }
                else {
                    feedNotes = feedNotes + (feed.id to (answer.problem ?: "The answer didn't have that value."))
                    feedDue[feed.id] = now() + 60          // try again sooner after a miss
                }
            }
        }
    }

    private fun refreshStocks(now: Double) {
        val wanted = program == Program.stocks || (program == Program.dashboard && dashStocks)
        if (!wanted || stockSymbols.isEmpty() || now < stocksDue || !fetching.add("stocks")) return
        stocksDue = now + (if (program == Program.stocks) 60 else 300)
        val symbols = if (program == Program.stocks) stockSymbols else stockSymbols.take(2)
        var left = symbols.size
        var problem = ""
        for (symbol in symbols) {
            // the service only answers requests that look like they come from a browser
            Http.get(Stocks.url(symbol), mapOf("User-Agent" to "Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0 Mobile Safari/537.36")) { answer ->
                val quote = if (answer.status in 200..299) answer.text?.let { Stocks.parse(it) } else null
                if (quote != null) stockQuotes = stockQuotes + (symbol to quote)
                else problem = if (answer.status == 404 || answer.status in 200..299) "No price found for $symbol." else "Couldn't reach the price service."
                left -= 1
                if (left == 0) { stockNote = problem; fetching.remove("stocks") }
            }
        }
    }

    private fun refreshData(now: Double) {
        refreshFeedData(now)
        refreshStocks(now)
        refreshNearby(now)
        val wantsScores = leagues.isNotEmpty() && (program == Program.scores || (program == Program.dashboard && dashScores) || (scoreAlerts && (link.isRunning || popUps)))
        if (wantsScores && now >= scoresDue && fetching.add("scores")) {
            scoresDue = now + 15            // floor; refined when the answer is in
            val wanted = League.entries.filter { it in leagues }
            val all = ArrayList<Game>()
            var left = wanted.size
            var anyWorked = false
            for (league in wanted) {
                Http.get(league.feed) { answer ->
                    if (answer.status == 200) answer.text?.let { anyWorked = true; all += Scoreboard.parse(it, league) }
                    left -= 1
                    if (left == 0) { fetching.remove("scores"); took(if (anyWorked) all.sortedBy { wanted.indexOf(it.league) } else null, now()) }
                }
            }
        }
        val wantsWeather = program == Program.weather || (program == Program.dashboard && dashWeather)
        if (wantsWeather && now >= weatherDue && fetching.add("weather")) {
            weatherDue = now + 60
            val name = city.trim()
            fun forecast(spot: Weather.Place) {
                Http.get(Weather.feed(spot.latitude, spot.longitude, celsius)) { answer ->
                    val fresh = if (answer.status == 200) answer.text?.let { Weather.parse(it, name) } else null
                    if (fresh != null) { weather = fresh; weatherNote = ""; weatherDue = now() + 20 * 60 }
                    else if (weather == null) weatherNote = "Couldn't reach the weather service."
                    fetching.remove("weather")
                }
            }
            val known = place
            if (known != null && known.name.equals(name, ignoreCase = true)) forecast(known)
            else if (name.isEmpty()) { weatherNote = "Enter a city in the app."; weather = null; fetching.remove("weather") }
            else Http.get(Weather.placeLookup(name)) { answer ->
                val found = if (answer.status == 200) answer.text?.let { Weather.parsePlace(it) } else null
                if (found != null) { val spot = Weather.Place(name, found.latitude, found.longitude); place = spot; forecast(spot) }
                else { weatherNote = "Couldn't find $name."; weather = null; fetching.remove("weather") }
            }
        }
        val wantsAgenda = program == Program.agenda || (program == Program.dashboard && dashAgenda)
        if (wantsAgenda && now >= agendaDue) {
            agendaDue = now + 120
            calendarAllowed = calendar.allowed
            val fresh = calendar.today(now)
            if (fresh != agenda) agenda = fresh
            val ahead = calendar.upcoming(7, now)
            if (ahead != week) week = ahead
        }
        val wantsNews = program == Program.news || (program == Program.dashboard && dashNews)
        if (wantsNews && now >= newsDue && fetching.add("news")) {
            newsDue = now + 10 * 60
            val sources = NewsSource.builtIn.filter { it.url in newsSourceList }.toMutableList()
            val custom = customFeed.trim()
            if (custom.lowercase().startsWith("http")) sources.add(NewsSource((try { java.net.URI(custom).host } catch (e: Exception) { null })?.removePrefix("www.") ?: "My feed", custom))
            val lists = ArrayList<List<NewsItem>>()
            var left = sources.size
            fun finish() {
                fetching.remove("news")
                val fresh = News.merged(lists)
                if (fresh.isEmpty()) {
                    if (news.isEmpty()) { newsNote = if (sources.isEmpty()) "Pick a news source in the app." else "Couldn't reach the news feeds."; newsDue = now() + 60 }
                } else {
                    val current = news.getOrNull(newsIndex)?.id
                    news = fresh; newsNote = ""
                    newsIndex = fresh.indexOfFirst { it.id == current }.coerceAtLeast(0)
                }
            }
            if (sources.isEmpty()) finish()
            for (source in sources) Http.get(source.url) { answer ->
                if (answer.status == 200) answer.text?.let { lists.add(News.parseFeed(it, source.name)) }
                left -= 1
                if (left == 0) finish()
            }
        }
        if (program == Program.news && reading == null && !menuOpen && !listEnd && headlineSeconds > 0 && news.size > 1 && now - headlineTurnedAt >= headlineSeconds) {
            newsIndex = (newsIndex + 1) % news.size; headlineTurnedAt = now
        }
        if (popUps && popFactMinutes > 0 && now >= popFactDue && !(link.isRunning && !popupOpen) && fetching.add("popfact")) {
            popFactDue = now + popFactMinutes * 60
            fetchFact { fresh ->
                if (fresh != null) {
                    val head = (if (glyphStyle != GlyphStyle.plain) glyphs.note + " " else "") + "Odd fact"
                    overlays.push(Card(listOf(head) + TextLayout.wrap(fresh, screen.columns, screen.rows - 1)), max(alertSeconds, 15.0))
                    unshown.add("Odd fact" to fresh)
                }
                fetching.remove("popfact")
            }
        }
        if (program == Program.facts && now >= factDue && fetching.add("fact")) {
            factDue = now + max(1.0, factMinutes) * 60
            fetchFact { fresh ->
                if (fresh != null) fact = fresh
                else if (fact == null) { fact = "Couldn't reach the fact service. Will try again."; factDue = now() + 30 }
                fetching.remove("fact")
            }
        }
    }

    private fun fetchFact(done: (String?) -> Unit) {
        fun random() = Http.get(Facts.randomFeed) { answer -> done(if (answer.status == 200) answer.text?.let { Facts.parseRandom(it) } else null) }
        if (!factsOnThisDay) { random(); return }
        Http.get(Facts.onThisDayFeed(now())) { answer ->
            val picks = if (answer.status == 200) answer.text?.let { Facts.parseOnThisDay(it) } ?: emptyList() else emptyList()
            if (picks.isNotEmpty()) done(picks.random()) else random()
        }
    }

    private fun took(fresh: List<Game>?, now: Double) {
        if (fresh == null) {
            if (game == null) scoresNote = "Couldn't reach the scores feed."
            scoresDue = now + 30
            return
        }
        scoresAt = now
        val all = fresh.toMutableList()
        // A followed team with no game on today's boards: ask its own page for its next one.
        for (team in followed) {
            if (fresh.any { it.has(team) }) continue
            for (league in League.entries) {
                if (league !in leagues) continue
                val key = "${league.name}/$team"
                val cached = nextGames[key]
                if (cached != null && now - cached.second < 30 * 60) {
                    val next = cached.first
                    if (next != null && all.none { it.id == next.id }) all.add(next)
                } else if (fetching.add(key)) {
                    val url = league.teamFeed(team)
                    if (url == null) { fetching.remove(key); continue }
                    Http.get(url) { answer ->
                        fetching.remove(key)
                        val next = if (answer.status == 200) answer.text?.let { Scoreboard.parseTeamNext(it, league) } else null
                        nextGames[key] = next to now()
                        if (next != null) scoresDue = never
                    }
                }
            }
        }
        if (all != games) games = all
        repick(now)
        scoresDue = now + Scoreboard.pollInterval(game, now)
    }

    /** Choose the game to show (the pinned one if it's still listed) and raise alerts for what changed in it. */
    private fun repick(now: Double = now()) {
        val picked = games.firstOrNull { it.id == pinnedGame } ?: Scoreboard.pick(games, followed, now)
        scoresNote = if (picked == null) "No games on the schedule." else ""
        val before = lastGame
        if (picked != null && scoreAlerts && before != null && before.id == picked.id) for (lines in Scoreboard.alerts(before, picked)) alert(lines, Program.scores)
        // other followed teams' games still get their alerts while a different game is on screen
        if (scoreAlerts) for (other in games) {
            if (other.id == picked?.id || followed.none { other.has(it) }) continue
            watched[other.id]?.let { was -> for (lines in Scoreboard.alerts(was, other)) alert(lines, Program.scores) }
        }
        watched = HashMap(games.filter { g -> followed.any { g.has(it) } }.associateBy { it.id })
        lastGame = picked
        if (picked != game) game = picked
    }

    fun nextFact() { factDue = never }

    // MARK: Alerts

    /** True when an alert can go to the display: it's on, or pop-up mode will open it. */
    private val reachable: Boolean get() = link.isShowing || link.isStandingBy || popUps

    /**
     * Something worth interrupting for. Goes to the display, a notification, or both, per the setting.
     * An alert from the program already on screen isn't shown over itself.
     */
    private fun alert(lines: List<String>, source: Program?) {
        val onDisplay = reachable && alertStyle != AlertStyle.notification
        val asNotification = alertStyle == AlertStyle.notification || alertStyle == AlertStyle.both || (alertStyle == AlertStyle.auto && !reachable)
        val body = lines.drop(1).joinToString(". ")
        if (onDisplay && (!link.isShowing || popupOpen || source == null || source != program || source == Program.scores)) {
            val fitted = ArrayList<String>()
            lines.firstOrNull()?.let { fitted.add(TextLayout.headline(it, screen)) }
            for (line in lines.drop(1)) fitted += TextLayout.wrap(line, screen.columns)
            overlays.push(Card(fitted.take(screen.rows)), alertSeconds)
            if (!link.isShowing) unshown.add((lines.firstOrNull() ?: "") to body)
        }
        if (asNotification && notificationsAllowed) notifier.post(lines.firstOrNull() ?: "", body)
    }

    /** A notification that arrived on the phone, to show on the glasses while the display is up. */
    fun phoneNotice(pkg: String, app: String, title: String, text: String) {
        if (!phoneNotices || !(link.isShowing || link.isStandingBy)) return
        val skip = noticeSkip.lowercase().split(',', '\n').map { it.trim() }.filter { it.isNotEmpty() }
        if (skip.any { app.lowercase().contains(it) || pkg.lowercase().contains(it) }) return
        val head = if (title.isNotEmpty() && !title.equals(app, ignoreCase = true)) "$app: $title" else app
        val lines = TextLayout.wrap(head, screen.columns, 2) + TextLayout.wrap(text, screen.columns, max(1, screen.rows - 2))
        overlays.push(Card(lines.take(screen.rows)), noticeSeconds)
        link.record("Notification from $app shown.")
        if (link.isRunning) tick()
    }

    /** Put a one-off card on the glasses for a few seconds (the "Send" box). */
    fun flash(text: String) {
        val card = Reader.note("", text, screen)
        if (reachable) { overlays.push(card, max(alertSeconds, 12.0)); if (!link.isShowing) unshown.add("Glasses Hub" to text) }
        else if (notificationsAllowed) notifier.post("Glasses Hub", text)
    }

    fun showTestCard() {
        val wide = screen.wideColumns
        overlays.push(Card(listOf("Display test, ${screen.rows} lines",
            TextLayout.wide("ABCDEFGHIJKLMNOPQRSTUVWXYZ".take(wide)),
            "1234567890123456789012345678901234567890123456789012345678901234567890".take(screen.columns),
            "The line above should end at ${screen.columns}.",
            Grid.row(listOf(Triple("KC", 4, false), Triple("7", 2, true))) + " < columns", Grid.row(listOf(Triple("BUF", 4, false), Triple("24", 2, true))) + " < line up?",
            "Line 7 (small text only)").take(screen.rows)), 30.0)
    }
    /** Put every symbol the app can use on the glasses, three pages for 12 seconds each. */
    fun showSymbolTest() { overlays.clear(); testCardsUntil = now() + 36 }

    // MARK: News

    fun newsStep(by: Int) {
        if (news.isEmpty()) return
        reading = null
        newsIndex = (newsIndex + by).mod(news.size)
        headlineTurnedAt = now()
    }

    /** Open a story in full. The feed's own text shows at once; the article page replaces it if it loads. */
    fun read(item: NewsItem) {
        news.indexOfFirst { it.id == item.id }.let { if (it >= 0) newsIndex = it }
        reading = item; readingNote = ""
        if (program != Program.news) program = Program.news
        pageRestart()
        val url = item.link
        if (articles[item.id] != null) return
        if (url == null) { articles[item.id] = ""; return }
        Http.get(url) { answer ->
            val text = if (answer.status == 200) News.articleText(answer.text ?: "").take(60_000) else ""
            // keep whichever is longer: some sites put the whole story in the feed and little on the page
            articles[item.id] = if (text.length > item.summary.length) text else ""
            if (text.isEmpty() && item.summary.isEmpty()) readingNote = "Couldn't get this story's text."
        }
    }
    fun readCurrent() { news.getOrNull(newsIndex)?.let { read(it) } }
    fun stopReading() { reading = null; headlineTurnedAt = now() }
    fun refreshNews() { newsDue = never }
    /** The full text of the story being read, for copying into the Reader. */
    val readingText: String get() {
        val story = reading ?: return ""
        return story.title + "\n\n" + (articles[story.id] ?: "").ifEmpty { story.summary }
    }

    // MARK: Trivia

    fun startTrivia() {
        if (!fetching.add("trivia")) return
        triviaNote = "Getting questions…"; round = null
        Http.get(Trivia.feed(triviaCount)) { answer ->
            fetching.remove("trivia")
            val questions = if (answer.status == 200) Trivia.parse(answer.text ?: "") else emptyList()
            if (questions.isEmpty()) triviaNote = "Couldn't get questions. Try again in a moment."
            else {
                triviaNote = ""
                round = TriviaRound(questions, now(), triviaQuestionSeconds, triviaAnswerSeconds, triviaAuto)
                if (program != Program.trivia) program = Program.trivia
            }
        }
    }
    fun triviaReveal() { round?.reveal(now()) }
    fun triviaNext() { round?.next(now()) }
    fun triviaStop() { round = null; triviaNote = "" }

    // MARK: Timer

    fun timerStart() {
        val untouched = !timer.isRunning && timer.pausedRemaining == timer.duration
        if (timer.isDone(now()) || (untouched && timer.duration != timerMinutes * 60)) timer = HubTimer.minutes(timerMinutes)
        timer.start(now())
    }
    fun timerPause() = timer.pause(now())
    fun timerReset() { timer = HubTimer.minutes(timerMinutes) }

    // MARK: Permissions

    fun refreshPermissions() {
        notificationsAllowed = notifier.allowed
        val had = calendarAllowed
        calendarAllowed = calendar.allowed
        if (calendarAllowed && !had) agendaDue = never
    }
}
