import Foundation
import SwiftUI
import UserNotifications
import HubCore

/// What can be on the glasses.
enum Program: String, CaseIterable, Identifiable {
    case dashboard, scores, trivia, facts, timer, weather, agenda, reader, message
    var id: String { rawValue }
    var title: String {
        switch self {
        case .dashboard: return "Dashboard"; case .scores: return "Scoreboard"; case .trivia: return "Trivia host"
        case .facts: return "Odd facts"; case .timer: return "Timer"; case .weather: return "Weather"
        case .agenda: return "Calendar"; case .reader: return "Reader"; case .message: return "Message"
        }
    }
    var icon: String {
        switch self {
        case .dashboard: return "square.grid.2x2"; case .scores: return "sportscourt"; case .trivia: return "questionmark.bubble"
        case .facts: return "lightbulb"; case .timer: return "timer"; case .weather: return "cloud.sun"
        case .agenda: return "calendar"; case .reader: return "text.alignleft"; case .message: return "text.bubble"
        }
    }
    var blurb: String {
        switch self {
        case .dashboard: return "Time, score, weather and your next event on one screen."
        case .scores: return "A live scoreboard for your team, with the last play."
        case .trivia: return "You read the question off your glasses; the answer follows."
        case .facts: return "A new surprising fact every few minutes."
        case .timer: return "A countdown you can see without looking down."
        case .weather: return "Now, today and tomorrow."
        case .agenda: return "What's left on today's calendar."
        case .reader: return "Paste any text and scroll it with the crown."
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

/// The app's brain: settings, the data each app shows, and the once-a-second loop that decides what the
/// glasses should say right now.
@MainActor
final class HubModel: ObservableObject {
    let link = GlassesLink()
    let pc = PCLink()
    private let keepAwake = KeepAwake()
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
    @Published var dashNote: String { didSet { defaults.set(dashNote, forKey: "dashNote") } }

    @Published var readerText: String { didSet { defaults.set(readerText, forKey: "readerText"); readerPart = 0 } }
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
    @Published private(set) var readerPart = 0
    @Published private(set) var readerParts = 1
    @Published private(set) var notificationsAllowed = false
    /// Why the display last stopped on its own, until the user dismisses it or starts again.
    @Published var endedNotice: String?

    private var overlays = OverlayQueue()
    private var ticker: Timer?
    private var inFront = true
    private var games: [Game] = []
    private var lastGame: Game?
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
        dashNote = d.string(forKey: "dashNote") ?? ""
        readerText = d.string(forKey: "readerText") ?? ""
        messageText = d.string(forKey: "messageText") ?? ""
        showPCNotes = bool("showPCNotes", true)
        let minutes = number("timerMinutes", 10)
        timerMinutes = minutes
        timer = HubTimer(minutes: minutes)

        calendarAllowed = calendar.allowed
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
        link.start(size: textSize, refresh: refreshScreen)
        applyKeepAwake()
        tick()
    }

    func stopDisplay() {
        link.stop()
        overlays.clear()
        applyKeepAwake()
    }

    func scene(active: Bool) {
        inFront = active
        if active {
            pc.resume()
            Task { await refreshPermissions() }
        } else if !link.isRunning {
            pc.pause()                      // nothing keeps the app awake without the display, so don't pretend
        }
        applyKeepAwake()
    }

    private func applyKeepAwake() {
        keepAwake.set(runWhenLocked && link.isRunning)
    }

    private func displayEnded(_ reason: String) {
        overlays.clear()
        applyKeepAwake()
        endedNotice = reason
        if !inFront { Notifier.shared.post(title: "Glasses display stopped", body: reason) }
    }

    private func programChanged() {
        overlays.clear()
        if program == .facts { factDue = .distantPast }
        if program == .agenda || program == .dashboard { agendaDue = .distantPast }
    }

    // MARK: The loop

    private func tick() {
        let now = Date()
        let awake = inFront || link.isRunning
        if awake { refreshData(now: now) }
        if link.isRunning { keepAwake.resume() }

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

        let card = overlays.current(now: now.timeIntervalSinceReferenceDate) ?? currentCard(now: now)
        let text = card.text(rows: screen.rows)
        if text != preview { preview = text }
        if card.scrolls != previewScrolls { previewScrolls = card.scrolls }
        if link.isRunning {
            link.show(text, scrolls: card.scrolls)
            link.tick()
        }
    }

    /// The card for the chosen program, with nothing borrowing the screen.
    func currentCard(now: Date) -> Card {
        let screen = self.screen
        switch program {
        case .dashboard:
            var lines = [String]()
            if dashScores, let game { lines.append(Scoreboard.summary(game, now: now)) }
            if dashWeather, let weather { lines.append(weather.summary) }
            if dashAgenda, let next = Agenda.summary(agenda, now: now) { lines.append(next) }
            if timer.isRunning { lines.append("Timer \(HubTimer.clock(timer.remaining(now: now)))") }
            if !dashNote.isEmpty { lines.append(dashNote) }
            return Dashboard.card(now: now, summaries: lines, screen: screen)
        case .scores:
            guard let game else {
                return Card(["Scoreboard", scoresNote.isEmpty ? "Looking for games…" : scoresNote])
            }
            return Scoreboard.card(game, screen: screen, now: now, stale: now.timeIntervalSince(scoresAt) > 120 && game.state == .live)
        case .trivia:
            guard let round else { return Card(["Trivia host", triviaNote.isEmpty ? "Start a round on your phone." : triviaNote]) }
            return round.card(screen: screen, now: now.timeIntervalSinceReferenceDate)
        case .facts:
            return fact.map { Facts.card($0, screen: screen) } ?? Card(["Odd fact", "Finding one…"])
        case .timer:
            return timer.card(screen: screen, now: now)
        case .weather:
            return weather?.card(screen: screen) ?? Card(["Weather", weatherNote.isEmpty ? "Checking \(city)…" : weatherNote])
        case .agenda:
            if !calendarAllowed { return Card(["Calendar", "Allow calendar access in the app."]) }
            return Agenda.card(agenda, screen: screen, now: now)
        case .reader:
            let parts = Reader.parts(readerText, screen: screen)
            if readerParts != max(1, parts.count) { readerParts = max(1, parts.count) }
            guard !parts.isEmpty else { return Card(["Reader", "Paste some text in the app."]) }
            return parts[min(readerPart, parts.count - 1)]
        case .message:
            let card = Reader.note(title: "", body: messageText, screen: screen)
            return card.isEmpty ? Card(["Message", "Type one in the app."]) : card
        }
    }

    // MARK: Data

    private func refreshData(now: Date) {
        let wantsScores = !leagues.isEmpty && (program == .scores || (program == .dashboard && dashScores) || (scoreAlerts && link.isRunning))
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
        games = fresh; scoresAt = now
        let picked = Scoreboard.pick(fresh, teams: followed, now: now)
        scoresNote = picked == nil ? "No games on the schedule." : ""
        if let picked, scoreAlerts, let before = lastGame, before.id == picked.id {
            let mine = followed.isEmpty || followed.contains { picked.has($0) }
            if mine { for lines in Scoreboard.alerts(old: before, new: picked) { alert(lines, source: .scores) } }
        }
        lastGame = picked
        if picked != game { game = picked }
        scoresDue = now.addingTimeInterval(Scoreboard.pollInterval(picked, now: now))
    }

    func nextFact() { factDue = .distantPast }

    // MARK: Alerts

    /// Something worth interrupting for. Goes to the display, a notification, or both, per the setting.
    /// An alert from the program already on screen isn't shown over itself.
    private func alert(_ lines: [String], source: Program?) {
        let showing = link.isShowing
        let onDisplay = (alertStyle == .display || alertStyle == .both || (alertStyle == .auto && showing)) && showing
        let asNotification = alertStyle == .notification || alertStyle == .both || (alertStyle == .auto && !showing)
        if onDisplay, source == nil || source != program || source == .scores {
            var fitted = [String]()
            if let first = lines.first { fitted.append(TextLayout.headline(first, screen: screen)) }
            for line in lines.dropFirst() { fitted += TextLayout.wrap(line, width: screen.columns) }
            overlays.push(Card(Array(fitted.prefix(screen.rows))), seconds: alertSeconds)
        }
        if asNotification, notificationsAllowed {
            Notifier.shared.post(title: lines.first ?? "", body: lines.dropFirst().joined(separator: ". "))
        }
    }

    private func received(_ note: PCNote) {
        guard showPCNotes else { return }
        let showing = link.isShowing
        if showing, alertStyle != .notification {
            overlays.push(Reader.note(title: note.title, body: note.body, screen: screen), seconds: max(alertSeconds, 12))
        }
        if notificationsAllowed, alertStyle == .notification || alertStyle == .both || !showing {
            Notifier.shared.post(title: note.title, body: note.body)
        }
    }

    /// Put a one-off card on the glasses for a few seconds (the "Send" box).
    func flash(_ text: String) {
        let card = Reader.note(title: "", body: text, screen: screen)
        if link.isShowing { overlays.push(card, seconds: max(alertSeconds, 12)) }
        else if notificationsAllowed { Notifier.shared.post(title: "Glasses Hub", body: text) }
    }

    func showTestCard() {
        let wide = screen.wideColumns
        overlays.push(Card(["Display test, \(screen.rows) lines",
                            TextLayout.wide(String("ABCDEFGHIJKLMNOPQRSTUVWXYZ".prefix(wide))),
                            String("1234567890123456789012345678901234567890123456789012345678901234567890".prefix(screen.columns)),
                            "The line above should end at \(screen.columns).",
                            "Symbols: < > ^ v * # @ & % + = / ° -",
                            "Line 6 (small text only)", "Line 7 (small text only)"].prefix(screen.rows).map { $0 }), seconds: 30)
    }

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

    func readerStep(_ by: Int) {
        readerPart = max(0, min(readerParts - 1, readerPart + by))
    }

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
