import SwiftUI
import HubCore

/// Fetches a feed's answer. Off the main actor: this is plain networking.
enum FeedFetch {
    static func get(_ url: URL, headers: [String: String]) async -> (data: Data?, problem: String?) {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 12)
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 200
            if code == 401 || code == 403 { return (nil, "Access refused. Check the token.") }
            if code == 404 { return (nil, "Not found. Check the address.") }
            guard (200..<300).contains(code) else { return (nil, "The server answered \(code).") }
            return (data, nil)
        } catch let error as URLError where error.code == .appTransportSecurityRequiresSecureConnection {
            return (nil, "Use an https address (plain http only works on your own network).")
        } catch {
            return (nil, "Couldn't reach it.")
        }
    }
}

/// The feeds, inside the Data feeds app's settings.
struct FeedList: View {
    @EnvironmentObject private var model: HubModel

    var body: some View {
        Section {
            ForEach(model.feeds) { feed in
                NavigationLink {
                    FeedEditor(id: feed.id)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(feed.title)
                        Text(status(feed)).font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
            .onDelete { model.feeds.remove(atOffsets: $0) }
            Menu {
                ForEach(FeedKind.allCases, id: \.self) { kind in
                    Button(kind.title) { model.feeds.append(DataFeed(kind: kind)) }
                }
            } label: { Label("Add a feed", systemImage: "plus") }
        } header: { Text("Feeds") } footer: {
            Text("A feed is one value fetched from a source of yours every few minutes. Each can have a line on the dashboard, and they all show on this app's own screen, where a turn of the crown refreshes them.\n\nFeeds are for a glance. Don't rely on one for medical or safety decisions; check the source itself.")
        }
        if !model.feeds.isEmpty {
            Section { Button("Check them all now") { model.refreshFeeds() } }
        }
    }

    private func status(_ feed: DataFeed) -> String {
        if let reading = model.feedReadings[feed.id] {
            let age = FeedParser.age(reading, feed: feed, now: Date())
            return reading.value + (age.isEmpty ? "" : " · " + age)
        }
        return model.feedNotes[feed.id].flatMap { $0.isEmpty ? nil : $0 } ?? feed.kind.title
    }
}

struct FeedEditor: View {
    @EnvironmentObject private var model: HubModel
    @Environment(\.dismiss) private var dismiss
    let id: UUID
    @State private var token = ""

    private var index: Int? { model.feeds.firstIndex { $0.id == id } }

    var body: some View {
        Form {
            if let index {
                let feed = $model.feeds[index]
                let kind = model.feeds[index].kind
                Section {
                    TextField(model.feeds[index].title, text: feed.name)
                } header: { Text("Name on the glasses") }
                Section {
                    switch kind {
                    case .nightscout:
                        field("Site address", "yoursite.example.com", feed.address, url: true)
                        SecureField("Access token (if the site needs one)", text: $token)
                        Toggle("Show mmol/L", isOn: Binding(get: { model.feeds[index].unit == "mmol" }, set: { model.feeds[index].unit = $0 ? "mmol" : "" }))
                    case .homeAssistant:
                        field("Address", "http://homeassistant.local:8123", feed.address, url: true)
                        field("Entity", "sensor.living_room_temperature", feed.item, url: true)
                        SecureField("Long-lived access token", text: $token)
                    case .custom:
                        field("Web address", "https://example.com/value.json", feed.address, url: true)
                        field("JSON field (optional)", "data.0.price", feed.item, url: true)
                        field("Text after the value (optional)", "USD", feed.unit, url: false)
                        SecureField("Access token (optional)", text: $token)
                    }
                } header: { Text(kind.title) } footer: { Text(help(kind)) }
                Section {
                    Stepper("Refresh every \(model.feeds[index].minutes) min", value: feed.minutes, in: 1...60)
                    Toggle("Show on the dashboard", isOn: feed.onDashboard)
                }
                Section {
                    if let reading = model.feedReadings[id] {
                        LabeledContent("Latest", value: FeedParser.line(model.feeds[index], reading: reading, now: Date(), arrows: true))
                    }
                    if let note = model.feedNotes[id], !note.isEmpty { Text(note).foregroundStyle(.secondary) }
                    Button("Check now") { model.setFeedToken(id, token); model.refreshFeeds() }
                }
                Section {
                    Button("Delete this feed", role: .destructive) { model.feeds.removeAll { $0.id == id }; dismiss() }
                }
            }
        }
        .navigationTitle("Feed")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { token = model.feedToken(id) }
        .onChange(of: token) { _, new in model.setFeedToken(id, new) }
    }

    private func field(_ title: String, _ example: String, _ text: Binding<String>, url: Bool) -> some View {
        LabeledContent(title) {
            TextField(example, text: text)
                .multilineTextAlignment(.trailing)
                .textInputAutocapitalization(url ? .never : .sentences)
                .autocorrectionDisabled(url)
                .keyboardType(url ? .URL : .default)
        }
    }

    private func help(_ kind: FeedKind) -> String {
        switch kind {
        case .nightscout:
            return "Shows the latest glucose reading from your Nightscout site, with its trend and how old it is. For a glance only: don't use it for treatment decisions, and check your CGM app or receiver."
        case .homeAssistant:
            return "Shows one entity's state. Create a long-lived access token in Home Assistant under your profile, on the Security tab. A home address only works on your home Wi-Fi unless you have remote access set up; away from home, use the remote (https) address."
        case .custom:
            return "Any address that answers with text or JSON. For JSON, give the field to show as a path with dots, such as data.0.price (numbers pick an item from a list). Leave it empty to show plain text. The token, if given, is sent as a Bearer authorization header."
        }
    }
}
