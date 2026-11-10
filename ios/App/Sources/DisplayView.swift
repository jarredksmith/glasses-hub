import SwiftUI
import HubCore

/// The home tab: turn the display on, see what the glasses see, pick what's showing.
struct DisplayView: View {
    @EnvironmentObject private var model: HubModel
    @EnvironmentObject private var link: GlassesLink
    @State private var flashText = ""

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    statusCard
                    LensPreview(text: model.preview, rows: model.screen.rows, live: link.isShowing, scrolls: model.previewScrolls)
                    programPicker
                    ProgramControls(program: model.program)
                    PageControls()
                    sendBox
                }
                .padding()
            }
            .navigationTitle("Glasses Hub")
        }
    }

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Circle().fill(link.isShowing ? Color.green : (link.isRunning ? Color.orange : Color.secondary.opacity(0.5)))
                    .frame(width: 10, height: 10)
                Text(link.status).font(.subheadline).fixedSize(horizontal: false, vertical: true)
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
            if !link.isRunning {
                Text("Keep the RayNeo app connected to your glasses. To leave the display from the glasses, hold the crown.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .padding()
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
    }

    private var programPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Showing").font(.headline)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 8)], spacing: 8) {
                ForEach(Program.allCases) { program in
                    Button { model.program = program } label: {
                        VStack(spacing: 6) {
                            Image(systemName: program.icon).font(.title3)
                            Text(program.title).font(.caption).lineLimit(1).minimumScaleFactor(0.8)
                        }
                        .frame(maxWidth: .infinity, minHeight: 58)
                    }
                    .buttonStyle(.bordered)
                    .tint(model.program == program ? Color.accentColor : Color.secondary)
                }
            }
        }
    }

    private var sendBox: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Flash a note").font(.headline)
            HStack {
                TextField("Shows for a few seconds", text: $flashText, axis: .vertical).textFieldStyle(.roundedBorder).lineLimit(1...3)
                Button("Send") {
                    model.flash(flashText); flashText = ""
                }
                .buttonStyle(.bordered)
                .disabled(flashText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
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
                Text("Long text turns a page every \(Int(model.pageSeconds)) seconds. Edit it under Apps > Reader.").font(.footnote).foregroundStyle(.secondary)
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
                Text("Page \(model.pageIndex + 1) of \(model.pageCount)" + (model.pagesPaused ? ", paused" : "")).font(.footnote)
                Spacer()
                Button("Start over") { model.pageRestart() }.font(.footnote)
            }
            .buttonStyle(.bordered)
        }
    }
}
