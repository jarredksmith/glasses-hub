import SwiftUI

/// Try each control on the glasses and watch it tick off, to learn them and to find one that isn't
/// getting through.
struct PracticeView: View {
    @EnvironmentObject private var model: HubModel
    @EnvironmentObject private var link: GlassesLink

    private let steps: [(title: String, does: String, help: String)] = [
        ("Turn the crown forward", "Next item or page", "One notch is enough."),
        ("Turn the crown back", "Previous item or page", "One notch back. If it doesn't register, turn forward once and try again."),
        ("Look up", "Select or open", "Tip your head up briefly, as if glancing at the ceiling, then wait a few seconds before trying again."),
        ("Double click the crown", "Apps menu", "If the RayNeo assistant opens instead, set the crown double-click shortcut to None in the RayNeo app, then try again."),
    ]

    var body: some View {
        List {
            Section {
                if link.isShowing {
                    Label("The glasses are showing the checklist", systemImage: "eyeglasses").foregroundStyle(.secondary)
                } else {
                    Label(link.isRunning ? link.status : "The display is off", systemImage: "exclamationmark.circle").foregroundStyle(.secondary)
                    if !link.isRunning { Button("Start the display") { model.startDisplay() } }
                }
            }
            Section {
                ForEach(steps.indices, id: \.self) { i in
                    let done = model.practiced.indices.contains(i) && model.practiced[i]
                    Label {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(steps[i].title).font(.headline)
                            Text(steps[i].does).font(.subheadline)
                            if !done { Text(steps[i].help).font(.footnote).foregroundStyle(.secondary) }
                        }
                    } icon: {
                        Image(systemName: done ? "checkmark.circle.fill" : "circle").foregroundStyle(done ? Color.green : Color.secondary)
                    }
                    .padding(.vertical, 3)
                }
            } footer: {
                Text(model.practiced.contains(false)
                     ? "Do each one with your glasses on. Nothing opens or changes while you practise."
                     : "All four controls work. Double click for the apps menu, turn to an app, and look up to open it.")
            }
            Section {
                Button("Start over") { model.startPractice() }
            }
        }
        .navigationTitle("Try the controls")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { model.startPractice() }
        .onDisappear { model.stopPractice() }
    }
}
