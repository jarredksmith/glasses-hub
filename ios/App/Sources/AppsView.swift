import SwiftUI
import HubCore

/// Every app, with its settings.
struct AppsView: View {
    @EnvironmentObject private var model: HubModel

    var body: some View {
        NavigationStack {
            List {
                Section { row(.dashboard) }
                ForEach(model.menuGroups) { group in
                    Section(group.title) { ForEach(group.items) { row($0) } }
                }
            }
            .navigationTitle("Apps")
        }
    }
}

extension AppsView {
    @ViewBuilder fileprivate func row(_ program: Program) -> some View {
        NavigationLink {
            ProgramSettings(program: program)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: program.icon).frame(width: 28).foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text(program.title)
                    Text(program.blurb).font(.footnote).foregroundStyle(.secondary)
                }
                if model.program == program {
                    Spacer()
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.green)
                }
            }
        }
    }
}

struct ProgramSettings: View {
    @EnvironmentObject private var model: HubModel
    let program: Program

    var body: some View {
        Form {
            Section {
                Button(model.program == program ? "Showing now" : "Show this on the glasses") { model.program = program }
                    .disabled(model.program == program)
            } footer: { Text(program.blurb) }
            switch program {
            case .dashboard: dashboard; dashboardSleep
            case .speed, .metronome, .tuner, .picker: tools
            case .scores: scores
            case .news: news
            case .mail: mail
            case .trivia: trivia
            case .facts: facts
            case .timer: timer
            case .weather: weather
            case .agenda: agenda
            case .reader: reader
            case .message: message
            case .live: liveText
            case .translate: liveTranslate
            }
        }
        .navigationTitle(program.title)
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder private var dashboard: some View {
        Section {
            Toggle("Score", isOn: $model.dashScores)
            Toggle("Weather", isOn: $model.dashWeather)
            Toggle("Next calendar event", isOn: $model.dashAgenda)
            Toggle("Top headline", isOn: $model.dashNews)
            TextField("Your own line (optional)", text: $model.dashNote)
        } header: { Text("Lines to include") } footer: {
            Text("The time and date are always on top. A running timer adds its own line. If there are more lines than fit, they take turns.")
        }
    }

    @ViewBuilder private var dashboardSleep: some View {
        Section {
            Toggle("Go blank when idle", isOn: $model.dashSleep)
            if model.dashSleep {
                Stepper("Blank after \(model.dashSleepSeconds) seconds", value: $model.dashSleepSeconds, in: 5...300, step: 5)
            }
        } footer: {
            Text("The dashboard clears after this long. Look up, or turn the crown, to bring it back. Alerts still pop up while it's blank.")
        }
    }

    @ViewBuilder private var tools: some View {
        switch program {
        case .metronome:
            Section {
                Stepper("\(model.metroBPM) BPM  (\(Metronome.tempoName(model.metroBPM)))", value: $model.metroBPM, in: Metronome.range, step: 1)
                Picker("Beats in a bar", selection: $model.metroBeats) { ForEach([2, 3, 4, 6], id: \.self) { Text("\($0)").tag($0) } }
                Button(model.metroOn ? "Stop" : "Start") { model.toggleMetronome() }
                Toggle("Show the beat on the glasses (experimental)", isOn: $model.metroVisual)
                if model.metroVisual {
                    Stepper("Send each beat \(model.metroLeadMs) ms early", value: $model.metroLeadMs, in: 0...500, step: 25)
                }
            } footer: {
                Text("The clicks come from your phone, so turn its volume up. On the glasses: turn the crown to change the tempo, look up to start or stop.")
            }
        case .tuner:
            Section {
                Button(model.tunerOn ? "Stop listening" : "Start listening") { model.toggleTuner() }
                if let r = model.tunerReading {
                    LabeledContent("Hearing", value: "\(r.note)\(r.octave)  \(r.cents > 0 ? "+" : "")\(r.cents) cents")
                } else if model.tunerOn { Text("Play a note near your phone.").foregroundStyle(.secondary) }
                if !model.tunerNote.isEmpty { Text(model.tunerNote).foregroundStyle(.secondary) }
            } footer: {
                Text("Uses the phone's microphone, so keep the phone near the instrument. Nothing is recorded. On the glasses: look up to start or stop.")
            }
        case .speed:
            Section {
                Stepper("\(model.speedWPM) words a minute", value: $model.speedWPM, in: 100...400, step: 20)
                Picker("Words at a time", selection: $model.speedChunk) { ForEach(1...3, id: \.self) { Text("\($0)").tag($0) } }
                Button(model.speedPlaying ? "Pause" : "Play") { model.toggleSpeedRead() }
                Button("Back to the start") { model.restartSpeedRead() }
            } footer: {
                Text("Reads the text you put under Apps > Reader. On the glasses: look up to play or pause, turn the crown to skip forward or back. The glasses can only be sent about three screens a second, so very fast settings show more words at a time.")
            }
        case .picker:
            Section {
                Picker("What to roll", selection: $model.pickerMode) { ForEach(PickerMode.allCases) { Text($0.title).tag($0) } }
                Button("Roll") { model.roll() }
                if let result = model.pickerResult, result.mode == model.pickerMode { LabeledContent("Result", value: result.text) }
            } footer: { Text("On the glasses: turn the crown to change what to roll, look up to roll.") }
            Section {
                TextEditor(text: $model.pickerOptions).frame(minHeight: 120)
            } header: { Text("My list") } footer: { Text("One option per line, for \"Pick from my list\".") }
        default: EmptyView()
        }
    }

    @ViewBuilder private var scores: some View {
        Section {
            Picker("View", selection: $model.scoresView) {
                ForEach(ScoresView.allCases) { Text($0.title).tag($0) }
            }
        } footer: {
            Text("The box score is a table of points by period. \"All games\" lists every game in your leagues, your teams first.")
        }
        Section {
            Button {
                model.pinnedGame = ""
            } label: {
                HStack { Text("Automatic (my teams first)"); Spacer(); if model.pinnedGame.isEmpty { Image(systemName: "checkmark") } }
            }
            ForEach(Scoreboard.ordered(model.games, teams: model.followed).prefix(40)) { game in
                Button {
                    model.pinnedGame = game.id
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(game.state == .scheduled ? game.title : game.scoreLine)
                            Text("\(game.league.short)  \(game.shortStatus(now: Date()))").font(.footnote).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if model.pinnedGame == game.id { Image(systemName: "checkmark") }
                    }
                }
                .foregroundStyle(.primary)
            }
        } header: { Text("Game to show") } footer: {
            Text(model.games.isEmpty ? "Games appear here once the scores load." : "Pick one to keep it on screen, whoever is playing.")
        }
        Section("Leagues") {
            ForEach(League.allCases) { league in
                Toggle(league.title, isOn: Binding(
                    get: { model.leagues.contains(league) },
                    set: { on in if on { model.leagues.insert(league) } else { model.leagues.remove(league) } }))
            }
        }
        Section {
            TextField("KC, OKC, OU", text: $model.teams)
                .textInputAutocapitalization(.characters).autocorrectionDisabled()
        } header: { Text("Teams to follow") } footer: {
            Text("Use the short names scoreboards use (KC, DAL, OKC). With none, the first live game shows.")
        }
        Section {
            Toggle("Interrupt for scores and finals", isOn: $model.scoreAlerts)
        } footer: {
            Text("Takes over the screen for a few seconds, whatever else is showing: every score in football (and red-zone trips), goals in hockey and soccer, runs in baseball, the end of each period and late lead changes in basketball, plus every start and final. Scores update every 15 seconds during a game.")
        }
    }

    @ViewBuilder private var trivia: some View {
        Section("Round") {
            Stepper("\(model.triviaCount) questions", value: $model.triviaCount, in: 3...20)
            Stepper(model.triviaQuestionSeconds == 0 ? "Answer when I tap" : "Answer after \(Int(model.triviaQuestionSeconds)) seconds",
                    value: $model.triviaQuestionSeconds, in: 0...90, step: 5)
            Toggle("Move to the next question by itself", isOn: $model.triviaAuto)
            if model.triviaAuto {
                Stepper("Show the answer for \(Int(model.triviaAnswerSeconds)) seconds", value: $model.triviaAnswerSeconds, in: 3...30)
            }
        }
        Section {
            Button("Start a round") { model.startTrivia() }
        } footer: { Text("Questions come from the Open Trivia Database. Changes apply to the next round.") }
    }

    @ViewBuilder private var facts: some View {
        Section {
            Stepper("New fact every \(Int(model.factMinutes)) min", value: $model.factMinutes, in: 1...60)
            Toggle("Prefer \"on this day\" history", isOn: $model.factsOnThisDay)
            Button("New fact now") { model.nextFact() }
        } footer: { Text("History facts come from Wikipedia; the rest from a random-fact service.") }
        Section {
            Stepper(model.popFactMinutes == 0 ? "No fact pop-ups" : "Pop up a fact every \(Int(model.popFactMinutes)) min",
                    value: $model.popFactMinutes, in: 0...180, step: 5)
        } footer: { Text("Used in pop-up mode (the switch on the Display tab): a fact appears on the glasses for a few seconds, then the display closes.") }
    }

    @ViewBuilder private var timer: some View {
        Section {
            Stepper("\(Int(model.timerMinutes)) minutes", value: $model.timerMinutes, in: 1...180)
            HStack {
                ForEach([5, 10, 15, 25, 45], id: \.self) { minutes in
                    Button("\(minutes)") { model.timerMinutes = Double(minutes); model.timerReset() }.buttonStyle(.bordered)
                }
            }
        } footer: { Text("Start and pause from the Display tab. When it ends, the glasses say so, whatever is showing.") }
    }

    @ViewBuilder private var news: some View {
        Section {
            ForEach(NewsSource.builtIn) { source in
                Toggle(source.name, isOn: Binding(
                    get: { model.newsSources.contains(source.url) },
                    set: { on in if on { model.newsSources.insert(source.url) } else { model.newsSources.remove(source.url) } }))
            }
            TextField("Another feed's address (RSS or Atom)", text: $model.customFeed)
                .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
        } header: { Text("Sources") }
        Section {
            Stepper(model.headlineSeconds == 0 ? "Change headlines when I tap" : "New headline every \(Int(model.headlineSeconds)) seconds",
                    value: $model.headlineSeconds, in: 0...60, step: 4)
            Button("Refresh now") { model.refreshNews() }
        } footer: {
            Text(model.newsNote.isEmpty ? "Headlines refresh every 10 minutes. Tap one below to read the whole story on your glasses, a page at a time." : model.newsNote)
        }
        Section("Headlines") {
            if model.news.isEmpty { Text("Nothing yet.").foregroundStyle(.secondary) }
            ForEach(model.news.prefix(30)) { item in
                Button { model.read(item) } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.title)
                        Text("\(item.source)  \(News.age(item.date, now: Date()))").font(.footnote).foregroundStyle(.secondary)
                    }
                }
                .foregroundStyle(.primary)
            }
        }
    }

    @ViewBuilder private var mail: some View {
        Section {
            if model.mailSignedIn {
                Label("Connected to Gmail (read-only)", systemImage: "checkmark.circle").foregroundStyle(.secondary)
                Button("Disconnect", role: .destructive) { model.mailSignOut() }
            } else {
                TextField("Google client ID", text: $model.gmailClientID)
                    .textInputAutocapitalization(.never).autocorrectionDisabled().font(.system(.footnote, design: .monospaced))
                Button("Sign in with Google") { Task { await model.mailSignIn() } }
                    .disabled(model.gmailClientID.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if !model.mailNote.isEmpty { Text(model.mailNote).font(.footnote).foregroundStyle(.secondary) }
        } header: { Text("Gmail") } footer: {
            Text("The app asks Google for permission to read your mail and nothing else: it can't send, delete or change anything. You sign in on Google's own page. Mail goes from Google to this phone to your glasses, and nowhere else.")
        }
        Section {
            TextField("in:inbox category:primary", text: $model.mailQuery).textInputAutocapitalization(.never).autocorrectionDisabled()
            Button("Refresh now") { model.refreshMail() }
        } header: { Text("Which mail") } footer: {
            Text("Any Gmail search works here: is:unread, from:someone, label:work. The newest 15 matches are listed, refreshed every 5 minutes while Mail is showing.")
        }
        if model.mailSignedIn {
            Section("Inbox") {
                if model.mail.isEmpty { Text("Nothing yet.").foregroundStyle(.secondary) }
                ForEach(model.mail) { message in
                    Button { model.openMail(message) } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(message.from).fontWeight(message.unread ? .semibold : .regular)
                            Text(message.subject).font(.subheadline)
                            Text(News.age(message.date, now: Date())).font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                    .foregroundStyle(.primary)
                }
            }
        }
    }

    @ViewBuilder private var weather: some View {
        Section {
            Picker("View", selection: $model.weatherView) {
                ForEach(WeatherView.allCases) { Text($0.title).tag($0) }
            }
            TextField("City", text: $model.city).autocorrectionDisabled()
            Toggle("Celsius", isOn: $model.celsius)
        } footer: { Text(model.weatherNote.isEmpty ? "Forecasts come from Open-Meteo and refresh every 20 minutes." : model.weatherNote) }
    }

    @ViewBuilder private var agenda: some View {
        Section {
            Picker("View", selection: $model.agendaView) {
                ForEach(AgendaView.allCases) { Text($0.title).tag($0) }
            }
            if model.calendarAllowed {
                Label("Calendar access is on", systemImage: "checkmark.circle").foregroundStyle(.secondary)
            } else {
                Button("Allow calendar access") { Task { await model.askCalendar() } }
            }
        } footer: { Text("Reads today's events from the calendars on this iPhone. Nothing is changed or sent anywhere but your glasses.") }
    }

    @ViewBuilder private var reader: some View {
        Section {
            TextEditor(text: $model.readerText).frame(minHeight: 220)
            Button("Paste from clipboard") {
                if let text = UIPasteboard.general.string { model.readerText = text }
            }
            TeleprompterButton(title: "Reader", text: model.readerText)
            if !model.readerText.isEmpty { Button("Clear", role: .destructive) { model.readerText = "" } }
        } header: { Text("Text to read") } footer: {
            Text("Long text is shown a screen at a time and turns by itself. Set the speed under Settings; pause or step pages from the Display tab.")
        }
    }

    @ViewBuilder private var liveTranslate: some View {
        Section {
            Picker("They speak", selection: $model.translateFrom) { ForEach(TranslateLanguage.all) { Text($0.name).tag($0.speech) } }
            Picker("Show me", selection: $model.translateTo) { ForEach(TranslateLanguage.all) { Text($0.name).tag($0.speech) } }
            Picker("Translate with", selection: $model.translateEngine) {
                Text("This iPhone").tag("device")
                Text("Soniox (faster)").tag("soniox")
            }
            if model.translateEngine == "soniox" {
                SecureField("Soniox API key", text: $model.sonioxKey).textInputAutocapitalization(.never).autocorrectionDisabled()
                Toggle("Label who's speaking", isOn: $model.translateSpeakers)
            } else {
                Toggle("Show the original line too", isOn: $model.translateShowsOriginal)
            }
            Button(model.translateOn ? "Stop listening" : "Start listening") { model.toggleTranslate() }
            if !model.translateNote.isEmpty { Text(model.translateNote).foregroundStyle(.secondary) }
        } footer: {
            if model.translateEngine == "soniox" {
                Text("Soniox translates while the person is still speaking. It needs your own API key from console.soniox.com and an internet connection, and the audio is sent to Soniox's servers. Soniox bills your account by the hour of audio. The key is kept in this iPhone's Keychain.")
            }
        }
        Section {} footer: {
            Text("Listens through the iPhone's microphone and translates on the phone, so keep the phone where it can hear. The first time you use a language pair, start it here with the app open: iOS may ask to download the languages. On the glasses: look up to start or stop. Needs iOS 18 or later.")
        }
    }

    @ViewBuilder private var liveText: some View {
        Section {
            Text(model.live.text.isEmpty ? "Nothing received yet." : model.live.text)
                .font(.callout).foregroundStyle(model.live.text.isEmpty ? .secondary : .primary).lineLimit(6)
            if !model.live.text.isEmpty { Button("Clear", role: .destructive) { model.clearLive() } }
            Toggle("Switch to Live text when text arrives", isOn: $model.liveSwitches)
        } header: { Text("Showing") } footer: {
            Text("The newest lines are kept at the bottom of the glasses' screen, like captions.")
        }
        Section {
            Toggle("Local API", isOn: $model.apiOn)
            if model.apiOn {
                Stepper("Port \(model.apiPort)", value: $model.apiPort, in: 1024...65535)
                LabeledContent("Status", value: model.apiState)
            }
        } header: { Text("From another app on this iPhone") } footer: {
            Text("With the Local API on, an app on this phone can send text while Glasses Hub runs in the background:\n\nPOST http://127.0.0.1:\(model.apiPort)/show\nwith JSON {\"text\": \"Hello\", \"append\": false}\n\nA plain-text body or ?text=Hello works too. /clear empties the screen and /status reports whether the display is on. Add ?start=1 to turn the display on if it's off. Only apps on this phone can reach it.")
        }
        Section {
            Text("Shortcuts: add the \"Show text on glasses\" action from Glasses Hub.")
            Text("Link: glasseshub://show?text=Hello  (add &append=1 to add a line, &start=1 to turn the display on). Opening a link brings Glasses Hub to the front, so the Local API or the Shortcuts action is better for a live stream.")
        } header: { Text("Other ways in") }
        .font(.footnote)
    }

    @ViewBuilder private var message: some View {
        Section("Message") {
            TextField("Stays on the glasses until you change it", text: $model.messageText, axis: .vertical).lineLimit(3...8)
        }
    }
}
