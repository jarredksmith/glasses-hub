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
                    NavigationLink { screenPage } label: { Label("Screen and text", systemImage: "textformat.size") }
                    NavigationLink { controlsPage } label: { Label("Glasses controls", systemImage: "dial.medium") }
                    NavigationLink { phonePage } label: { Label("iPhone buttons and Shortcuts", systemImage: "iphone") }
                    NavigationLink { behaviourPage } label: { Label("Pages and alerts", systemImage: "bell") }
                }
                Section {
                    NavigationLink { PracticeView() } label: { Label("Try the controls", systemImage: "checklist") }
                    Button { model.setupSeen = false } label: { Label("Show the setup guide", systemImage: "questionmark.circle") }
                    NavigationLink { LogView() } label: { Label("Connection log", systemImage: "doc.text") }
                } header: { Text("Help") }
                Section {
                    NavigationLink { advancedPage } label: { Label("Advanced and experiments", systemImage: "wrench.and.screwdriver") }
                    NavigationLink { aboutPage } label: { Label("About", systemImage: "info.circle") }
                }
            }
            .navigationTitle("Settings")
        }
    }

    private func page<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        Form { content() }.navigationTitle(title).navigationBarTitleDisplayMode(.inline)
    }

    private var screenPage: some View {
        page("Screen and text") {
            Section {
                Picker("Text size", selection: $model.textSize) {
                    ForEach(TextSize.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Stepper("\(columns.wrappedValue) characters per line", value: columns, in: 20...120)
                Button("Show a test card for 30 seconds") { model.showTestCard() }
            } header: { Text("Size") } footer: {
                Text("Text size applies the next time the display starts. If lines wrap early on the glasses, lower the characters per line; if there's room to spare, raise it. The test card has a ruler to check against.")
            }
            Section {
                Picker("Characters", selection: $model.glyphStyle) {
                    ForEach(GlyphStyle.allCases) { Text($0.title).tag($0) }
                }
                Button("Show the symbol test (3 screens)") { model.showSymbolTest() }
            } header: { Text("Symbols") } footer: {
                Text("Symbols add dots, stars, arrows and table lines to scores, weather, the calendar and news. Run the test with the display on: if any character shows as an empty box or a gap, drop down a level.")
            }
        }
    }

    private var controlsPage: some View {
        page("Glasses controls") {
            Section {
                Toggle("Navigate with the crown", isOn: $model.crownPaging)
                if model.crownPaging {
                    Toggle("Turn back for the previous item", isOn: $model.crownBack)
                    ActionPicker(title: "Double click", selection: $model.doubleClickAction)
                }
            } header: { Text("Crown") } footer: {
                Text("Turn forward for the next page, headline, game, event or message, and back for the previous one. For the double click to reach Glasses Hub, set the crown double-click shortcut to None in the RayNeo app. Holding the crown leaves the page.")
            }
            Section {
                Toggle("Use a look up", isOn: $model.headPaging)
                if model.headPaging { ActionPicker(title: "Look up", selection: $model.headAction) }
            } header: { Text("Head") } footer: {
                Text("Tip your head up briefly. Leave a few seconds between look ups: looking back down is ignored for that long.")
            }
            Section {
                Toggle("Remind me of the controls on the apps menu", isOn: Binding(get: { model.menuHintsLeft > 0 }, set: { model.menuHintsLeft = $0 ? 8 : 0 }))
                NavigationLink("Try the controls") { PracticeView() }
            } footer: {
                Text("The reminder is a line under the apps menu. It turns itself off after you've opened a few things.")
            }
        }
    }

    private var phonePage: some View {
        page("iPhone buttons") {
            Section {
                Toggle("Navigate with the volume buttons", isOn: $model.volumePaging)
                if model.volumePaging {
                    ActionPicker(title: "Volume up", selection: $model.volumeUpAction)
                    ActionPicker(title: "Volume down", selection: $model.volumeDownAction)
                    ActionPicker(title: "Double-press volume up", selection: $model.volumeUpDouble)
                    ActionPicker(title: "Double-press volume down", selection: $model.volumeDownDouble)
                }
            } header: { Text("Volume buttons") } footer: {
                Text("They work with the display on, with the phone locked, from the phone or a Bluetooth ring that sends them, and your volume is put back after each press. With a double press set, a single press takes a moment longer (under half a second) while the app waits to see whether a second press follows.")
            }
            Section {
                Text("Add a Glasses Hub action (Next, Previous, Select, Apps menu, Start or stop the display, Show text) in the Shortcuts app. Then assign that shortcut under Settings > Action Button, or Accessibility > Touch > Back Tap, or ask Siri for it.")
                    .font(.footnote)
            } header: { Text("Action button, Back Tap and Siri") }
        }
    }

    private var behaviourPage: some View {
        page("Pages and alerts") {
            Section {
                Stepper(model.pageSeconds == 0 ? "Pages turn only when I do it" : "Turn the page every \(Int(model.pageSeconds)) seconds",
                        value: $model.pageSeconds, in: 0...60, step: 2)
            } header: { Text("Long text") } footer: {
                Text("Anything taller than the screen is split into pages.")
            }
            Section {
                Picker("Alerts go to", selection: $model.alertStyle) {
                    ForEach(AlertStyle.allCases) { Text($0.title).tag($0) }
                }
                Stepper("Stay on screen \(Int(model.alertSeconds)) seconds", value: $model.alertSeconds, in: 4...30)
                Toggle("Say when a phone notification was blocked", isOn: $model.noticeBlocked)
                if model.notificationsAllowed {
                    Label("Notifications are allowed", systemImage: "checkmark.circle").foregroundStyle(.secondary)
                } else {
                    Button("Allow notifications") { Task { await model.askNotifications() } }
                }
            } header: { Text("Alerts") } footer: {
                Text("Alerts are scores, a finished timer, and notes from your PC. Notifications reach the glasses through the RayNeo app: turn on Glasses Hub in its notification list.\n\nThe glasses don't show phone notifications while Glasses Hub's page is open. They do report which app one came from, so Glasses Hub can show \"Notification: Messages\" for a few seconds, without the message itself. To see notifications in full, use pop-up mode on the Display tab, or the dashboard's option to let notifications through while blank.")
            }
            Section {
                Toggle("Keep running when the phone is locked", isOn: $model.runWhenLocked)
                Toggle("Re-send the screen every 30 seconds", isOn: $model.refreshScreen)
            } header: { Text("While the display is on") } footer: {
                Text("Running while locked uses a silent audio trick iOS allows, and some extra battery. It's only active while the display is on. Re-sending keeps a screen that isn't changing from going stale.")
            }
        }
    }

    private var advancedPage: some View {
        page("Advanced") {
            Section {
                Toggle("Show the Mail app", isOn: $model.showMail)
            } footer: { Text("Mail needs your own Google sign-in set-up.") }
            Section {
                Toggle("Log what the glasses report", isOn: $model.logEvents)
                LabeledContent("Screens sent this session", value: "\(link.framesSent)")
            } header: { Text("Diagnostics") }
            Section {
                Picker("After a single crown click", selection: $model.clickRearm) {
                    Text("Do nothing").tag(0)
                    Text("Reopen the page").tag(2)
                    Text("Refresh quietly").tag(1)
                }
                Toggle("Hold the crown to select (page reopens)", isOn: $model.holdSelects)
                Picker("Translation-mode page", selection: $model.translationMode) {
                    Text("Off").tag(0)
                    Text("Mode 1").tag(1)
                    Text("Mode 2").tag(2)
                    Text("Mode 3").tag(3)
                }
                Toggle("Let the crown scroll long text", isOn: $model.crownScroll)
            } header: { Text("Experiments") } footer: {
                Text("Leftovers from working out the controls; none are needed. The glasses report a single crown click only once per screen, which is why select is a look up. Crown scrolling sends reader and news text in one piece and applies the next time the display starts.")
            }
        }
    }

    private var aboutPage: some View {
        page("About") {
            Section {
                Text("Glasses Hub uses the glasses' Live Captions page as its screen. It joins the connection the RayNeo app already has, so that app has to be connected. It doesn't pair, sign in, or change anything on the glasses, and it never takes the screen from something else that's open.")
                    .font(.footnote)
                Text("To leave from the glasses, hold the crown. If the display won't start, close whatever is open on the glasses and try again.")
                    .font(.footnote)
                Text("Glasses Hub is an independent project and isn't made or endorsed by RayNeo.")
                    .font(.footnote)
            }
            Section {
                LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")
                LabeledContent("Build", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "")
            }
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

/// Chooses what a button or gesture does.
struct ActionPicker: View {
    let title: String
    @Binding var selection: Int
    var body: some View {
        Picker(title, selection: $selection) {
            Text("Next").tag(0)
            Text("Previous").tag(3)
            Text("Select").tag(1)
            Text("Apps menu").tag(2)
            Text("Nothing").tag(4)
        }
    }
}
