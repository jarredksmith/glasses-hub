import AppIntents

// Actions for the Shortcuts app. Assign one to the iPhone's Action button, to Back Tap, or say it to Siri,
// and it steps the glasses the same way the crown does.

struct GlassesNextIntent: AppIntent {
    static var title: LocalizedStringResource = "Next on glasses"
    static var description = IntentDescription("Moves Glasses Hub to the next item or page.")
    static var openAppWhenRun = false
    @MainActor func perform() async throws -> some IntentResult { HubModel.shared.remote(0); return .result() }
}

struct GlassesPreviousIntent: AppIntent {
    static var title: LocalizedStringResource = "Previous on glasses"
    static var description = IntentDescription("Moves Glasses Hub to the previous item or page.")
    static var openAppWhenRun = false
    @MainActor func perform() async throws -> some IntentResult { HubModel.shared.remote(3); return .result() }
}

struct GlassesSelectIntent: AppIntent {
    static var title: LocalizedStringResource = "Select on glasses"
    static var description = IntentDescription("Opens or selects what Glasses Hub is showing.")
    static var openAppWhenRun = false
    @MainActor func perform() async throws -> some IntentResult { HubModel.shared.remote(1); return .result() }
}

struct GlassesMenuIntent: AppIntent {
    static var title: LocalizedStringResource = "Glasses apps menu"
    static var description = IntentDescription("Opens or closes the Glasses Hub apps menu on the glasses.")
    static var openAppWhenRun = false
    @MainActor func perform() async throws -> some IntentResult { HubModel.shared.remote(2); return .result() }
}

struct GlassesDisplayIntent: AppIntent {
    static var title: LocalizedStringResource = "Start or stop the glasses display"
    static var description = IntentDescription("Turns the Glasses Hub display on the glasses on or off.")
    static var openAppWhenRun = false
    @MainActor func perform() async throws -> some IntentResult { HubModel.shared.toggleDisplay(); return .result() }
}

struct GlassesHubShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: GlassesNextIntent(), phrases: ["Next in \(.applicationName)"], shortTitle: "Next", systemImageName: "chevron.right")
        AppShortcut(intent: GlassesPreviousIntent(), phrases: ["Previous in \(.applicationName)"], shortTitle: "Previous", systemImageName: "chevron.left")
        AppShortcut(intent: GlassesSelectIntent(), phrases: ["Select in \(.applicationName)"], shortTitle: "Select", systemImageName: "hand.tap")
        AppShortcut(intent: GlassesMenuIntent(), phrases: ["\(.applicationName) menu"], shortTitle: "Apps menu", systemImageName: "square.grid.2x2")
        AppShortcut(intent: GlassesDisplayIntent(), phrases: ["Start or stop \(.applicationName)"], shortTitle: "Start or stop", systemImageName: "eyeglasses")
    }
}
