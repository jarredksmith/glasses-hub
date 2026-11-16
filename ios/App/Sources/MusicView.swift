import SwiftUI
import HubCore

/// Settings for the guitar chord follower and the drum trainer.
struct MusicSettings: View {
    @EnvironmentObject private var model: HubModel
    let program: Program

    var body: some View {
        switch program {
        case .chords:
            Section {
                Picker("Song", selection: $model.chordSong) {
                    ForEach(ChordChart.songs) { Text($0.title).tag($0.id) }
                    Text("My own chart").tag("custom")
                }
                Button(model.chordOn ? "Stop listening" : "Start listening") { model.toggleChords() }
                Button("Back to the first chord") { model.restartChords() }
                if !model.musicNote.isEmpty { Text(model.musicNote).foregroundStyle(.secondary) }
            } footer: {
                Text("The glasses show the chord to play, the one after it, and the words. While listening, the phone moves on when it hears the next chord. On the glasses: look up to start or stop listening, turn the crown to step forward or back by hand.\n\nIt works best with clear, ringing chords and the phone within a few feet. Fast changes and near-identical chords may need a turn of the crown. Nothing is recorded.")
            }
            if model.chordSong == "custom" {
                Section {
                    TextEditor(text: $model.chordText).frame(minHeight: 180).font(.system(.body, design: .monospaced))
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                } header: { Text("My chart") } footer: {
                    Text("Put each chord in square brackets where it changes: [G]Amazing [C]grace. A line of chord names above a line of words works too. \(model.chordCount) chord changes found.")
                }
            }
        case .drums:
            Section {
                Picker("Pattern", selection: $model.drumPattern) {
                    ForEach(DrumPattern.library) { Text($0.name).tag($0.name) }
                    Text("My own pattern").tag("custom")
                }
                Button(model.drumOn ? "Stop listening" : "Start listening") { model.toggleDrums() }
                Button("Back to the start") { model.restartDrums() }
                if !model.musicNote.isEmpty { Text(model.musicNote).foregroundStyle(.secondary) }
            } footer: {
                Text("The glasses show one bar as a grid: hi-hat, snare and bass drum, with a marker under the note to play. Each right hit moves the marker; at the end of the bar you see the tempo you played it at. On the glasses: look up to start or stop, turn the crown to change pattern.\n\nPut the phone a few feet from the kit, not on it. Nothing is recorded.")
            }
            Section {
                if let stage = model.drumCalibration {
                    Label(stage, systemImage: "waveform").foregroundStyle(.orange)
                    Button("Skip this drum") { model.skipCalibrationStage() }
                    Button("Cancel", role: .cancel) { model.cancelCalibration() }
                } else {
                    LabeledContent("Kit", value: model.drumKit.calibrated ? "Learned from your drums" : "Standard guess")
                    Button(model.drumKit.calibrated ? "Teach it your kit again" : "Teach it your kit") { model.startCalibration() }
                    if model.drumKit.calibrated { Button("Go back to the standard guess", role: .destructive) { model.forgetKit() } }
                }
                Stepper("Sensitivity \(model.drumSensitivity)", value: $model.drumSensitivity, in: 1...9)
                if !model.drumHeard.isEmpty { LabeledContent("Last heard", value: model.drumHeard) }
            } header: { Text("Hearing your kit") } footer: {
                Text("Teaching takes a minute: it asks for four hits each of the kick, snare, hi-hat and a tom, and learns how each sounds in your room. Do this before judging how well it follows. Raise the sensitivity if soft hits are missed; lower it if one hit counts twice. \"Last heard\" shows what it made of each hit, which helps when a drum is being mistaken for another.")
            }
            if model.drumPattern == "custom" {
                Section {
                    TextEditor(text: $model.drumText).frame(minHeight: 130).font(.system(.body, design: .monospaced))
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                } header: { Text("My pattern") } footer: {
                    Text("One row per drum, one character per step, any letter for a hit and a dash for a rest:\nHH x-x-x-x-x-x-x-x-\nSD ----o-------o---\nBD o-------o-------\nTM for toms. Repeat the rows for a second bar. Use 16 steps for straight time or 12 for a shuffle.")
                }
            }
        default: EmptyView()
        }
    }
}
