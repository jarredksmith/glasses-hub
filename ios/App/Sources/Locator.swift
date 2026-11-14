import CoreLocation
import Foundation

/// Where the phone is, for the apps about what's around you. Only runs while one of them needs it.
@MainActor
final class Locator: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private(set) var latitude: Double?
    private(set) var longitude: Double?
    private(set) var denied = false
    private var running = false
    /// Called when the position changes by enough to matter.
    var onMove: (() -> Void)?

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        manager.distanceFilter = 30
        manager.pausesLocationUpdatesAutomatically = false
    }

    func set(_ on: Bool) {
        guard on != running else { return }
        running = on
        if on {
            if manager.authorizationStatus == .notDetermined { manager.requestWhenInUseAuthorization() }
            manager.allowsBackgroundLocationUpdates = true          // keeps following while the display runs with the phone locked
            manager.startUpdatingLocation()
        } else {
            manager.stopUpdatingLocation()
            manager.allowsBackgroundLocationUpdates = false
        }
    }

    private func took(latitude: Double, longitude: Double) {
        self.latitude = latitude; self.longitude = longitude
        onMove?()
    }
    private func took(status: CLAuthorizationStatus) {
        denied = status == .denied || status == .restricted
        if running, status == .authorizedWhenInUse || status == .authorizedAlways { manager.startUpdatingLocation() }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let last = locations.last else { return }
        let latitude = last.coordinate.latitude, longitude = last.coordinate.longitude
        Task { @MainActor in self.took(latitude: latitude, longitude: longitude) }
    }
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in self.took(status: status) }
    }
    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {}
}

/// Asks the AI for its next line in a game.
enum AIClient {
    static func ask(key: String, model: String, system: String, messages: [[String: String]]) async -> (text: String?, problem: String?) {
        guard let url = URL(string: "https://api.anthropic.com/v1/messages") else { return (nil, "Bad address.") }
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.setValue("2026-10-21", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        let body: [String: Any] = ["model": model, "max_tokens": 120, "system": system, "messages": messages]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            let code = (response as? HTTPURLResponse)?.statusCode ?? 200
            guard (200..<300).contains(code) else {
                if code == 401 { return (nil, "The AI key was refused. Check it in the app.") }
                if code == 404 { return (nil, "The AI model name wasn't recognised. Check it in the app.") }
                let message = (json?["error"] as? [String: Any])?["message"] as? String
                return (nil, message.map { "AI: " + $0 } ?? "The AI service answered \(code).")
            }
            let blocks = json?["content"] as? [[String: Any]] ?? []
            let text = blocks.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined(separator: " ")
            return text.isEmpty ? (nil, "The AI sent nothing back.") : (text, nil)
        } catch {
            return (nil, "Couldn't reach the AI. Check your connection.")
        }
    }
}
