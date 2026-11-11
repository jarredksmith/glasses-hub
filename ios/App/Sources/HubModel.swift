import Foundation
import SwiftUI
import UserNotifications
import HubCore

/// What can be on the glasses.
enum Program: String, CaseIterable, Identifiable {
    case dashboard, scores, news, trivia, facts, timer, weather, agenda, reader, message
    var id: String { rawValue }
    var title: String {
        switch self {
        case .dashboard: return "Dashboard"; case .scores: return "Scoreboard"; case .trivia: return "Trivia host"
        case .facts: return "Odd facts"; case .timer: return "Timer"; case .weather: return "Weather"
        case .agenda: return "Calendar"; case .reader: return "Reader"; case .message: return "Message"
        case .news: return "News"
        }
    }
    var icon: String {
        switch self {
        case .dashboard: return "square.grid.2x2"; case .scores: return "sportscourt"; case .trivia: return "questionmark.bubble"
        case .facts: return "lightbulb"; case .timer: return "timer"; case .weather: return "cloud.sun"
        case .agenda: return "calendar"; case .reader: return "text.alignleft"; case .message: return "text.bubble"
        case .news: return "newspaper"
        }
    }
    var blurb: String {
        switch self {
        case .dashboard: return "Time, score, weather and your next event on one screen."
        case .scores: return "Live score, box score by period, or the whole league as a table."
        case .news: return "Headlines that turn by themselves, and full stories a page at a time."
        case .trivia: return "You read the question off your glasses; the answer follows."
        case .facts: return "A new surprising fact every few minutes."
        case .timer: return "A countdown you can see without looking down."
        case .weather: return "Now, the next 12 hours as a table, or the week ahead."
        case .agenda: return "Today's events, or the month as a grid."
        case .reader: return "Paste any text and read it a page at a time."
        case .message: return "Put a line of text on the glasses and leave it there."
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
    @Published var crownPaging: Bool { didSet { defaults.set(crownPaging, forKey: "crownPaging") } }
    @Published var logEvents: Bool { didSet { defaults.set(logEvents, forKey: "logEvents"); link.logEvents = logEvents } }
    @Published var crownScroll: Bool { didSet { defaults.set(crownScroll, forKey: "crownScroll") } }
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
        volumePaging = bool("volumePaging", true)
        logEvents = bool("logEvents", false)
        crownPaging = bool("crownPaging", true)
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
        link.onCrown = { [weak self] direction in
            guard let self, self.crownPaging else { return }
            self.buttonPressed(direction)
        }
        buttons.onPress = { [weak self] direction in self?.buttonPressed(direction) }
        popFactDue = Date().addingTimeInterval(max(1, popFactMinutes) * 60)
        applyKeepAwake()
        link.onEnded = { [weak self] reason in self?.displayEnded(reason) }
        pc.onNote = { [weak self] note in self?.received(note) }
        Notifier.shared.setUp()
        let made = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
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
        overlays.clear()
        if program == .facts { factDue = .distantPast }
        if program == .agenda || program == .dashboard { agendaDue = .distantPast }
        pager = AutoPager(); pagesPaused = false
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
            let readingText = program == .reader || (program == .news && reading != nil)
            // crown mode only works for text short enough to send in one piece
            if !(crownScroll && readingText && card.lines.joined(separator: "\n").utf8.count <= 3500) {
                pager.paused = pagesPaused
                card = pager.page(of: card, rows: screen.rows, now: now.timeIntervalSinceReferenceDate, seconds: pageSeconds, loops: !readingText)
                if pageIndex != pager.index { pageIndex = pager.index }
                if pageCount != pager.count { pageCount = pager.count }
            } else if pageCount != 1 { pageCount = 1 }
        }
        let text = card.text(rows: screen.rows)
        if text != preview { preview = text }
        if card.scrolls != previewScrolls { previewScrolls = card.scrolls }
        if link.isRunning {
            link.show(text, scrolls: card.scrolls)
            link.tick()
        }
    }

    /// A volume button (or scroll ring) was pressed: forward is +1, back is -1. Turns the page when there
    /// are pages; otherwise does the obvious next thing for what's showing.
    private func buttonPressed(_ direction: Int) {
        guard link.isShowing else { return }
        if pageCount > 1, !(direction > 0 && pageIndex >= pageCount - 1 && program == .news) {
            pageStep(direction)
            return
        }
        switch program {
        case .news:
            if reading != nil, direction < 0 { stopReading() } else { newsStep(direction) }
        case .trivia:
            if direction > 0 { if round?.phase == .question { triviaReveal() } else { triviaNext() } }
        case .facts:
            if direction > 0 { nextFact() }
        default: break
        }
    }

    func pageStep(_ by: Int) { pager.step(by, now: Date().timeIntervalSinceReferenceDate) }
    func pageRestart() { pager.restart(now: Date().timeIntervalSinceReferenceDate); pagesPaused = false }
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
        switch program {
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
            return views.isEmpty ? weather.card(screen: screen) : views[turn(views.count, now: now)]
        case .agenda:
            let busy = Set(agenda.map { Calendar.current.component(.day, from: $0.start) })
            let month = Agenda.monthCard(now: now, screen: screen, glyphs: glyphs, busyDays: busy)
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
        if program == .news, reading == nil, headlineSeconds > 0, news.count > 1, now.timeIntervalSince(headlineTurnedAt) >= headlineSeconds {
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
