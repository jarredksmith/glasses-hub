import SwiftUI

/// First-run guide: what the app needs from the glasses and the RayNeo app, and how to drive it.
struct SetupView: View {
    @EnvironmentObject private var model: HubModel

    private struct Step: Identifiable { let id: Int; let icon: String; let title: String; let text: String }
    private let steps = [
        Step(id: 1, icon: "eyeglasses", title: "Pair your glasses in the RayNeo app",
             text: "Glasses Hub shares the RayNeo app's connection to RayNeo iO glasses. Keep the RayNeo app installed and your glasses connected to it."),
        Step(id: 2, icon: "hand.tap", title: "Set the crown double click to None",
             text: "In the RayNeo app's settings for your glasses, change the crown double-click shortcut to None. Glasses Hub uses the double click itself; left on its default it opens the RayNeo assistant instead."),
        Step(id: 3, icon: "play.circle", title: "Start the display",
             text: "On the Display tab, tap Start. The glasses show the Glasses Hub page. Allow Bluetooth when asked."),
    ]
    private let controls: [(String, String)] = [
        ("Turn the crown forward", "Next item or page"),
        ("Turn the crown back", "Previous item or page"),
        ("Look up", "Select or open"),
        ("Double click the crown", "Apps menu (again to close)"),
        ("Hold the crown", "Leave the page"),
    ]

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(steps) { step in
                        Label {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("\(step.id). \(step.title)").font(.headline)
                                Text(step.text).font(.subheadline).foregroundStyle(.secondary)
                            }
                        } icon: { Image(systemName: step.icon) }
                        .padding(.vertical, 4)
                    }
                } header: { Text("Before you start") }
                Section {
                    ForEach(controls, id: \.0) { control in
                        LabeledContent(control.0, value: control.1)
                    }
                } header: { Text("Controls on the glasses") } footer: {
                    Text("You can change what a look up and a double click do in Settings.")
                }
                Section {
                    Text("Glasses Hub is an independent project and isn't made or endorsed by RayNeo. It relies on how the glasses behave on Strix OS 1.0.6; a glasses update may change that.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Set up Glasses Hub")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { model.setupSeen = true } } }
        }
    }
}
