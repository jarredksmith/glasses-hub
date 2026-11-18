import SwiftUI
import HubCore

/// The home tab: turn the display on, see what the glasses see, pick what's showing.
struct DisplayView: View {
    @EnvironmentObject private var model: HubModel
    @EnvironmentObject private var link: GlassesLink
    @State private var flashText = ""
    @State private var choosing = false
    @State private var showNote = false
    @State private var showPad = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    statusCard
                    LensPreview(text: model.preview, rows: model.screen.rows, live: link.isShowing, scrolls: model.previewScrolls)
                    programPicker
                    ProgramControls(program: model.program)
                    PageControls()
                    HStack {
                        Button { model.input(.previous) } label: { Label("Back", systemImage: "arrow.counterclockwise") }
                        Button { model.input(.next) } label: { Label("Turn", systemImage: "arrow.clockwise") }
                        Button { model.input(.select) } label: { Label("Select", systemImage: "hand.tap") }
                        Spacer()
                    }
                    .buttonStyle(.bordered)
                    .labelStyle(.titleAndIcon)
                }
                .padding()
            }
            .navigationTitle("Glasses Hub")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showPad = true } label: { Image(systemName: "av.remote") }.accessibilityLabel("Remote pad for a ring or clicker")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showNote = true } label: { Image(systemName: "square.and.pencil") }.accessibilityLabel("Flash a note")
                }
            }
            .sheet(isPresented: $choosing) { AppChooser() }
            .fullScreenCover(isPresented: $showPad) { RemotePadView() }
            .sheet(isPresented: $showNote) {
                NavigationStack {
                    Form { sendBox }
                        .navigationTitle("Flash a note").navigationBarTitleDisplayMode(.inline)
                        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { showNote = false } } }
                }
                .presentationDetents([.medium])
            }
        }
    }

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Circle().fill(link.isShowing ? Color.green : (link.isRunning ? Color.orange : Color.secondary.opacity(0.5)))
                    .frame(width: 10, height: 10)
                Text(link.status).font(.subheadline).fixedSize(horizontal: false, vertical: true)
                if let battery = link.battery, link.isRunning {
                    Spacer()
                    Label("\(battery)%", systemImage: "battery.50").font(.footnote).foregroundStyle(.secondary)
                }
            }
            if let ended = model.endedNotice, !link.isRunning, ended != link.status {
                Text(ended).font(.footnote).foregroundStyle(.secondary)
            }
            Button {
                if link.isRunning { model.stopDisplay() } else { model.startDisplay() }
            } label: {
                Label(link.isRunning ? "Stop display" : "Start display", systemImage: link.isRunning ? "stop.fill" : "play.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(link.isRunning ? Color.red : Color.accentColor)
            .controlSize(.large)
            Toggle("Pop up only when something comes in", isOn: $model.popUps).font(.subheadline)
            if model.popUps, !link.isRunning {
                Text("Waiting. The display opens by itself for alerts, then closes. Leave this app running in the background.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .padding()
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
    }

    /// What's showing, the pinned apps a tap away, and the way to everything else.
    private var programPicker: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button { choosing = true } label: {
                HStack(spacing: 12) {
                    Image(systemName: model.program.icon).font(.title3).frame(width: 30)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Showing").font(.caption).foregroundStyle(.secondary)
                        Text(model.program.title).font(.headline).foregroundStyle(Color.primary)
                    }
                    Spacer()
                    Text("All apps").font(.subheadline)
                    Image(systemName: "chevron.right").font(.footnote)
                }
                .padding(12)
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
            }
            .buttonStyle(.plain)
            let pinned = model.favoriteApps
            if !pinned.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(pinned) { program in
                            Button { model.program = program } label: {
                                Label(program.title, systemImage: program.icon).font(.subheadline).lineLimit(1)
                            }
                            .buttonStyle(.bordered)
                            .tint(model.program == program ? Color.accentColor : Color.secondary)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder private var sendBox: some View {
        Section {
            TextField("Shows on the glasses for a few seconds", text: $flashText, axis: .vertical).lineLimit(2...5)
            Button("Send") {
                model.flash(flashText); flashText = ""; showNote = false
            }
            .disabled(flashText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }
}

/// A stand-in for the lens: the same text the glasses get, green on black.
struct LensPreview: View {
    let text: String
    let rows: Int
    let live: Bool
    let scrolls: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(live ? "On your glasses now" : "Preview").font(.headline)
                Spacer()
                if scrolls { Label("Crown scrolls", systemImage: "arrow.up.and.down").font(.caption).foregroundStyle(.secondary) }
            }
            ScrollView {
                Text(text.isEmpty ? " " : text)
                    .font(.system(size: 15, weight: .medium, design: .monospaced))
                    .foregroundStyle(Color.green)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
            .frame(height: CGFloat(rows) * 21 + 24)
            .background(Color.black, in: RoundedRectangle(cornerRadius: 12))
            .accessibilityLabel("Glasses preview: \(text)")
        }
    }
}

/// The handful of buttons each program needs while it's on screen.
struct ProgramControls: View {
    @EnvironmentObject private var model: HubModel
    let program: Program

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            switch program {
            case .trivia: trivia
            case .timer: timer
            case .reader:
                TeleprompterButton(title: "Reader", text: model.readerText).buttonStyle(.bordered)
                Text("Edit the text under Apps > Reader.").font(.footnote).foregroundStyle(.secondary)
            case .news: news
            case .facts:
                Button("New fact now") { model.nextFact() }.buttonStyle(.bordered)
            case .message:
                TextField("Message for the glasses", text: $model.messageText, axis: .vertical)
                    .textFieldStyle(.roundedBorder).lineLimit(2...6)
            case .scores:
                if let game = model.game {
                    Text("Following: \(game.away.name) at \(game.home.name)").font(.footnote).foregroundStyle(.secondary)
                } else if !model.scoresNote.isEmpty {
                    Text(model.scoresNote).font(.footnote).foregroundStyle(.secondary)
                }
            default: EmptyView()
            }
        }
    }

    @ViewBuilder private var trivia: some View {
        if let round = model.round, round.phase != .done {
            HStack {
                Button("Reveal answer") { model.triviaReveal() }.disabled(round.phase != .question)
                Button("Next question") { model.triviaNext() }
                Spacer()
                Button("End", role: .destructive) { model.triviaStop() }
            }
            .buttonStyle(.bordered)
            if let q = round.current {
                Text("Answer: \(q.answer)").font(.footnote).foregroundStyle(.secondary)
            }
        } else {
            Button("Start a round of \(model.triviaCount)") { model.startTrivia() }.buttonStyle(.borderedProminent)
            if !model.triviaNote.isEmpty { Text(model.triviaNote).font(.footnote).foregroundStyle(.secondary) }
        }
    }

    @ViewBuilder private var timer: some View {
        HStack {
            if model.timer.isRunning {
                Button("Pause") { model.timerPause() }
            } else {
                Button("Start") { model.timerStart() }.buttonStyle(.borderedProminent)
            }
            Button("Reset") { model.timerReset() }
            Spacer()
            Stepper("\(Int(model.timerMinutes)) min", value: $model.timerMinutes, in: 1...180, step: model.timerMinutes < 10 ? 1 : 5)
                .fixedSize()
        }
        .buttonStyle(.bordered)
    }

    @ViewBuilder private var news: some View {
        HStack {
            Button("Previous") { model.newsStep(-1) }
            Button("Next") { model.newsStep(1) }
            Spacer()
            if model.reading == nil {
                Button("Read story") { model.readCurrent() }.buttonStyle(.borderedProminent).disabled(model.news.isEmpty)
            } else {
                Button("Headlines") { model.stopReading() }
            }
        }
        .buttonStyle(.bordered)
        if let reading = model.reading {
            Text("Reading: \(reading.title)").font(.footnote).foregroundStyle(.secondary)
            TeleprompterButton(title: reading.title, text: model.readingText).buttonStyle(.bordered)
        }
    }
}

/// Shown whenever what's on the glasses runs to more than one screen.
struct PageControls: View {
    @EnvironmentObject private var model: HubModel

    var body: some View {
        if model.pageCount > 1 {
            HStack {
                Button { model.pageStep(-1) } label: { Image(systemName: "chevron.left") }.disabled(model.pageIndex == 0)
                Button { model.togglePagesPaused() } label: { Image(systemName: model.pagesPaused ? "play.fill" : "pause.fill") }
                Button { model.pageStep(1) } label: { Image(systemName: "chevron.right") }.disabled(model.pageIndex >= model.pageCount - 1)
                Text("Page \(model.pageIndex + 1) of \(model.pageCount)" + (model.pagesPaused || model.pageSeconds == 0 ? "" : ", auto")).font(.footnote)
                Spacer()
                Button("Start over") { model.pageRestart() }.font(.footnote)
            }
            .buttonStyle(.bordered)
        }
    }
}

/// Every app, grouped as on the glasses' menu, to pick what's showing.
struct AppChooser: View {
    @EnvironmentObject private var model: HubModel
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""

    private func matches(_ program: Program) -> Bool {
        let wanted = search.trimmingCharacters(in: .whitespaces)
        return wanted.isEmpty || program.title.localizedCaseInsensitiveContains(wanted)
    }

    var body: some View {
        NavigationStack {
            List {
                if matches(.dashboard) { Section { row(.dashboard) } }
                ForEach(model.menuGroups) { group in
                    let items = group.items.filter(matches)
                    if !items.isEmpty { Section(group.title) { ForEach(items) { row($0) } } }
                }
            }
            .searchable(text: $search, prompt: "Find an app")
            .navigationTitle("Show on the glasses")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
        }
    }

    private func row(_ program: Program) -> some View {
        HStack(spacing: 12) {
            Button {
                model.program = program; dismiss()
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: program.icon).frame(width: 28).foregroundStyle(Color.accentColor)
                    Text(program.title).foregroundStyle(Color.primary)
                    Spacer()
                    if model.program == program { Image(systemName: "checkmark").foregroundStyle(Color.accentColor) }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Button { model.toggleFavorite(program) } label: {
                Image(systemName: model.isFavorite(program) ? "pin.fill" : "pin").foregroundStyle(model.isFavorite(program) ? Color.orange : Color.secondary)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(model.isFavorite(program) ? "Unpin \(program.title)" : "Pin \(program.title)")
        }
    }
}
