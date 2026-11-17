import SwiftUI
import HubCore

/// Settings for the word game and 20 questions.
struct GameSettings: View {
    @EnvironmentObject private var model: HubModel
    let program: Program

    var body: some View {
        switch program {
        case .word:
            Section {
                LabeledContent("Daily streak", value: "\(model.wordStreak)")
                Button("Skip to a new word") { model.newWord() }
            } footer: {
                Text("Guess the hidden word a letter at a time. On the glasses: turn the crown to choose a letter, look up to guess it. Six wrong letters and the word is lost. There's one daily word, the same for everyone, and as many extra words as you like after it.")
            }
        case .twenty:
            Section {
                SecureField("Anthropic API key", text: $model.aiKey).textInputAutocapitalization(.never).autocorrectionDisabled()
                LabeledContent("Model") {
                    TextField("claude-haiku-5-5", text: $model.aiModel).multilineTextAlignment(.trailing)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                }
                Button("Start a new game") { model.startTwenty() }
            } footer: {
                Text("You think of something and the AI tries to guess it in 20 yes-or-no questions. On the glasses: look up to start, then turn the crown forward for yes, back for no, and look up for not sure.\n\nThe questions come from Anthropic's Claude, so this needs your own API key and an internet connection. Only the questions and your yes or no answers are sent. A game costs a fraction of a cent. The key is kept in this iPhone's Keychain.")
            }
        default: EmptyView()
        }
    }
}

/// Settings for the apps about what's around you.
struct NearbySettings: View {
    @EnvironmentObject private var model: HubModel
    let program: Program

    var body: some View {
        switch program {
        case .planes:
            Section {
                if let note = model.nearbyProblem { Text(note).foregroundStyle(.secondary) }
                else { LabeledContent("In the air nearby", value: "\(model.planes.count)") }
            } footer: {
                Text("Shows the aircraft closest to you: flight, aircraft type, route when it's known, height, speed, and which way to look. On the glasses: turn the crown for the next nearest, look up to refresh.\n\nIt uses your location while it's showing. Positions come from the adsb.lol community network and routes from adsbdb; both are volunteer-run, so some flights are missing and some routes are out of date.")
            }
        case .tour:
            Section {
                if let note = model.nearbyProblem { Text(note).foregroundStyle(.secondary) }
                else { LabeledContent("Places found nearby", value: "\(model.places.count)") }
                Toggle("Tell me when I pass something", isOn: $model.tourAnnounce)
            } footer: {
                Text("Lists the places around you that have a Wikipedia article, nearest first. On the glasses: turn the crown for the next place, look up to read about it.\n\nWith \"Tell me when I pass something\" on, a place pops up as you come within a short walk of it, whatever app is showing. That keeps using your location while the display or pop-up mode is on, including with the phone locked. Text is from Wikipedia.")
            }
        default: EmptyView()
        }
    }
}
