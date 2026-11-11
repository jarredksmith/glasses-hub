import SwiftUI
import HubCore

/// Every app, with its settings.
struct AppsView: View {
    @EnvironmentObject private var model: HubModel

    var body: some View {
        NavigationStack {
            List(Program.allCases) { program in
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
            .navigationTitle("Apps")
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
            case .dashboard: dashboard
            case .scores: scores
            case .news: news
            case .trivia: trivia
            case .facts: facts
            case .timer: timer
            case .weather: weather
            case .agenda: agenda
            case .reader: reader
            case .message: message
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

    @ViewBuilder private var message: some View {
        Section("Message") {
            TextField("Stays on the glasses until you change it", text: $model.messageText, axis: .vertical).lineLimit(3...8)
        }
    }
}
