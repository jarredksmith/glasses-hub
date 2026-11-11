import SwiftUI
import HubCore

struct SettingsView: View {
    @EnvironmentObject private var model: HubModel
    @EnvironmentObject private var link: GlassesLink

    private var columns: Binding<Int> {
        model.textSize == .small ? $model.columnsSmall : $model.columnsLarge
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Text size", selection: $model.textSize) {
                        ForEach(TextSize.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    Stepper("\(columns.wrappedValue) characters per line", value: columns, in: 20...70)
                    Button("Show a test card for 30 seconds") { model.showTestCard() }
                } header: { Text("Screen") } footer: {
                    Text("Text size applies the next time the display starts. If lines wrap early on the glasses, lower the characters per line; if there's room to spare, raise it. The test card has a ruler to check against.")
                }

                Section {
                    Picker("Characters", selection: $model.glyphStyle) {
                        ForEach(GlyphStyle.allCases) { Text($0.title).tag($0) }
                    }
                    Button("Show the symbol test (3 screens)") { model.showSymbolTest() }
                } header: { Text("Look") } footer: {
                    Text("Symbols add dots, stars, arrows and table lines to scores, weather, the calendar and news. Run the test with the display on: if any character shows as an empty box or a gap, tell me which, or drop down a level. Shaded bars are the least certain.")
                }

                Section {
                    Stepper(model.pageSeconds == 0 ? "Pages turn only when I press a button" : "Turn the page every \(Int(model.pageSeconds)) seconds",
                            value: $model.pageSeconds, in: 0...60, step: 2)
                    Toggle("Navigate with the crown", isOn: $model.crownPaging)
                    Toggle("Navigate with the volume buttons", isOn: $model.volumePaging)
                    Toggle("Tilt my head up for \"next\" (experimental)", isOn: $model.headPaging)
                    Toggle("Let the crown scroll long text instead (experimental)", isOn: $model.crownScroll)
                } header: { Text("Long text") } footer: {
                    Text("Turn the crown forward for the next thing (page, headline, game, event or message) and back for the previous one. Click it to open what's showing, to go back when something is open, or otherwise to bring up the menu of apps. Lists end in a stop that also leads to the menu. Double-click and hold still belong to the glasses.\n\nThe volume buttons do the same with the display on: up is a turn, down is a click. They work with the phone locked, from the phone or a Bluetooth ring that sends them, and your volume is put back after each press.\n\nAnything taller than the screen is split into pages that turn by themselves, because the glasses jump back to the end of scrolled text after a few seconds. The experiment sends reader and news text in one piece, marked as finished, which may stop that jump. It applies the next time the display starts.")
                }

                Section {
                    Toggle("Keep running when the phone is locked", isOn: $model.runWhenLocked)
                    Toggle("Re-send the screen every 30 seconds", isOn: $model.refreshScreen)
                } header: { Text("While the display is on") } footer: {
                    Text("Running while locked uses a silent audio trick iOS allows, and some extra battery. It's only active while the display is on. Re-sending keeps a screen that isn't changing from going stale; it's skipped for text you scroll.")
                }

                Section {
                    Picker("Alerts go to", selection: $model.alertStyle) {
                        ForEach(AlertStyle.allCases) { Text($0.title).tag($0) }
                    }
                    Stepper("Stay on screen \(Int(model.alertSeconds)) seconds", value: $model.alertSeconds, in: 4...30)
                    if model.notificationsAllowed {
                        Label("Notifications are allowed", systemImage: "checkmark.circle").foregroundStyle(.secondary)
                    } else {
                        Button("Allow notifications") { Task { await model.askNotifications() } }
                    }
                } header: { Text("Alerts") } footer: {
                    Text("Alerts are scores, a finished timer, and notes from your PC. Notifications reach the glasses through the RayNeo app: turn on Glasses Hub in its notification list.")
                }

                Section("About the display") {
                    Text("Glasses Hub uses the glasses' Live Captions page as its screen. It joins the connection the RayNeo app already has, so that app has to be connected. It doesn't pair, sign in, or change anything on the glasses, and it never takes the screen from something else that's open.")
                        .font(.footnote)
                    Text("To leave from the glasses, hold the crown. If the display won't start, close whatever is open on the glasses and try again.")
                        .font(.footnote)
                }

                Section {
                    NavigationLink("Connection log") { LogView() }
                    Toggle("Log what the glasses report", isOn: $model.logEvents)
                    LabeledContent("Screens sent this session", value: "\(link.framesSent)")
                    LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")
                    LabeledContent("Build", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "")
                } header: { Text("Troubleshooting") }
            }
            .navigationTitle("Settings")
        }
    }
}

struct LogView: View {
    @EnvironmentObject private var link: GlassesLink

    var body: some View {
        ScrollView {
            Text(link.log.isEmpty ? "Nothing yet. Start the display to see what happens." : link.log.joined(separator: "\n"))
                .font(.system(.footnote, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
                .padding()
        }
        .navigationTitle("Connection log")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button("Copy") { UIPasteboard.general.string = link.log.joined(separator: "\n") }
                Button("Clear") { link.clearLog() }
            }
        }
    }
}
