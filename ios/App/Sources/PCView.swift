import SwiftUI

/// Pairing with Glasses Hub on the PC, its plug-ins, and the notes it has sent.
struct PCView: View {
    @EnvironmentObject private var model: HubModel
    @EnvironmentObject private var pc: PCLink
    @State private var pairing = false

    var body: some View {
        NavigationStack {
            Form {
                if pc.paired { pairedSections } else { pairSection }
            }
            .navigationTitle("PC")
        }
    }

    @ViewBuilder private var pairSection: some View {
        Section {
            TextField("ABCD-EFGH-JKLM-NPQR", text: $pc.code)
                .textInputAutocapitalization(.characters).autocorrectionDisabled()
                .font(.system(.body, design: .monospaced))
            Button(pairing ? "Connecting…" : "Pair with my PC") {
                pairing = true
                Task { await pc.pair(); pairing = false }
            }
            .disabled(pairing || !pc.hasCode)
            if !pc.message.isEmpty { Text(pc.message).font(.footnote).foregroundStyle(.secondary) }
        } header: { Text("Pairing code") } footer: {
            Text("Open Glasses Hub on your PC and type the code it shows. Notes from the PC's plug-ins and your own scripts then show up on the glasses as cards.\n\nWhile this app is running, notes show on the glasses' display. When it's closed, they arrive as notifications, once the PC has its Apple push key (PC app > Settings).")
        }
    }

    @ViewBuilder private var pairedSections: some View {
        Section {
            HStack {
                Circle().fill(pc.connected ? Color.green : Color.orange).frame(width: 10, height: 10)
                Text(pc.connected ? "Connected to \(pc.pcName.isEmpty ? "your PC" : pc.pcName)" : "Reconnecting…")
            }
            Label(pc.reachesWhenClosed ? "Notes also arrive when this app is closed" : "Notes arrive only while this app is running. Add the Apple push key on the PC to fix that.",
                  systemImage: pc.reachesWhenClosed ? "checkmark.circle" : "exclamationmark.circle")
                .font(.footnote).foregroundStyle(.secondary)
            Toggle("Show the PC's notes on the glasses", isOn: $model.showPCNotes)
            Button("Send a test from the PC") { pc.sendTest() }
            if pc.quietHours { Text("Quiet hours are on at your PC: only things you ask for come through.").font(.footnote).foregroundStyle(.secondary) }
            if !pc.message.isEmpty { Text(pc.message).font(.footnote).foregroundStyle(.secondary) }
        }
        if !pc.plugins.isEmpty {
            Section("Plug-ins on the PC") {
                ForEach(pc.plugins) { plugin in
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle(plugin.name, isOn: Binding(get: { plugin.on }, set: { pc.toggle(plugin, on: $0) }))
                        Text(plugin.on ? (plugin.state.isEmpty ? "On" : plugin.state) : "Off").font(.footnote).foregroundStyle(.secondary)
                        if plugin.on, !plugin.actions.isEmpty {
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack {
                                    ForEach(plugin.actions) { action in
                                        Button(action.label) { pc.run(action, of: plugin) }.buttonStyle(.bordered)
                                    }
                                }
                            }
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        Section("Recent notes") {
            if pc.notes.isEmpty { Text("Nothing yet.").foregroundStyle(.secondary) }
            ForEach(pc.notes.prefix(25)) { note in
                VStack(alignment: .leading, spacing: 2) {
                    Text(note.title).font(.subheadline.weight(.semibold))
                    if !note.body.isEmpty { Text(note.body).font(.footnote) }
                    Text("\(note.source) · \(note.time.formatted(date: .omitted, time: .shortened))").font(.caption2).foregroundStyle(.secondary)
                }
            }
            if !pc.notes.isEmpty { Button("Clear", role: .destructive) { pc.clearNotes() } }
        }
        Section {
            Button("Disconnect from this PC", role: .destructive) { pc.forget() }
        }
    }
}
