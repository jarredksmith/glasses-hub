import SwiftUI
import UniformTypeIdentifiers
import HubCore

/// The Movie captions app's page: what's loaded, finding a film or show, and the files kept on the phone.
struct MovieSettings: View {
    @EnvironmentObject private var model: HubModel
    @State private var importing = false
    @State private var problem = ""

    var body: some View {
        Section {
            if model.movie.isEmpty {
                Text("Nothing loaded yet. Find a movie or show below.").foregroundStyle(.secondary)
            } else {
                LabeledContent("Loaded", value: model.movieTitle)
                TimelineView(.periodic(from: .now, by: 1)) { moment in
                    LabeledContent("Captions", value: status(at: moment.date))
                }
                if model.movieCanListen {
                    Button(model.movieOn ? "Stop listening" : "Start captions") {
                        if !model.movieOn { model.program = .movie }
                        model.toggleMovie()
                    }
                }
                if model.movie.state != .waiting || !model.movieCanListen {
                    Button(model.movie.state == .running ? "Pause the captions" : (model.movie.state == .held ? "Carry on" : "Start at the first line")) {
                        model.program = .movie; model.holdMovie()
                    }
                }
                if model.movie.state != .waiting {
                    HStack {
                        Text("Timing")
                        Spacer()
                        Button("Earlier") { model.nudgeMovie(0.5) }.buttonStyle(.bordered)
                        Button("Later") { model.nudgeMovie(-0.5) }.buttonStyle(.bordered)
                    }
                    Button("Start over") { model.restartMovie() }
                }
            }
            if !model.movieNote.isEmpty { Text(model.movieNote).font(.footnote).foregroundStyle(.secondary) }
        } footer: {
            Text(model.movieCanListen
                 ? "Start the film, then tap Start captions and leave the phone where it can hear. Once it recognises a line, the real subtitles follow along, and it finds its place again after a pause or a skip. On the glasses: click to pause or carry on, turn the crown to move the captions earlier or later."
                 : "The captions are in a different language from the film, so they can't follow by ear. Tap Start at the first line as the first line is spoken, then use Earlier and Later (or the crown) to line them up.")
        }
        Section {
            NavigationLink { MovieSearch() } label: { Label("Find a movie or show", systemImage: "magnifyingglass") }
            Button { importing = true } label: { Label("Import a subtitle file", systemImage: "square.and.arrow.down") }
            if !problem.isEmpty { Text(problem).font(.footnote).foregroundStyle(.secondary) }
        } footer: {
            Text("Importing takes an .srt or .vtt file from Files, iCloud Drive or another app.")
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: MovieSettings.types) { result in
            guard case .success(let url) = result else { return }
            let allowed = url.startAccessingSecurityScopedResource()
            defer { if allowed { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url) else { problem = "Couldn't open that file."; return }
            let name = url.deletingPathExtension().lastPathComponent
            problem = model.addMovie(title: name, detail: "Imported file", text: SubtitleFile.decode(data)) ? "" : "That doesn't look like a subtitle file (.srt or .vtt)."
        }
        if !model.movieLibrary.isEmpty {
            Section("On this iPhone") {
                ForEach(model.movieLibrary) { entry in
                    Button { model.movieCurrent = entry.id } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(entry.title).foregroundStyle(.primary)
                                Text(entry.detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer()
                            if entry.id == model.movieCurrent { Image(systemName: "checkmark").foregroundStyle(.tint) }
                        }
                    }
                }
                .onDelete { model.removeMovies(at: $0) }
            }
        }
        Section {
            Picker("Captions in", selection: $model.movieLanguage) { ForEach(SubtitleSearch.languages, id: \.code) { Text($0.name).tag($0.code) } }
            Picker("The film is in", selection: $model.movieAudio) { ForEach(SubtitleSearch.languages, id: \.code) { Text($0.name).tag($0.code) } }
            Toggle("Pause when the room goes quiet", isOn: $model.movieHolds)
            if SubtitleSearch.builtInKey.isEmpty {
                SecureField("OpenSubtitles API key", text: $model.subtitleKey).textInputAutocapitalization(.never).autocorrectionDisabled()
            }
        } footer: {
            Text("Pick a captions language different from the film's to read a translation. \"Pause when the room goes quiet\" holds the captions if half a minute of dialogue goes by unheard, which usually means the film was paused."
                 + (SubtitleSearch.builtInKey.isEmpty ? "\n\nSearching needs a free API key from opensubtitles.com (sign in, then Consumers > New consumer). Importing a file works without one." : "")
                 + "\n\nSubtitle files come from OpenSubtitles.com, where volunteers upload them. The phone only listens to match the dialogue; nothing is recorded or sent anywhere.")
        }
    }

    private static let types: [UTType] = [UTType(filenameExtension: "srt"), UTType(filenameExtension: "vtt"), UTType.plainText, UTType.text].compactMap { $0 }

    private func status(at date: Date) -> String {
        let now = date.timeIntervalSinceReferenceDate
        switch model.movie.state {
        case .waiting: return model.movieOn ? "Listening for a line…" : "Not started"
        case .held: return "Paused at " + MovieTracker.clock(model.movie.position(at: now) ?? 0)
        case .running: return MovieTracker.clock(model.movie.position(at: now) ?? 0) + " of " + MovieTracker.clock(model.movie.length)
        }
    }
}

/// Search OpenSubtitles by name, pick the film or the episode, and download its subtitles.
struct MovieSearch: View {
    @EnvironmentObject private var model: HubModel
    @State private var typed = ""
    @State private var results = [SubtitleSearch.Title]()
    @State private var busy = false
    @State private var note = ""

    var body: some View {
        Form {
            Section {
                HStack {
                    TextField("Name of a movie or show", text: $typed).autocorrectionDisabled().submitLabel(.search).onSubmit(search)
                    if busy { ProgressView() } else { Button("Search", action: search).disabled(typed.trimmingCharacters(in: .whitespaces).count < 2) }
                }
                if !note.isEmpty { Text(note).font(.footnote).foregroundStyle(.secondary) }
            }
            if !results.isEmpty {
                Section {
                    ForEach(results) { title in
                        NavigationLink { MovieVersions(title: title) } label: {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(title.title)
                                Text([title.isSeries ? "Series" : "Movie", title.year].filter { !$0.isEmpty }.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Find subtitles")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func search() {
        let query = typed.trimmingCharacters(in: .whitespaces)
        guard query.count >= 2, !busy else { return }
        guard !model.movieKey.isEmpty else { note = "Add an OpenSubtitles API key on the previous page to search, or import a file instead."; return }
        busy = true; note = ""
        let key = model.movieKey
        Task {
            do {
                let found = try await SubtitleSearch.titles(query, key: key)
                results = found
                note = found.isEmpty ? "Nothing found by that name." : ""
            } catch { results = []; note = error.localizedDescription }
            busy = false
        }
    }
}

/// The subtitle files for one film, or one episode of a show.
struct MovieVersions: View {
    let title: SubtitleSearch.Title
    @EnvironmentObject private var model: HubModel
    @Environment(\.dismiss) private var dismiss
    @State private var season = 1
    @State private var episode = 1
    @State private var versions = [SubtitleSearch.Version]()
    @State private var busy = false
    @State private var looked = false
    @State private var note = ""
    @State private var done = false

    var body: some View {
        Form {
            if title.isSeries {
                Section {
                    Stepper("Season \(season)", value: $season, in: 0...60)
                    Stepper("Episode \(episode)", value: $episode, in: 1...400)
                    Button("Find this episode", action: look).disabled(busy)
                }
            }
            if busy { Section { HStack { ProgressView(); Text("  Working…").foregroundStyle(.secondary) } } }
            if !note.isEmpty { Section { Text(note).foregroundStyle(.secondary) } }
            if done {
                Section {
                    Label("Ready: \(model.movieTitle)", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    Button("Start captions") { model.program = .movie; if !model.movieOn { model.toggleMovie() } }
                } footer: { Text("Start the film first. If the timing looks off for this copy of the film, try another version below.") }
            }
            if !versions.isEmpty {
                Section {
                    if !done { Button { get(versions[0]) } label: { Label("Get the most popular", systemImage: "arrow.down.circle.fill") }.disabled(busy) }
                    ForEach(versions.prefix(12)) { version in
                        Button { get(version) } label: {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(version.release).font(.callout).foregroundStyle(.primary).lineLimit(2)
                                Text("\(version.downloads) downloads" + (version.hearingImpaired ? " · includes sounds" : "")).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .disabled(busy)
                    }
                } header: { Text("Versions") } footer: {
                    Text("Different releases of a film can be timed a little differently. The most downloaded is usually right.")
                }
            }
        }
        .navigationTitle(label)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { if !title.isSeries, !looked { look() } }
    }

    private var label: String { title.isSeries ? title.title : (title.year.isEmpty ? title.title : "\(title.title) (\(title.year))") }

    private func look() {
        guard !busy else { return }
        busy = true; looked = true; note = ""; done = false
        let key = model.movieKey, language = model.movieLanguage, s = season, e = episode
        Task {
            do {
                let found = try await SubtitleSearch.versions(of: title, season: s, episode: e, language: language, key: key)
                versions = found
                note = found.isEmpty ? "No subtitles in that language for this one." : ""
            } catch { versions = []; note = error.localizedDescription }
            busy = false
        }
    }

    private func get(_ version: SubtitleSearch.Version) {
        guard !busy else { return }
        busy = true; note = ""
        let key = model.movieKey
        let name = title.isSeries ? "\(title.title) S\(season)E\(episode)" : label
        Task {
            do {
                let text = try await SubtitleSearch.download(version, key: key)
                if model.addMovie(title: name, detail: version.release, text: text) { done = true }
                else { note = "That file couldn't be read. Try another version." }
            } catch { note = error.localizedDescription }
            busy = false
        }
    }
}
