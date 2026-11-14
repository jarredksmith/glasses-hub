import Foundation

/// Distances and directions on the ground.
public enum Geo {
    /// Metres between two points.
    public static func distance(_ lat1: Double, _ lon1: Double, _ lat2: Double, _ lon2: Double) -> Double {
        let r = 6_371_000.0, toRad = Double.pi / 180
        let dLat = (lat2 - lat1) * toRad, dLon = (lon2 - lon1) * toRad
        let a = sin(dLat / 2) * sin(dLat / 2) + cos(lat1 * toRad) * cos(lat2 * toRad) * sin(dLon / 2) * sin(dLon / 2)
        return 2 * r * atan2(sqrt(a), sqrt(1 - a))
    }
    /// Compass bearing in degrees from the first point to the second.
    public static func bearing(_ lat1: Double, _ lon1: Double, _ lat2: Double, _ lon2: Double) -> Double {
        let toRad = Double.pi / 180
        let y = sin((lon2 - lon1) * toRad) * cos(lat2 * toRad)
        let x = cos(lat1 * toRad) * sin(lat2 * toRad) - sin(lat1 * toRad) * cos(lat2 * toRad) * cos((lon2 - lon1) * toRad)
        return (atan2(y, x) / toRad + 360).truncatingRemainder(dividingBy: 360)
    }
    public static func compass(_ degrees: Double) -> String {
        let names = ["N", "NE", "E", "SE", "S", "SW", "W", "NW"]
        return names[Int(((degrees.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360) + 22.5) / 45) % 8]
    }
    /// A distance for reading at a glance: "350 ft", "1.2 mi", "400 m", "2.1 km".
    public static func length(_ metres: Double, metric: Bool) -> String {
        if metric { return metres < 950 ? "\(Int((metres / 10).rounded()) * 10) m" : String(format: "%.1f km", metres / 1000) }
        let feet = metres * 3.28084
        return feet < 900 ? "\(Int((feet / 50).rounded()) * 50) ft" : String(format: "%.1f mi", metres / 1609.344)
    }
}

// MARK: - Planes overhead

public struct Aircraft: Equatable, Identifiable {
    public var id: String
    public var callsign: String
    public var type: String
    public var registration: String
    /// Feet. Nil on the ground or unknown.
    public var altitude: Int?
    /// Knots.
    public var speed: Int?
    public var track: Double?
    /// Feet a minute.
    public var climb: Int?
    /// Metres along the ground from the wearer, and the compass bearing to look along.
    public var distance: Double
    public var bearing: Double
    public var name: String { !callsign.isEmpty ? callsign : (!registration.isEmpty ? registration : id.uppercased()) }
}

public struct PlaneRoute: Equatable {
    public var from: String
    public var to: String
    public var airline: String
}

public enum Planes {
    /// Aircraft within `miles` nautical miles of a point, from the adsb.lol community network.
    public static func url(latitude: Double, longitude: Double, miles: Int = 15) -> URL? {
        URL(string: String(format: "https://api.adsb.lol/v2/lat/%.4f/lon/%.4f/dist/%d", latitude, longitude, miles))
    }
    public static func routeURL(callsign: String) -> URL? {
        let safe = callsign.filter { $0.isLetter || $0.isNumber }
        return safe.count >= 3 ? URL(string: "https://api.adsbdb.com/v0/callsign/" + safe) : nil
    }

    /// Airborne aircraft from the network's answer, nearest first.
    public static func parse(_ data: Data, latitude: Double, longitude: Double) -> [Aircraft]? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let list = json["ac"] as? [[String: Any]] else { return nil }
        func int(_ value: Any?) -> Int? { (value as? NSNumber).map { Int($0.doubleValue.rounded()) } }
        var found = [Aircraft]()
        for item in list {
            guard let lat = (item["lat"] as? NSNumber)?.doubleValue, let lon = (item["lon"] as? NSNumber)?.doubleValue else { continue }
            guard let altitude = int(item["alt_baro"]) ?? int(item["alt_geom"]) else { continue }        // "ground" or nothing: not overhead
            found.append(Aircraft(id: item["hex"] as? String ?? UUID().uuidString,
                                  callsign: (item["flight"] as? String ?? "").trimmingCharacters(in: .whitespaces),
                                  type: item["t"] as? String ?? "", registration: item["r"] as? String ?? "",
                                  altitude: altitude, speed: int(item["gs"]), track: (item["track"] as? NSNumber)?.doubleValue,
                                  climb: int(item["baro_rate"]) ?? int(item["geom_rate"]),
                                  distance: Geo.distance(latitude, longitude, lat, lon), bearing: Geo.bearing(latitude, longitude, lat, lon)))
        }
        return found.sorted { $0.distance < $1.distance }
    }

    /// Where a flight is going, from adsbdb's answer for its callsign.
    public static func route(_ data: Data) -> PlaneRoute? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let route = (json["response"] as? [String: Any])?["flightroute"] as? [String: Any] else { return nil }
        func place(_ value: Any?) -> String {
            guard let airport = value as? [String: Any] else { return "" }
            let city = airport["municipality"] as? String ?? airport["name"] as? String ?? ""
            let code = airport["iata_code"] as? String ?? airport["icao_code"] as? String ?? ""
            return city.isEmpty ? code : city
        }
        let from = place(route["origin"]), to = place(route["destination"])
        guard !from.isEmpty, !to.isEmpty else { return nil }
        return PlaneRoute(from: from, to: to, airline: (route["airline"] as? [String: Any])?["name"] as? String ?? "")
    }

    public static func card(_ planes: [Aircraft], index: Int, routes: [String: PlaneRoute], note: String, metric: Bool, arrows: Bool, screen: Screen) -> Card {
        let width = screen.columns
        guard !planes.isEmpty else {
            return Card(["Planes overhead"] + TextLayout.wrap(note.isEmpty ? "Nothing in the air within 15 miles right now." : note, width: width, maxLines: max(1, screen.rows - 1)))
        }
        let at = min(max(0, index), planes.count - 1), plane = planes[at]
        var lines = [TextLayout.fit(plane.name + (plane.type.isEmpty ? "" : "  " + plane.type) + "   \(at + 1)/\(planes.count)", width: width)]
        if let route = routes[plane.callsign] {
            lines.append(TextLayout.fit(route.from + (arrows ? " → " : " to ") + route.to, width: width))
            if !route.airline.isEmpty, screen.rows >= 5 { lines.append(TextLayout.fit(route.airline, width: width)) }
        }
        var flight = [String]()
        if let altitude = plane.altitude {
            flight.append(metric ? "\(Int((Double(altitude) * 0.3048 / 10).rounded()) * 10) m" : "\(Int((Double(altitude) / 100).rounded()) * 100) ft")
        }
        if let speed = plane.speed { flight.append(metric ? "\(Int((Double(speed) * 1.852).rounded())) km/h" : "\(Int((Double(speed) * 1.15078).rounded())) mph") }
        if let climb = plane.climb, abs(climb) >= 300 { flight.append(climb > 0 ? (arrows ? "↑" : "climbing") : (arrows ? "↓" : "descending")) }
        if !flight.isEmpty { lines.append(TextLayout.fit(flight.joined(separator: "  "), width: width)) }
        var where_ = Geo.length(plane.distance, metric: metric) + " " + Geo.compass(plane.bearing)
        if let track = plane.track { where_ += ", heading " + Geo.compass(track) }
        lines.append(TextLayout.fit(where_, width: width))
        return Card(Array(lines.prefix(screen.rows)))
    }
}

// MARK: - Walking tour

public struct NearbyPlace: Equatable, Identifiable {
    public var id: Int
    public var title: String
    public var summary: String
    public var latitude: Double
    public var longitude: Double
    public var distance: Double
    public var bearing: Double
}

public enum Tour {
    /// Wikipedia articles about places within `radius` metres, with their opening sentences.
    public static func url(latitude: Double, longitude: Double, radius: Int = 1500, language: String = "en") -> URL? {
        var parts = URLComponents(string: "https://\(language).wikipedia.org/w/api.php")
        parts?.queryItems = [
            ("action", "query"), ("format", "json"), ("generator", "geosearch"),
            ("ggscoord", String(format: "%.5f|%.5f", latitude, longitude)), ("ggsradius", String(min(10000, max(10, radius)))), ("ggslimit", "20"),
            ("prop", "extracts|coordinates"), ("exintro", "1"), ("explaintext", "1"), ("exsentences", "4"), ("exlimit", "20"), ("colimit", "20"),
        ].map { URLQueryItem(name: $0.0, value: $0.1) }
        return parts?.url
    }

    public static func parse(_ data: Data, latitude: Double, longitude: Double) -> [NearbyPlace]? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        guard let pages = (json["query"] as? [String: Any])?["pages"] as? [String: Any] else { return json["batchcomplete"] != nil ? [] : nil }
        var found = [NearbyPlace]()
        for case let page as [String: Any] in pages.values {
            guard let id = (page["pageid"] as? NSNumber)?.intValue, let title = page["title"] as? String,
                  let spot = (page["coordinates"] as? [[String: Any]])?.first,
                  let lat = (spot["lat"] as? NSNumber)?.doubleValue, let lon = (spot["lon"] as? NSNumber)?.doubleValue else { continue }
            let summary = (page["extract"] as? String ?? "").replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
            found.append(NearbyPlace(id: id, title: title, summary: summary, latitude: lat, longitude: lon,
                                     distance: Geo.distance(latitude, longitude, lat, lon), bearing: Geo.bearing(latitude, longitude, lat, lon)))
        }
        return found.sorted { $0.distance < $1.distance }
    }

    /// The same places measured from a new position, nearest first.
    public static func moved(_ places: [NearbyPlace], latitude: Double, longitude: Double) -> [NearbyPlace] {
        places.map { place in
            var place = place
            place.distance = Geo.distance(latitude, longitude, place.latitude, place.longitude)
            place.bearing = Geo.bearing(latitude, longitude, place.latitude, place.longitude)
            return place
        }.sorted { $0.distance < $1.distance }
    }

    public static func whereLine(_ place: NearbyPlace, metric: Bool) -> String {
        Geo.length(place.distance, metric: metric) + " " + Geo.compass(place.bearing)
    }

    public static func listCard(_ places: [NearbyPlace], index: Int, note: String, metric: Bool, screen: Screen) -> Card {
        let width = screen.columns
        guard !places.isEmpty else {
            return Card(["Walking tour"] + TextLayout.wrap(note.isEmpty ? "Nothing with a Wikipedia page within a mile of here." : note, width: width, maxLines: max(1, screen.rows - 1)))
        }
        let at = min(max(0, index), places.count - 1), place = places[at]
        let room = max(1, screen.rows - 3)
        return Card(["Nearby  \(at + 1)/\(places.count)"] + TextLayout.wrap(place.title, width: width, maxLines: room)
                    + [whereLine(place, metric: metric), place.summary.isEmpty ? "" : "Look up: read"].filter { !$0.isEmpty })
    }
}
