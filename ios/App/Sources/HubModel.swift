import Foundation
import SwiftUI
import UserNotifications
import HubCore

/// What can be on the glasses.
enum Program: String, CaseIterable, Identifiable {
    case dashboard, scores, news, mail, agenda, weather, trivia, facts, timer, reader, message
    case speed, metronome, tuner, picker
    var id: String { rawValue }
    var title: String {
        switch self {
        case .dashboard: return "Dashboard"; case .scores: return "Scoreboard"; case .trivia: return "Trivia host"
        case .facts: return "Odd facts"; case .timer: return "Timer"; case .weather: return "Weather"
        case .agenda: return "Calendar"; case .reader: return "Reader"; case .message: return "Message"
        case .news: return "News"; case .mail: return "Mail"
        case .speed: return "Speed read"; case .metronome: return "Metronome"; case .tuner: return "Tuner"; case .picker: return "Dice & coin"
        }
    }
    var icon: String {
        switch self {
        case .dashboard: return "square.grid.2x2"; case .scores: return "sportscourt"; case .trivia: return "questionmark.bubble"
        case .facts: return "lightbulb"; case .timer: return "timer"; case .weather: return "cloud.sun"
        case .agenda: return "calendar"; case .reader: return "text.alignleft"; case .message: return "text.bubble"
        case .news: return "newspaper"; case .mail: return "envelope"
        case .speed: return "bolt.horizontal"; case .metronome: return "metronome"; case .tuner: return "tuningfork"; case .picker: return "dice"
        }
    }
    var blurb: String {
        switch self {
        case .dashboard: return "Time, score, weather and your next event on one screen."
        case .scores: return "Live score, box score by period, or the whole league as a table."
        case .mail: return "Your Gmail inbox: scroll the list, click to read one."
        case .news: return "Headlines that turn by themselves, and full stories a page at a time."
        case .trivia: return "You read the question off your glasses; the answer follows."
        case .facts: return "A new surprising fact every few minutes."
        case .timer: return "A countdown you can see without looking down."
        case .weather: return "Now, the next 12 hours as a table, or the week ahead."
        case .agenda: return "Today's events, or the month as a grid."
        case .reader: return "Paste any text and read it a page at a time."
        case .message: return "Put a line of text on the glasses and leave it there."
        case .speed: return "The Reader's text a few words at a time, in one spot."
        case .metronome: return "Clicks from your phone; set the tempo with the crown."
        case .tuner: return "Play a note near your phone and see how far off it is."
        case .picker: return "Flip a coin, roll dice, or pick from your own list."
        }
    }
}

enum AlertStyle: String, CaseIterable, Identifiable {
    case auto, display, notification, both
    var id: String { rawValue }
    var title: String {
        switch self {
        case .auto: return "Display when it's on, else notify"
        case .display: return "Display only"
        case .notification: return "Notifications only"
        case .both: return "Both"
        }
    }
}

enum ScoresView: String, CaseIterable, Identifiable {
    case auto, game, box, league
    var id: String { rawValue }
    var title: String {
        switch self { case .auto: return "Game, then box score"; case .game: return "Game"; case .box: return "Box score"; case .league: return "All games" }
    }
}
enum WeatherView: String, CaseIterable, Identifiable {
    case cycle, now, hours, week
    var id: String { rawValue }
    var title: String {
        switch self { case .cycle: return "Take turns"; case .now: return "Now"; case .hours: return "Next 12 hours"; case .week: return "Week" }
    }
}
enum AgendaView: String, CaseIterable, Identifiable {
    case cycle, list, month
    var id: String { rawValue }
    var title: String { switch self { case .cycle: return "Take turns"; case .list: return "Today's events"; case .month: return "Month" } }
}

/// The app's brain: settings, the data each app shows, and the once-a-second loop that decides what the
/// glasses should say right now.
@MainActor
final class HubModel: ObservableObject {
    let link = GlassesLink()
    let pc = PCLink()
    private let keepAwake = KeepAwake()
    private let buttons = VolumeButtons()
    let google = GoogleAuth()
    private let calendar = CalendarReader()
    private let defaults = UserDefaults.standard

    // MARK: Settings (saved)

    @Published var program: Program { didSet { defaults.set(program.rawValue, forKey: "program"); programChanged() } }
    @Published var textSize: TextSize { didSet { defaults.set(textSize.rawValue, forKey: "textSize") } }
    @Published var columnsSmall: Int { didSet { defaults.set(columnsSmall, forKey: "columnsSmall") } }
    @Published var columnsLarge: Int { didSet { defaults.set(columnsLarge, forKey: "columnsLarge") } }
    @Published var runWhenLocked: Bool { didSet { defaults.set(runWhenLocked, forKey: "runWhenLocked"); applyKeepAwake() } }
    @Published var refreshScreen: Bool { didSet { defaults.set(refreshScreen, forKey: "refreshScreen") } }
    @Published var alertStyle: AlertStyle { didSet { defaults.set(alertStyle.rawValue, forKey: "alertStyle") } }
    @Published var alertSeconds: Double { didSet { defaults.set(alertSeconds, forKey: "alertSeconds") } }

    @Published var glyphStyle: GlyphStyle { didSet { defaults.set(glyphStyle.rawValue, forKey: "glyphStyle") } }
    @Published var pageSeconds: Double { didSet { defaults.set(pageSeconds, forKey: "pageSeconds") } }
    @Published var volumePaging: Bool { didSet { defaults.set(volumePaging, forKey: "volumePaging"); applyKeepAwake() } }
    @Published var gmailClientID: String { didSet { defaults.set(gmailClientID, forKey: "gmailClientID") } }
    /// Mail needs the owner's own Google sign-in set-up, so it stays hidden unless switched on.
    @Published var showMail: Bool { didSet { defaults.set(showMail, forKey: "showMail") } }
    // Tools
    private let sound = ToolSound()
    @Published var metroBPM: Int { didSet { defaults.set(metroBPM, forKey: "metroBPM"); if metroOn { sound.startMetronome(bpm: metroBPM, beats: metroBeats) } } }
    @Published var metroBeats: Int { didSet { defaults.set(metroBeats, forKey: "metroBeats"); if metroOn { sound.startMetronome(bpm: metroBPM, beats: metroBeats) } } }
    @Published private(set) var metroOn = false
    @Published private(set) var tunerOn = false
    @Published private(set) var tunerReading: TunerReading?
    @Published private(set) var tunerNote = ""
    private var tunerHeardAt = Date.distantPast
    @Published var speedWPM: Int { didSet { defaults.set(speedWPM, forKey: "speedWPM"); speedAnchor() } }
    @Published var speedChunk: Int { didSet { defaults.set(speedChunk, forKey: "speedChunk"); speedAnchor() } }
    @Published private(set) var speedPlaying = false
    @Published private(set) var speedIndex = 0
    private var speedWords: (key: Int, words: [String]) = (0, [])
    private var speedShownAt = Date.distantPast
    @Published var pickerMode: PickerMode { didSet { defaults.set(pickerMode.rawValue, forKey: "pickerMode") } }
    @Published var pickerOptions: String { didSet { defaults.set(pickerOptions, forKey: "pickerOptions") } }
    @Published private(set) var pickerResult: PickerResult?
    private var pickerRolledAt = Date.distantPast

    /// The menu on the glasses: the dashboard, then groups of apps.
    struct MenuGroup: Identifiable { let title: String; let items: [Program]; var id: String { title } }
    var menuGroups: [MenuGroup] {
        [MenuGroup(title: "Info", items: [.scores, .news, .mail, .agenda, .weather].filter { $0 != .mail || showMail }),
         MenuGroup(title: "Reading", items: [.reader, .speed, .message]),
         MenuGroup(title: "Tools", items: [.timer, .metronome, .tuner, .picker]),
         MenuGroup(title: "Fun", items: [.trivia, .facts])]
    }
    @Published private(set) var menuGroup: Int?
    private var menuTitles: [String] {
        if let g = menuGroup, menuGroups.indices.contains(g) { return ["< Back"] + menuGroups[g].items.map(\.title) }
        return [Program.dashboard.title] + menuGroups.map { $0.title + " >" }
    }

    /// The apps on offer, on the phone and in the glasses' menu.
    var apps: [Program] { [.dashboard] + menuGroups.flatMap(\.items) }
    @Published var setupSeen: Bool { didSet { defaults.set(setupSeen, forKey: "setupSeen") } }
    @Published var mailQuery: String { didSet { defaults.set(mailQuery, forKey: "mailQuery"); mailDue = .distantPast } }
    @Published var headPaging: Bool { didSet { defaults.set(headPaging, forKey: "lookUp") } }
    /// What a look up does when head navigation is on: false = next, true = select.
    @Published var headAction: Int { didSet { defaults.set(headAction, forKey: "headAction") } }   // 0 next, 1 select, 2 apps menu
    @Published var doubleClickAction: Int { didSet { defaults.set(doubleClickAction, forKey: "doubleClickAction") } }   // same values
    @Published var crownPaging: Bool { didSet { defaults.set(crownPaging, forKey: "crownPaging") } }
    /// Turning the crown back selects, like a click. The glasses report a crown click only now and
    /// then (one came through, then none for minutes), while every turn is reported, so the back turn
    /// is the dependable way to select. It needs a line of scroll room above each screen.
    @Published var crownBack: Bool { didSet { defaults.set(crownBack, forKey: "crownTwoWay") } }
    @Published var logEvents: Bool { didSet { defaults.set(logEvents, forKey: "logEvents"); link.logEvents = logEvents } }
    @Published var crownScroll: Bool { didSet { defaults.set(crownScroll, forKey: "crownScroll") } }
    /// Holding the crown (which makes the glasses leave the page) counts as select; the page reopens.
    @Published var holdSelects: Bool { didSet { defaults.set(holdSelects, forKey: "holdSelects") } }
    /// How to keep crown clicks coming (see GlassesLink.rearm).
    @Published var clickRearm: Int { didSet { defaults.set(clickRearm, forKey: "clickRearm2"); link.rearm = clickRearm } }
    /// Experiment for finding a click the glasses report every time. 0 = off.
    @Published var translationMode: Int { didSet { defaults.set(translationMode, forKey: "translationMode"); link.translationMode = translationMode } }
    @Published var scoresView: ScoresView { didSet { defaults.set(scoresView.rawValue, forKey: "scoresView") } }
    @Published var pinnedGame: String { didSet { defaults.set(pinnedGame, forKey: "pinnedGame"); repick() } }
    @Published var weatherView: WeatherView { didSet { defaults.set(weatherView.rawValue, forKey: "weatherView") } }
    @Published var agendaView: AgendaView { didSet { defaults.set(agendaView.rawValue, forKey: "agendaView") } }
    @Published var newsSources: Set<String> { didSet { defaults.set(Array(newsSources).sorted(), forKey: "newsSources"); newsDue = .distantPast } }
    @Published var customFeed: String { didSet { defaults.set(customFeed, forKey: "customFeed"); newsDue = .distantPast } }
    @Published var headlineSeconds: Double { didSet { defaults.set(headlineSeconds, forKey: "headlineSeconds") } }

    /// Pop-up mode: the display stays closed until something comes in, opens for it, then closes again.
    @Published var popUps: Bool { didSet { defaults.set(popUps, forKey: "popUps"); popFactDue = Date().addingTimeInterval(max(1, popFactMinutes) * 60); applyKeepAwake(); if popUps { pc.resume() } } }
    @Published var popFactMinutes: Double { didSet { defaults.set(popFactMinutes, forKey: "popFactMinutes"); popFactDue = Date().addingTimeInterval(max(1, popFactMinutes) * 60) } }

    @Published var leagues: Set<League> { didSet { defaults.set(leagues.map(\.rawValue).sorted(), forKey: "leagues"); scoresDue = .distantPast } }
    @Published var teams: String { didSet { defaults.set(teams, forKey: "teams"); lastGame = nil } }
    @Published var scoreAlerts: Bool { didSet { defaults.set(scoreAlerts, forKey: "scoreAlerts") } }

    @Published var triviaCount: Int { didSet { defaults.set(triviaCount, forKey: "triviaCount") } }
    @Published var triviaQuestionSeconds: Double { didSet { defaults.set(triviaQuestionSeconds, forKey: "triviaQuestionSeconds") } }
    @Published var triviaAnswerSeconds: Double { didSet { defaults.set(triviaAnswerSeconds, forKey: "triviaAnswerSeconds") } }
    @Published var triviaAuto: Bool { didSet { defaults.set(triviaAuto, forKey: "triviaAuto") } }

    @Published var factMinutes: Double { didSet { defaults.set(factMinutes, forKey: "factMinutes") } }
    @Published var factsOnThisDay: Bool { didSet { defaults.set(factsOnThisDay, forKey: "factsOnThisDay") } }

    @Published var city: String { didSet { defaults.set(city, forKey: "city") } }
    @Published var celsius: Bool { didSet { defaults.set(celsius, forKey: "celsius"); weatherDue = .distantPast } }

    @Published var dashScores: Bool { didSet { defaults.set(dashScores, forKey: "dashScores") } }
    /// The dashboard goes blank after a while and comes back when the wearer looks up (or uses the crown).
    @Published var dashSleep: Bool { didSet { defaults.set(dashSleep, forKey: "dashSleep"); wakeDashboard() } }
    @Published var dashSleepSeconds: Int { didSet { defaults.set(dashSleepSeconds, forKey: "dashSleepSeconds"); wakeDashboard() } }
    private var dashAwakeUntil = Date.distantFuture
    private var dashAsleep: Bool { dashSleep && program == .dashboard && !menuOpen && Date() > dashAwakeUntil }
    private func wakeDashboard() { dashAwakeUntil = Date().addingTimeInterval(Double(max(5, dashSleepSeconds))) }
    @Published var dashWeather: Bool { didSet { defaults.set(dashWeather, forKey: "dashWeather") } }
    @Published var dashAgenda: Bool { didSet { defaults.set(dashAgenda, forKey: "dashAgenda") } }
    @Published var dashNews: Bool { didSet { defaults.set(dashNews, forKey: "dashNews") } }
    @Published var dashNote: String { didSet { defaults.set(dashNote, forKey: "dashNote") } }

    @Published var readerText: String { didSet { defaults.set(readerText, forKey: "readerText") } }
    @Published var messageText: String { didSet { defaults.set(messageText, forKey: "messageText") } }
    @Published var showPCNotes: Bool { didSet { defaults.set(showPCNotes, forKey: "showPCNotes") } }
    @Published var timerMinutes: Double { didSet { defaults.set(timerMinutes, forKey: "timerMinutes") } }

    // MARK: Live state

    @Published private(set) var preview = ""
    @Published private(set) var previewScrolls = false
    @Published private(set) var game: Game?
    @Published private(set) var scoresNote = ""
    @Published private(set) var weather: Weather?
    @Published private(set) var weatherNote = ""
    @Published private(set) var agenda: [AgendaItem] = []
    @Published private(set) var calendarAllowed = false
    @Published private(set) var fact: String?
    @Published private(set) var round: TriviaRound?
    @Published private(set) var triviaNote = ""
    @Published var timer: HubTimer
    /// Every game on the enabled leagues' boards, for the picker.
    @Published private(set) var games: [Game] = []
    @Published private(set) var pageIndex = 0
    @Published private(set) var pageCount = 1
    @Published private(set) var pagesPaused = false
    @Published private(set) var news: [NewsItem] = []
    @Published private(set) var newsIndex = 0
    @Published private(set) var newsNote = ""
    /// The on-glasses app menu is up.
    @Published private(set) var menuOpen = false
    @Published private(set) var menuIndex = 0
    /// The current list has been scrolled past its last item, to the "end of list" stop.
    @Published private(set) var listEnd = false
    @Published private(set) var mail: [MailMessage] = []
    @Published private(set) var mailIndex = 0
    @Published private(set) var mailOpen = false
    @Published private(set) var mailNote = ""
    @Published private(set) var mailSignedIn = false
    /// Events over the coming week, for stepping through one at a time.
    @Published private(set) var week: [AgendaItem] = []
    /// The story being read in full, if any.
    @Published private(set) var reading: NewsItem?
    @Published private(set) var readingNote = ""
    @Published private(set) var notificationsAllowed = false
    /// Why the display last stopped on its own, until the user dismisses it or starts again.
    @Published var endedNotice: String?

    private var overlays = OverlayQueue()
    private var ticker: Timer?
    private var inFront = true
    private var lastGame: Game?
    private var watched = [String: Game]()
    private var pager = AutoPager()
    private var popupOpen = false
    private var scrollingBlock = false
    private var sectionIndex = 0
    private var sectionKey = ""
    private var agendaStep = 0
    private var weatherStep: Int?
    private var mailDue = Date.distantPast
    private var popFactDue = Date.distantFuture
    /// Alerts queued for a pop-up that hasn't opened yet, kept so they can go out as notifications if it can't.
    private var unshown = [(title: String, body: String)]()
    private var nextGames = [String: (game: Game?, at: Date)]()
    private var newsDue = Date.distantPast
    private var headlineTurnedAt = Date()
    private var articles = [String: String]()
    private var wrapped: (key: String, lines: [String]) = ("", [])
    private var testCardsUntil = Date.distantPast
    private var scoresDue = Date.distantPast
    private var scoresAt = Date.distantPast
    private var weatherDue = Date.distantPast
    private var place: (name: String, latitude: Double, longitude: Double)?
    private var agendaDue = Date.distantPast
    private var factDue = Date.distantPast
    private var fetching = Set<String>()
    private var timerAnnounced = false

    init() {
        let d = UserDefaults.standard
        func bool(_ key: String, _ fallback: Bool) -> Bool { d.object(forKey: key) == nil ? fallback : d.bool(forKey: key) }
        func number(_ key: String, _ fallback: Double) -> Double { d.object(forKey: key) == nil ? fallback : d.double(forKey: key) }
        program = Program(rawValue: d.string(forKey: "program") ?? "") ?? .dashboard
        textSize = TextSize(rawValue: d.string(forKey: "textSize") ?? "") ?? .small
        columnsSmall = Int(number("columnsSmall", Double(TextSize.small.defaultColumns)))
        columnsLarge = Int(number("columnsLarge", Double(TextSize.large.defaultColumns)))
        runWhenLocked = bool("runWhenLocked", true)
        refreshScreen = bool("refreshScreen", true)
        alertStyle = AlertStyle(rawValue: d.string(forKey: "alertStyle") ?? "") ?? .auto
        alertSeconds = number("alertSeconds", 10)
        glyphStyle = GlyphStyle(rawValue: d.string(forKey: "glyphStyle") ?? "") ?? .symbols
        pageSeconds = number("pageSeconds", 12)
        crownScroll = bool("crownScroll", false)
        holdSelects = bool("holdSelects", false)
        translationMode = defaults.integer(forKey: "translationMode")
        clickRearm = defaults.object(forKey: "clickRearm2") as? Int ?? 0
        volumePaging = bool("volumePaging", true)
        logEvents = bool("logEvents", false)
        crownPaging = bool("crownPaging", true)
        crownBack = bool("crownTwoWay", true)
        headPaging = bool("lookUp", true)
        headAction = defaults.object(forKey: "headAction") as? Int ?? 1
        doubleClickAction = defaults.object(forKey: "doubleClickAction") as? Int ?? 2
        gmailClientID = d.string(forKey: "gmailClientID") ?? ""
        metroBPM = d.object(forKey: "metroBPM") as? Int ?? 100
        metroBeats = d.object(forKey: "metroBeats") as? Int ?? 4
        speedWPM = d.object(forKey: "speedWPM") as? Int ?? 200
        speedChunk = d.object(forKey: "speedChunk") as? Int ?? 2
        pickerMode = PickerMode(rawValue: d.string(forKey: "pickerMode") ?? "") ?? .coin
        pickerOptions = d.string(forKey: "pickerOptions") ?? "Pizza\nTacos\nSushi\nBurgers"
        showMail = d.object(forKey: "showMail") as? Bool ?? !(d.string(forKey: "gmailClientID") ?? "").isEmpty
        // Anyone who already has the display set up doesn't need the first-run guide.
        setupSeen = d.object(forKey: "setupSeen") != nil ? d.bool(forKey: "setupSeen") : (d.object(forKey: "crownPaging") != nil || d.object(forKey: "lookUp") != nil)
        mailQuery = d.string(forKey: "mailQuery") ?? "in:inbox category:primary"
        scoresView = ScoresView(rawValue: d.string(forKey: "scoresView") ?? "") ?? .auto
        pinnedGame = d.string(forKey: "pinnedGame") ?? ""
        weatherView = WeatherView(rawValue: d.string(forKey: "weatherView") ?? "") ?? .cycle
        agendaView = AgendaView(rawValue: d.string(forKey: "agendaView") ?? "") ?? .cycle
        newsSources = Set(d.stringArray(forKey: "newsSources") ?? [NewsSource.builtIn[0].url, NewsSource.builtIn[1].url])
        customFeed = d.string(forKey: "customFeed") ?? ""
        headlineSeconds = number("headlineSeconds", 12)
        popUps = bool("popUps", false)
        popFactMinutes = number("popFactMinutes", 30)
        leagues = Set((d.stringArray(forKey: "leagues") ?? ["nfl"]).compactMap(League.init(rawValue:)))
        teams = d.string(forKey: "teams") ?? "KC"
        scoreAlerts = bool("scoreAlerts", true)
        triviaCount = Int(number("triviaCount", 10))
        triviaQuestionSeconds = number("triviaQuestionSeconds", 20)
        triviaAnswerSeconds = number("triviaAnswerSeconds", 8)
        triviaAuto = bool("triviaAuto", true)
        factMinutes = number("factMinutes", 5)
        factsOnThisDay = bool("factsOnThisDay", false)
        city = d.string(forKey: "city") ?? "Oklahoma City"
        celsius = bool("celsius", false)
        dashScores = bool("dashScores", true)
        dashSleep = bool("dashSleep", false)
        dashSleepSeconds = d.object(forKey: "dashSleepSeconds") as? Int ?? 20
        dashWeather = bool("dashWeather", true)
        dashAgenda = bool("dashAgenda", true)
        dashNews = bool("dashNews", false)
        dashNote = d.string(forKey: "dashNote") ?? ""
        readerText = d.string(forKey: "readerText") ?? ""
        messageText = d.string(forKey: "messageText") ?? ""
        showPCNotes = bool("showPCNotes", true)
        let minutes = number("timerMinutes", 10)
        timerMinutes = minutes
        timer = HubTimer(minutes: minutes)

        calendarAllowed = calendar.allowed
        link.logEvents = logEvents
        mailSignedIn = google.signedIn
        link.translationMode = translationMode
        link.rearm = clickRearm
        sound.onPitch = { [weak self] hz in self?.heard(hz) }
        link.onHoldExit = { [weak self] in
            guard let self, self.holdSelects else { return false }
            self.input(.select)
            return true
        }
        link.onDoubleClick = { [weak self] in
            guard let self, self.crownPaging, self.link.isShowing else { return }
            self.gesture(self.doubleClickAction)
        }
        link.onCrown = { [weak self] direction in
            guard let self, self.crownPaging, self.link.isShowing else { return }
            if direction == 0 { self.input(.select) }
            else if !self.scrollingBlock { self.input(direction > 0 ? .next : .previous) }   // in crown-scroll mode the crown just scrolls
        }
        link.onHeadRaise = { [weak self] in
            guard let self, self.link.isShowing else { return }
            if self.dashAsleep { self.link.record("Look up: dashboard back on."); self.wakeDashboard(); return }
            guard self.headPaging else { return }
            self.link.record("Look up.")
            self.gesture(self.headAction)
        }
        buttons.onPress = { [weak self] direction in
            guard let self, self.link.isShowing else { return }
            self.input(direction > 0 ? .next : .select)
        }
        popFactDue = Date().addingTimeInterval(max(1, popFactMinutes) * 60)
        applyKeepAwake()
        link.onEnded = { [weak self] reason in self?.displayEnded(reason) }
        pc.onNote = { [weak self] note in self?.received(note) }
        Notifier.shared.setUp()
        let made = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(made, forMode: .common)
        ticker = made
        pc.resume()
        Task { await refreshPermissions() }
    }

    var screen: Screen {
        Screen(rows: link.isShowing ? link.rows : textSize.rows,
               columns: textSize == .small ? columnsSmall : columnsLarge, wideColumns: textSize.wideColumns)
    }
    var followed: [String] {
        teams.uppercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
    }

    // MARK: Display controls

    func startDisplay() {
        wakeDashboard()
        endedNotice = nil
        link.start(size: textSize, refresh: refreshScreen, finishScrollingText: crownScroll)
        applyKeepAwake()
        tick()
    }

    func stopDisplay() {
        link.stop()
        overlays.clear(); unshown.removeAll(); popupOpen = false
        applyKeepAwake()
        if !inFront && !popUps { pc.pause() }
    }

    func scene(active: Bool) {
        inFront = active
        if active {
            pc.resume()
            Task { await refreshPermissions() }
        } else if !link.isRunning && !popUps {
            pc.pause()                      // nothing keeps the app awake without the display, so don't pretend
        }
        applyKeepAwake()
    }

    private func applyKeepAwake() {
        // Volume-button paging needs the audio session too, so it keeps the app awake while the display is on.
        keepAwake.set((runWhenLocked && (link.isRunning || popUps)) || (volumePaging && link.isRunning))
        buttons.set(volumePaging && link.isRunning)
    }

    private func displayEnded(_ reason: String) {
        overlays.clear()
        applyKeepAwake()
        endedNotice = reason
        if popupOpen {
            // A pop-up couldn't open (glasses away, or something else on their screen). Don't lose what
            // it was for: send it as ordinary notifications instead.
            popupOpen = false
            if notificationsAllowed { for item in unshown { Notifier.shared.post(title: item.title, body: item.body) } }
            unshown.removeAll()
            return
        }
        if !inFront && !popUps { pc.pause() }          // nothing keeps the app awake now; let the PC switch to Apple push
        if !inFront { Notifier.shared.post(title: "Glasses display stopped", body: reason) }
    }

    private func programChanged() {
        wakeDashboard()
        overlays.clear()
        stopTools()
        if program == .facts { factDue = .distantPast }
        if program == .agenda || program == .dashboard { agendaDue = .distantPast }
        pager = AutoPager(); pagesPaused = false
        listEnd = false; agendaStep = 0; weatherStep = nil; mailOpen = false
        if program == .mail { mailDue = .distantPast }
    }

    // MARK: The loop

    private func tick() {
        let now = Date()
        let awake = inFront || link.isRunning || popUps
        if awake { refreshData(now: now) }
        if link.isRunning || popUps { keepAwake.resume() }
        if popUps, !link.isRunning, !overlays.isEmpty {
            popupOpen = true
            link.start(size: textSize, refresh: refreshScreen, finishScrollingText: crownScroll)
        }

        // Speed read moves on by the clock, and is the one app that sends screens faster than once a second.
        link.pace = program == .speed && speedPlaying && !menuOpen ? SpeedRead.interval(wpm: speedWPM, chunk: speedChunk) : 1.0
        if program == .speed, speedPlaying, !menuOpen {
            let words = speedText()
            let step = SpeedRead.interval(wpm: speedWPM, chunk: speedChunk)
            if now.timeIntervalSince(speedShownAt) >= step {
                speedIndex = min(words.count, speedIndex + max(1, SpeedRead.chunk(words, at: speedIndex, size: speedChunk, width: screen.columns).count))
                speedShownAt = now
                if speedIndex >= words.count { speedPlaying = false }
            }
        }

        // Trivia and the timer move on their own.
        if var playing = round {
            let before = playing
            playing.tick(now: now.timeIntervalSinceReferenceDate)
            if playing != before { round = playing }
        }
        if timer.isDone(now: now), !timerAnnounced {
            timerAnnounced = true
            alert(["TIME'S UP", timer.label], source: .timer)
        }
        if !timer.isDone(now: now) { timerAnnounced = false }

        var card: Card
        if popupOpen, !link.isShowing { card = currentCard(now: now) }        // still opening; the alert's clock hasn't started
        else if let alert = overlays.current(now: now.timeIntervalSinceReferenceDate) { card = alert; unshown.removeAll() }
        else if popupOpen {
            popupOpen = false                                                 // everything has been shown: close again
            link.stop(); applyKeepAwake()
            card = currentCard(now: now)
        } else {
            card = currentCard(now: now)
            // Anything taller than the screen is shown a page at a time. Reading stops on the last page;
            // everything else starts over.
            let readingText = !menuOpen && !listEnd && (program == .reader || (program == .news && reading != nil) || (program == .mail && mailOpen)
                                                        || (program == .agenda && agendaStep >= 2))
            if crownScroll && readingText {
                // Crown mode: send the text in one block for the glasses to scroll. A block can only be so
                // big, so long text goes up in sections, stepped with "next" like pages.
                var sections = [[String]](), current = [String](), bytes = 0
                for line in card.lines {
                    let cost = line.utf8.count + 1
                    if bytes + cost > 2200, !current.isEmpty { sections.append(current); current = []; bytes = 0 }
                    current.append(line); bytes += cost
                }
                if !current.isEmpty { sections.append(current) }
                let key = "\(card.lines.count)|\(card.lines.first ?? "")"
                if key != sectionKey { sectionKey = key; sectionIndex = 0 }
                sectionIndex = max(0, min(sections.count - 1, sectionIndex))
                var shown = sections.isEmpty ? card.lines : sections[sectionIndex]
                if sections.count > 1 { shown.append("(section \(sectionIndex + 1) of \(sections.count))") }
                card = Card(shown, scrolls: shown.count > screen.rows)
                if pageIndex != sectionIndex { pageIndex = sectionIndex }
                if pageCount != max(1, sections.count) { pageCount = max(1, sections.count) }
            } else {
                pager.paused = pagesPaused
                card = pager.page(of: card, rows: screen.rows, now: now.timeIntervalSinceReferenceDate, seconds: pageSeconds, loops: !readingText)
                if pageIndex != pager.index { pageIndex = pager.index }
                if pageCount != pager.count { pageCount = pager.count }
            }
        }
        let text = card.text(rows: screen.rows)
        if text != preview { preview = text }
        if card.scrolls != previewScrolls { previewScrolls = card.scrolls }
        scrollingBlock = card.scrolls
        if link.isRunning {
            // Each screen goes up with a line of scroll room above it; that is what lets the glasses'
            // reports tell a turn back (select) from a turn forward (next).
            let room = crownPaging && crownBack && !card.scrolls
            let sent = room
                ? TextLayout.withScrollRoom(card.lines, rows: screen.rows, marker: "\u{00B7}").joined(separator: "\n") : text
            link.show(sent, scrolls: card.scrolls)
            link.tick()
        }
    }

    // MARK: Crown and button navigation

    enum Input { case next, previous, select }

    /// One step of navigation, from the crown (turn = next, click = select), the volume buttons (up = next,
    /// down = select) or the two buttons on the Display tab.
    ///
    /// The scheme is the same everywhere: "next" moves to the next thing (page, headline, game, event,
    /// message); "select" opens what's showing if it can be opened, goes back if something is open, and
    /// otherwise brings up the menu of apps. Lists end in a stop that also leads to the menu.
    func input(_ what: Input) {
        link.record("Input \(what) on \(program.rawValue)" + (menuOpen ? ", menu open" : "") + (listEnd ? ", at list end" : ""))
        if dashAsleep { wakeDashboard(); return }           // the first touch only brings the dashboard back
        wakeDashboard()
        if !menuOpen, !listEnd, toolInput(what) { return }
        if what == .previous { goBack(); return }
        let next = what == .next
        if menuOpen {
            if next { menuIndex = (menuIndex + 1) % menuTitles.count } else { menuSelect() }
            return
        }
        if listEnd {
            listEnd = false
            if next { restartList() } else { openMenu() }
            return
        }
        let morePages = pageCount > 1 && pageIndex < pageCount - 1
        switch program {
        case .news:
            if reading != nil {
                if !next { stopReading() } else if morePages { pageStep(1) } else { stopReading(); advance(&newsIndex, count: news.count) }
            } else if next { advance(&newsIndex, count: news.count); headlineTurnedAt = Date() } else { readCurrent() }
        case .mail:
            if mailOpen {
                if !next { mailOpen = false } else if morePages { pageStep(1) } else { mailOpen = false; advance(&mailIndex, count: mail.count) }
            } else if next { advance(&mailIndex, count: mail.count) } else if !mail.isEmpty { mailOpen = true; pageRestart() } else { openMenu() }
        case .scores:
            if scoresView == .league {
                if !next { openMenu() } else if morePages { pageStep(1) } else { pageRestart() }
            } else if next {
                let list = Scoreboard.ordered(games, teams: followed)
                let at = list.firstIndex { $0.id == game?.id } ?? -1
                if at + 1 >= list.count { listEnd = true } else { pinnedGame = list[at + 1].id }
            } else { scoresView = scoresView == .box ? .game : .box }
        case .agenda:
            if !next { if agendaStep == 0 { openMenu() } else { agendaStep = 0 } }
            else if morePages { pageStep(1) }
            else if agendaStep >= 1 + week.count { listEnd = true }
            else { agendaStep += 1; pageRestart() }
        case .weather:
            if next { weatherStep = (weatherStep ?? 0) + 1 } else { openMenu() }
        case .trivia:
            if !next { openMenu() }
            else if round == nil || round?.phase == .done { startTrivia() }
            else if round?.phase == .question { triviaReveal() } else { triviaNext() }
        case .facts:
            if !next { openMenu() } else if morePages { pageStep(1) } else { nextFact() }
        case .reader:
            if !next { openMenu() } else if morePages { pageStep(1) } else { pageRestart() }
        case .timer:
            if !next { openMenu() } else if timer.isRunning { timerPause() } else { timerStart() }
        case .dashboard, .message:
            openMenu()
        case .speed, .metronome, .tuner, .picker:
            break                                   // handled in toolInput
        }
    }

    /// Opens what the menu's arrow is on: a group, the way back, or an app.
    private func menuSelect() {
        if let g = menuGroup, menuGroups.indices.contains(g) {
            let items = menuGroups[g].items
            if menuIndex == 0 || items.isEmpty { menuGroup = nil; menuIndex = g + 1; return }
            menuOpen = false; menuGroup = nil
            program = items[min(menuIndex - 1, items.count - 1)]
        } else if menuIndex == 0 {
            menuOpen = false; program = .dashboard
        } else {
            menuGroup = min(menuIndex - 1, menuGroups.count - 1); menuIndex = 1
        }
    }

    /// The tools take all three inputs themselves. True when the input was used.
    private func toolInput(_ what: Input) -> Bool {
        switch program {
        case .metronome:
            switch what {
            case .next: metroBPM = min(Metronome.range.upperBound, metroBPM + 4)
            case .previous: metroBPM = max(Metronome.range.lowerBound, metroBPM - 4)
            case .select: toggleMetronome()
            }
        case .tuner:
            if what == .select { toggleTuner() }
        case .speed:
            let words = speedText()
            switch what {
            case .select:
                if speedIndex >= words.count { speedIndex = 0; speedPlaying = true } else { speedPlaying.toggle() }
            case .next: speedIndex = min(words.count, speedIndex + 12)
            case .previous: speedIndex = max(0, speedIndex - 12)
            }
            speedAnchor()
        case .picker:
            let all = PickerMode.allCases
            let at = all.firstIndex(of: pickerMode) ?? 0
            switch what {
            case .next: pickerMode = all[(at + 1) % all.count]
            case .previous: pickerMode = all[(at + all.count - 1) % all.count]
            case .select: roll()
            }
        default:
            return false
        }
        return true
    }

    // MARK: Tools

    func toggleMetronome() {
        if metroOn { sound.stopMetronome() } else { sound.startMetronome(bpm: metroBPM, beats: metroBeats) }
        metroOn = sound.metronomeOn
    }

    func toggleTuner() {
        if tunerOn {
            sound.stopListening(); tunerOn = false; tunerReading = nil
            keepAwake.resume()
            return
        }
        tunerNote = ""
        Task {
            let started = await sound.startListening()
            self.tunerOn = started
            self.tunerNote = started ? "" : "Allow the microphone for Glasses Hub in the iPhone's Settings."
        }
    }

    private func heard(_ hz: Double?) {
        if let hz, let reading = TunerReading(hz: hz) {
            tunerReading = reading; tunerHeardAt = Date()
        } else if Date().timeIntervalSince(tunerHeardAt) > 2 {
            tunerReading = nil
        }
    }

    private func speedText() -> [String] {
        let key = readerText.hashValue
        if speedWords.key != key { speedWords = (key, SpeedRead.words(of: readerText)) }
        return speedWords.words
    }
    private func speedAnchor() { speedShownAt = Date() }
    func toggleSpeedRead() { _ = toolInput(.select) }
    func restartSpeedRead() { speedIndex = 0; speedAnchor() }

    func roll() {
        pickerResult = Picker.roll(pickerMode, options: Picker.options(from: pickerOptions))
        pickerRolledAt = Date()
    }

    private func stopTools() {
        if metroOn { sound.stopMetronome(); metroOn = false }
        if tunerOn { sound.stopListening(); tunerOn = false; tunerReading = nil }
        speedPlaying = false
    }

    /// The crown turned backwards: the previous page, item or view. Never opens or closes anything.
    private func goBack() {
        if menuOpen { let n = menuTitles.count; menuIndex = (menuIndex + n - 1) % n; return }
        if listEnd { listEnd = false; return }                     // back from the end stop to the last item
        let earlierPage = pageCount > 1 && pageIndex > 0
        switch program {
        case .news:
            if reading != nil { if earlierPage { pageStep(-1) } }
            else if newsIndex > 0 { newsIndex -= 1; headlineTurnedAt = Date() }
        case .mail:
            if mailOpen { if earlierPage { pageStep(-1) } } else if mailIndex > 0 { mailIndex -= 1 }
        case .scores:
            if scoresView == .league { if earlierPage { pageStep(-1) } }
            else {
                let list = Scoreboard.ordered(games, teams: followed)
                if let at = list.firstIndex(where: { $0.id == game?.id }), at > 0 { pinnedGame = list[at - 1].id }
            }
        case .agenda:
            if earlierPage { pageStep(-1) } else if agendaStep > 0 { agendaStep -= 1; pageRestart() }
        case .weather:
            weatherStep = max(0, (weatherStep ?? 0) + 2)             // three views: two forward is one back
        case .facts, .reader:
            if earlierPage { pageStep(-1) }
        case .trivia, .timer, .dashboard, .message, .speed, .metronome, .tuner, .picker:
            break
        }
    }

    private func advance(_ index: inout Int, count: Int) {
        if count == 0 || index >= count - 1 { listEnd = count > 0 } else { index += 1 }
        pageRestart()
    }
    private func restartList() {
        switch program {
        case .news: newsIndex = 0; headlineTurnedAt = Date()
        case .mail: mailIndex = 0
        case .scores: pinnedGame = ""
        case .agenda: agendaStep = 0
        default: break
        }
    }
    /// What a look up or a double click does: 0 next, 1 select, 2 the apps menu (again to close it).
    private func gesture(_ action: Int) {
        if action == 2 { wakeDashboard() }                  // the menu opens straight from a blank dashboard
        switch action {
        case 0: input(.next)
        case 1: input(.select)
        default:
            link.record("Apps menu " + (menuOpen ? "closed." : "opened."))
            if menuOpen { closeMenu() } else { openMenu() }
        }
    }

    private func openMenu() {
        // Always the top level, with the arrow on where the current app lives.
        menuGroup = nil
        menuIndex = (menuGroups.firstIndex { $0.items.contains(program) }).map { $0 + 1 } ?? 0
        menuOpen = true
    }
    func closeMenu() { menuOpen = false; menuGroup = nil; listEnd = false }

    func pageStep(_ by: Int) { sectionIndex += by; pager.step(by, now: Date().timeIntervalSinceReferenceDate) }
    func pageRestart() { sectionIndex = 0; pager.restart(now: Date().timeIntervalSinceReferenceDate); pagesPaused = false }
    func togglePagesPaused() { pagesPaused.toggle() }

    private var glyphs: Glyphs { Glyphs(glyphStyle) }
    /// Which of `count` views is up, for programs that take turns.
    private func turn(_ count: Int, now: Date) -> Int { count < 2 ? 0 : Int(now.timeIntervalSinceReferenceDate / (pageSeconds == 0 ? 10 : max(4, pageSeconds))) % count }
    private func lines(of text: String) -> [String] {
        let key = "\(screen.columns)|\(text.utf8.count)|\(text.hashValue)"
        if wrapped.key != key { wrapped = (key, TextLayout.wrap(text, width: screen.columns)) }
        return wrapped.lines
    }

    /// The card for the chosen program, with nothing borrowing the screen.
    func currentCard(now: Date) -> Card {
        let screen = self.screen, glyphs = self.glyphs
        let rich = glyphStyle != .plain
        if now < testCardsUntil {
            let pages = Glyphs.testPages
            let shown = pages.count - 1 - Int(testCardsUntil.timeIntervalSince(now) / 12)
            return Card(pages[max(0, min(pages.count - 1, shown))])
        }
        if dashAsleep { return Card(["\u{3000}"]) }
        if menuOpen {
            let title = menuGroup.flatMap { menuGroups.indices.contains($0) ? menuGroups[$0].title : nil } ?? "Apps"
            return AppMenu.card(title: title, titles: menuTitles, selected: min(menuIndex, menuTitles.count - 1), screen: screen, glyphs: glyphs)
        }
        if listEnd {
            let what: String
            switch program { case .news: what = "headlines"; case .mail: what = "the inbox"; case .scores: what = "games"; case .agenda: what = "events"; default: what = "the list" }
            return AppMenu.endCard(of: what)
        }
        switch program {
        case .mail:
            guard mailSignedIn else { return Card(["Mail", "Connect Gmail in the app,", "under Apps > Mail."]) }
            guard !mail.isEmpty else { return Card(["Mail", mailNote.isEmpty ? "Checking your inbox…" : mailNote]) }
            let index = min(mailIndex, mail.count - 1)
            if mailOpen {
                let m = mail[index]
                return Card([TextLayout.fit("From " + m.from, width: screen.columns)] + TextLayout.wrap(m.subject, width: screen.columns) + [""]
                            + lines(of: m.body.isEmpty ? m.preview : m.body) + ["- end -"], scrolls: true)
            }
            return Mail.listCard(mail[index], index: index, count: mail.count, screen: screen, now: now, glyphs: glyphs)
        case .dashboard:
            var lines = [String]()
            func add(_ mark: String, _ text: String) { lines.append(rich ? mark + " " + TextLayout.fit(text, width: screen.columns - 3) : text) }
            if dashScores, let game { add(game.state == .live ? glyphs.live : glyphs.bullet, Scoreboard.summary(game, now: now)) }
            if dashWeather, let weather { add(glyphs.weather(weather.code), weather.summary) }
            if dashAgenda, let next = Agenda.summary(agenda, now: now) { add(glyphs.next, next) }
            if timer.isRunning {
                let left = timer.remaining(now: now)
                lines.append(rich ? glyphs.meter(left / max(1, timer.duration), cells: 6) + " " + HubTimer.clock(left) : "Timer \(HubTimer.clock(left))")
            }
            if dashNews, let top = news.first { add(glyphs.note, top.title) }
            if !dashNote.isEmpty { add(glyphs.star, dashNote) }
            return Dashboard.card(now: now, summaries: lines, screen: screen, rotate: pageSeconds == 0 ? 10 : max(4, pageSeconds))
        case .scores:
            if scoresView == .league {
                let list = Scoreboard.ordered(games, teams: followed)
                let title = leagues.count == 1 ? (leagues.first?.short ?? "Scores") : "Scores"
                let pages = Scoreboard.tablePages(list, title: title, screen: screen, now: now, glyphs: glyphs)
                return pages[turn(pages.count, now: now)]
            }
            guard let game else {
                return Card(["Scoreboard", scoresNote.isEmpty ? "Looking for games…" : scoresNote])
            }
            let stale = now.timeIntervalSince(scoresAt) > 120 && game.state == .live
            let main = Scoreboard.card(game, screen: screen, now: now, stale: stale, glyphs: glyphs)
            guard scoresView != .game, let box = Scoreboard.boxCard(game, screen: screen, glyphs: glyphs) else { return main }
            return scoresView == .box || turn(2, now: now) == 1 ? box : main
        case .news:
            if let reading {
                if let text = articles[reading.id] {
                    let body = text.isEmpty ? reading.summary : text
                    return Card(TextLayout.wrap(reading.title, width: screen.columns) + [""] + lines(of: body) + ["- end -"], scrolls: true)
                }
                return Card([reading.source, readingNote.isEmpty ? "Getting the story…" : readingNote])
            }
            guard !news.isEmpty else { return Card(["News", newsNote.isEmpty ? "Getting headlines…" : newsNote]) }
            let index = min(newsIndex, news.count - 1)
            return News.headlineCard(news[index], index: index, count: news.count, screen: screen, now: now, glyphs: glyphs)
        case .trivia:
            guard let round else { return Card(["Trivia host", triviaNote.isEmpty ? "Start a round on your phone." : triviaNote]) }
            return round.card(screen: screen, now: now.timeIntervalSinceReferenceDate)
        case .facts:
            guard let fact else { return Card(["Odd fact", "Finding one…"]) }
            return Card([(rich ? glyphs.note + " " : "") + "Odd fact"] + TextLayout.wrap(fact, width: screen.columns))
        case .timer:
            return timer.card(screen: screen, now: now, glyphs: glyphs)
        case .weather:
            guard let weather else { return Card(["Weather", weatherNote.isEmpty ? "Checking \(city)…" : weatherNote]) }
            var views = [Card]()
            if weatherView == .cycle || weatherView == .now { views.append(weather.card(screen: screen)) }
            if weatherView == .cycle || weatherView == .hours, let hours = weather.hoursCard(screen: screen, glyphs: glyphs) { views.append(hours) }
            if weatherView == .cycle || weatherView == .week, let week = weather.weekCard(screen: screen, glyphs: glyphs) { views.append(week) }
            if let step = weatherStep {           // stepping through by hand: every view, in order
                let all = [weather.card(screen: screen), weather.hoursCard(screen: screen, glyphs: glyphs), weather.weekCard(screen: screen, glyphs: glyphs)].compactMap { $0 }
                return all[step % all.count]
            }
            return views.isEmpty ? weather.card(screen: screen) : views[turn(views.count, now: now)]
        case .agenda:
            let busy = Set(agenda.map { Calendar.current.component(.day, from: $0.start) })
            let month = Agenda.monthCard(now: now, screen: screen, glyphs: glyphs, busyDays: busy)
            if agendaStep == 1 { return month }
            if agendaStep >= 2, week.indices.contains(agendaStep - 2) {
                return Agenda.detailCard(week[agendaStep - 2], index: agendaStep - 2, count: week.count, screen: screen, now: now, glyphs: glyphs)
            }
            if agendaView == .month { return month }
            if !calendarAllowed { return agendaView == .cycle ? month : Card(["Calendar", "Allow calendar access in the app."]) }
            let list = Agenda.listCard(agenda, screen: screen, now: now, glyphs: glyphs)
            // a long list pages by itself, so only take turns with the month when it fits one screen
            return agendaView == .cycle && list.lines.count <= screen.rows && turn(2, now: now) == 1 ? month : list
        case .reader:
            let body = lines(of: readerText)
            return body.isEmpty ? Card(["Reader", "Paste some text in the app."]) : Card(body, scrolls: true)
        case .message:
            let card = Reader.note(title: "", body: messageText, screen: screen)
            return card.isEmpty ? Card(["Message", "Type one in the app."]) : card
        case .speed:
            return SpeedRead.card(words: speedText(), index: speedIndex, size: speedChunk, playing: speedPlaying, wpm: speedWPM, screen: screen)
        case .metronome:
            return Metronome.card(bpm: metroBPM, beats: metroBeats, running: metroOn, screen: screen)
        case .tuner:
            if !tunerNote.isEmpty { return Card(["Tuner"] + TextLayout.wrap(tunerNote, width: screen.columns)) }
            return Tuner.card(tunerReading, listening: tunerOn, screen: screen, glyphs: glyphs)
        case .picker:
            return Picker.card(mode: pickerMode, result: pickerResult, rolling: now.timeIntervalSince(pickerRolledAt) < 0.6, screen: screen)
        }
    }

    // MARK: Data

    private func refreshData(now: Date) {
        let wantsScores = !leagues.isEmpty && (program == .scores || (program == .dashboard && dashScores) || (scoreAlerts && (link.isRunning || popUps)))
        if wantsScores, now >= scoresDue, fetching.insert("scores").inserted {
            scoresDue = now.addingTimeInterval(15)            // floor; refined when the answer is in
            let wanted = League.allCases.filter { leagues.contains($0) }
            Task {
                let fresh = await Feeds.games(wanted)
                self.fetching.remove("scores")
                self.took(games: fresh, now: Date())
            }
        }
        let wantsWeather = program == .weather || (program == .dashboard && dashWeather)
        if wantsWeather, now >= weatherDue, fetching.insert("weather").inserted {
            weatherDue = now.addingTimeInterval(60)
            let name = city.trimmingCharacters(in: .whitespaces), metric = celsius
            Task {
                if self.place?.name.caseInsensitiveCompare(name) != .orderedSame {
                    if let found = await Feeds.place(name) { self.place = (name, found.latitude, found.longitude) }
                    else { self.weatherNote = name.isEmpty ? "Enter a city in the app." : "Couldn't find \(name)."; self.weather = nil }
                }
                if let place = self.place, place.name.caseInsensitiveCompare(name) == .orderedSame {
                    if let fresh = await Feeds.weather(place: name, latitude: place.latitude, longitude: place.longitude, celsius: metric) {
                        self.weather = fresh; self.weatherNote = ""
                        self.weatherDue = Date().addingTimeInterval(20 * 60)
                    } else if self.weather == nil { self.weatherNote = "Couldn't reach the weather service." }
                }
                self.fetching.remove("weather")
            }
        }
        let wantsAgenda = program == .agenda || (program == .dashboard && dashAgenda)
        if wantsAgenda, now >= agendaDue {
            agendaDue = now.addingTimeInterval(120)
            calendarAllowed = calendar.allowed
            let fresh = calendar.today(now: now)
            if fresh != agenda { agenda = fresh }
            let ahead = calendar.upcoming(days: 7, now: now)
            if ahead != week { week = ahead }
        }
        let wantsNews = program == .news || (program == .dashboard && dashNews)
        if wantsNews, now >= newsDue, fetching.insert("news").inserted {
            newsDue = now.addingTimeInterval(10 * 60)
            var sources = NewsSource.builtIn.filter { newsSources.contains($0.url) }
            let custom = customFeed.trimmingCharacters(in: .whitespacesAndNewlines)
            if custom.lowercased().hasPrefix("http") { sources.append(NewsSource(name: URL(string: custom)?.host?.replacingOccurrences(of: "www.", with: "") ?? "My feed", url: custom)) }
            Task {
                var lists = [[NewsItem]]()
                for source in sources { lists.append(await Feeds.news(source)) }
                let fresh = News.merged(lists)
                self.fetching.remove("news")
                if fresh.isEmpty {
                    if self.news.isEmpty { self.newsNote = sources.isEmpty ? "Pick a news source in the app." : "Couldn't reach the news feeds."; self.newsDue = Date().addingTimeInterval(60) }
                } else {
                    let current = self.news.indices.contains(self.newsIndex) ? self.news[self.newsIndex].id : nil
                    self.news = fresh; self.newsNote = ""
                    self.newsIndex = current.flatMap { id in fresh.firstIndex { $0.id == id } } ?? 0
                }
            }
        }
        if program == .mail, mailSignedIn, now >= mailDue, fetching.insert("mail").inserted {
            mailDue = now.addingTimeInterval(5 * 60)
            let query = mailQuery
            let known = Dictionary(mail.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            Task {
                defer { self.fetching.remove("mail") }
                guard let token = await self.google.accessToken() else {
                    self.mailSignedIn = self.google.signedIn
                    self.mailNote = self.mailSignedIn ? "Couldn't reach Google." : "Gmail needs you to sign in again."
                    self.mailDue = Date().addingTimeInterval(60)
                    return
                }
                guard let fresh = await Feeds.mail(token: token, query: query, known: known) else {
                    if self.mail.isEmpty { self.mailNote = "Couldn't get your mail from Google." }
                    self.mailDue = Date().addingTimeInterval(60)
                    return
                }
                let current = self.mail.indices.contains(self.mailIndex) ? self.mail[self.mailIndex].id : nil
                self.mail = fresh
                self.mailNote = fresh.isEmpty ? "No messages match." : ""
                self.mailIndex = current.flatMap { id in fresh.firstIndex { $0.id == id } } ?? 0
            }
        }
        if program == .news, reading == nil, !menuOpen, !listEnd, headlineSeconds > 0, news.count > 1, now.timeIntervalSince(headlineTurnedAt) >= headlineSeconds {
            newsIndex = (newsIndex + 1) % news.count; headlineTurnedAt = now
        }
        if popUps, popFactMinutes > 0, now >= popFactDue, !(link.isRunning && !popupOpen), fetching.insert("popfact").inserted {
            popFactDue = now.addingTimeInterval(popFactMinutes * 60)
            let day = factsOnThisDay
            Task {
                if let fresh = await Feeds.fact(onThisDay: day) {
                    let head = (self.glyphStyle != .plain ? self.glyphs.note + " " : "") + "Odd fact"
                    self.overlays.push(Card([head] + TextLayout.wrap(fresh, width: self.screen.columns, maxLines: self.screen.rows - 1)), seconds: max(self.alertSeconds, 15))
                    self.unshown.append(("Odd fact", fresh))
                }
                self.fetching.remove("popfact")
            }
        }
        if program == .facts, now >= factDue, fetching.insert("fact").inserted {
            factDue = now.addingTimeInterval(max(1, factMinutes) * 60)
            let day = factsOnThisDay
            Task {
                if let fresh = await Feeds.fact(onThisDay: day) { self.fact = fresh }
                else if self.fact == nil { self.fact = "Couldn't reach the fact service. Will try again." ; self.factDue = Date().addingTimeInterval(30) }
                self.fetching.remove("fact")
            }
        }
    }

    private func took(games fresh: [Game]?, now: Date) {
        guard let fresh else {
            if game == nil { scoresNote = "Couldn't reach the scores feed." }
            scoresDue = now.addingTimeInterval(30)
            return
        }
        scoresAt = now
        var all = fresh
        // A followed team with no game on today's boards: ask its own page for its next one.
        for team in followed where !fresh.contains(where: { $0.has(team) }) {
            for league in League.allCases where leagues.contains(league) {
                let key = "\(league.rawValue)/\(team)"
                if let cached = nextGames[key], now.timeIntervalSince(cached.at) < 30 * 60 {
                    if let next = cached.game, !all.contains(where: { $0.id == next.id }) { all.append(next) }
                } else if fetching.insert(key).inserted {
                    Task {
                        let next = await Feeds.nextGame(team: team, league: league)
                        self.fetching.remove(key)
                        self.nextGames[key] = (next, Date())
                        if next != nil { self.scoresDue = .distantPast }
                    }
                }
            }
        }
        if all != games { games = all }
        repick(now: now)
        scoresDue = now.addingTimeInterval(Scoreboard.pollInterval(game, now: now))
    }

    /// Choose the game to show (the pinned one if it's still listed) and raise alerts for what changed in it.
    private func repick(now: Date = Date()) {
        let picked = games.first { $0.id == pinnedGame } ?? Scoreboard.pick(games, teams: followed, now: now)
        scoresNote = picked == nil ? "No games on the schedule." : ""
        if let picked, scoreAlerts, let before = lastGame, before.id == picked.id {
            for lines in Scoreboard.alerts(old: before, new: picked) { alert(lines, source: .scores) }
        }
        // other followed teams' games still get their alerts while a different game is on screen
        if scoreAlerts {
            for other in games where other.id != picked?.id && followed.contains(where: { other.has($0) }) {
                if let before = watched[other.id] { for lines in Scoreboard.alerts(old: before, new: other) { alert(lines, source: .scores) } }
            }
        }
        watched = Dictionary(games.filter { g in followed.contains { g.has($0) } }.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        lastGame = picked
        if picked != game { game = picked }
    }

    func nextFact() { factDue = .distantPast }

    // MARK: Alerts

    /// Something worth interrupting for. Goes to the display, a notification, or both, per the setting.
    /// An alert from the program already on screen isn't shown over itself.
    /// True when an alert can go to the display: it's on, or pop-up mode will open it.
    private var reachable: Bool { link.isShowing || popUps }

    private func alert(_ lines: [String], source: Program?) {
        let onDisplay = reachable && alertStyle != .notification
        let asNotification = alertStyle == .notification || alertStyle == .both || (alertStyle == .auto && !reachable)
        let body = lines.dropFirst().joined(separator: ". ")
        if onDisplay, !link.isShowing || popupOpen || source == nil || source != program || source == .scores {
            var fitted = [String]()
            if let first = lines.first { fitted.append(TextLayout.headline(first, screen: screen)) }
            for line in lines.dropFirst() { fitted += TextLayout.wrap(line, width: screen.columns) }
            overlays.push(Card(Array(fitted.prefix(screen.rows))), seconds: alertSeconds)
            if !link.isShowing { unshown.append((lines.first ?? "", body)) }
        }
        if asNotification, notificationsAllowed { Notifier.shared.post(title: lines.first ?? "", body: body) }
    }

    private func received(_ note: PCNote) {
        guard showPCNotes else { return }
        if reachable, alertStyle != .notification {
            overlays.push(Reader.note(title: note.title, body: note.body, screen: screen), seconds: max(alertSeconds, 12))
            if !link.isShowing { unshown.append((note.title, note.body)) }
        }
        if notificationsAllowed, alertStyle == .notification || alertStyle == .both || !reachable {
            Notifier.shared.post(title: note.title, body: note.body)
        }
    }

    /// Put a one-off card on the glasses for a few seconds (the "Send" box).
    func flash(_ text: String) {
        let card = Reader.note(title: "", body: text, screen: screen)
        if reachable { overlays.push(card, seconds: max(alertSeconds, 12)); if !link.isShowing { unshown.append(("Glasses Hub", text)) } }
        else if notificationsAllowed { Notifier.shared.post(title: "Glasses Hub", body: text) }
    }

    func showTestCard() {
        let wide = screen.wideColumns
        overlays.push(Card(["Display test, \(screen.rows) lines",
                            TextLayout.wide(String("ABCDEFGHIJKLMNOPQRSTUVWXYZ".prefix(wide))),
                            String("1234567890123456789012345678901234567890123456789012345678901234567890".prefix(screen.columns)),
                            "The line above should end at \(screen.columns).",
                            Grid.row([("KC", 4, false), ("7", 2, true)]) + " < columns", Grid.row([("BUF", 4, false), ("24", 2, true)]) + " < line up?",
                            "Line 7 (small text only)"].prefix(screen.rows).map { $0 }), seconds: 30)
    }

    /// Put every symbol the app can use on the glasses, three pages for 12 seconds each.
    func showSymbolTest() {
        overlays.clear()
        testCardsUntil = Date().addingTimeInterval(36)
    }

    // MARK: News

    func newsStep(_ by: Int) {
        guard !news.isEmpty else { return }
        reading = nil
        newsIndex = (newsIndex + by + news.count) % news.count
        headlineTurnedAt = Date()
    }

    /// Open a story in full. The feed's own text shows at once; the article page replaces it if it loads.
    func read(_ item: NewsItem) {
        if let index = news.firstIndex(where: { $0.id == item.id }) { newsIndex = index }
        reading = item; readingNote = ""
        if program != .news { program = .news }
        pageRestart()
        guard articles[item.id] == nil, let link = item.link else {
            if articles[item.id] == nil { articles[item.id] = "" }
            return
        }
        Task {
            let text = await Feeds.article(link)
            // keep whichever is longer: some sites put the whole story in the feed and little on the page
            self.articles[item.id] = text.count > item.summary.count ? text : ""
            if text.isEmpty, item.summary.isEmpty { self.readingNote = "Couldn't get this story's text." }
        }
    }
    /// Save text as a .txt file in this app's folder (visible in the Files app under "Glasses Hub"), ready
    /// to import into the RayNeo app's teleprompter. Returns the file, or nil if it couldn't be written.
    func saveForTeleprompter(title: String, text: String) -> URL? {
        guard let folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return nil }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: " -"))
        var name = String(String.UnicodeScalarView(TextLayout.clean(title).unicodeScalars.filter { allowed.contains($0) })).trimmingCharacters(in: .whitespaces)
        if name.isEmpty { name = "Reading" }
        let url = folder.appendingPathComponent(String(name.prefix(50)) + ".txt")
        do { try Data(text.utf8).write(to: url, options: .atomic) } catch { return nil }
        // keep the folder from filling up: only the 15 newest files stay
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        let dated = files.filter { $0.pathExtension == "txt" }.map { ($0, (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) }
        for (old, _) in dated.sorted(by: { $0.1 > $1.1 }).dropFirst(15) { try? FileManager.default.removeItem(at: old) }
        return url
    }

    /// The full text of the story being read, for the teleprompter button.
    var readingText: String {
        guard let reading else { return "" }
        let body = articles[reading.id] ?? ""
        return reading.title + "\n\n" + (body.isEmpty ? reading.summary : body)
    }

    // MARK: Mail

    func mailSignIn() async {
        mailNote = "Opening Google's sign-in…"
        if let problem = await google.signIn(clientID: gmailClientID) { mailNote = problem }
        else { mailNote = ""; mailDue = .distantPast }
        mailSignedIn = google.signedIn
    }
    func mailSignOut() { google.signOut(); mailSignedIn = false; mail = []; mailNote = "" }
    func refreshMail() { mailDue = .distantPast }
    func openMail(_ message: MailMessage) {
        if let index = mail.firstIndex(where: { $0.id == message.id }) { mailIndex = index }
        if program != .mail { program = .mail }
        menuOpen = false; listEnd = false; mailOpen = true
        pageRestart()
    }

    func readCurrent() { if news.indices.contains(newsIndex) { read(news[newsIndex]) } }
    func stopReading() { reading = nil; headlineTurnedAt = Date() }
    func refreshNews() { newsDue = .distantPast }

    // MARK: Trivia

    func startTrivia() {
        guard fetching.insert("trivia").inserted else { return }
        triviaNote = "Getting questions…"; round = nil
        let count = triviaCount
        Task {
            let questions = await Feeds.trivia(count: count)
            self.fetching.remove("trivia")
            guard !questions.isEmpty else { self.triviaNote = "Couldn't get questions. Try again in a moment."; return }
            self.triviaNote = ""
            self.round = TriviaRound(questions: questions, now: Date().timeIntervalSinceReferenceDate,
                                     questionSeconds: self.triviaQuestionSeconds, answerSeconds: self.triviaAnswerSeconds,
                                     autoAdvance: self.triviaAuto)
            if self.program != .trivia { self.program = .trivia }
        }
    }
    func triviaReveal() { round?.reveal(now: Date().timeIntervalSinceReferenceDate) }
    func triviaNext() { round?.next(now: Date().timeIntervalSinceReferenceDate) }
    func triviaStop() { round = nil; triviaNote = "" }

    // MARK: Timer and reader

    func timerStart() {
        let untouched = !timer.isRunning && timer.pausedRemaining == timer.duration
        if timer.isDone(now: Date()) || (untouched && timer.duration != timerMinutes * 60) {
            timer = HubTimer(minutes: timerMinutes)
        }
        timer.start(now: Date())
    }
    func timerPause() { timer.pause(now: Date()) }
    func timerReset() { timer = HubTimer(minutes: timerMinutes) }

    // MARK: Permissions

    func refreshPermissions() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        notificationsAllowed = settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
        calendarAllowed = calendar.allowed
    }
    func askNotifications() async {
        _ = await Notifier.shared.askPermission()
        await refreshPermissions()
    }
    func askCalendar() async {
        _ = await calendar.askPermission()
        calendarAllowed = calendar.allowed
        agendaDue = .distantPast
    }
}
